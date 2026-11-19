import AppKit
import Security
import YabUpdate

// How yab gets to where it lives.
//
// The disk image holds one thing, Open yab (Installer/Open), which puts
// yab into Applications and opens it with `--arrival x,y,w,h`: where the
// image's Finder window is, from the top-left of the main display. That
// window is the welcome's dark ground, drawn still
// (Installer/background.swift). So the browser's first window opens right
// there, over it, on the same ground, and grows to its own size
// while the image is put away behind it: the Finder window seems to become
// the browser. It happens once in the life of a Mac, which is why it moves
// at all; with Reduce Motion, or once yab has been welcomed, the window
// opens where it would anyway.
//
// And a yab opened from anywhere else, an older disk image, the ZIP
// unpacked in Downloads, would never be updated there: the updater swaps
// the bundle where it stands and needs a folder that takes it. So on its
// very first run, before any window, a yab signed for shipping that finds
// Applications without one moves itself in and opens from there.

enum Arrival {
    /// Where the image's window was, in AppKit's coordinates, if yab was
    /// opened by Open yab and there is a first welcome to show.
    static let frame: CGRect? = {
        let arguments = CommandLine.arguments
        guard let at = arguments.firstIndex(of: "--arrival"), at + 1 < arguments.count else { return nil }
        let numbers = arguments[at + 1].split(separator: ",").compactMap { Double($0) }
        guard numbers.count == 4, numbers[2] > 100, numbers[3] > 100,
              let main = NSScreen.screens.first else { return nil }
        // The window server counts down from the top of the main display;
        // AppKit counts up from its bottom.
        let rect = CGRect(x: numbers[0], y: main.frame.maxY - numbers[1] - numbers[3], width: numbers[2], height: numbers[3])
        guard NSScreen.screens.contains(where: { $0.frame.intersects(rect) }) else { return nil }
        return rect
    }()

    /// The first window takes the image window's place: it is on the same
    /// ground from the first frame (see HeroView), so the two read as one.
    static var arriving: Bool {
        frame != nil && !welcomed && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private static var received = false

    /// Called as the browser's window is dressed, once. The window is put
    /// over the Finder's at once, and after a beat grows to the frame it was
    /// going to have, its own saved one, or the default in the middle.
    static func receive(_ window: NSWindow) {
        // The first launch's light reveals the window where it is; the
        // grow from the image's window is for when it doesn't play.
        let lit = MainActor.assumeIsolated { LaunchArrival.shared.offer(window) }
        guard !received, !lit, arriving, let from = frame else { return }
        received = true
        let to = window.frame
        window.setFrame(from, display: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.6
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                context.allowsImplicitAnimation = true
                window.animator().setFrame(to, display: true)
            }
        }
    }

    static var welcomed: Bool {
        Store.settings.bool(forKey: "welcomed") || Store.settings.object(forKey: "glyph") != nil
    }

    // MARK: - moving in

    /// Before anything else runs. Either nothing happens, or yab is now in
    /// Applications, this copy has asked for that one to be opened, and it
    /// ends here.
    static let settle: Void = {
        // Woken by an agent: a move would relaunch it as a plain yab.
        guard !Headless.on, let destination = moveTarget else { return }
        let files = FileManager.default
        let here = Bundle.main.bundleURL
        LaunchJournal.record("arrival.relocate", target: destination)
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".pane-move-\(UUID().uuidString)", isDirectory: true)
        do {
            try files.createDirectory(at: staging, withIntermediateDirectories: false)
            defer { try? files.removeItem(at: staging) }
            let copy = staging.appendingPathComponent("Pane.app", isDirectory: true)
            try files.copyItem(at: here, to: copy)
            // Something that turned up there meanwhile is never overwritten.
            guard renamex_np(copy.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { return }
        } catch {
            return
        }
        // Start the helper from the installed, sealed bundle before removing
        // this copy. A helper launch failure leaves this process usable.
        do { try Relaunch.start(bundle: destination) } catch { return }
        // The copy left behind goes to the Trash when it can be told where it
        // is, not from a disk image, not from the place macOS runs a
        // downloaded app from before it has been moved.
        if !here.pathComponents.contains("AppTranslocation"),
           (try? here.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == false {
            try? files.trashItem(at: here, resultingItemURL: nil)
        }
        LaunchJournal.record("arrival.exit", target: destination)
        exit(0)
    }()

    /// /Applications/Pane.app, when this copy should move there: the first
    /// run of a build signed for shipping, from outside any Applications
    /// folder, with nothing there already and a folder that takes it.
    private static var moveTarget: URL? {
        guard !Store.testing, !Store.development, !welcomed, frame == nil else { return nil }
        let here = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        guard !here.path.hasPrefix("/Applications/"), !here.path.hasPrefix(home + "/") else { return nil }
        // A build made here is ad hoc and has no team: it runs from wherever
        // it was built, and is never moved.
        guard isShipping(here) else { return nil }
        let folder = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let destination = folder.appendingPathComponent("Pane.app", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path),
              FileManager.default.isWritableFile(atPath: folder.path) else { return nil }
        return destination
    }

    private static func isShipping(_ bundle: URL) -> Bool {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let signing = info as? [String: Any]
        else { return false }
        return signing[kSecCodeInfoTeamIdentifier as String] is String
    }
}
