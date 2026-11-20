import AppKit
import Combine
import SwiftUI

// Open yab, the one thing in the disk image. Double-clicked, it puts yab
// into Applications, opens it, and puts the image away; that takes under a
// second, and nothing of its own is shown while it happens. A window comes
// only when there is something to say or to choose: the copy is slow, an
// older yab is open, Applications is locked, this Mac can't run yab, or
// something went wrong.
//
// Built by build.sh into build/installer, around a copy of build/yab.app
// in its Resources. The updater never sees it: updates are still yab.zip.

@MainActor
final class Installer: ObservableObject {
    enum Scene: Equatable {
        /// Working, with nothing shown unless it takes a while.
        case copying
        /// Installed while an older yab is open: restart it, or leave it.
        case restart(version: String)
        /// Asking the open yab to quit, before opening the new one.
        case restarting
        case locked
        case unsupported(title: String, detail: String)
        case failed(String)
        /// In Applications, but macOS wouldn't open it.
        case unopened(String)
        case done
    }

    @Published var scene = Scene.copying
    @Published var progress = 0.0
    private var install: Install?
    private var installed: URL?

    var payload: URL? { Bundle.main.resourceURL?.appendingPathComponent("Payload/\(Install.name)") }
    /// /Applications, or, for trying the installer without touching the
    /// yab that's installed, YAB_INSTALL_INTO, which only a launcher
    /// started from a shell can be given.
    let applications = URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["YAB_INSTALL_INTO"] ?? "/Applications", isDirectory: true
    )

    /// Where the image's window is, read the moment the launcher starts,
    /// before any window of ours could be the front one.
    let finderWindow = Handoff.finderWindow()

    func begin(personal: Bool = false) {
        guard let payload, FileManager.default.fileExists(atPath: payload.path) else {
            scene = .failed(Install.Failure.invalidPayload.localizedDescription); return
        }
        if let unsupported = Self.unsupported(payload) { scene = unsupported; return }
        let folder = personal
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
            : applications
        if personal { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        scene = .copying
        progress = 0
        let install = Install()
        self.install = install
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try install.run(source: payload, into: folder) { value in
                DispatchQueue.main.async { [weak self] in self?.progress = value }
            } }
            DispatchQueue.main.async { [weak self] in self?.finish(result) }
        }
    }

    private func finish(_ result: Result<Install.Outcome, Error>) {
        switch result {
        case .success(.installed(let app)):
            installed = app
            open(app, arrivingFrom: finderWindow)
        case .success(.present(let app)):
            // Nothing new to put there: the yab that's there, as it is.
            installed = app
            open(app, arrivingFrom: nil)
        case .success(.replaced(let app)):
            installed = app
            if Self.running(app) != nil {
                scene = .restart(version: Install.version(at: app) ?? "")
            } else {
                open(app, arrivingFrom: nil)
            }
        case .failure(Install.Failure.canceled):
            NSApp.terminate(nil)
        case .failure(Install.Failure.notWritable):
            scene = .locked
        case .failure(let error):
            scene = .failed(error.localizedDescription)
        }
    }

    func cancel() {
        guard scene == .copying, install?.cancel() == true else { return }
    }

    /// The open yab is asked to quit, as ⌘Q would, so it saves its tabs
    /// on the way out and, if it has something to ask first, asks, and the
    /// new one opened once it has gone. It is never forced.
    func restart() {
        guard let app = installed else { return }
        guard let running = Self.running(app) else { open(app, arrivingFrom: nil); return }
        scene = .restarting
        running.terminate()
        let started = Date()
        func wait() {
            if running.isTerminated {
                open(app, arrivingFrom: nil)
            } else if Date().timeIntervalSince(started) > 30 {
                // It said no, a download under way, a page asking to stay.
                scene = .restart(version: Install.version(at: app) ?? "")
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: wait)
            }
        }
        wait()
    }

    func later() {
        scene = .done
        leave()
    }

    func openInstalled() {
        if let installed { open(installed, arrivingFrom: nil) }
    }

    private func open(_ app: URL, arrivingFrom frame: String?) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if let frame { config.arguments = ["--arrival", frame] }
        // A test run's world goes with it, so the yab it opens keeps its
        // own settings and data.
        if let world = ProcessInfo.processInfo.environment["YAB_PROBE"] { config.environment = ["YAB_PROBE": world] }
        NSWorkspace.shared.openApplication(at: app, configuration: config) { opened, error in
            DispatchQueue.main.async {
                if let error {
                    self.scene = .unopened(error.localizedDescription)
                    return
                }
                self.scene = .done
                guard let pid = opened?.processIdentifier else { self.leave(); return }
                Handoff.waitForWindow(of: pid) { self.leave() }
            }
        }
    }

    /// Gone, and the image with it.
    private func leave() {
        Image.containingLauncher()?.ejectAfterExit()
        NSApp.terminate(nil)
    }

    static func running(_ app: URL) -> NSRunningApplication? {
        let path = app.resolvingSymlinksInPath().path
        // Whatever its bundle id: a yab of before (see Install.isFormer)
        // is asked to quit like any other.
        return NSWorkspace.shared.runningApplications
            .first { $0.bundleURL?.resolvingSymlinksInPath().path == path }
    }

    /// Said plainly, instead of the crossed-out icon macOS would show when
    /// yab itself failed to open: this launcher is built to run on older
    /// systems and both kinds of Mac for exactly this.
    private static func unsupported(_ payload: URL) -> Scene? {
        let info = NSDictionary(contentsOf: payload.appendingPathComponent("Contents/Info.plist"))
        if let minimum = info?["LSMinimumSystemVersion"] as? String {
            let parts = minimum.split(separator: ".").compactMap { Int($0) }
            let wanted = OperatingSystemVersion(
                majorVersion: parts.first ?? 0, minorVersion: parts.count > 1 ? parts[1] : 0, patchVersion: 0
            )
            if !ProcessInfo.processInfo.isOperatingSystemAtLeast(wanted) {
                let have = ProcessInfo.processInfo.operatingSystemVersion
                return .unsupported(
                    title: "Pane needs macOS \(minimum) or later",
                    detail: "This Mac has macOS \(have.majorVersion).\(have.minorVersion). Pane will open here once it's updated, from Software Update in System Settings."
                )
            }
        }
        if let executable = Bundle(url: payload)?.executableArchitectures?.map(\.intValue) {
            var system = utsname()
            uname(&system)
            let machine = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let appleSilicon = machine.hasPrefix("arm64") || Self.translated
            if !appleSilicon, !executable.contains(NSBundleExecutableArchitectureX86_64) {
                return .unsupported(
                    title: "Pane needs a Mac with Apple silicon",
                    detail: "This Mac has an Intel processor, and Pane is made only for Macs with M-series chips."
                )
            }
        }
        return nil
    }

    /// Running under Rosetta: the Mac itself is Apple silicon.
    private static var translated: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("sysctl.proc_translated", &value, &size, nil, 0) == 0 && value == 1
    }
}

