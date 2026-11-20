import Foundation
import SyncKit

// Tasks the iPhone sends this Mac (docs/sync.md, "Tasks from the iPhone"):
// a `taskcommand` record, written by the phone, for this Mac, carrying the
// read-only epoch this Mac said in its `commandcap` record. Each is reserved
// once in the journal (TaskLaunch: a relaunch or a replay never runs it
// again), then run by the Tasks agent with the read-only MCP server, every
// call of it answered by SyncTaskRead, and told back as the task's `task`
// record. One the Mac can't run is told back as failed, with why.

extension SyncCenter {
    /// This run of Yab's read-only epoch: a request sent for an earlier run
    /// is said to be too old rather than run on a Mac that restarted.
    nonisolated static let taskEpoch = UUID().uuidString.lowercased()

    /// How late a task may come and still run.
    nonisolated static let taskLifetime: TimeInterval = 12 * 3600

    /// The tasks waiting for this Mac, each taken once.
    func takeTasks() {
        guard let journal, let client, client.journal === journal, state == .live, let reader = taskReader,
              let browser = BrowserWindows.shared.browsers.first(where: { $0.windowID == nil }) else { return }
        let account = client.seal.account
        let device = Self.deviceID
        let phones = devices
        for record in journal.all(TaskRecords.requestCollection) where record.alive() {
            guard let body = record["body"]?.string,
                  let peek = try? JSONDecoder().decode(TaskRecords.Request.self, from: Data(body.utf8)), peek.mac == device,
                  let request = try? TaskRecords.Request.read(record, account: account, phone: peek.phone, mac: device),
                  let epoch = request.readOnlyEpoch else { continue }
            do {
                if let mapping = try journal.taskMapping(request: request.id, account: account, device: device) {
                    interruptTask(mapping, request: request, reader: reader)
                    continue
                }
                // The phone among the account's devices first. One that
                // joined since the list was read asks for it again, at most
                // every ten seconds; the list coming back takes the task.
                guard phones.contains(where: { $0.id == request.phone && !$0.revoked
                    && $0.isMobile }) else {
                    if !phones.contains(where: { $0.id == request.phone }), Date().timeIntervalSince(taskAskedForDevices) > 10 {
                        taskAskedForDevices = Date()
                        refreshDevices()
                    }
                    continue
                }
                let picked = ModelDefaults.shared.pick(.tasks)
                var cli = ChatAgent(rawValue: picked.cli)?.rawValue ?? ChatAgent.claude.rawValue
                // Auto goes to a plan that is signed in: Claude out, ChatGPT
                // in (or the reverse) takes the task, as a chat would.
                let plans = PlanAccounts.shared
                let other = Agents.other(cli)
                let usable = ModelDefaults.shared[.tasks].cli == nil
                if usable, cli == "claude" || cli == "codex", plans.allSignedOut(cli), !plans.allSignedOut(other),
                   AgentSetup.connected(other), AgentModels.here(other) { cli = other }
                guard case let .reserved(mapping) = try TaskLaunch.reserve(record, client: client, knownPhones: phones,
                                                                          publicSpace: request.space, cli: cli) else { continue }
                // Every plan takes the iPhone's tasks (ChatAgent): Cursor
                // and Gemini too, on the same read-only tools, never Claude
                // in their place.
                if let refusal = GeminiSupport.launchRefusal(cli, textOnly: false, remote: true) {
                    try failTask(mapping, request: request, reason: refusal)
                    continue
                }
                if let reason = Self.taskRefusal(request, epoch: epoch, hasSpace: SyncTaskRead.has(space: request.space, in: browser)) {
                    try failTask(mapping, request: request, reason: reason)
                    continue
                }
                let session = try Agents.shared.prepareRemoteTask(mapping, journal: journal, account: account, device: device)
                if picked.cli == cli {
                    if let model = picked.model { session.model = model }
                    if let effort = picked.effort { session.effort = effort }
                }
                do {
                    try reader.register(mapping)
                } catch {
                    session.result = "\(Brand.name) on your Mac couldn't start this task."
                    session.state = .failed
                    try failTask(mapping, request: request, reason: session.result)
                    continue
                }
                Agents.shared.launchRemoteTask(session)
            } catch {
                NSLog("sync: a task from iPhone wasn't taken: %@", String(describing: error))
            }
        }
    }

    /// Why a reserved task can't run here, or nil.
    nonisolated static func taskRefusal(_ request: TaskRecords.Request, epoch: String, hasSpace: Bool, now: Date = Date()) -> String? {
        if epoch != taskEpoch { return "\(Brand.name) on your Mac restarted before it took this task. Send it again." }
        if now.timeIntervalSince1970 - request.created > taskLifetime { return "This task reached your Mac too late. Send it again." }
        if !hasSpace { return "That space isn't on your Mac." }
        return nil
    }

    /// A task taken before: running, or told already, it is left alone;
    /// one whose session is gone (Yab quit while it ran) ends as failed.
    private func interruptTask(_ mapping: TaskLaunch.Mapping, request: TaskRecords.Request, reader: SyncTaskRead) {
        guard let journal, let client else { return }
        let session = Agents.shared.session(mapping.session).flatMap { $0.remoteTask?.mapping == mapping ? $0 : nil }
        if session?.state.live == true { return }
        let previous = try? journal.taskObservation(mapping: mapping, account: mapping.account, device: mapping.mac)
        if let previous, [TaskRecords.Status.done, .failed, .stopped].contains(previous.status) { return }
        // Ended while the line was down: SyncTaskRead tells how.
        if session != nil, reader.owns(mapping.session) { return reader.resume() }
        let revision = (previous?.revision ?? 0) + 1
        guard revision > 0, let failed = try? TaskRecords.Observation(
            request: request, revision: revision, session: mapping.session, status: .failed,
            title: previous?.title ?? Chat.title(from: request.words),
            progress: previous == nil ? "\(Brand.name) on your Mac quit before this task started. Send it again."
                                      : "\(Brand.name) on your Mac quit before this task finished.") else { return }
        _ = try? TaskObservation.checkpoint(failed, mapping: mapping, client: client, knownPhones: devices)
    }

    /// The task's first and last word: failed, with why.
    private func failTask(_ mapping: TaskLaunch.Mapping, request: TaskRecords.Request, reason: String) throws {
        guard let client else { return }
        let observation = try TaskRecords.Observation(request: request, revision: 1, session: mapping.session, status: .failed,
                                                      title: Chat.title(from: request.words), progress: reason)
        try TaskObservation.checkpoint(observation, mapping: mapping, client: client, knownPhones: devices)
    }
}
