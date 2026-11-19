import AppKit
import Darwin
import os
import YabStore

/// A restart is performed by the helper sealed inside the destination app.
/// No shell source, temporary executable or arbitrary command is accepted.
public enum Relaunch {
    public static let flag = "--relaunch-after"
    public static let installFlag = "--install-after"
    public static let environmentKeys = ["YAB_PROBE", "YAB_FEED", "YAB_HISTORY", "YAB_TEST_KEYCHAIN"]
    /// How long the app and what it started may take to wind down.
    static let patience: TimeInterval = 120
    private static let log = Logger(subsystem: Store.productionBundleID, category: "relaunch")

    public struct Request: Equatable {
        public let pid: pid_t
        public let behind: Bool
        public let installing: Int?
        public let reopens: Bool

        public init?(arguments: [String]) {
            guard arguments.count >= 2, let pid = pid_t(arguments[1]), pid > 1 else { return nil }
            if arguments[0] == Relaunch.flag {
                guard arguments.count == 2 || (arguments.count == 3 && arguments[2] == "--background") else { return nil }
                installing = nil
                reopens = true
                behind = arguments.count == 3
            } else if arguments[0] == Relaunch.installFlag {
                guard arguments.count >= 3, let build = Int(arguments[2]), build > 0 else { return nil }
                let options = Array(arguments.dropFirst(3))
                guard Set(options).count == options.count,
                      options.allSatisfy({ ["--reopen", "--background"].contains($0) }),
                      !options.contains("--background") || options.contains("--reopen") else { return nil }
                installing = build
                reopens = options.contains("--reopen")
                behind = options.contains("--background")
            } else { return nil }
            self.pid = pid
        }
    }

    public static func environment(_ source: [String: String]) -> [String: String] {
        source.filter { environmentKeys.contains($0.key) }
    }

    public static func start(bundle: URL, behind: Bool = false, installing: Int? = nil, reopen: Bool = true) throws {
        LaunchJournal.record("relaunch.request", target: bundle)
        let helper = Process()
        helper.executableURL = bundle.appendingPathComponent("Contents/MacOS/PaneUpdater")
        if let installing {
            helper.arguments = [installFlag, String(ProcessInfo.processInfo.processIdentifier), String(installing)]
                + (reopen ? ["--reopen"] : []) + (behind ? ["--background"] : [])
        } else {
            helper.arguments = [flag, String(ProcessInfo.processInfo.processIdentifier)] + (behind ? ["--background"] : [])
        }
        // Do not inherit DYLD overrides, shell startup configuration or a
        // parent agent's credentials into the restart helper.
        helper.environment = environment(ProcessInfo.processInfo.environment)
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.runValidated()
    }

    /// Called before the updater opens preferences or checks its feed.
    /// Relaunch only this helper's own containing application, and only once
    /// nothing LaunchServices counts as that application is left running.
    ///
    /// The app is not the only one: YabCore makes itself a UI element of the
    /// same bundle (LSBundlePath Pane.app, net.serubin.pane), and it winds down
    /// after the app has gone, the longer the more tabs and extensions it had.
    /// An open of the bundle in that time finds "Yab" running in that
    /// YabCore on its way out and launches nothing: Yab closed and never
    /// came back (register 2596; after a swap YabCore even runs from
    /// yab.app.old while LaunchServices still files it under yab.app). So, as
    /// Sparkle's installer does for its app, wait for the exit itself (kqueue,
    /// NOTE_EXIT) and then for LaunchServices to see every instance of this
    /// bundle terminated (NSRunningApplication.isTerminated), and only then open.
    @MainActor public static func run(_ request: Request) async -> Bool {
        LaunchJournal.record("relaunch.helper.entry", child: request.pid)
        let identifier = Bundle.main.bundleIdentifier
        let destination = Swap.target
        // A live, unrelated PID is never waited on.
        if let app = NSRunningApplication(processIdentifier: request.pid), app.bundleIdentifier != identifier {
            log.error("pid \(request.pid) is not this app")
            return false
        }
        let deadline = Date().addingTimeInterval(patience)
        // Its own: taken while the app still runs, YabCore is its child.
        let family = instances(identifier: identifier, parent: request.pid)
        guard await exited(request.pid, by: deadline) else {
            log.error("pid \(request.pid) did not exit")
            return false
        }
        var waiting = family, seen = Set<pid_t>()
        while true {
            waiting += instances(identifier: identifier, parent: nil)
            guard let next = waiting.first(where: { !seen.contains($0.processIdentifier) }) else { break }
            seen.insert(next.processIdentifier)
            guard await terminated(next, by: deadline) else {
                log.error("\(next.processIdentifier) of this app still runs, nothing opened")
                return false
            }
        }
        var installed = true
        if let build = request.installing {
            do { try Swap.completePrepared(build: build, proceed: { instances(identifier: identifier, parent: nil).isEmpty }) }
            catch is Swap.Stopped { installed = false }
            catch {
                installed = false
                Update.Failure.keep(Update.Failure.reason(error), in: Store.settings)
                log.error("prepared update failed: \(String(describing: error), privacy: .public)")
            }
            Store.settings.synchronize()
        }
        guard request.reopens else { return installed }
        let configuration = NSWorkspace.OpenConfiguration()
        // The wait above deliberately excludes independent copies. Do not
        // then let Launch Services substitute one of those copies for the
        // bundle whose sealed helper was asked to restart it.
        configuration.allowsRunningApplicationSubstitution = false
        configuration.activates = !request.behind
        configuration.environment = environment(ProcessInfo.processInfo.environment)
        let installationSucceeded = installed
        return await withCheckedContinuation { done in
            LaunchJournal.record("relaunch.open", target: destination)
            NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { app, error in
                if let app { LaunchJournal.record("relaunch.opened", target: app.bundleURL, child: app.processIdentifier) }
                if let error { log.error("open failed: \(error.localizedDescription, privacy: .public)") }
                done.resume(returning: app != nil && error == nil && installationSucceeded)
            }
        }
    }

