import Foundation

/// An agent's permission to work in a tab never includes extension vaults or
/// a wallet's recovery-phrase entry. Chromium keeps this boundary in isolated worlds and
/// authenticates frame origins through the helper, not page-supplied labels.
@MainActor
enum AgentSecrets {
    struct Refused: LocalizedError {
        let message: String
        @MainActor init(_ page: (any PageHandle)? = nil) { message = page.map { AgentSecrets.refusal(for: $0) } ?? AgentSecrets.refusal }
        var errorDescription: String? { message }
    }

    // This fixed Chromium component is a document renderer, not an installed
    // extension vault. Match the authenticated origin, never a page label or
    // an occurrence of its id in an ordinary address.
    nonisolated static func builtInPDFViewer(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == "chrome-extension" &&
            url?.host?.lowercased() == "mhjfbmdgcfjbbpaeojofohoefgiehjai"
    }

    nonisolated static func protected(_ url: URL?) -> Bool {
        guard let url else { return false }
        let scheme = url.scheme?.lowercased() ?? ""
        if ["chrome-extension", "webkit-extension", "safari-web-extension", "moz-extension"].contains(scheme) { return true }
        if ["blob", "filesystem"].contains(scheme) {
            // Nested origins are bounded. Unknown or deeply nested wrappers
            // are refused rather than accepted as an ordinary document.
            var raw = url.absoluteString
            for _ in 0..<4 {
                guard let current = URL(string: raw), let prefix = current.scheme?.lowercased() else { return true }
                if ["blob", "filesystem"].contains(prefix) { raw = String(raw.dropFirst(prefix.count + 1)); continue }
                return protected(current)
            }
            return true
        }
        return false
    }

