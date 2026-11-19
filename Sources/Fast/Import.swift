import YabStore
import AppKit
import Foundation
import Security
import SQLite3
import CommonCrypto
import CryptoKit
import os

// Reading what another browser on this Mac already holds.
//
// Every Chromium browser, Chrome, Dia, Arc, Brave, Edge, the rest, keeps its
// passwords the same way: a SQLite file called "Login Data", each password
// encrypted with a key that the browser itself keeps in the macOS keychain
// under "<Name> Safe Storage". macOS asks you before handing that key to
// anyone else, which is the one thing here you have to say yes to. After
// that it is arithmetic: the key is stretched the way Chromium stretches it,
// and each password is unwrapped and put in the keychain under this app's
// name instead.
//
// The file is copied before it is read. The browser it belongs to is usually
// running, and reading its live database underneath it is how you get a lock
// error, or worse, its attention.

enum DefaultBrowserImport {
    static var bundleIdentifier: String? {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return nil }
        return Bundle(url: app)?.bundleIdentifier
    }

    /// nil leaves a person's existing preference alone, including Yab itself.
    static func sidebar(for bundle: String?) -> Bool? {
        guard let bundle, !bundle.isEmpty, bundle != "unknown",
              bundle != Bundle.main.bundleIdentifier,
              !Store.bundleFamily(bundle) else { return nil }
        return bundle == TabImport.arc || bundle == TabImport.dia
    }
}

enum Chromium {
    struct Source: Identifiable, Hashable {
        let name: String
        /// Under ~/Library/Application Support.
        let folder: String
        let service: String
        let account: String
        /// The app itself, so a folder left behind by a browser that was
        /// thrown away doesn't count as a browser.
        let bundle: String
        /// A fixture or an explicitly selected data folder.
        var dataRoot: URL? = nil

        /// A capability carried only through one explicit Bring In operation.
        /// Never persisted in preferences or granted by keychain ACLs.
        private(set) var importRoot: URL? = nil
        var credentialAccess: Bool { importRoot == root }

        func authorizingImport() -> Source {
            var copy = self
            copy.importRoot = root
            return copy
        }

        var id: String { name }

        /// Where the app is, if it is on this Mac at all: as Launch
        /// Services knows it, or, when it doesn't, where the running one
        /// was opened from.
        var app: URL? {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
                ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.bundleURL
        }

        /// The app's own icon, the one in the Dock.
        var icon: NSImage? {
            guard let app else { return nil }
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 64, height: 64)
            return icon
        }

        /// True when links from other apps go to this browser today.
        var isDefault: Bool {
            DefaultBrowserImport.bundleIdentifier == bundle
        }

        /// When it was last browsed in: the newest of its profiles'
        /// History files, which the browser writes as it goes. Nil when no
        /// profile has one.
        var lastUsed: Date? {
            guard credentialAccess else { return nil }
            return profiles
                .map { $0.appendingPathComponent("History") }
                .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
                .max()
        }

        /// Running now, or when it was last browsed in: how recently it
        /// was used, for the import's one primary button.
        var recency: (running: Bool, at: Date) {
            (!NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty, lastUsed ?? .distantPast)
        }

        var root: URL {
            if let dataRoot { return dataRoot }
            return FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(folder, isDirectory: true)
        }

        /// Profiles with any portable browser data, even when no password
        /// database exists. Inspect at most two directory levels and stop
        /// at profiles so Network/Cookies is not counted twice.
        var profiles: [URL] { scan.profiles }

        /// The profiles, and why its data folder couldn't be read when it
        /// is there but macOS kept it from Yab or the read failed: such a
        /// browser is still listed, and says why it has nothing to bring,
        /// rather than not being there at all.
        var scan: (profiles: [URL], trouble: Error?) {
            let files = FileManager.default
            var trouble: Error?
            func folders(in folder: URL) -> [URL] {
                do {
                    return try files.contentsOfDirectory(atPath: folder.path)
                        .filter { !$0.hasPrefix(".") && !Self.credentialName($0) }
                        .compactMap { name in
                            let url = folder.appendingPathComponent(name)
                            var directory: ObjCBool = false
                            return files.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue ? url : nil
                        }
                } catch {
                    if trouble == nil { trouble = error }
                    return []
                }
            }
            var isFolder: ObjCBool = false
            guard files.fileExists(atPath: root.path, isDirectory: &isFolder), isFolder.boolValue else { return ([], nil) }
            let markers = ["Preferences", "Secure Preferences", "Login Data", "Login Data For Account",
                           "Bookmarks", "AccountBookmarks", "History", "Web Data", "Cookies", "Network/Cookies", "Sessions", "Current Session", "Last Session"]
            func isProfile(_ folder: URL) -> Bool {
                // readdir names only: never stat a credential file to discover a profile.
                let names = Set((try? files.contentsOfDirectory(atPath: folder.path)) ?? [])
                return markers.contains { names.contains($0) } || names.contains("Network")
            }
            let candidates = isProfile(root) ? [root] : folders(in: root).flatMap { folder in
                isProfile(folder) ? [folder] : folders(in: folder).filter(isProfile)
            }
            let sorted = candidates
                .sorted {
                    func rank(_ folder: URL) -> (Int, String) {
                        let name = folder.lastPathComponent
                        return (name == "Default" ? -1 : Int(name.split(separator: " ").last ?? "") ?? Int.max, folder.path)
                    }
                    return rank($0) < rank($1)
                }
            return (sorted, sorted.isEmpty ? trouble : nil)
        }

