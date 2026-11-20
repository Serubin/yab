import Foundation

/// Apple's Chrome extension needs a browser-approved helper. Yab uses its
/// existing native Apple Passwords connection instead, for either engine.
@MainActor
enum ApplePasswordExtensionRoute {
    enum Action: Equatable { case connect, alreadyOn }
    /// The same effect boundary used by install/toolbar regression tests.
    static var handler: ((Action) -> Void)?
    static var isConnected: () -> Bool = { PasswordManagers.appleNative }
    static var connected: Bool { isConnected() }
    static var pair: () async -> Bool = { await ApplePasswordsPairing.pair(registerConnection: true) }

    nonisolated static func matches(_ id: String) -> Bool {
        Extensions.iCloudPasswords.contains(id)
    }

    @discardableResult
    static func intercept(_ id: String, browser: Browser? = nil) -> Bool {
        guard matches(id) else { return false }
        let action: Action = connected ? .alreadyOn : .connect
        if let handler { handler(action); return true }
        switch action {
        case .alreadyOn:
            let browser = browser ?? BrowserWindows.shared.activeBrowser ?? Extensions.shared.browser
            browser?.announce("Apple Passwords is already on in \(Brand.name)", mark: "key")
        case .connect:
            Task { _ = await pair() }
        }
        return true
    }

    /// Keep the package, pin and all other metadata. No connection UI at launch.
    static func disabled(_ entries: [Installed]) -> [Installed] {
        entries.map { entry in
            var entry = entry
            if matches(entry.id) { entry.enabled = false }
            return entry
        }
    }

    /// Retain the person's existing toolbar route after disabling the worker.
    static func offersButton(_ id: String) -> Bool { matches(id) && !connected }
}
