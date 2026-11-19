import Foundation
import OSLog

/// WebAuthn's related origins (Level 3, "Related Origin Requests"): a site
/// that lives at more than one address names the others in a file of its
/// own, https://<rp>/.well-known/webauthn, and a page at one of them may ask
/// for the passkeys made for <rp>. X is the case that brought it here: its
/// passkeys were made on twitter.com and sign-in is on x.com, and
/// twitter.com's file lists https://x.com. Without it, every passkey request
/// from x.com was refused before the Mac's sheet, as another site's.
///
/// The file is fetched with no cookies and no redirects, and read as
/// Chrome and Safari read it: at most five site labels ("twitter", "x")
/// count, and the caller must be one of the listed origins exactly.
enum RelatedOrigins {
    private static let log = Logger(subsystem: Store.productionBundleID, category: "RelatedOrigins")

    /// The most distinct labels a file may bring in, the standard's floor.
    static let labels = 5

    /// The origins each relying party listed, kept for the launch.
    @MainActor private static var known: [String: [String]] = [:]

    /// Whether the site at `rp` names `origin` as its own.
    @MainActor static func allow(rp: String, origin: String) async -> Bool {
        let rp = rp.lowercased()
        guard valid(rp) else { return false }
        if let origins = known[rp] { return permits(origins, caller: origin) }
        guard let origins = await fetch(rp) else { return false }
        known[rp] = origins
        let allowed = permits(origins, caller: origin)
        log.notice("\(rp, privacy: .public) lists \(origins.count) origins, \(origin, privacy: .public) \(allowed ? "among them" : "not", privacy: .public)")
        return allowed
    }

    /// A name a file can be asked of: a domain, never an address or a
    /// suffix anyone can register under.
    static func valid(_ rp: String) -> Bool {
        guard rp.contains("."), !rp.contains(":"), !rp.contains("/"),
              !rp.allSatisfy({ $0.isNumber || $0 == "." }) else { return false }
        return !(Vault.publicSuffix.map { $0(rp as CFString) } ?? false)
    }

    /// The standard's check, given the file's list: walked in order, a new
    /// label counted only while fewer than five are, and the caller
    /// matched as an origin, scheme, host and port.
    static func permits(_ origins: [String], caller: String) -> Bool {
        guard let mine = normalized(caller) else { return false }
        var seen: Set<String> = []
        for item in origins {
            guard let url = URL(string: item), let host = url.host()?.lowercased(), !host.isEmpty,
                  let label = label(host) else { continue }
            if seen.count >= labels, !seen.contains(label) { continue }
            if normalized(item) == mine { return true }
            if seen.count < labels { seen.insert(label) }
        }
        return false
    }

    /// The label of a host's site, "twitter" for mobile.twitter.com and
    /// "bbc" for bbc.co.uk; nil for an address or a public suffix.
    static func label(_ host: String) -> String? {
        if host.contains(":") || host.allSatisfy({ $0.isNumber || $0 == "." }) { return nil }
        let site = Vault.registrable(host)
        if Vault.publicSuffix.map({ $0(site as CFString) }) ?? false { return nil }
        guard let first = site.split(separator: ".").first, site.contains(".") else { return nil }
        return String(first)
    }

    /// scheme://host[:port], the port left out where it is the scheme's own.
    static func normalized(_ text: String) -> String? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        let port = url.port.flatMap { (scheme == "https" && $0 == 443) || (scheme == "http" && $0 == 80) ? nil : $0 }
        return "\(scheme)://\(host)" + (port.map { ":\($0)" } ?? "")
    }

    /// The origins in a file's body, or nil when it isn't one.
    static func origins(in body: Data) -> [String]? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let list = object["origins"] as? [Any] else { return nil }
        return list.compactMap { $0 as? String }
    }

    private static func fetch(_ rp: String) async -> [String]? {
        guard let url = URL(string: "https://\(rp)/.well-known/webauthn") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (body, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  (http.mimeType ?? "").lowercased() == "application/json" else {
                log.notice("\(rp, privacy: .public): no related origins file")
                return nil
            }
            return origins(in: body)
        } catch {
            log.notice("\(rp, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    /// The standard fetches the file with redirects refused.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