        /// On this Mac: a data container exists. Whether it has portable
        /// data is determined after the person chooses the operation. The
        /// app need not be found; LaunchServices misses some copies.
        var present: Bool {
            // Discovery needs only the container's existence. Walking every
            // profile here made idle history requests and command menus read
            // other browsers' directories before anyone chose an import.
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: root.path, isDirectory: &directory) && directory.boolValue
        }

        static func credentialName(_ name: String) -> Bool {
            ["Login Data", "Login Data For Account", "Web Data", "Cookies", "Local State"].contains {
                name == $0 || name.hasPrefix($0 + "-")
            }
        }

        var files: [URL] {
            guard credentialAccess else { return [] }
            return profiles.flatMap { folder in
                ["Login Data", "Login Data For Account"].map { folder.appendingPathComponent($0) }
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
            }
        }
    }

    static let known: [Source] = [
        Source(name: "Dia", folder: "Dia/User Data", service: "Dia Safe Storage", account: "Dia", bundle: "company.thebrowser.dia"),
        Source(name: "Chrome", folder: "Google/Chrome", service: "Chrome Safe Storage", account: "Chrome", bundle: "com.google.Chrome"),
        // The beta shares Chrome's keychain key; only its folder is its own.
        Source(name: "Chrome Beta", folder: "Google/Chrome Beta", service: "Chrome Safe Storage", account: "Chrome", bundle: "com.google.Chrome.beta"),
        Source(name: "Arc", folder: "Arc/User Data", service: "Arc Safe Storage", account: "Arc", bundle: "company.thebrowser.Browser"),
        Source(name: "Aside", folder: "Aside", service: "Aside Safe Storage", account: "Aside", bundle: "at.studio.AsideBrowser"),
        Source(name: "Comet", folder: "Comet", service: "Comet Safe Storage", account: "Comet", bundle: "ai.perplexity.comet"),
        Source(name: "Brave", folder: "BraveSoftware/Brave-Browser", service: "Brave Safe Storage", account: "Brave", bundle: "com.brave.Browser"),
        // Brave's Beta and Nightly share its keychain key (Chrome's channels
        // share Chrome's too); each keeps a folder of its own.
        Source(name: "Brave Beta", folder: "BraveSoftware/Brave-Browser-Beta", service: "Brave Safe Storage", account: "Brave", bundle: "com.brave.Browser.beta"),
        Source(name: "Brave Nightly", folder: "BraveSoftware/Brave-Browser-Nightly", service: "Brave Safe Storage", account: "Brave", bundle: "com.brave.Browser.nightly"),
        Source(name: "Edge", folder: "Microsoft Edge", service: "Microsoft Edge Safe Storage", account: "Microsoft Edge", bundle: "com.microsoft.edgemac"),
        Source(name: "Vivaldi", folder: "Vivaldi", service: "Vivaldi Safe Storage", account: "Vivaldi", bundle: "com.vivaldi.Vivaldi"),
        Source(name: "Chromium", folder: "Chromium", service: "Chromium Safe Storage", account: "Chromium", bundle: "org.chromium.Chromium"),
        Source(name: "Chrome Dev", folder: "Google/Chrome Dev", service: "Chrome Safe Storage", account: "Chrome", bundle: "com.google.Chrome.dev"),
        Source(name: "Chrome Canary", folder: "Google/Chrome Canary", service: "Chrome Safe Storage", account: "Chrome", bundle: "com.google.Chrome.canary"),
        // Helium renames all three, and its key isn't called Safe Storage
        // (imputnet/helium-macos: change-keychain-name.patch,
        // change-product-dir-name.patch; the bundle id from its branding).
        Source(name: "Helium", folder: "net.imput.helium", service: "Helium Storage Key", account: "Helium", bundle: "net.imput.helium"),
    ]

    /// Fixture folders a probe has standing in for the browsers on this
    /// Mac, in a test world only (Bench, `ui` with "standIn"). Set on the
    /// main thread, read off it too (BrowserLookFinder), so behind a lock.
    static let standIns = OSAllocatedUnfairLock<[Source]>(initialState: [])

    /// A fixture folder's Safe Storage passphrase, by the folder's path, in
    /// a test world only: its cookies read with no keychain asked.
    static let standInKeys = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    /// The browsers on this Mac with something to read, or a data folder
    /// that says why it can't be (`present`). The default browser first,
    /// since it is the one most people mean, then the one browsed in last:
    /// with Safari the default, the first of these is the one in use, not
    /// the first of the list above.
    static func installed() -> [Source] {
        let standing = Store.testing ? standIns.withLock({ $0 }) : []
        if !standing.isEmpty { return standing }
        return installed(among: known)
    }

    static func installed(among sources: [Source]) -> [Source] {
        let here = sources.filter(\.present)
        let links = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
            .flatMap { Bundle(url: $0)?.bundleIdentifier }
        let ranked = here.enumerated().map { (index: $0.offset, source: $0.element, isDefault: $0.element.bundle == links, used: $0.element.lastUsed ?? .distantPast) }
        return ranked.sorted { a, b in
            if a.isDefault != b.isDefault { return a.isDefault }
            if a.used != b.used { return a.used > b.used }
            return a.index < b.index
        }.map(\.source)
    }

    /// Of these browsers and Safari, the one used most lately, by name:
    /// running beats not, then the latest use. An import offers it first,
    /// its button the one primary.
    static func recent(among sources: [Source]) -> String? {
        let safari = SafariImport.recency.map { [(name: "Safari", running: $0.running, at: $0.at)] } ?? []
        let all = safari + sources.map { (name: $0.name, running: $0.recency.running, at: $0.recency.at) }
        return all.max { a, b in a.running != b.running ? !a.running : a.at < b.at }?.name
    }

    /// How many passwords are there to bring, without asking the keychain
    /// for anything: the rows are counted, not unwrapped.
    static func loginCount(_ source: Source) -> Int {
        var seen = Set<String>()
        for file in source.files {
            guard let rows = try? rows(in: file) else { continue }
            for row in rows where !row.never {
                let host = Vault.host(of: row.origin)
                guard !host.isEmpty else { continue }
                seen.insert(host + "\u{1F}" + row.user)
            }
        }
        return seen.count
    }

    enum Trouble: Error {
        case noPassphrase
        case unreadable
    }

    struct Found {
        var logins: [Login]
        /// Sites the other browser was told never to ask about.
        var never: [String]
    }

    /// `quiet`: do not show another keychain prompt during this import.
    /// A current import capability is still required.
    static func read(_ source: Source, quiet: Bool = false) throws -> Found {
        guard let passphrase = safeStorage(source, quiet: quiet) else { throw Trouble.noPassphrase }
        let key = stretch(passphrase)

        var logins: [Login] = []
        var never: [String] = []
        var readAny = false

        for file in source.files {
            guard let rows = try? rows(in: file) else { continue }
            readAny = true
            for row in rows {
                let host = Vault.host(of: row.origin)
                guard !host.isEmpty else { continue }
                if row.never {
                    never.append(host)
                    continue
                }
                guard let password = unwrap(row.blob, key: key), !password.isEmpty else { continue }
                let clear = row.origin.lowercased().hasPrefix("http://")
                logins.append(Login(host: host, user: row.user, password: password, used: row.used, clear: clear))
            }
        }
        guard readAny else { throw Trouble.unreadable }
        if !quiet { Vault.broughtIn(from: source) }
        return Found(logins: newest(logins), never: never)
    }

    /// One login a site and name, the one used last. Rows collide more than
    /// they look: www.example.com and example.com are one host here, and a
    /// profile's and another's are one list, and which one the file happens
    /// to list first is no reason to keep it. One never used is the oldest.
    /// In the order first seen.
    static func newest(_ logins: [Login]) -> [Login] {
        var best: [String: Login] = [:]
        var order: [String] = []
        for login in logins {
            guard let kept = best[login.id] else {
                best[login.id] = login
                order.append(login.id)
                continue
            }
            if (login.used ?? .distantPast) > (kept.used ?? .distantPast) { best[login.id] = login }
        }
        return order.compactMap { best[$0] }
    }

    // MARK: - what they kept

    /// The other browser's bookmarks: the bar first, then anything filed
    /// elsewhere, folders and all. Chromium keeps them as one JSON file a
    /// profile, and Chrome a second, AccountBookmarks, for the ones kept in
    /// the Google account; its bar shows the account's first, then this
    /// Mac's, and so do we. Profiles often hold the same ones, synced or
    /// copied, so each after the first is merged in by address, as a second
    /// import would be: one Other folder, and a page kept in two profiles
    /// comes once.
    static func bookmarks(in source: Source) -> [Bookmark] {
        var out: [Bookmark] = []
        var earlier = Set<String>()
        for folder in source.profiles {
            let profile = bookmarks(inProfile: folder)
            // Only against the profiles before it: within one, a page kept
            // in two folders was kept there twice on purpose.
            Bookmarks.merge(profile, into: &out, skipping: earlier, fresh: true)
            earlier.formUnion(Bookmarks.addresses(profile))
        }
        return out
    }

    static func bookmarks(inProfile folder: URL) -> [Bookmark] {
        bookmarkFiles.compactMap { tree(at: folder.appendingPathComponent($0)) }
            .reduce(into: [Bookmark]()) { joined, file in Self.join(file, into: &joined) }
    }

    /// The account's file first: Chrome lists its bookmarks ahead of this
    /// Mac's in the bar.
    static let bookmarkFiles = ["AccountBookmarks", "Bookmarks"]

    /// One bookmarks file as the bar, then Other and Mobile folders.
    static func tree(at file: URL) -> [Bookmark]? {
        guard let data = try? Data(contentsOf: file),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = top["roots"] as? [String: Any]
        else { return nil }
        var out: [Bookmark] = []
        if let bar = roots["bookmark_bar"] as? [String: Any] {
            out += nodes(in: bar["children"] as? [[String: Any]] ?? [])
        }
        for key in ["other", "synced"] {
            if let more = roots[key] as? [String: Any] {
                let kids = nodes(in: more["children"] as? [[String: Any]] ?? [])
                if !kids.isEmpty { out.append(.folder(key == "other" ? "Other" : "Mobile", kids)) }
            }
        }
        return out
    }

    /// The account's and this Mac's files of one profile as one tree: a
    /// folder into the one of the same name at the same level, and a page
    /// already in that folder once. The same page in another folder stays,
    /// as it would within one file.
    static func join(_ incoming: [Bookmark], into target: inout [Bookmark]) {
        let before = target.count
        let here = Set(target.compactMap(\.url))
        for node in incoming {
            if node.isFolder {
                if let at = target[..<before].firstIndex(where: { $0.isFolder && $0.title == node.title }) {
                    var into = target[at].children ?? []
                    join(node.children ?? [], into: &into)
                    target[at].children = into
                } else {
                    target.append(node)
                }
            } else if let url = node.url, !here.contains(url) {
                target.append(node)
            }
        }
    }

    static func nodes(in raw: [[String: Any]]) -> [Bookmark] {
        raw.compactMap { entry in
            let name = entry["name"] as? String ?? ""
            // Microseconds since 1601, "0" when it doesn't know.
            let added = (entry["date_added"] as? String).flatMap(HistoryFile.date)
            switch entry["type"] as? String {
            case "folder":
                return .folder(name, nodes(in: entry["children"] as? [[String: Any]] ?? []), added: added)
            case "url":
                guard let text = entry["url"] as? String, let url = URL(string: text),
                      url.scheme == "http" || url.scheme == "https"
                else { return nil }
                return .site(name, url, added: added)
            default:
                return nil
            }
        }
    }

    /// The other browser's icons for the given pages, host by host: the
    /// largest bitmap it kept for the page itself, or failing that for the
    /// site's front door. Read from a copy of its "Favicons" file.
    static func icons(in source: Source, for urls: [URL], limit: Int = 400) -> [String: Data] {
        var out: [String: Data] = [:]
        var wanted: [(host: String, url: URL)] = []
        var seen = Set<String>()
        for url in urls {
            guard let host = url.host()?.lowercased(), seen.insert(host).inserted else { continue }
            wanted.append((host, url))
            if wanted.count >= limit { break }
        }
        guard !wanted.isEmpty else { return out }

        for folder in source.profiles {
            let icons = folder.appendingPathComponent("Favicons")
            guard FileManager.default.fileExists(atPath: icons.path) else { continue }
            guard let temp = try? copyWithLog(icons) else { continue }
            defer { removeWithLog(temp) }

            var db: OpaquePointer?
            guard sqlite3_open_v2(temp.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { continue }
            defer { sqlite3_close(db) }
            let sql = """
            SELECT b.image_data FROM icon_mapping m
            JOIN favicon_bitmaps b ON b.icon_id = m.icon_id
            WHERE m.page_url = ? AND b.width BETWEEN 16 AND 256
            ORDER BY b.width DESC LIMIT 1
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { continue }
            defer { sqlite3_finalize(statement) }

            for (host, url) in wanted where out[host] == nil {
                var doors = [url.absoluteString]
                if let scheme = url.scheme, let home = url.host() {
                    doors.append("\(scheme)://\(home)/")
                }
                for door in doors {
                    sqlite3_reset(statement)
                    sqlite3_bind_text(statement, 1, door, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { continue }
                    let count = Int(sqlite3_column_bytes(statement, 0))
                    guard count > 60 else { continue }
                    out[host] = Data(bytes: bytes, count: count)
                    break
                }
            }
        }
        return out
    }

    // MARK: - where they have been

    struct Place {
        let url: URL
        let title: String
        let count: Int
        /// Of those, how many were typed into the address bar.
        let typed: Int
        let last: Date
    }

    /// The other browser's history, what it takes to finish an address on
    /// the first day. Same file rules as the passwords: a copy, read once.
    static func places(in source: Source, limit: Int? = nil) -> [Place] {
        var out: [Place] = []
        for folder in source.profiles {
            let history = folder.appendingPathComponent("History")
            guard FileManager.default.fileExists(atPath: history.path) else { continue }
            out += (try? placeRows(in: history, limit: limit)) ?? []
        }
        let sorted = out.sorted { $0.last > $1.last }
        return limit.map { Array(sorted.prefix(max(0, $0))) } ?? sorted
    }

    static func placeRows(in file: URL, limit: Int? = nil) throws -> [Place] {
        let temp = try copyWithLog(file)
        defer { removeWithLog(temp) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(temp.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw Trouble.unreadable
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT url, title, visit_count, last_visit_time, typed_count FROM urls
        WHERE hidden = 0 AND visit_count > 0
        ORDER BY last_visit_time DESC \(limit.map { "LIMIT \(max(0, $0))" } ?? "")
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Trouble.unreadable
        }
        defer { sqlite3_finalize(statement) }

        var out: [Place] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0), let url = URL(string: String(cString: raw)),
                  url.scheme == "http" || url.scheme == "https"
            else { continue }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let count = Int(sqlite3_column_int(statement, 2))
            let stamp = sqlite3_column_int64(statement, 3)
            let last = stamp > 0 ? Date(timeIntervalSince1970: Double(stamp) / 1_000_000 - 11_644_473_600) : Date()
            let typed = Int(sqlite3_column_int(statement, 4))
            out.append(Place(url: url, title: title, count: max(1, count), typed: max(0, typed), last: last))
        }
        return out
    }

    // MARK: - who they are still signed in as

    /// One cookie, the way another browser kept it, enough to hand WebKit so
    /// a site opens already signed in.
    struct Cookie {
        let host: String
        let name: String
        let value: String
        let path: String
        /// Nil for a session cookie, gone when the browser closes.
        let expires: Date?
        let secure: Bool
        let httpOnly: Bool
        /// Chromium's SameSite: -1 unspecified, 0 none, 1 lax, 2 strict.
        let sameSite: Int
    }

    /// Every profile's cookie store. Newer Chromium keeps it a folder deeper,
    /// under "Network"; older builds keep it beside "Login Data". One or the
    /// other per profile, never both worth reading.
    /// `only`: the profile folders wanted, "Default", "Profile 1"; all of
    /// them when nil.
    private static func cookieFiles(in source: Source, only: Set<String>? = nil) -> [URL] {
        guard source.credentialAccess else { return [] }
        var out: [URL] = []
        for folder in source.profiles {
            if let only, !only.contains(folder.lastPathComponent) { continue }
            let deep = folder.appendingPathComponent("Network/Cookies")
            let flat = folder.appendingPathComponent("Cookies")
            if FileManager.default.fileExists(atPath: deep.path) { out.append(deep) }
            else if FileManager.default.fileExists(atPath: flat.path) { out.append(flat) }
        }
        return out
    }

    /// How many sign-ins there are to bring, counted without the keychain:
    /// the cookies that haven't expired, rows not unwrapped.
    static func cookieCount(_ source: Source) -> Int {
        var total = 0
        for file in cookieFiles(in: source) {
            total += (try? countCookies(in: file)) ?? 0
        }
        return total
    }

    /// A coherent snapshot of a live SQLite database, including committed
    /// WAL rows. SQLite's backup API reads the source without copying its
    /// database and journal at different points in time.
    static func sqliteFailure(_ db: OpaquePointer?, at stage: String) -> Error {
        let code = db.map { sqlite3_errcode($0) } ?? SQLITE_ERROR
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "No SQLite handle"
        return NSError(domain: "YabImport.SQLite", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "\(stage): \(message)"])
    }

    static func copyWithLog(_ file: URL, into folder: URL = FileManager.default.temporaryDirectory,
                            within limit: TimeInterval = 10) throws -> URL {
        do { return try snapshot(file, into: folder, within: limit) }
        catch {
            let failure = error as NSError
            // A closed WAL database may have no journal or SHM file. macOS
            // SQLite cannot always create those from a read-only handle.
            // Read its stable, checkpointed main file with immutable=1.
            func hasWAL() -> Bool {
                let wal = URL(fileURLWithPath: file.path + "-wal")
                return ((try? wal.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
            }
            guard failure.domain == "YabImport.SQLite", failure.code == Int(SQLITE_CANTOPEN), !hasWAL() else { throw error }
            let fm = FileManager.default
            let before = try fm.attributesOfItem(atPath: file.path)
            let copy = try snapshot(file, immutable: true, into: folder, within: limit)
            let after = try? fm.attributesOfItem(atPath: file.path)
            guard !hasWAL(), before[.modificationDate] as? Date == after?[.modificationDate] as? Date,
                  before[.size] as? Int == after?[.size] as? Int,
                  before[.systemFileNumber] as? UInt64 == after?[.systemFileNumber] as? UInt64 else {
                removeWithLog(copy)
                throw error
            }
            return copy
        }
    }

    private static func snapshot(_ file: URL, immutable: Bool = false, into folder: URL, within limit: TimeInterval) throws -> URL {
        let temp = folder.appendingPathComponent("yab-import-\(UUID().uuidString).db")
        var source: OpaquePointer?
        var uri = URLComponents(url: file, resolvingAgainstBaseURL: false)
        uri?.queryItems = [URLQueryItem(name: "immutable", value: "1")]
        let path = immutable ? uri?.string ?? file.path : file.path
        let flags = SQLITE_OPEN_READONLY | (immutable ? SQLITE_OPEN_URI : 0)
        guard sqlite3_open_v2(path, &source, flags, nil) == SQLITE_OK, let source else {
            let error = sqliteFailure(source, at: "Source open")
            if let source { sqlite3_close(source) }
            throw error
        }
        defer { sqlite3_close(source) }
        do {
            try backup(source, into: temp, within: limit)
        } catch {
            // Only with the copy's own connection closed: unlinking the file
            // of a database open in this process was EXC_GUARD (a vnode guard
            // on the copy), Yab gone. A large History or Web Data, or one
            // another browser held locked (Chrome keeps its databases in
            // exclusive mode), failed the backup in its ten seconds and took
            // Yab down that way (0.46.17, macOS 27.0.1).
            removeWithLog(temp)
            throw error
        }
        return temp
    }

    /// `source` copied into a new database at `temp` within `limit` seconds.
    /// The copy's connection is closed by the time this returns, whether or
    /// not the copy worked.
    private static func backup(_ source: OpaquePointer, into temp: URL, within limit: TimeInterval) throws {
        var target: OpaquePointer?
        guard sqlite3_open_v2(temp.path, &target, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let target else {
            let error = sqliteFailure(target, at: "Snapshot open")
            if let target { sqlite3_close(target) }
            throw error
        }
        defer { sqlite3_close(target) }
        sqlite3_busy_timeout(source, 2000)
        guard let backup = sqlite3_backup_init(target, "main", source, "main") else {
            throw sqliteFailure(target, at: "Snapshot init")
        }
        let deadline = Date().addingTimeInterval(limit)
        var status: Int32
        repeat {
            status = sqlite3_backup_step(backup, 256)
            if status == SQLITE_BUSY || status == SQLITE_LOCKED { Thread.sleep(forTimeInterval: 0.01) }
        } while (status == SQLITE_OK || status == SQLITE_BUSY || status == SQLITE_LOCKED) && Date() < deadline
        let finished = sqlite3_backup_finish(backup)
        guard status == SQLITE_DONE, finished == SQLITE_OK else {
            throw NSError(domain: "YabImport.SQLite", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Snapshot failed: step \(status), finish \(finished)"])
        }
    }

    static func removeWithLog(_ temp: URL) {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: temp.path + suffix))
        }
    }

    private static func countCookies(in file: URL) throws -> Int {
        let temp = try copyWithLog(file)
        defer { removeWithLog(temp) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(temp.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw Trouble.unreadable
        }
        defer { sqlite3_close(db) }
        // Microseconds since 1601; 13_324_608_000_000_000 is 2023-ish, but
        // has_expires = 0 marks a session cookie, which is worth bringing and
        // has expires_utc 0, so it is not filtered by time.
        let now = Int64((Date().timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
        let sql = "SELECT COUNT(*) FROM cookies WHERE has_expires = 0 OR expires_utc > \(now)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Trouble.unreadable
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    /// The other browser's live sign-ins: its cookies, unwrapped with the same
    /// keychain key the passwords use, so one "allow" covers both. Expired
    /// ones are left behind; session cookies come, since a sign-in often is
    /// one.
    static func cookies(in source: Source, only: Set<String>? = nil) throws -> [Cookie] {
        try cookiesByProfile(in: source, only: only).values.flatMap { $0 }
    }

    /// The same, by profile folder, "Default", "Profile 1": the keychain
    /// asked once for all of them.
    static func cookiesByProfile(in source: Source, only: Set<String>? = nil) throws -> [String: [Cookie]] {
        // No cookies to read, no key to ask macOS for.
        let files = cookieFiles(in: source, only: only)
        guard !files.isEmpty else { throw Trouble.unreadable }
        guard let passphrase = safeStorage(source) else { throw Trouble.noPassphrase }
        let key = stretch(passphrase)
        var out: [String: [Cookie]] = [:]
        var readAny = false
        for file in files {
            guard let rows = try? cookieRows(in: file, key: key) else { continue }
            readAny = true
            // …/Profile 1/Network/Cookies or …/Profile 1/Cookies.
            let folder = file.deletingLastPathComponent().lastPathComponent == "Network"
                ? file.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
                : file.deletingLastPathComponent().lastPathComponent
            out[folder, default: []] += rows
        }
        guard readAny else { throw Trouble.unreadable }
        return out
    }

    static func cookieRows(in file: URL, key: [UInt8]) throws -> [Cookie] {
        let temp = try copyWithLog(file)
        defer { removeWithLog(temp) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(temp.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw Trouble.unreadable
        }
        defer { sqlite3_close(db) }

        var version: Int32 = 0
        var meta: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = 'version'", -1, &meta, nil) == SQLITE_OK, let meta {
            if sqlite3_step(meta) == SQLITE_ROW { version = sqlite3_column_int(meta, 0) }
            sqlite3_finalize(meta)
        }
        let columns = columns(in: db, table: "cookies")
        let sql = """
        SELECT host_key, name, encrypted_value, value, path, expires_utc, has_expires, is_secure, is_httponly, samesite
        FROM cookies
        \(columns.contains("top_frame_site_key") ? "WHERE top_frame_site_key = ''" : "")
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Trouble.unreadable
        }
        defer { sqlite3_finalize(statement) }

        let now = Date()
        var out: [Cookie] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let host = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            let name = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            guard !host.isEmpty, !name.isEmpty else { continue }

            var value: String
            if let bytes = sqlite3_column_blob(statement, 2), sqlite3_column_bytes(statement, 2) > 0 {
                let blob = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 2)))
                guard var plain = decrypt(blob, key: key) else { continue }
                if version >= 24 {
                    let expected = Data(SHA256.hash(data: Data(host.utf8)))
                    guard plain.count >= 32, plain.prefix(32) == expected else { continue }
                    plain = Data(plain.dropFirst(32))
                }
                guard let text = String(data: plain, encoding: .utf8) else { continue }
                value = text
            } else {
                value = sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? ""
            }

            let path = sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? "/"
            let stamp = sqlite3_column_int64(statement, 5)
            let hasExpires = sqlite3_column_int(statement, 6) != 0
            let expires = (hasExpires && stamp > 0)
                ? Date(timeIntervalSince1970: Double(stamp) / 1_000_000 - 11_644_473_600)
                : nil
            // Already stale: no use to a store that would drop it anyway.
            if let expires, expires <= now { continue }
            let secure = sqlite3_column_int(statement, 7) != 0
            let httpOnly = sqlite3_column_int(statement, 8) != 0
            let sameSite = Int(sqlite3_column_int(statement, 9))
            out.append(Cookie(
                host: host, name: name, value: value, path: path.isEmpty ? "/" : path,
                expires: expires, secure: secure, httpOnly: httpOnly, sameSite: sameSite
            ))
        }
        return out
    }

    // MARK: - the key

    /// Also read for its cards (WalletImport).
    static func safeStorage(_ source: Source, quiet: Bool = false) -> String? {
        guard source.credentialAccess else { return nil }
        if Store.testing, let key = standInKeys.withLock({ $0[source.root.path] }) { return key }
        var out: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: source.service,
            kSecAttrAccount as String: source.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        // The item trusts only its own browser: an import the person asked
        // for needs the system's Allow, a quiet look must never show it.
        let status = quiet ? Keychain.copyMatching(query as CFDictionary, &out)
                           : Keychain.copyMatchingAsking(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data,
              let text = String(data: data, encoding: .utf8), !text.isEmpty
        else { return nil }
        return text
    }

    /// Chromium's own recipe, unchanged for a decade: PBKDF2 over SHA-1, the
    /// salt "saltysalt", 1003 rounds, sixteen bytes out.
    static func stretch(_ passphrase: String) -> [UInt8] {
        var key = [UInt8](repeating: 0, count: 16)
        let salt = Array("saltysalt".utf8)
        let pass = Array(passphrase.utf8)
        pass.withUnsafeBufferPointer { p in
            salt.withUnsafeBufferPointer { s in
                _ = CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    UnsafeRawPointer(p.baseAddress!).assumingMemoryBound(to: Int8.self), pass.count,
                    s.baseAddress!, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                    &key, key.count
                )
            }
        }
        return key
    }

    /// "v10" and then AES-128-CBC with an IV of sixteen spaces.
    static func unwrap(_ blob: Data, key: [UInt8]) -> String? {
        guard let plain = decrypt(blob, key: key) else { return nil }
        if let text = String(data: plain, encoding: .utf8) { return text }
        guard plain.count > 32 else { return nil }
        return String(data: plain.dropFirst(32), encoding: .utf8)
    }

    private static func decrypt(_ blob: Data, key: [UInt8]) -> Data? {
        guard blob.count > 3, blob.prefix(3) == Data("v10".utf8) else {
            // New encrypted formats must never be imported as plaintext.
            let bytes = [UInt8](blob.prefix(3))
            if bytes.count == 3, bytes[0] == 0x76, (0x30...0x39).contains(bytes[1]), (0x30...0x39).contains(bytes[2]) { return nil }
            return blob
        }
        let body = [UInt8](blob.dropFirst(3))
        let iv = [UInt8](repeating: 0x20, count: 16)
        var out = [UInt8](repeating: 0, count: body.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
            key, key.count, iv,
            body, body.count,
            &out, out.count, &moved
        )
        guard status == kCCSuccess else { return nil }
        return Data(out.prefix(moved))
    }

    static func columns(in db: OpaquePointer, table: String) -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var out = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) { out.insert(String(cString: name)) }
        }
        return out
    }

    // MARK: - the file

    private struct Row {
        let origin: String
        let user: String
        let blob: Data
        let never: Bool
        let used: Date?
    }

    private static func rows(in file: URL) throws -> [Row] {
        // A copy, next to nothing the other browser is watching.
        let temp = try copyWithLog(file)
        defer { removeWithLog(temp) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(temp.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw Trouble.unreadable
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT origin_url, username_value, password_value, blacklisted_by_user, date_last_used
        FROM logins
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Trouble.unreadable
        }
        defer { sqlite3_finalize(statement) }

        var out: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let origin = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            let user = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            var blob = Data()
            if let bytes = sqlite3_column_blob(statement, 2) {
                blob = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 2)))
            }
            let never = sqlite3_column_int(statement, 3) != 0
            // Microseconds since 1601, Chromium's idea of a date.
            let stamp = sqlite3_column_int64(statement, 4)
            let used = stamp > 0 ? Date(timeIntervalSince1970: Double(stamp) / 1_000_000 - 11_644_473_600) : nil
            out.append(Row(origin: origin, user: user, blob: blob, never: never, used: used))
        }
        return out
    }
}

extension Chromium.Cookie {
    /// The same cookie as WebKit keeps them. Nil when it won't form a valid
    /// one, a domain WebKit refuses, say. A session cookie (no expiry) is
    /// marked to discard so WebKit treats it as one.
    var http: HTTPCookie? {
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: host,
            .path: path,
        ]
        if let expires {
            props[.expires] = expires
        } else {
            props[.discard] = "TRUE"
        }
        if secure { props[.secure] = "TRUE" }
        // No public key sets HttpOnly; WebKit reads this one from a header,
        // and honors it here too. Losing it would only let our own page
        // scripts read a cookie the site meant to keep from them.
        if httpOnly { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        switch sameSite {
        case 1: props[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax.rawValue
        case 2: props[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict.rawValue
        default: break
        }
        return HTTPCookie(properties: props)
    }
}
