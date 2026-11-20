import YabStore
import Foundation
import Security
import WebKit

// Cookies that last only while the browser does ("session" cookies, no
// expiry) are how some sites keep a sign-in (e2b's did, Railway's didn't)
// or a choice: the account YouTube was switched to is one, and every
// relaunch opened it on the first Google account again. Yab brings its
// tabs back, so it brings these back too, as Arc always does: every quit, ⌘Q,
// an update, a hidden Yab going on its own (Headless), keeps them in the
// keychain, and the next launch, hidden or not, puts them back. Not kept
// longer than a week.
//
// Not only on the way out: a crash, Force Quit, a kill from outside or a
// Mac that loses power runs no quit handler, and every sign-in held in a
// session cookie went with it, the next launch opening the same tabs
// signed out ("Yab signs you out more than any other browser", 2026-10-10).
// Chrome writes them down as it goes when it continues where you left off.
// So the keychain item follows the jar while Yab runs: a change in any
// store is looked at half a minute later and written only when the session
// cookies themselves changed (watch). Put back at launch, the item stays,
// so a second crash before anything changes loses nothing either.
@MainActor
enum KeptCookies {
    nonisolated static let service = (Bundle.main.bundleIdentifier ?? Store.productionBundleID) + ".session-cookies." + Store.name
    nonisolated private static let account = "session"
    private static let lifetime: TimeInterval = 7 * 24 * 3600
    // Even a missing per-probe item can wait on the shared securityd.
    // Ordinary test worlds use only their isolated WebKit cookie stores;
    // the headless --keychain integration check explicitly opts in.
    private static var usesKeychain: Bool {
        !Store.testing || ProcessInfo.processInfo.environment["YAB_TEST_KEYCHAIN"] == "1"
    }

    /// Filtering, comparing, encoding and the keychain, on a queue of their
    /// own: a sweep of a jar of thousands of cookies every half minute is
    /// no work for the window (docs/main-thread-budget.md).
    nonisolated static let keeper = CookieKeeper(write: { write($0) }, remove: { remove() })

    /// The stores sign-ins live in: the first space's, shared by every
    /// space that shares its sign-ins, and those of spaces with their own
    /// that were opened in this run.
    private static var stores: [(String, WKWebsiteDataStore)] {
        [("first", Store.websites)] + Spaces.madeStores.map { ($0.key.uuidString, $0.value) }
    }

    /// The session cookies of every store, into the keychain; then `done`,
    /// at the latest after two seconds. The deadline is a timer on the run
    /// loop in every mode, not the main queue: a quit waiting on it
    /// (terminateLater) turns a modal loop that a block on the queue can
    /// sit behind (Farewell). So the keeper's work is waited for here, on
    /// the way out, and never left to a block sent back to the main queue.
    static func save(_ done: @escaping @MainActor () -> Void) {
        guard usesKeychain else { done(); return }
        gather { jars, at, _ in
            // Out of time, what came is still the best there is to keep.
            keeper.keepNow(jars, at: at)
            done()
        }
    }

    /// Every store's whole jar as WebKit hands it over, untouched, then
    /// `got` once, with whether every store answered within two seconds.
    private static func gather(_ got: @escaping @MainActor ([String: [HTTPCookie]], Date, Bool) -> Void) {
        var jars: [String: [HTTPCookie]] = [:]
        let at = Date()
        let all = stores
        var left = all.count
        var finished = false
        func finish() {
            guard !finished else { return }
            finished = true
            got(jars, at, left == 0)
        }
        for (key, store) in all {
            store.httpCookieStore.getAllCookies { cookies in
                MainActor.assumeIsolated {
                    MainBudget.chunk("cookies.sweep") { jars[key] = cookies }
                    left -= 1
                    if left == 0 { finish() }
                }
            }
        }
        let deadline = Timer(timeInterval: 2, repeats: false) { _ in MainActor.assumeIsolated { finish() } }
        RunLoop.main.add(deadline, forMode: .common)
    }

    // MARK: - kept as they change

