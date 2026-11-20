import AppKit
import Darwin

// A folder macOS keeps closed, asked for in the chat.
//
// Documents, Desktop, Downloads, iCloud Drive and other disks are closed to
// an app until you open them to it in System Settings › Privacy & Security
// › Files & Folders. A task's own terminal runs as Yab, so when its read of
// such a place fails, the switch it needs is Yab's. macOS asks once, at
// the first read; after a no it never asks again, and no API says which
// switches are on.
//
// So the agent says what it couldn't read and why it wanted it
// (`folder_access`), and Yab does the rest: tries the read itself, and only
// if that fails too puts a line where the chat's field is, with a picture
// of the switch to turn on (FolderSwitchPicture). Coming back to Yab tries
// the read again; when it works the line goes and the agent reads on.
// Choose File is the way round: the one file, copied where the task can
// read it, the folder left as it was.

/// A place macOS keeps closed until it is opened to the app.
enum ClosedPlace: String, Equatable {
    case documents, desktop, downloads, iCloud, removable, network

    /// Where a path lies, if it is in such a place.
    nonisolated static func of(_ path: String) -> ClosedPlace? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let full = (path as NSString).expandingTildeInPath
        func under(_ inside: String) -> Bool { full == home + inside || full.hasPrefix(home + inside + "/") }
        if under("/Documents") { return .documents }
        if under("/Desktop") { return .desktop }
        if under("/Downloads") { return .downloads }
        if under("/Library/Mobile Documents") { return .iCloud }
        if full.hasPrefix("/Volumes/") {
            let parts = URL(fileURLWithPath: full).pathComponents
            guard parts.count > 2 else { return nil }
            let values = try? URL(fileURLWithPath: "/Volumes/" + parts[2]).resourceValues(forKeys: [.volumeIsLocalKey])
            return values?.volumeIsLocal == false ? .network : .removable
        }
        return nil
    }

    /// Its name as the Finder says it, in the Mac's language.
    var name: String {
        switch self {
        case .iCloud: return "iCloud Drive"
        case .removable: return "Removable Volumes"
        case .network: return "Network Volumes"
        default:
            let home = FileManager.default.homeDirectoryForCurrentUser
            let folder = home.appendingPathComponent(rawValue.capitalized)
            return FileManager.default.displayName(atPath: folder.path)
        }
    }

    /// The switch's own words in Files & Folders.
    var switchName: String {
        switch self {
        case .documents, .desktop, .downloads:
            // English says "Documents Folder"; other languages put the
            // folder's own name in their own frame, close enough to find.
            return Locale.preferredLanguages.first?.hasPrefix("en") ?? true ? "\(name) Folder" : name
        default: return name
        }
    }
}

/// What the line asks, and how far it has got.
struct FolderAsk: Equatable {
    enum Stage: Equatable {
        /// Closed: the read failed, Yab's too.
        case closed
        /// Back in Yab: reading again.
        case checking
        /// Back from Settings, and still closed.
        case stillClosed
        /// The folder opens now, this one file doesn't.
        case folderOnly
    }

    /// What the agent couldn't read, a file or a folder.
    let path: String
    let place: ClosedPlace
    let file: Bool
    /// What it wanted it for, in its words: "To read the Q3 update for the broadcast".
    let reason: String
    /// The task's name, for the line.
    let task: String
    var stage: Stage = .closed
    /// Settings was opened from the line: coming back reads again.
    var sent = false
    /// The last read: when, and what macOS said.
    var checked = Date()
    var error = ""

    var name: String { (path as NSString).lastPathComponent }

    var question: String {
        stage == .checking ? "Checking \(place.name)…" : "\(place.name) for \(task)"
    }

    /// Choose File leads when one known file is all it needs, or when the
    /// folder is open and this file still isn't; Open Settings when it may
    /// have to look through the folder.
    var choosing: Bool { file || stage == .folderOnly }
}

@MainActor
final class FolderAccess {
    static let shared = FolderAccess()

    /// How a request ended, kept for the agent's call to collect.
    enum Outcome: Equatable {
        case opened
        case chose([URL])
        case declined
    }

    private var outcomes: [String: Outcome] = [:]
    /// Places the person said Not Now to, by task: not asked again.
    private var declined: [String: Set<ClosedPlace>] = [:]
    private var watching: Any?

    private static func key(_ session: String, _ path: String) -> String { session + "\u{0}" + path }

    // MARK: - reading, as Yab

