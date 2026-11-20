import AppKit
import WebKit
import YabCoreClient

// chrome.omnibox: an extension's keyword in the field.
//
// An extension that names `omnibox.keyword` in its manifest (OneTab "11",
// Raindrop "rd", LastPass "lp", DuckDuckGo "ddg", Toby "to/", AIPRM, Vimium C)
// is searched from the field the way a site is (Scopes.swift): type the
// keyword, Tab, and the field becomes the extension's, the way back at its
// head and its icon and name at its foot. A space after the keyword enters
// it too, as in Chrome, while Settings › Field › Sites › Keyboard shortcut
// is Space or Tab (Scopes.spaced); at Tab, "v 8" or "11 tabs" stay words,
// as Yab had it from 2026-10-13 until register 2668. The words typed after
// it go to `onInputStarted` once and `onInputChanged` on every change, whose
// `suggest` rows fill the list under the extension's `setDefaultSuggestion`;
// Return sends `onInputEntered` with the row's content (`currentTab`, or
// `newForegroundTab` from an empty field asking for a new tab), ⌘Return
// `newBackgroundTab`, ⌘⇧Return `newForegroundTab`; Escape, ⌫ in its empty
// field or its way back, or the field going away sends `onInputCancelled`.
//
// Events reach the extension's worker over a native port its shim opens
// (only an extension with a keyword does): the worker is woken first if
// WebKit has put it to sleep, as Chrome wakes it, and what comes before the
// port is there waits for it.

@available(macOS 15.4, *)
@MainActor
final class ExtensionOmnibox {
    static let shared = ExtensionOmnibox()
    nonisolated static let portName = ExtensionShims.application + ".omnibox"
    /// The rows' addresses: never loaded, read back when one is taken.
    nonisolated static let scheme = "yab-omnibox"

    private var ports: [String: WKWebExtension.MessagePort] = [:]
    private var waiting: [String: [[String: Any]]] = [:]
    /// The extension's first row, `%s` where the words go.
    private var defaults: [String: String] = [:]
    /// What the extension suggested for the words it was last told.
    private var rows: [String: (text: String, list: [(content: String, description: String)])] = [:]
    private var asked: [String: String] = [:]
    private var request = 0
    /// The extension whose keyword the field is in, until entered or let go.
    private var active: String?
    private weak var field: Browser?

    // MARK: - the keywords

