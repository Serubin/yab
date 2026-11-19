import AppKit
import ObjectiveC
import Combine

// A class of our own lets Awake keep the glass lit without changing every
// NSWindow in the process or replacing a live window's class underneath KVO.
final class BrowserWindow: NSWindow {
    /// Its pages asked whether they may go, and they may: this close goes
    /// through (LeavePage.swift).
    private var agreed = false

    private var looked: AnyCancellable?

    /// Light or dark as the look of its space has it, the app's Theme on
    /// Auto, from before its first frame and at every change, as the first
    /// window wears it. That one is SwiftUI's scene, where the color scheme
    /// preference (LookModeScheme) is the window's appearance; on a window
    /// of ours the preference never reached the window, so ⌘N on a space
    /// with its own Dark opened in the light shades of its colors beside
    /// the window it came from (R2588, feedback #2029).
    func wearLookMode(of prefs: Preferences) {
        looked = prefs.changes(\.lookMode).combineLatest(prefs.changes(\.lookPreview)).sink { [weak self] mode, preview in
            self?.appearance = LookMode(rawValue: Preferences.worn(mode: mode, preview: preview))?.appearance
        }
    }

    /// The red button, Close Window, ⌘W with no tab: a page holding
    /// something typed asks first, and a Stay keeps the window.
    override func performClose(_ sender: Any?) {
        if agreed {
            agreed = false
            return super.performClose(sender)
        }
        Leaving.window(self) { [weak self] in
            guard let self else { return }
            self.agreed = true
            self.performClose(sender)
        }
    }
}

// Liquid Glass, left alone, goes flat when its window is not key: the light
// wash and the rim go, and what is left is a gray slab over the page. The
// glass asks its window, not itself (an NSGlassEffectView that ignores the
// key change goes flat all the same; environment overrides in SwiftUI change
// nothing), through NSWindow's private _hasActiveAppearance. Answering yes
// there keeps the glass as it is in front.
//
// The window is SwiftUI's, so it can't be a subclass of ours, and a subclass
// slid under it at run time crashed on launch (KVO had already slid one in):
// SwiftUI's window class is taught the answer, for itself only.
//
// Everything else that asks the same question would stay lit too, the traffic
// lights first, so they are answered with the window's real state.
enum Awake {
    private static var kept: Set<ObjectIdentifier> = []

    static func keep(_ window: NSWindow) {
        // The class the window says it is: SwiftUI's own, under whatever KVO
        // has slid beneath it. A plain NSWindow is left alone, the answer
        // would reach every window in the app.
        let cls: AnyClass = window.classForCoder
        guard cls != NSWindow.self, kept.insert(ObjectIdentifier(cls)).inserted else { return }
        let lit: @convention(block) (NSWindow) -> Bool = { _ in true }
        put(lit, "_hasActiveAppearance", "B@:", in: cls)
        // Honest for the buttons: lit while the window is where typing goes
        // and the app is in front, as AppKit's own are.
        let honest: @convention(block) (NSWindow, UInt) -> Bool = { window, _ in
            NSApp.isActive && (window.isKeyWindow || window.isMainWindow)
        }
        put(honest, "_hasActiveAppearanceForStandardWindowButton:", "B@:Q", in: cls)
    }

    private static func put(_ block: Any, _ selector: String, _ types: String, in cls: AnyClass) {
        class_replaceMethod(cls, NSSelectorFromString(selector), imp_implementationWithBlock(block), types)
    }
}
