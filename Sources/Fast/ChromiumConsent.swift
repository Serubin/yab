import AppKit
import CryptoKit
import YabCoreClient

/// Chrome's question before any extension side effect. Identity and warning
/// text come from the engine, never from the page that initiated the install.
struct ChromiumConsentRequest: Sendable {
    let request: String
    let profile: String
    let operation: String
    let extensionID: String
    let displayName: String
    let version: String
    let manifestSHA256: String?
    let warnings: [(text: String, details: String)]
    let tab: String?

    static func parse(_ p: [String: JSONValue]) -> Self? {
        guard let request = p["request"]?.string, !request.isEmpty, request.count <= 256,
              let profile = p["profile"]?.string, !profile.isEmpty,
              let id = p["extensionId"]?.string, ChromiumExtensions.validID(id),
              let operation = p["operation"]?.string,
              ["install", "uninstall", "permissions", "reenable"].contains(operation),
              let name = p["displayName"]?.string, !name.isEmpty else { return nil }
        var warnings: [(text: String, details: String)] = []
        if operation != "uninstall" {
            guard let manifest = p["manifest"]?.string, manifest.utf8.count <= 1_048_576,
                  let hash = p["manifestSHA256"]?.string,
                  Self.digest(manifest) == hash,
                  (try? JSONSerialization.jsonObject(with: Data(manifest.utf8))) is [String: Any],
                  case .array(let rows)? = p["warnings"], rows.count <= 256 else { return nil }
            for row in rows {
                guard let text = row["text"].string, !text.isEmpty,
                      let details = row["details"].string else { return nil }
                warnings.append((text, details))
            }
        }
        return Self(request: request, profile: profile, operation: operation, extensionID: id,
                    displayName: name, version: p["version"]?.string ?? "",
                    manifestSHA256: p["manifestSHA256"]?.string, warnings: warnings, tab: p["tab"]?.string)
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
enum ChromiumConsent {
    static var handler: (@MainActor (ChromiumConsentRequest) async -> Bool)?
    private struct Pending { let client: YabCoreClient; let question: UUID; let ask: ChromiumConsentRequest }
    private static var pending: [String: Pending] = [:]
    /// What the person already said yes to in the other engine, each answered
    /// once with no second question ("uninstall", "permissions"), by
    /// operation and extension.
    private static var approved: Set<String> = []
    static func approve(_ operation: String, _ id: String) { approved.insert(operation + ":" + id) }
    static func withdrawApproval(_ operation: String, _ id: String) { approved.remove(operation + ":" + id) }

    static func receive(_ event: YabCoreEvent, from client: YabCoreClient?) -> Bool {
        guard event.name == "extension.consent" || event.name == "extension.consent.withdrawn" else { return false }
        guard let client, let token = event.params["request"]?.string else { return true }
        if event.name == "extension.consent.withdrawn" {
            if let old = pending[token], old.client === client {
                pending[token] = nil
                Questions.shared.withdraw(old.question)
            }
            return true
        }
        guard pending[token] == nil else { return true }
        // Source CEF's own store installer must be refused before any
        // prior approval or permission question can accept it.
        if let ask = ChromiumConsentRequest.parse(event.params),
           redirectsToApplePasswords(ask) {
            reject(event.params, client: client)
            let page = ask.tab.flatMap { remote in ChromiumProcess.shared.livePages.first { $0.remoteID == remote && $0.profile == ask.profile } }
            let browser = (page?.navigationTab?.delegate as? Browser)
                ?? BrowserWindows.shared.browsers.first { ChromiumPersistentProfiles.profile(for: $0) == ask.profile }
            if let browser { ApplePasswordExtensionRoute.intercept(ask.extensionID, browser: browser) }
            return true
        }
        if let ask = ChromiumConsentRequest.parse(event.params), approved.remove(ask.operation + ":" + ask.extensionID) != nil {
            Task { _ = try? await client.request("extension.consent.reply", params: reply(ask, accept: true)) }
            return true
        }
        guard let ask = ChromiumConsentRequest.parse(event.params), let question = question(for: ask) else {
            reject(event.params, client: client)
            return true
        }
        pending[token] = Pending(client: client, question: question.id, ask: ask)
        Task { @MainActor in
            let accepted: Bool
            if let handler { accepted = await handler(ask) }
            else { accepted = await Questions.shared.ask(question) }
            guard let old = pending[token], old.client === client else { return }
            pending[token] = nil
            guard ChromiumProcess.shared.isCurrent(client) else { return }
            _ = try? await client.request("extension.consent.reply", params: reply(ask, accept: accepted))
            if accepted, ask.operation == "permissions", #available(macOS 15.4, *) {
                ChromiumExtensions.grantChanged(profile: ask.profile, id: ask.extensionID)
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(120))
            guard let old = pending[token], old.client === client else { return }
            Questions.shared.withdraw(old.question)
        }
        return true
    }

    static func redirectsToApplePasswords(_ ask: ChromiumConsentRequest) -> Bool {
        ApplePasswordExtensionRoute.matches(ask.extensionID) && ["install", "reenable"].contains(ask.operation)
    }

    static func disconnected(_ client: YabCoreClient?) {
        for (token, old) in pending where client == nil || old.client === client {
            pending[token] = nil
            Questions.shared.withdraw(old.question)
        }
    }

    static func reply(_ ask: ChromiumConsentRequest, accept: Bool) -> [String: JSONValue] {
        ["request": .string(ask.request), "extension": .string(ask.extensionID),
         "profile": .string(ask.profile), "accept": .bool(accept)]
    }

    static var benchState: [[String: Any]] {
        pending.values.map { old in
            ["request": old.ask.request, "profile": old.ask.profile, "extension": old.ask.extensionID,
             "operation": old.ask.operation, "question": old.question.uuidString,
             "manifestSHA256": old.ask.manifestSHA256 ?? "",
             "warnings": old.ask.warnings.map { ["text": $0.text, "details": $0.details] }]
        }
    }

    private static func reject(_ p: [String: JSONValue], client: YabCoreClient) {
        guard let token = p["request"], let id = p["extensionId"], let profile = p["profile"] else { return }
        Task { _ = try? await client.request("extension.consent.reply", params: [
            "request": token, "extension": id, "profile": profile, "accept": .bool(false)]) }
    }

    /// The window Chrome would ask in, as WindowControllerList::
    /// CurrentWindowForFunction picks it: the asking tab's own; with no tab,
    /// the focused window if it shows the profile, else the profile's newest
    /// window (Chrome's last in its list). Chrome's permission prompt
    /// (permissions.request, made from a native window) and its uninstall
    /// dialog never name a tab, so the fallback is the common case, not an
    /// edge: refusing it whenever a sign-in had two windows refused every
    /// site an extension asked for and every removal from Settings (#2030).
    /// A tab of another profile, or a profile with no window, has no owner.
    /// `windows`: the profile's windows, oldest first.
    static func owner<Window: Equatable>(tab: Window?, tabMatches: Bool, focused: Window?, windows: [Window]) -> Window? {
        if let tab { return tabMatches ? tab : nil }
        if let focused, windows.contains(focused) { return focused }
        return windows.last
    }

    private static func question(for ask: ChromiumConsentRequest) -> Question? {
        // Never move a request to another sign-in simply because its window
        // became active. If its profile has no live browser, cancel it.
        let all = BrowserWindows.shared
        let ownerPage = ask.tab.flatMap { remote in ChromiumProcess.shared.livePages.first { $0.remoteID == remote } }
        let ownerMatches = ownerPage.map { $0.profile == ask.profile && $0.navigationTab?.chromiumProfile == ask.profile } ?? false
        // Only the profile's own windows stand in for a missing tab: a
        // shared sign-in's several windows are all its own.
        let matching = all.browsers.filter {
            ChromiumPersistentProfiles.profile(for: $0) == ask.profile && all.window(for: $0)?.isVisible == true
        }
        guard let browser = owner(tab: ownerPage?.navigationTab?.delegate as? Browser, tabMatches: ownerMatches,
                                  focused: all.activeBrowser, windows: matching),
              let window = all.window(for: browser) else { return nil }
        let uninstall = ask.operation == "uninstall"
        let title = uninstall ? "Remove “\(ask.displayName)”?" : ask.operation == "install" ? "Add “\(ask.displayName)”?" : "\(ask.displayName) wants access"
        // Preserve Chrome's wording, including the secondary permission detail.
        let lines = ask.warnings.flatMap { $0.details.isEmpty ? [$0.text] : [$0.text, $0.details] }
        return Question(title: title,
                        detail: uninstall ? "What it kept in \(Brand.name) goes with it." : lines.isEmpty ? "It asks for no special access." : "It can:",
                        lines: lines, yes: uninstall ? "Remove" : ask.operation == "install" ? "Add" : "Allow",
                        danger: uninstall, window: window.windowNumber)
    }
}