    private static var watched: Set<ObjectIdentifier> = []
    private static var due = false
    private static let observer = KeptCookiesObserver()

    /// Follows a store that keeps sign-ins (LastingSignIns.keep): what
    /// changes in it reaches the keychain within half a minute.
    static func watch(_ store: WKWebsiteDataStore) {
        guard usesKeychain, store.isPersistent, watched.insert(ObjectIdentifier(store)).inserted else { return }
        store.httpCookieStore.add(observer)
    }

    /// Pages change cookies all the time, analytics on every click: one
    /// look half a minute after the first change, then quiet until the next.
    fileprivate static func changed() {
        guard !due else { return }
        due = true
        let later = Timer(timeInterval: 30, repeats: false) { _ in
            MainActor.assumeIsolated {
                due = false
                gather { jars, at, whole in
                    // A store that didn't answer would read as signed out.
                    if whole { keeper.keepLater(jars, at: at) }
                }
            }
        }
        later.tolerance = 5
        RunLoop.main.add(later, forMode: .common)
    }

    /// A session cookie was just taken out (the engine bridge carried a
    /// sign-out): the keychain follows now. Half a minute on, a crash in
    /// between would put the ended sign-in back at the next launch.
    static func keepSoon() {
        guard usesKeychain else { return }
        gather { jars, at, whole in
            if whole { keeper.keepLater(jars, at: at) }
        }
    }

    private static let restoration = SignInReadiness()

    /// What the last run kept, back in the stores, once per launch. Pages
    /// wait for every setCookie reply, not just for the calls to be sent.
    static func restore(_ done: @escaping @MainActor () -> Void = {}) {
        restoration.whenReady(prepare: { ready in
            guard usesKeychain, let kept = keeper.restore(read(), lifetime: lifetime) else { ready(); return }
            let pending = DispatchGroup()
            for (key, cookies) in kept.stores {
                let store = key == "first" ? Store.websites : UUID(uuidString: key).map(Spaces.store(for:))
                guard let store else { continue }
                for kept in cookies {
                    guard let cookie = kept.cookie else { continue }
                    pending.enter()
                    store.httpCookieStore.setCookie(cookie) { pending.leave() }
                }
            }
            pending.notify(queue: .main) { MainActor.assumeIsolated { ready() } }
        }, done: done)
    }

    // MARK: - the keychain

    nonisolated static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    nonisolated private static func write(_ data: Data) {
        let changed = Keychain.update(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard changed == errSecItemNotFound else { return }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel as String] = "\(Store.name) session sign-ins"
        Keychain.add(item as CFDictionary, nil)
    }

    nonisolated private static func read() -> Data? {
        var ask = query
        ask[kSecReturnData as String] = true
        ask[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: AnyObject?
        guard Keychain.copyMatching(ask as CFDictionary, &found) == errSecSuccess else { return nil }
        return found as? Data
    }

    nonisolated private static func remove() {
        Keychain.delete(query as CFDictionary)
    }

}

/// What KeptCookies keeps and when it writes, on its own serial queue:
/// sweeps are kept in the order they were taken, the item is written only
/// when the session cookies changed or a day went by, and removed when
/// there are none. `write` and `remove` are the keychain, or a test's.
final class CookieKeeper: @unchecked Sendable {
    struct Kept: Codable {
        var saved: Date
        var stores: [String: [Cookie]]
    }

    struct Cookie: Codable, Equatable {
        var name, value, domain, path: String
        var secure, httpOnly: Bool
        var sameSite: String?

        init(name: String, value: String, domain: String, path: String, secure: Bool, httpOnly: Bool, sameSite: String?) {
            self.name = name; self.value = value; self.domain = domain; self.path = path
            self.secure = secure; self.httpOnly = httpOnly; self.sameSite = sameSite
        }

        init(_ cookie: HTTPCookie) {
            self.init(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path, secure: cookie.isSecure,
                      httpOnly: cookie.isHTTPOnly, sameSite: cookie.sameSitePolicy?.rawValue)
        }