// MARK: - the window

/// Dark, like the image's window and the browser's welcome: the mark and the
/// name at the top, what happened in the middle, what to do at the bottom.
struct InstallerView: View {
    @ObservedObject var installer: Installer

    var body: some View {
        ZStack(alignment: .top) {
            Color(red: 0x14 / 255.0, green: 0x14 / 255.0, blue: 0x14 / 255.0)
            HStack(spacing: 8) {
                // The mark, the same picture as yab's welcome (Icon/Mark.png),
                // which build.sh puts in this app's Resources.
                if let mark = Bundle.main.url(forResource: "Mark", withExtension: "png").flatMap({ NSImage(contentsOf: $0) }) {
                    SwiftUI.Image(nsImage: mark).resizable().interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 26)
                }
                Text("Pane").font(.system(size: 19, weight: .semibold, design: .rounded))
            }
            .padding(.top, 34)
            VStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                Text(detail)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
                if installer.scene == .copying {
                    ProgressView(value: installer.progress)
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .frame(width: 160)
                        .padding(.top, 8)
                }
            }
            .padding(.top, 104)
            VStack(spacing: 10) {
                Spacer()
                buttons
            }
            .padding(.bottom, 30)
        }
        .foregroundColor(.white)
        .frame(width: 520, height: 340)
        .preferredColorScheme(.dark)
    }

    private var title: String {
        switch installer.scene {
        case .copying, .done: return "Moving Pane into Applications…"
        case .restart(let version): return version.isEmpty ? "The new Pane is ready" : "Pane \(version) is ready"
        case .restarting: return "Restarting Pane…"
        case .locked: return "Applications is locked"
        case .unsupported(let title, _): return title
        case .failed: return "Pane couldn't be installed"
        case .unopened: return "Pane is in Applications"
        }
    }

    private var detail: String {
        switch installer.scene {
        case .copying, .done: return "It opens as soon as it's there."
        case .restart: return "The Pane that's open is the one before. Restart it and your tabs come back just as they are."
        case .restarting: return "Your tabs come back with it."
        case .locked: return "This account can't add apps there. Pane can go in your own Applications folder instead."
        case .unsupported(_, let detail): return detail
        case .failed(let reason): return reason
        case .unopened(let reason): return "It didn't open: \(reason)"
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch installer.scene {
        case .copying:
            QuietButton(title: "Cancel") { installer.cancel() }
        case .restart:
            PillButton(title: "Restart Pane") { installer.restart() }
            QuietButton(title: "Later") { installer.later() }
        case .locked:
            PillButton(title: "Install for Me") { installer.begin(personal: true) }
            QuietButton(title: "Close") { NSApp.terminate(nil) }
        case .failed:
            PillButton(title: "Try Again") { installer.begin() }
            QuietButton(title: "Close") { NSApp.terminate(nil) }
        case .unopened:
            PillButton(title: "Open Pane") { installer.openInstalled() }
            QuietButton(title: "Close") { NSApp.terminate(nil) }
        case .unsupported:
            PillButton(title: "Close") { NSApp.terminate(nil) }
        case .restarting, .done:
            EmptyView()
        }
    }
}