    /// What the guard is for: an agent never reads or acts on an extension's
    /// own pages (password vaults, wallets) or a wallet's recovery-phrase
    /// entry. It is not a scan for scary words. Body text, hashes, wallet
    /// addresses and the size of a page say nothing: Apple's Certificates,
    /// Identifiers & Profiles mention "private key", Gmail and Figma are huge,
    /// every page with an ad has a cross-origin frame. Only fields count: a
    /// field whose own hints (name, id, placeholder, aria-label, autocomplete,
    /// its labels, its group's legend) name a seed or recovery phrase, or a
    /// field holding a PEM private key. Only a fixed reason leaves the
    /// renderer, never a word of the page.
    static let reasonProbe = #"""
    (() => {
      const phrase = /\b(?:seed|recovery|backup|mnemonic)\s+(?:phrase|words?)\b|\bmnemonic\b/iu;
      const pem = /-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----/u;
      const skip = /^(?:hidden|button|submit|reset|image|checkbox|radio|file|range|color)$/iu;
      const words = node => node ? (node.textContent || '') : '';
      const hintsOf = field => {
        const own = ['name', 'id', 'placeholder', 'aria-label', 'autocomplete'].map(key => field.getAttribute(key) || '');
        const labels = Array.from(field.labels || [], words);
        const root = field.getRootNode();
        const by = (field.getAttribute('aria-labelledby') || '').split(/\s+/u).filter(Boolean)
          .map(id => words(root.getElementById ? root.getElementById(id) : null));
        const group = field.closest('fieldset,[role=group]');
        const legend = group ? [group.getAttribute('aria-label') || '', words(group.querySelector(':scope > legend'))] : [];
        return [...own, ...labels, ...by, ...legend].join(' ').replace(/([a-z])([A-Z])/gu, '$1 $2').replace(/[_-]+/gu, ' ');
      };
      const roots = [document];
      while (roots.length) {
        const root = roots.pop();
        for (const node of root.querySelectorAll('*')) {
          if (node.shadowRoot) roots.push(node.shadowRoot);
          const name = node.localName;
          const editable = node.hasAttribute('contenteditable') && node.getAttribute('contenteditable') !== 'false';
          if (name !== 'input' && name !== 'textarea' && !editable) continue;
          if (name === 'input' && skip.test(node.type || '')) continue;
          if (phrase.test(hintsOf(node))) return 'recovery phrase field';
          const value = name === 'input' || name === 'textarea' ? node.value : node.textContent;
          if (value && value.length < 100000 && pem.test(value)) return 'private key field';
        }
      }
      return false;
    })()
    """#

    static var probe: String { "Boolean(\(reasonProbe))" }

    static let reasons: [String: String] = [
        "extension page": "it is an extension's own page (a password manager, wallet or other extension)",
        "extension frame": "an extension's frame is open on it (a password manager's or wallet's own window)",
        "recovery phrase field": "it has a recovery-phrase field (a wallet's seed words)",
        "private key field": "it has a field holding a private key",
    ]

    static func message(_ reason: String) -> String {
        "\(Brand.name) keeps agents off this page because \(reasons[reason] ?? reason). The person must handle it; continue after they leave this page."
    }

    private static var found: [ObjectIdentifier: String] = [:]
    static var refusal: String { message("extension page") }
    static func refusal(for page: any PageHandle) -> String {
        message(found[ObjectIdentifier(page)] ?? "extension page")
    }

    // Keep the caller's JavaScript line numbers: this prefix adds no lines.
    // Remove whole-line comments before joining; otherwise // would consume
    // the following statements when the probe is put on one line.
    private static let inlineProbe = reasonProbe.split(separator: "\n")
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: " ")

    static var guardBody: String {
        let field = String(reflecting: message("recovery phrase field")), key = String(reflecting: message("private key field"))
        return "{ const reason = \(inlineProbe); if (reason) throw new Error(reason === 'private key field' ? \(key) : \(field)); } "
    }

    /// Why the last check refused, for the helper's log; never page words.
    private static func refuse(_ why: String) -> Bool {
        FileHandle.standardError.write(Data("yab: agent guard refused: \(why)\n".utf8))
        return false
    }

    /// A browser-native question can suspend every renderer request. This
    /// response contains no page-supplied words or tool result. It is not a
    /// successful guard: only a fresh check after the person answers may
    /// release page data, including the question's own message.
    static func nativeQuestionReply(_ tabs: [Tab]) -> [String: Any]? {
        guard tabs.contains(where: { $0.engineKind == .chromium && $0.asks.contains(where: \.fromPage) }) else { return nil }
        return ["error": "The page is waiting for the person to answer its question in \(Brand.name). Continue after they answer.",
                "needs_user": true, "code": "NATIVE_PAGE_QUESTION"]
    }

    /// Refuses only for an extension's page or frame and for the fields
    /// above. Whatever cannot be checked (a frame with no script context, a
    /// frame that came or went during the check, a probe that failed) is
    /// left out and logged; it never refuses the whole page.
    static func check(_ page: any PageHandle) async -> Bool {
        let id = ObjectIdentifier(page)
        found[id] = nil
        func refuse(_ reason: String, _ why: String) -> Bool {
            found[id] = reason
            return AgentSecrets.refuse(why)
        }
        // An extension's own PDF is still an extension document. Only the
        // browser's fixed component may be treated as a document renderer.
        guard !protected(page.url) || (page is ChromiumPage && builtInPDFViewer(page.url)) else {
            return refuse("extension page", "extension address")
        }
        // A PDF has no fields to type a phrase into.
        if page.webKit?.webKitShowsPDF == true { return true }
        func probe(_ frame: PageFrame?) async -> String? {
            do {
                let result = try await page.call("return " + reasonProbe, in: .agent, frame: frame, gesture: false)
                if let reason = result as? String, reasons[reason] != nil { return reason }
                if result as? Bool != false { skipped("probe gave \(String(describing: result))") }
            } catch { skipped("probe failed: \(error)") }
            return nil
        }
        guard let chromium = page as? ChromiumPage else {
            let frames = await withCheckedContinuation { continuation in
                page.childFrames { continuation.resume(returning: $0) }
            }
            if frames.contains(where: { protected($0.url) }) { return refuse("extension frame", "extension frame") }
            for frame in [nil] + frames.map({ Optional($0) }) {
                if let reason = await probe(frame) { return refuse(reason, reason) }
            }
            return true
        }
        // Chromium: every attached renderer, with authenticated origins. A
        // frame that appears while checking is checked on the next pass.
        var checked = Set<String>()
        for pass in 0..<3 {
            let frames: [PageFrame]
            do { frames = try await chromium.agentFrames() } catch {
                skipped("frame inventory: \(error)")
                if pass == 0, let reason = await probe(nil) { return refuse(reason, reason) }
                return true
            }
            var fresh = false
            for frame in frames {
                let origin = URL(string: frame.origin.scheme + "://" + frame.origin.host)
                let pdfViewer = builtInPDFViewer(frame.url) && builtInPDFViewer(origin)
                guard pdfViewer || (!protected(frame.url) && !protected(origin)) else {
                    return refuse(frame.isMain ? "extension page" : "extension frame", "extension frame")
                }
                guard let token = try? chromium.scripts.token(frame, tab: chromium.remoteID) else {
                    skipped("a frame without a script context"); continue
                }
                guard checked.insert(token).inserted else { continue }
                fresh = true
                if pdfViewer { continue }
                if let reason = await probe(frame) { return refuse(reason, reason) }
            }
            if !fresh || pass == 2 {
                if fresh { skipped("frames still changing after three passes") }
                return true
            }
        }
        return true
    }

    /// Something the guard could not look at, for the helper's log.
    private static func skipped(_ why: String) {
        FileHandle.standardError.write(Data("yab: agent guard left out: \(why)\n".utf8))
    }
}