        /// As a store takes it back.
        var cookie: HTTPCookie? {
            var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
            // Either key, there at all, makes it so, whatever it says.
            if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if secure { properties[.secure] = "TRUE" }
            // WebKit says "none" for a cookie that named no policy, and
            // drops a cookie set as none that isn't secure: only a
            // policy the site named goes back.
            if let sameSite = sameSite?.lowercased(), sameSite == "lax" || sameSite == "strict" { properties[.sameSitePolicy] = sameSite }
            return HTTPCookie(properties: properties)
        }
    }

    let queue = DispatchQueue(label: "yab.kept-cookies", qos: .utility)
    private let write: (Data) -> Void
    private let remove: () -> Void
    /// The stores' part of the item as this run last wrote it, and when;
    /// `known`: whether this run knows what the item holds at all. The
    /// queue's alone.
    private var written: Data?
    private var writtenAt: Date?
    private var known = false

    init(write: @escaping (Data) -> Void, remove: @escaping () -> Void) {
        self.write = write
        self.remove = remove
    }

    /// Whole jars, kept on the queue; the caller goes on at once.
    func keepLater(_ jars: [String: [HTTPCookie]], at: Date) {
        queue.async { self.keep(Self.session(jars), at: at) }
    }

    /// Whole jars, kept before this returns: the way out.
    func keepNow(_ jars: [String: [HTTPCookie]], at: Date) {
        queue.sync { self.keep(Self.session(jars), at: at) }
    }

    /// The session cookies of each jar, the ones gone with the browser.
    static func session(_ jars: [String: [HTTPCookie]]) -> [String: [Cookie]] {
        MainBudget.chunk("cookies.filter") {
            var out: [String: [Cookie]] = [:]
            for (key, cookies) in jars {
                let session = cookies.filter(\.isSessionOnly).map(Cookie.init)
                if !session.isEmpty { out[key] = session }
            }
            return out
        }
    }

    /// Into the keychain, or the item gone when there is nothing to keep;
    /// left alone when it already says the same and was written today.
    /// On the queue.
    func keep(_ stores: [String: [Cookie]], at: Date) {
        dispatchPrecondition(condition: .onQueue(queue))
        MainBudget.chunk("cookies.keep") {
            guard !stores.isEmpty else {
                if written != nil || !known { remove() }
                written = nil
                known = true
                return
            }
            guard let print = Self.fingerprint(stores) else { return }
            if print == written, let writtenAt, at.timeIntervalSince(writtenAt) < 24 * 3600 { return }
            guard let data = try? JSONEncoder().encode(Kept(saved: at, stores: stores)) else { return }
            write(data)
            written = print
            writtenAt = at
            known = true
        }
    }

    /// The item read at launch: what it keeps, if young enough, and from
    /// then on what this run knows the item holds. An item too old or
    /// unreadable is removed.
    func restore(_ data: Data?, lifetime: TimeInterval, now: Date = Date()) -> Kept? {
        queue.sync {
            guard let data else { known = true; return nil }
            guard let kept = try? JSONDecoder().decode(Kept.self, from: data), now.timeIntervalSince(kept.saved) < lifetime else {
                remove()
                known = true
                return nil
            }
            written = Self.fingerprint(kept.stores)
            writtenAt = kept.saved
            known = true
            return kept
        }
    }

    /// Everything queued so far, done.
    func settle() { queue.sync {} }

    /// The stores' cookies in one order whatever order they came in, to
    /// tell whether anything changed.
    static func fingerprint(_ stores: [String: [Cookie]]) -> Data? {
        let sorted = stores.mapValues { $0.sorted { ($0.domain, $0.path, $0.name) < ($1.domain, $1.path, $1.name) } }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(sorted)
    }
}

/// A change in a watched store's jar (KeptCookies.watch); WebKit calls it
/// on the main thread.
private final class KeptCookiesObserver: NSObject, WKHTTPCookieStoreObserver {
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        // WebKit enters from a native callback, without a Swift executor
        // guarantee. A fresh hop establishes one; checking the caller's
        // executor here crashed before changed() in #1318 and #1321.
        Task { @MainActor in KeptCookies.changed() }
    }
}
