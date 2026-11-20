import AppKit
import CoreText
import Darwin
import os

// How long a launch takes, from the process starting to the window's first
// frame on screen and to the first page loaded in it. The moments are kept
// every launch, a handful of numbers; `./bench startup` reads them, and with
// YAB_STARTUP_TIMING=1 they are also printed and added to startup.log in the
// world's folder once the first page is in, one line of JSON a launch.
//
// Every moment is counted from when the kernel started the process, so the
// time dyld and the Swift runtime take before main is counted too, as a
// person waiting for the window counts it: main (the app's first line),
// launched (AppKit done launching), window (the first pass of the main loop
// with the window in, its first frame sent), shown (the window server says
// it is on screen), page (the first page loaded, in any tab).
//
// What the launch does on the main thread is timed stage by stage too
// (`stage`), and each stage is an interval for Instruments' os_signpost
// track (subsystem net.serubin.pane, category launch). Work nobody sees in
// the first window waits (`later`) until the first page is in, or a few
// seconds after the first frame, and then runs one piece at a time, so it
// never stands between the window and the person (docs/lazy-launch.md).

@MainActor
enum Startup {
    /// Milliseconds from the process starting, by the name of the moment.
    private(set) static var marks: [String: Double] = [:]
    private static var order: [String] = []
    private static var watching: NSObjectProtocol?
    private static var passes: CFRunLoopObserver?
    private static var told = false

    static let printing = ProcessInfo.processInfo.environment["YAB_STARTUP_TIMING"] == "1"

    /// A launch change that is on, unless a test run turns it off with
    /// YAB_LAUNCH_<NAME>=0 to measure what it saves (evals/stand/startup.py,
    /// docs/evidence/night-startup-2026-10-14.md).
    nonisolated static func flag(_ name: String) -> Bool {
        ProcessInfo.processInfo.environment["YAB_LAUNCH_" + name] != "0"
    }