    /// A scope for each loaded extension with a keyword, by its keyword.
    func scope(for typed: String) -> Scope? {
        let text = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return nil }
        // The window's sign-in's, each by its key there (ExtensionExternal.key).
        let here = Extensions.here
        for (named, context) in here.contexts {
            guard let omnibox = context.webExtension.manifest["omnibox"] as? [String: Any],
                  let keyword = (omnibox["keyword"] as? String)?.lowercased(), keyword == text else { continue }
            let id = ExtensionExternal.key(named, in: here.signIn)
            var scope = Scope(id: "omnibox:" + id, name: context.webExtension.displayName ?? keyword, template: "")
            scope.aliases = [keyword]
            scope.extensionID = id
            return scope
        }
        return chromiumScope(for: text)
    }

    // MARK: - what the field does

    /// Tab into the keyword.
    func started(_ id: String, in browser: Browser) {
        field = browser
        active = id
        asked[id] = nil
        rows[id] = nil
        if Self.chromiumID(id) != nil { tellChromium(id, "started"); return }
        send(id, ["e": "onInputStarted", "a": [Any]()])
    }

    /// The words after the keyword, as they change.
    func changed(_ id: String, text: String, in browser: Browser) {
        field = browser
        // Chrome says nothing until there are words, then every change,
        // back to none included.
        guard active == id, asked[id] != text, asked[id] != nil || !text.isEmpty else { return }
        asked[id] = text
        request += 1
        if Self.chromiumID(id) != nil { tellChromium(id, "changed", text: text); return }
        send(id, ["e": "onInputChanged", "a": [text], "r": request])
    }

    /// The rows the field shows: the extension's first row for the words,
    /// then what it suggested for them.
    func suggestions(_ id: String, name: String, text: String) -> [Suggestion] {
        var list: [Suggestion] = []
        let first = defaults[id].map { Self.plain($0).replacingOccurrences(of: "%s", with: text) } ?? (text.isEmpty ? "" : text)
        if !first.isEmpty || !text.isEmpty {
            list.append(Suggestion(key: first.isEmpty ? text : first, title: name, url: Self.address(id, content: text, typed: true), kind: .search))
        }
        if let kept = rows[id], kept.text == text {
            for row in kept.list.prefix(8) {
                list.append(Suggestion(key: Self.plain(row.description), title: "", url: Self.address(id, content: row.content), kind: .suggested))
            }
        }
        return list
    }

    /// Return on a row, or on the words: the extension is told, and the
    /// field goes as after any place it was sent to.
    func entered(_ id: String, content: String, way: Browser.Way, askingNew: Bool) {
        let disposition: String
        switch way {
        case .here: disposition = askingNew ? "newForegroundTab" : "currentTab"
        case .behind: disposition = "newBackgroundTab"
        case .ahead, .last, .split: disposition = "newForegroundTab"
        }
        active = nil
        if Self.chromiumID(id) != nil { tellChromium(id, "entered", text: content, disposition: disposition); return }
        send(id, ["e": "onInputEntered", "a": [content, disposition]])
    }

    /// The keyword let go of without Return.
    func cancelled(_ id: String) {
        guard active == id else { return }
        active = nil
        asked[id] = nil
        if Self.chromiumID(id) != nil { tellChromium(id, "cancelled"); return }
        send(id, ["e": "onInputCancelled", "a": [Any]()])
    }

    /// A row's address, and what it carries back.
    nonisolated static func address(_ id: String, content: String, typed: Bool = false) -> URL? {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = id
        parts.queryItems = [URLQueryItem(name: "content", value: content)] + (typed ? [URLQueryItem(name: "typed", value: "1")] : [])
        return parts.url
    }

    nonisolated static func content(of url: URL) -> (id: String, content: String)? {
        guard url.scheme == scheme, let id = url.host() else { return nil }
        let content = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "content" }?.value ?? ""
        return (id, content)
    }

    /// A description as Chrome's XML-ish markup writes it, as words: its
    /// <match>, <dim> and <url> spans and its entities taken out.
    nonisolated static func plain(_ description: String) -> String {
        var text = description.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - the extension's calls

    func run(_ api: String, _ args: [Any], context: WKWebExtensionContext) throws -> Any? {
        let id = ExtensionExternal.key(context.uniqueIdentifier, in: Extensions.owner(of: context).signIn)
        switch api {
        case "omnibox.setDefaultSuggestion":
            let spec = args.first as? [String: Any] ?? [:]
            defaults[id] = spec["description"] as? String
            refresh()
            return nil
        case "omnibox.suggest":
            // Only the answer to the words still in the field counts.
            guard args.count > 1, (args[0] as? NSNumber)?.intValue == request, let text = asked[id] else { return nil }
            let list = (args[1] as? [[String: Any]] ?? []).compactMap { row -> (String, String)? in
                guard let content = row["content"] as? String else { return nil }
                return (content, row["description"] as? String ?? content)
            }
            rows[id] = (text, list.map { (content: $0.0, description: $0.1) })
            refresh()
            return nil
        default:
            throw ExtensionShims.Unsupported(what: "\(api) isn't available in \(Brand.name)")
        }
    }

    private func refresh() {
        guard let field, field.query.scope?.extensionID != nil else { return }
        field.guessAgain()
    }

    // MARK: - the port

    func connect(_ port: WKWebExtension.MessagePort, from id: String) {
        if let old = ports[id], old !== port { old.disconnect() }
        ports[id] = port
        port.messageHandler = { [weak self, weak port] message, _ in
            MainActor.assumeIsolated {
                guard let self, let port, let body = message as? [String: Any] else { return }
                if (body["__yabNative"] as? String) == "here?" { port.sendMessage(["__yabNative": "here"]) { _ in } }
                // The worker's word that it listens: what waited goes.
                if body["ready"] != nil {
                    port.sendMessage(["heard": true]) { _ in }
                    self.flush(id)
                }
            }
        }
        port.disconnectHandler = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.ports[id] === port else { return }
                self.ports[id] = nil
            }
        }
    }

    private func send(_ id: String, _ message: [String: Any]) {
        if let port = ports[id], !port.isDisconnected {
            port.sendMessage(message) { _ in }
            return
        }
        // Asleep: woken, and the event waits for its port.
        waiting[id, default: []].append(message)
        let (signIn, named) = ExtensionExternal.parts(id)
        let owner = Extensions.instance(signIn)
        if waiting[id]?.count == 1, let context = owner.contexts[named], context.webExtension.hasBackgroundContent {
            owner.trace(named, "the omnibox woke the worker")
            context.loadBackgroundContent { _ in }
        }
    }

    private func flush(_ id: String) {
        guard let port = ports[id], let list = waiting.removeValue(forKey: id) else { return }
        for message in list { port.sendMessage(message) { _ in } }
    }

    // MARK: - Chromium tabs (CEF patch 0124)

    // In a Chromium tab the extension runs in Chrome, and so does its
    // omnibox API: Yab's field hands the words to Chrome's own
    // ExtensionOmniboxEventRouter (onInputStarted, onInputChanged with a
    // request id, onInputEntered with the disposition, onInputCancelled), as
    // Chrome's KeywordProvider does from its omnibox, and omnibox.suggest's
    // rows come back for that request (`extension.omniboxSuggestions`).
    // The keyword is the manifest's, read from the folder Chrome loaded the
    // extension from. A helper without 0124 offers no keyword.

    /// The field's id of a Chromium extension's keyword, and back.
    nonisolated static let chromiumPrefix = "chromium:"
    nonisolated static func chromiumID(_ id: String) -> String? {
        guard id.hasPrefix(chromiumPrefix) else { return nil }
        let extensionID = String(id.dropFirst(chromiumPrefix.count))
        return ChromiumSidePanel.validExtensionID(extensionID) ? extensionID : nil
    }

    private var keywords: [String: (version: String, keyword: String?)] = [:]

    private func chromiumScope(for text: String) -> Scope? {
        guard ChromiumProcess.shared.extensionSurfaces.omnibox,
              let tab = BrowserWindows.shared.activeBrowser?.active, tab.engineKind == .chromium,
              let native = ChromiumColumn.shared.native(for: tab) else { return nil }
        for item in ChromiumColumn.shared.items(native, for: tab) where item.enabled {
            guard let keyword = keyword(of: item), keyword == text else { continue }
            var scope = Scope(id: "omnibox:" + Self.chromiumPrefix + item.id, name: item.name, template: "")
            scope.aliases = [keyword]
            scope.extensionID = Self.chromiumPrefix + item.id
            return scope
        }
        return nil
    }

    /// The manifest's omnibox keyword, lowercased, its __MSG_ name resolved
    /// in the default locale as Chrome resolves it (OmniboxInfo).
    private func keyword(of item: ChromiumExtensions.Item) -> String? {
        if let known = keywords[item.id], known.version == item.version { return known.keyword }
        var found: String?
        if let path = item.path {
            let folder = URL(fileURLWithPath: path)
            found = Self.keyword(manifest: try? Data(contentsOf: folder.appendingPathComponent("manifest.json"))) { locale, name in
                let file = folder.appendingPathComponent("_locales").appendingPathComponent(locale).appendingPathComponent("messages.json")
                guard let data = try? Data(contentsOf: file),
                      let messages = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                let entry = messages.first { $0.key.lowercased() == name.lowercased() }?.value as? [String: Any]
                return entry?["message"] as? String
            }
        }
        keywords[item.id] = (item.version, found)
        return found
    }

    nonisolated static func keyword(manifest data: Data?, message: (String, String) -> String?) -> String? {
        guard let data, let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let omnibox = manifest["omnibox"] as? [String: Any], var keyword = omnibox["keyword"] as? String else { return nil }
        if keyword.hasPrefix("__MSG_"), keyword.hasSuffix("__"), let locale = manifest["default_locale"] as? String {
            keyword = message(locale, String(keyword.dropFirst(6).dropLast(2))) ?? ""
        }
        let text = keyword.trimmingCharacters(in: .whitespaces).lowercased()
        return text.isEmpty ? nil : text
    }

    /// The input, to Chrome for the field's Chromium tab in front.
    private func tellChromium(_ id: String, _ event: String, text: String = "", disposition: String = "currentTab") {
        guard let extensionID = Self.chromiumID(id),
              let page = (field ?? BrowserWindows.shared.activeBrowser)?.active?.builtPage as? ChromiumPage else { return }
        let request = self.request
        Task { @MainActor [weak self] in
            let reply = await page.extensionSurface("extension.omnibox", [
                "extension": .string(extensionID), "event": .string(event), "text": .string(text),
                "requestId": .number(Double(request)), "disposition": .string(disposition)])
            guard let self else { return }
            if let description = reply?["default"].string { self.defaults[id] = description; self.refresh() }
        }
    }

    /// `extension.omniboxSuggestions`: only the answer to the words still in
    /// the field counts, as for a WebKit extension's.
    func chromiumSuggested(_ extensionID: String, request answered: Int, rows list: [(content: String, description: String)]) {
        let id = Self.chromiumPrefix + extensionID
        guard answered == request, let text = asked[id] else { return }
        rows[id] = (text, list)
        refresh()
    }

    nonisolated static func chromiumSuggestions(_ params: [String: JSONValue]) -> (extensionID: String, request: Int, list: [(content: String, description: String)])? {
        guard let id = params["extensionId"]?.string, ChromiumSidePanel.validExtensionID(id),
              let request = params["requestId"]?.number, case .array(let rows)? = params["suggestions"] else { return nil }
        let list = rows.prefix(64).compactMap { row -> (content: String, description: String)? in
            guard let content = row["content"].string else { return nil }
            return (content, row["description"].string ?? content)
        }
        return (id, Int(request), list)
    }
}
