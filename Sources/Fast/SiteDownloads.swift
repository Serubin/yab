import Foundation
import AppKit

// A file a site starts sending on its own, from a timer or a redirect with
// nobody's click behind it, is asked about first: "<site>
// wants to download a file", Allow or Don't Allow, the answer kept for the
// site until Yab quits. What you started goes ahead as before: a click, a
// menu's Download, an address typed in the field (a load Yab made that
// turned into a file before any page came up), an extension's, an agent's.
//
// A click gets one file. A page that starts more after it, three from one
// press, is asked about the rest: "<site> wants to
// download multiple files", Allow or Don't Allow, the answer kept for the
// site (Site Controls › Automatic downloads lets it go). The next click
// gets one again.
//
// Files a page sends while its card is up wait on that one card, the
// unasked ones too, and a second file makes it the "multiple files" card:
// a download Google Drive splits into parts, each started seconds after the
// click, is asked about once and every part comes (#1940). A site whose
// automatic downloads are Allowed sends its first unasked file too.
//
// On Chromium the answer is also the origin's AUTOMATIC_DOWNLOADS, which
// Chromium's own limiter reads before a file ever reaches Yab: Yab writes it
// for the origins it was given on (ChromiumPermissions), and Chromium keeps
// none of its own (YabCore's AnswerDownloads), so what Site Controls lists
// is all there is.
//
// And every file from the web is marked for quarantine, so macOS checks
// an app, a disk image or an installer from it before it first opens.

@MainActor
enum SiteDownloads {
    /// Pages Yab itself was asked to load, until they show a document: a
    /// file met on the way there is the one you asked for.
    private static var opened: [ObjectIdentifier: Date] = [:]
    /// Downloads a page's script or a redirect started, to be asked about.
    private static var started = Set<ObjectIdentifier>()
    /// The answers, by site, until quit.
    private static var said: [String: Bool] = [:]

    /// Yab loading an address into the page (WKWebView.open).
    static func open(_ webView: NSView) {
        opened[ObjectIdentifier(webView)] = Date()
    }

    /// A document came up: whatever it starts later is its own doing.
    static func committed(_ webView: NSView) {
        opened[ObjectIdentifier(webView)] = nil
        since[ObjectIdentifier(webView)] = nil
    }

    // MARK: - more files than a click asked for

    /// Files a page started since your last click or key in it, by page.
    private static var since: [ObjectIdentifier: (input: TimeInterval?, count: Int)] = [:]
    nonisolated private static func manyKey(_ site: String) -> String { manyPrefix + site }

    /// The site to ask about, if this download is one more than the click
    /// before it asked for; nil when it goes ahead. Counted once a download.
    static func more(_ download: any PageDownload) -> String? {
        guard let web = download.sourceView, let page = download.pageURL,
              ["http", "https"].contains(page.scheme?.lowercased() ?? ""),
              let host = page.host(), !host.isEmpty else { return nil }
        let input = download.page?.lastInput
        let key = ObjectIdentifier(web)
        var seen = since[key] ?? (input: input, count: 0)
        // A new click or key in the page: one file more is its own.
        if seen.input != input { seen = (input: input, count: 0) }
        seen.count += 1
        since[key] = seen
        return seen.count > 1 ? host : nil
    }

    nonisolated static let manyPrefix = "downloads.many."
    /// The origins the site's answer was given on (Browser.origin's
    /// spelling): Chromium keeps a site's automatic downloads per origin,
    /// and is told Yab's answer for each (ChromiumPermissions).
    nonisolated private static func askedOnKey(_ site: String) -> String { "downloads.askedOn." + site }

    nonisolated static func askedOn(_ site: String, in settings: [String: Any]) -> [String] {
        settings[askedOnKey(site)] as? [String] ?? []
    }

    /// What the site was told about more files than a click asks for:
    /// kept until it is let go in Site Controls.
    static func many(for host: String) -> Bool? {
        Store.settings.object(forKey: manyKey(Browser.site(host))) as? Bool
    }

    static func rememberMany(_ host: String, _ yes: Bool, origin: String? = nil) {
        let site = Browser.site(host)
        if let origin {
            let asked = Store.settings.stringArray(forKey: askedOnKey(site)) ?? []
            if !asked.contains(origin) { Store.settings.set(asked + [origin], forKey: askedOnKey(site)) }
        }
        Store.settings.set(yes, forKey: manyKey(site))
    }

    static func forgetMany(_ host: String) {
        let site = Browser.site(host)
        Store.settings.removeObject(forKey: manyKey(site))
        Store.settings.removeObject(forKey: askedOnKey(site))
    }

    /// A navigation that became a file: noted when nobody started it.
    static func became(_ download: any PageDownload, in webView: NSView, url: URL?) {
        if let at = opened[ObjectIdentifier(webView)], Date().timeIntervalSince(at) < 30 { return }
        guard !download.isUserInitiated, let page = url,
              ["http", "https"].contains(page.scheme?.lowercased() ?? "") else { return }
        started.insert(ObjectIdentifier(download))
    }

    /// The site to ask about, if this download needs asking; nil when it
    /// goes ahead. Taken once.
    static func asking(_ download: any PageDownload) -> String? {
        guard started.remove(ObjectIdentifier(download)) != nil,
              let host = download.pageURL?.host(), !host.isEmpty else { return nil }
        return host
    }

    static func answer(for host: String) -> Bool? { said[Browser.site(host)] }

    static func remember(_ host: String, _ yes: Bool) { said[Browser.site(host)] = yes }

    /// Marked for quarantine, so Gatekeeper asks before an
    /// app or an installer from it opens. macOS 27 left the addresses
    /// given here out of its quarantine event (checked 2026-10-15); they
    /// are on the file anyway, as kMDItemWhereFroms. Yab's own updates
    /// never come through here (Updater.swift).
    nonisolated static func quarantine(_ file: URL, from source: URL?, page: URL?) {
        var properties: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "\(Brand.name)",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
        ]
        if let source, ["http", "https"].contains(source.scheme?.lowercased() ?? "") {
            properties[kLSQuarantineDataURLKey as String] = source
        }
        if let page { properties[kLSQuarantineOriginURLKey as String] = page }
        var values = URLResourceValues()
        values.quarantineProperties = properties
        var marked = file
        try? marked.setResourceValues(values)
    }
}