    enum Read: Equatable {
        case open
        /// macOS keeps it closed; the folder itself may open.
        case closed(String, folderOpens: Bool)
        /// Not there, or not readable for another reason than macOS's.
        case other(String)
    }

    /// The read the agent tried, tried by Yab. Off the main thread: a first
    /// read can wait on the system's question.
    nonisolated static func read(_ path: String, file: Bool) async -> Read {
        let shut = Store.testing ? ProcessInfo.processInfo.environment["YAB_FOLDER_SHUT"] : nil
        return await Task.detached(priority: .userInitiated) {
            // A test world's closed folder: a file saying how closed, since
            // a probe can't turn macOS's switches.
            if let shut, ClosedPlace.of(path) != nil, let how = try? String(contentsOfFile: shut, encoding: .utf8) {
                switch how.trimmingCharacters(in: .whitespacesAndNewlines) {
                case "closed": return .closed("Operation not permitted", folderOpens: false)
                case "file": return .closed("Operation not permitted", folderOpens: file)
                default: return .open
                }
            }
            func listable(_ folder: String) -> Bool {
                guard let dir = opendir(folder) else { return false }
                closedir(dir)
                return true
            }
            let tried: Int32
            if file {
                let fd = open(path, O_RDONLY)
                if fd >= 0 { close(fd); return .open }
                tried = errno
            } else {
                if listable(path) { return .open }
                tried = errno
            }
            let said = String(cString: strerror(tried))
            guard tried == EPERM || tried == EACCES else { return .other(said) }
            let folder = file ? (path as NSString).deletingLastPathComponent : path
            return .closed(said, folderOpens: file && listable(folder))
        }.value
    }

    // MARK: - the agent's call

    /// `folder_access`: what the agent hears now, or nil once the line is
    /// put up and the call is to wait on it (Mcp's patient).
    func request(_ session: Agents.Session, path raw: String, reason: String, browser: Browser) async -> [String: Any] {
        let path = (raw as NSString).expandingTildeInPath
        let agents = Agents.shared
        if let outcome = outcomes.removeValue(forKey: Self.key(session.id, path)) {
            switch outcome {
            case .opened: return ["text": "\(Brand.name) can read \(path) now. Read it again and carry on."]
            case .chose(let copies):
                return ["text": "The person chose a file instead of opening the folder: "
                        + copies.map(\.path).joined(separator: ", ")
                        + ". Read that copy; the folder stays closed, so don't ask for it again."]
            case .declined:
                return ["error": "The person said not now. Carry on without it, and don't ask for it again."]
            }
        }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        let file = exists ? !isDir.boolValue : !(path as NSString).pathExtension.isEmpty
        guard let place = ClosedPlace.of(path) else {
            switch await Self.read(path, file: file) {
            case .open: return ["text": "\(Brand.name) can read \(path). Read it again."]
            case .closed(let said, _), .other(let said):
                return ["error": "\(path) isn't in a place macOS keeps closed, so there is no switch for the person to turn on (\(said)). Don't ask them about it."]
            }
        }
        if declined[session.id]?.contains(place) == true {
            return ["error": "The person said not now to \(place.name) for this task. Carry on without it."]
        }
        switch await Self.read(path, file: file) {
        case .open:
            return ["text": "\(Brand.name) can read \(path) now. Read it again and carry on."]
        case .other(let said):
            return ["error": "\(path): \(said). That isn't something the person can open in Settings."]
        case .closed(let said, let folderOpens):
            guard let tab = agents.askTab(for: session.id, in: browser) else { return ["error": "no tab to ask in"] }
            if tab.permit != nil || tab.handoff != nil {
                return ["error": "another question is waiting in that tab; try again in a moment"]
            }
            let words = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            var ask = FolderAsk(path: path, place: place, file: file,
                                reason: String((words.isEmpty ? "To read \((path as NSString).lastPathComponent)" : words).prefix(160)),
                                task: session.name)
            ask.stage = folderOpens ? .folderOnly : .closed
            ask.error = said
            agents.ask(tab, AgentPermit(kind: .folder(ask), session: session.id, detail: ""))
            agents.showAsk(tab, session: session.id, in: browser)
            agents.note(session, "Waiting for \(place.name)")
            watch()
            return ["error": "asking the person to open \(place.name)", "asking": true, "tab": Bench.short(tab)]
        }
    }

    // MARK: - the line's buttons