    /// The process's own start, in the same clock as `Date()`.
    private static let began: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1e6)
    }()

    /// The first time `name` happens, from the process's start. Later ones
    /// are not moments of the launch.
    static func mark(_ name: String) {
        guard marks[name] == nil else { return }
        marks[name] = (Date().timeIntervalSince(began) * 10000).rounded() / 10
        order.append(name)
        if name == "page" { tell(); beginLater() }
        if name == "window" { DispatchQueue.main.asyncAfter(deadline: .now() + laterAfterFrame) { beginLater() } }
    }

    // MARK: - stages

    static let signposter = OSSignposter(subsystem: Store.productionBundleID, category: "launch")
    /// What each stage held the main thread, in ms, in the order they ran.
    private(set) static var stages: [(name: String, ms: Double)] = []

    /// `body`, timed as the launch stage `name`. A stage run again (an
    /// extension loaded twice) is kept twice.
    @discardableResult
    static func stage<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval("stage", id: signposter.makeSignpostID(), "\(name, privacy: .public)")
        let start = CACurrentMediaTime()
        defer {
            stages.append((name, ((CACurrentMediaTime() - start) * 10000).rounded() / 10))
            signposter.endInterval("stage", state)
        }
        return try body()
    }

    /// Main-thread time of something that runs many times, summed until
    /// the window's first frame (a stage named "before window: NAME").
    private(set) static var accrued: [String: Double] = [:]

    static func accrue(_ name: String, ms: Double) {
        guard marks["window"] == nil else { return }
        accrued[name, default: 0] += ms
    }

    /// An asynchronous stage's main-thread part, measured by its caller.
    static func note(_ name: String, ms: Double) {
        stages.append((name, (ms * 10).rounded() / 10))
    }

    // MARK: - later

    /// How long after the first frame the waiting work starts when no page
    /// loads (a window with no tabs, or a page that never finishes).
    static let laterAfterFrame: TimeInterval = 3
    /// Between two pieces of waiting work: a frame or two for whatever the
    /// person does meanwhile.
    static let laterGap: TimeInterval = 0.05
    private static var waiting: [(name: String, work: () -> Void)] = []
    private static var laterBegun = false
    /// Whether the waiting work has started running (bench, tests).
    static var laterStarted: Bool { laterBegun }

    /// `work`, once the launch is over: after the first page is in, or
    /// three seconds after the first frame, one piece per turn of the main
    /// loop, a little apart. Once the launch is over, at once.
    static func later(_ name: String, _ work: @escaping () -> Void) {
        if laterBegun && waiting.isEmpty {
            stage("later " + name, work)
            return
        }
        waiting.append((name, work))
        // A Yab that never draws a window (hidden for agents, opened at
        // login) is past its launch too, soon enough.
        if marks["window"] == nil, waiting.count == 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + laterAfterFrame * 2) { beginLater() }
        }
    }

    /// The waiting work, now, from where it was (bench, tests).
    static func beginLater() {
        guard !laterBegun else { return }
        laterBegun = true
        runNext()
    }

    private static func runNext() {
        guard !waiting.isEmpty else { return }
        let next = waiting.removeFirst()
        stage("later " + next.name, next.work)
        guard !waiting.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + laterGap) { runNext() }
    }

    /// The window's first frame: the end of the first pass of the main
    /// loop with the window ordered in, after Core Animation has sent what
    /// it draws to the window server ("window"); and the window server
    /// saying it is on screen ("shown"), which a locked screen or a window
    /// behind others never says.
    static func watch(_ window: NSWindow) {
        guard marks["window"] == nil, passes == nil else { return }
        let passes = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) { observer, _ in
            MainActor.assumeIsolated {
                guard window.isVisible else { return }
                mark("window")
                CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
                Startup.passes = nil
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), passes, .commonModes)
        self.passes = passes
        if window.occlusionState.contains(.visible), window.isVisible { return mark("shown") }
        watching = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard window.occlusionState.contains(.visible) else { return }
                mark("shown")
                if let watching { NotificationCenter.default.removeObserver(watching) }
                watching = nil
            }
        }
    }

    static var report: [String: Any] {
        ["marks": marks, "order": order, "later": laterBegun, "waiting": waiting.map(\.name),
         // The menu bar as it is now: its menus and how many items they hold.
         "menus": (NSApp.mainMenu?.items ?? []).map { "\($0.title) \($0.submenu?.items.count ?? 0)" },
         "stages": stages.map { [$0.name, $0.ms] as [Any] }
             + accrued.sorted { $0.key < $1.key }.map { ["before window: " + $0.key, ($0.value * 10).rounded() / 10] as [Any] }]
    }

    private static func tell() {
        guard printing, !told else { return }
        told = true
        let line = order.map { "\($0)=\(marks[$0] ?? 0)" }.joined(separator: " ")
        print("startup ms " + line)
        fflush(stdout)
        var entry: [String: Any] = marks
        entry["at"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        let file = Store.file("startup.log")
        if let handle = try? FileHandle(forWritingTo: file) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data + Data("\n".utf8))
            try? handle.close()
        } else {
            try? (data + Data("\n".utf8)).write(to: file)
        }
    }
}

/// What the system makes on the main thread the first time a page is made,
/// started at the process's first line on a thread of its own, so the main
/// thread finds it done: the OpenGL renderers and Metal devices WebKit asks
/// for its GPU process's screen properties (CGLQueryRendererInfo, before
/// the first window), and the fonts registry it reads when the first page's
/// process starts (YAB_LAUNCH_GPU_WARM=0, YAB_LAUNCH_FONT_WARM=0 to measure
/// without; docs/evidence/night-startup-2026-10-14.md).
enum LaunchWarm {
    static func start() {
        let gpu = Startup.flag("GPU_WARM"), fonts = Startup.flag("FONT_WARM")
        guard gpu || fonts else { return }
        Thread.detachNewThread {
            if gpu, let gl = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY),
               let query = dlsym(gl, "CGLQueryRendererInfo"), let destroy = dlsym(gl, "CGLDestroyRendererInfo") {
                typealias Query = @convention(c) (UInt32, UnsafeMutablePointer<OpaquePointer?>, UnsafeMutablePointer<Int32>) -> Int32
                typealias Destroy = @convention(c) (OpaquePointer?) -> Int32
                var info: OpaquePointer?
                var count: Int32 = 0
                if unsafeBitCast(query, to: Query.self)(0xFFFF_FFFF, &info, &count) == 0, info != nil {
                    _ = unsafeBitCast(destroy, to: Destroy.self)(info)
                }
            }
            if fonts { _ = CTFontManagerCopyAvailableFontURLs() }
        }
    }
}
