import AppKit

/// Opt-in only in the separately identified, disposable preview app.
/// A double-click gets a new world before Store or SwiftUI reads any state.
enum LaunchArrivalPreview {
    static var enabled: Bool {
        Bundle.main.bundleIdentifier == "net.serubin.pane.launcharrival.dev"
            && Bundle.main.object(forInfoDictionaryKey: "YabLaunchArrivalPreview") as? Bool == true
    }

    static func prepareProcess() {
        guard enabled else { return }
        // Leave room for bench.sock in Darwin's 104-byte Unix socket path.
        let world = "arrival-clean-" + UUID().uuidString.lowercased().prefix(12)
        setenv("YAB_PROBE", world, 1)
        setenv("YAB_LAUNCH_ARRIVAL", "1", 1)
        if let identifier = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: identifier)
        }
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
        // This app previews the arrival itself, without the welcome overlay
        // opening another animation or changing the browser's minimum size.
        Store.settings.set(true, forKey: "welcomed")
        Store.settings.set(true, forKey: "bench")
    }

    static func frame(screen: CGRect, visible: CGRect) -> CGRect {
        let size = CGSize(width: min(1180, visible.width), height: min(780, visible.height))
        return CGRect(
            x: max(visible.minX, min(screen.midX - size.width / 2, visible.maxX - size.width)),
            y: max(visible.minY, min(screen.midY - size.height / 2, visible.maxY - size.height)),
            width: size.width, height: size.height)
    }

    @MainActor static func place(_ window: NSWindow) {
        guard enabled,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.main ?? NSScreen.screens.first else { return }
        window.isRestorable = false
        window.setFrameAutosaveName("")
        window.setFrame(frame(screen: screen.frame, visible: screen.visibleFrame), display: false, animate: false)
        window.contentView?.layoutSubtreeIfNeeded()
        record("placed", window: window)
    }

    /// Also in a test world, where a probe reads whether the light played.
    @MainActor static func record(_ event: String, window: NSWindow) {
        guard enabled || Store.testing
                || Bundle.main.object(forInfoDictionaryKey: "YabLaunchArrivalTrace") as? Bool == true else { return }
        let frame = window.frame
        let entry: [String: Any] = ["event": event, "time": ProcessInfo.processInfo.systemUptime,
            "frame": [frame.minX, frame.minY, frame.width, frame.height], "alpha": window.alphaValue]
        if let data = try? JSONSerialization.data(withJSONObject: entry), let line = String(data: data, encoding: .utf8) {
            fputs("YAB_LAUNCH_PREVIEW \(line)\n", stderr)
        }
    }
}