    func openSettings(_ tab: Tab) {
        guard var ask = Self.ask(on: tab) else { return }
        ask.sent = true
        put(ask, on: tab)
        if Store.testing { return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The Mac's own panel, at the file; what is chosen is copied where the
    /// task can read it, as the person's, and the line goes.
    func choose(_ tab: Tab) {
        guard let ask = Self.ask(on: tab), let permit = tab.permit else { return }
        // A test world's choice, the panel being out of a probe's reach.
        if Store.testing, let picked = ProcessInfo.processInfo.environment["YAB_FOLDER_PICK"] {
            end(tab, .chose(copy([URL(fileURLWithPath: picked)], for: permit.session)))
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = !ask.file
        panel.prompt = "Choose"
        panel.message = ask.reason
        // A file's own URL opens the panel on it, chosen.
        panel.directoryURL = URL(fileURLWithPath: ask.path)
        let done: (NSApplication.ModalResponse) -> Void = { [weak self, weak tab] answer in
            guard let self, let tab, answer == .OK, tab.permit == permit else { return }
            let copies = self.copy(panel.urls, for: permit.session)
            guard !copies.isEmpty else { return }
            self.end(tab, .chose(copies))
        }
        if let window = Agents.front(of: tab).flatMap({ BrowserWindows.shared.window(for: $0) }) {
            panel.beginSheetModal(for: window, completionHandler: done)
        } else {
            panel.begin(completionHandler: done)
        }
    }

    /// Not now: the agent hears it and goes on without.
    func decline(_ tab: Tab) {
        guard let ask = Self.ask(on: tab), let permit = tab.permit else { return }
        declined[permit.session, default: []].insert(ask.place)
        end(tab, .declined)
    }

    /// What was chosen, into a folder of the task's outside the closed
    /// places: the panel opened the file to Yab, not to the task's terminal.
    private func copy(_ urls: [URL], for session: String) -> [URL] {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("yab-chosen").appendingPathComponent(String(session.suffix(8)))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return urls.compactMap { url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= 100 << 20 else { return nil }
            let target = folder.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: target)
            return (try? FileManager.default.copyItem(at: url, to: target)) != nil ? target : nil
        }
    }

    // MARK: - back in Yab

    /// Coming back to Yab reads again, for every line Settings was opened from.
    private func watch() {
        guard watching == nil else { return }
        watching = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FolderAccess.shared.recheck() }
        }
    }

    func recheck() {
        let tabs = BrowserWindows.shared.browsers.flatMap(\.tabs).filter { Self.ask(on: $0)?.sent == true }
        if tabs.isEmpty, let watching {
            NotificationCenter.default.removeObserver(watching)
            self.watching = nil
        }
        for tab in tabs { Task { await check(tab) } }
    }

    func check(_ tab: Tab) async {
        guard var ask = Self.ask(on: tab), ask.stage != .checking else { return }
        let before = ask.stage
        ask.stage = .checking
        put(ask, on: tab)
        // Never a flash: a read is quicker than the eye.
        async let read = Self.read(ask.path, file: ask.file)
        try? await Task.sleep(for: .milliseconds(450))
        let got = await read
        guard var now = Self.ask(on: tab), now.path == ask.path else { return }
        now.checked = Date()
        switch got {
        case .open:
            end(tab, .opened)
            return
        case .closed(let said, let folderOpens):
            now.error = said
            now.stage = folderOpens ? .folderOnly : .stillClosed
        case .other(let said):
            now.error = said
            now.stage = before == .closed ? .stillClosed : before
        }
        put(now, on: tab)
    }

    // MARK: - the line

    static func ask(on tab: Tab) -> FolderAsk? {
        if case .folder(let ask) = tab.permit?.kind { return ask }
        return nil
    }

    private func put(_ ask: FolderAsk, on tab: Tab) {
        guard let permit = tab.permit else { return }
        tab.permit = AgentPermit(kind: .folder(ask), session: permit.session, detail: permit.detail)
        let words = ask.question
        if tab.handoff != words { tab.handoff = words }
    }

    /// The line goes and the waiting call collects what came of it.
    private func end(_ tab: Tab, _ outcome: Outcome) {
        guard let ask = Self.ask(on: tab), let permit = tab.permit else { return }
        outcomes[Self.key(permit.session, ask.path)] = outcome
        if let session = Agents.shared.session(permit.session) {
            switch outcome {
            case .opened: Agents.shared.note(session, "\(ask.place.name) opened")
            case .chose(let copies): Agents.shared.note(session, "Chose \(copies.map(\.lastPathComponent).joined(separator: ", "))")
            case .declined: Agents.shared.note(session, "\(ask.place.name): not now")
            }
        }
        tab.permit = nil
        Agents.shared.handBack(tab)
    }
}