    /// What LaunchServices runs as this app: from this bundle or the one a
    /// swap set aside, or, while the app runs, anything it started (a copy
    /// relocated by Arrival leaves its YabCore at the old place). Never this
    /// helper, and never another copy of Yab somewhere else.
    @MainActor static func instances(identifier: String?, parent: pid_t?) -> [NSRunningApplication] {
        guard identifier != nil else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        let bundles = [Swap.target, Swap.aside]
        return NSWorkspace.shared.runningApplications.filter { app in
            app.processIdentifier != me && !app.isTerminated
                && (containsApplication(bundles, app.bundleURL) || parent.map { ppid(of: app.processIdentifier) == $0 } == true)
        }
    }

    /// YabCore has its own identity and a nested bundle since 0.47.8. A
    /// bundle-id query for Yab alone misses the engine still using its files.
    public static func containsApplication(_ bundles: [URL], _ url: URL?) -> Bool {
        guard let url else { return false }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return bundles.contains {
            let root = $0.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            return path.starts(with: root)
        }
    }

    /// Whether `url` is one of `bundles`, as paths with links resolved.
    public static func contains(_ bundles: [URL], _ url: URL?) -> Bool {
        guard let url else { return false }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return bundles.contains { $0.resolvingSymlinksInPath().standardizedFileURL.path == path }
    }

    private static func ppid(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// The process gone, as the kernel says it (EVFILT_PROC, NOTE_EXIT), not
    /// as anyone's list of applications does. A pid already gone counts.
    static func exited(_ pid: pid_t, by deadline: Date) async -> Bool {
        await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                let queue = kqueue()
                guard queue >= 0 else { done.resume(returning: kill(pid, 0) != 0 && errno == ESRCH); return }
                defer { close(queue) }
                var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                                    fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
                guard kevent(queue, &change, 1, nil, 0, nil) == 0 else {
                    done.resume(returning: errno == ESRCH)
                    return
                }
                let wait = max(0, deadline.timeIntervalSinceNow)
                var timeout = timespec(tv_sec: Int(wait), tv_nsec: Int((wait - wait.rounded(.down)) * 1e9))
                var event = kevent()
                done.resume(returning: kevent(queue, nil, 0, &event, 1, &timeout) == 1)
            }
        }
    }

    /// The process gone (kqueue) and LaunchServices done with it: its
    /// `isTerminated` observed, as Sparkle's installer waits for its target
    /// app, and asked again of LaunchServices itself every 50 ms, since a
    /// helper with no NSApplication can't count on the observation alone.
    @MainActor static func terminated(_ app: NSRunningApplication, by deadline: Date) async -> Bool {
        let pid = app.processIdentifier
        guard await exited(pid, by: deadline) else { return false }
        let wait = Waiter(app, deadline: deadline)
        if wait.gone() { return true }
        return await withCheckedContinuation { done in
            // The body runs at once, on the caller's actor: the main one.
            MainActor.assumeIsolated { wait.start(done) }
        }
    }

    @MainActor private final class Waiter {
        let app: NSRunningApplication
        let deadline: Date
        var done: CheckedContinuation<Bool, Never>?
        var observation: NSKeyValueObservation?

        init(_ app: NSRunningApplication, deadline: Date) {
            self.app = app
            self.deadline = deadline
        }

        func gone() -> Bool { app.isTerminated || NSRunningApplication(processIdentifier: app.processIdentifier) == nil }

        func start(_ done: CheckedContinuation<Bool, Never>) {
            self.done = done
            observation = app.observe(\.isTerminated, options: [.new]) { [weak self] app, _ in
                guard app.isTerminated else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.finish(true) } }
            }
            check()
        }

        func check() {
            guard done != nil else { return }
            if gone() { finish(true); return }
            guard Date() < deadline else { finish(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { self.check() } }
        }

        func finish(_ terminated: Bool) {
            observation?.invalidate()
            observation = nil
            done?.resume(returning: terminated)
            done = nil
        }
    }
}
