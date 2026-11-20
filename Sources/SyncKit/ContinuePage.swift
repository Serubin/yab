import Foundation

/// The page in front, carried to another device by Handoff: the Dock's
/// Handoff icon on a Mac and the card in the iPhone's app switcher. Both apps
/// list `type` in NSUserActivityTypes and are signed by the same team, which
/// is all Handoff asks; the page itself travels in the activity, between the
/// devices of one Apple ID, and never through the sync server.
///
/// A device without Yab opens `webpageURL` in its own browser, which is what
/// that field is for. This file holds what both ends agree on: which pages
/// are offered, what is sent, and what is accepted from the other end.
public enum ContinuePage {
    public static let type = "net.serubin.pane.page"
    /// Safari's type, which the Mac hands to the default browser: Yab takes
    /// it too (a Mac where Yab is the default browser) and reads it the same.
    public static let webType = "NSUserActivityTypeBrowsingWeb"
    /// The space the page was in, as sync names it, in `userInfo`.
    public static let spaceKey = "space"
    static let titleLimit = 200

    /// A page worth offering.
    public struct Page: Equatable, Sendable {
        public var url: URL
        public var title: String
        public var space: String?

        public var userInfo: [String: String] { space.map { [ContinuePage.spaceKey: $0] } ?? [:] }
    }

    /// A page picked up from the other device.
    public struct Arrival: Equatable, Sendable {
        public var url: URL
        public var space: String?
    }

    /// The page to offer for what is in front, or nil when it is not one to
    /// offer: not a web address, a private page, an address only this device
    /// can reach, or one with a sign-in in it.
    public static func page(url: URL?, title: String, space: String?) -> Page? {
        guard let url, let web = OpenOnMac.url(url.absoluteString), !local(web) else { return nil }
        var title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = web.host(percentEncoded: false) ?? web.absoluteString }
        if title.count > titleLimit { title = String(title.prefix(titleLimit)) }
        let space = space?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Page(url: web, title: title, space: space?.isEmpty == false ? space : nil)
    }

    /// What arrived, trusted no further than an address from anywhere: only
    /// a web page, nothing with credentials in it.
    public static func arrival(webpageURL: URL?, userInfo: [AnyHashable: Any]?) -> Arrival? {
        guard let webpageURL, let url = OpenOnMac.url(webpageURL.absoluteString) else { return nil }
        let space = (userInfo?[spaceKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Arrival(url: url, space: space?.isEmpty == false ? space : nil)
    }

    /// Two addresses that are one page: the host in any case, `www.` and a
    /// slash at the end set aside, the scheme too (a page that moved to https
    /// is the same page), the query kept, the fragment not.
    public static func same(_ a: URL, _ b: URL) -> Bool { key(a) == key(b) }

    static func key(_ url: URL) -> String {
        var host = (url.host(percentEncoded: false) ?? "").lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = url.path(percentEncoded: true)
        while path.hasSuffix("/") { path.removeLast() }
        let port = url.port.map { ":\($0)" } ?? ""
        let query = url.query(percentEncoded: true).map { "?\($0)" } ?? ""
        return host + port + path + query
    }

    /// Whether a space named by the other device is this one (sync names a
    /// space by its UUID, written in either case).
    public static func sameSpace(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }

    /// An address that means a different thing on another device.
    static func local(_ url: URL) -> Bool {
        guard let host = url.host(percentEncoded: false)?.lowercased() else { return true }
        return host == "localhost" || host.hasSuffix(".localhost") || host == "0.0.0.0" || host == "::1"
            || host.hasPrefix("127.") || host == "[::1]"
    }
}