/// The browser's one button: white on the dark.
struct PillButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(white: 0.08))
                .padding(.horizontal, 20)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white))
        }
        .buttonStyle(.plain)
        // Return presses it; the system's blue ring would only fight the white.
        .focusable(false)
        .keyboardShortcut(.defaultAction)
    }
}

struct QuietButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12)).foregroundColor(.white.opacity(0.6))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
    }
}

// MARK: - the app

@MainActor
final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let installer = Installer()
    private var window: NSWindow?
    private var watching: AnyCancellable?
    private var reveal: DispatchWorkItem?

    /// A copy this slow is worth showing; a quicker one never shows anything.
    static let slowCopy: TimeInterval = 2

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let item = NSMenuItem()
        item.submenu = NSMenu()
        item.submenu?.addItem(withTitle: "Quit Installer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(item)
        NSApp.mainMenu = menu

        // A @Published value is announced before it is set: a window built
        // on the announcement would show the scene before. So the next turn.
        watching = installer.$scene.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] scene in self?.changed(to: scene) }
        // Dragged out of the image and opened from somewhere else, it still
        // installs, and, once yab is open, goes to the Trash, since a
        // second yab-looking icon in Applications is only confusing.
        installer.begin()
    }

    private func changed(to scene: Installer.Scene) {
        reveal?.cancel()
        switch scene {
        case .copying:
            let work = DispatchWorkItem { [weak self] in
                guard self?.installer.scene == .copying else { return }
                self?.show()
            }
            reveal = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.slowCopy, execute: work)
        case .done:
            window?.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
        default:
            show()
        }
    }

    private func show() {
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
                styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false
            )
            window.title = "Install Pane"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = NSHostingView(rootView: InstallerView(installer: installer))
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A second double-click while the first is still copying doesn't turn
    /// the quick path into a window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if window?.isVisible == true { show() }
        return false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if installer.scene == .copying { installer.cancel(); return false }
        NSApp.terminate(nil)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if installer.scene == .copying, installer.cancelIfRunning() { return .terminateCancel }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        if installer.scene == .done { Self.trashIfLoose() }
    }

    /// Only a launcher that was copied off the image, never the one on it,
    /// never a translocated copy.
    private static func trashIfLoose() {
        let here = Bundle.main.bundleURL
        guard !here.pathComponents.contains("AppTranslocation"),
              (try? here.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == false,
              Image.containingLauncher() == nil
        else { return }
        try? FileManager.default.trashItem(at: here, resultingItemURL: nil)
    }
}

extension Installer {
    /// Cancels a copy under way; true when there was one to cancel.
    func cancelIfRunning() -> Bool {
        guard scene == .copying else { return false }
        cancel()
        return true
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { Delegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
