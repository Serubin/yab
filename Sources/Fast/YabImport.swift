import AppKit
import Foundation

// Bookmarks and history read from an upstream Yab install, only on request, never written back.

enum YabBrowser {
    struct Source: Identifiable, Hashable {
        let name: String
        /// Under ~/Library/Application Support.
        let folder: String
        /// The folder of installs from before Yab's own name ("Fast").
        let legacy: String
        /// The app itself, so a folder left behind doesn't count as a browser.
        let bundle: String
        /// A fixture's data folder, read as is.
        var dataRoot: URL? = nil
        /// A fixture's Application Support, where `folder` and `legacy` are looked for.
        var support: URL? = nil

        var id: String { name }

        var app: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) }

        var root: URL {
            if let dataRoot { return dataRoot }
            let base = support ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let current = base.appendingPathComponent(folder, isDirectory: true)
            let older = base.appendingPathComponent(legacy, isDirectory: true)
            return YabBrowser.holdsData(current) || !YabBrowser.holdsData(older) ? current : older
        }

        var hasData: Bool { YabBrowser.holdsData(root) }

        /// The app's own icon, the one in the Dock.
        var icon: NSImage? {
            guard let app else { return nil }
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 64, height: 64)
            return icon
        }
    }

    static let known: [Source] = [
        Source(name: "Yab", folder: "Yab", legacy: "Fast", bundle: "dev.serafim.fast"),
        Source(name: "Yab Dev", folder: "Yab Dev", legacy: "Fast Dev", bundle: "dev.serafim.fast.dev"),
    ]

    /// Fixture folders standing in for the installs on this Mac, in a test world only.
    nonisolated(unsafe) static var standIns: [Source] = []

    /// The largest file read: a history this big is far past any real one.
    static let cap = 256 << 20

    static let bookmarksFile = "bookmarks.json"
    static let historyFile = "history.json"

    /// The installs on this Mac with something to bring: existence checks only, nothing opened.
    static func installed() -> [Source] {
        if Store.testing, !standIns.isEmpty { return standIns.filter(\.hasData) }
        return known.filter { $0.app != nil && $0.hasData }
    }

    static func holdsData(_ folder: URL) -> Bool {
        let files = FileManager.default
        return [bookmarksFile, historyFile, spacesFile, firstSessionFile].contains { files.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    // MARK: - reading

    enum Read: Equatable {
        case missing
        case refused
        case copied(URL)
    }

    /// One of Yab's files copied into a private folder for `body`, removed after.
    /// Links, non-regular files, paths outside Yab's folder and files past `cap` are refused.
    static func withCopy<T>(of name: String, in source: Source, _ body: (Read) -> T) -> T {
        let files = FileManager.default
        let root = source.root.standardizedFileURL
        let path = root.appendingPathComponent(name).path
        guard files.fileExists(atPath: path) || isLink(path) else { return body(.missing) }
        let realRoot = root.resolvingSymlinksInPath().path
        guard URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(realRoot + "/"),
              let data = readPlain(path)
        else { return body(.refused) }
        let temp = files.temporaryDirectory.appendingPathComponent("pane-yab-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? files.removeItem(at: temp) }
        do {
            try files.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let copy = temp.appendingPathComponent(name)
            try data.write(to: copy, options: .withoutOverwriting)
            return body(.copied(copy))
        } catch {
            return body(.refused)
        }
    }

    private static func isLink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    /// A regular file's bytes, opened read-only without following a link; nil past `cap`.
    private static func readPlain(_ path: String) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0, info.st_size <= cap else { return nil }
        guard let data = try? handle.read(upToCount: cap + 1), data.count <= cap else { return nil }
        return data
    }

    // MARK: - what Yab kept

    /// Yab's bookmarks rebuilt as fresh ones, web pages only; empty for none.
    /// Nil when the file is refused or doesn't decode.
    static func bookmarks(in source: Source) -> [Bookmark]? {
        withCopy(of: bookmarksFile, in: source) { read -> [Bookmark]? in
            switch read {
            case .missing: return []
            case .refused: return nil
            case .copied(let copy):
                guard let data = try? Data(contentsOf: copy),
                      let list = try? JSONDecoder().decode([Bookmark].self, from: data) else { return nil }
                return fresh(list)
            }
        }
    }

    private static func fresh(_ nodes: [Bookmark], depth: Int = 0) -> [Bookmark] {
        guard depth < 64 else { return [] }
        return nodes.compactMap { node in
            if let text = node.url {
                guard let url = URL(string: text), Bookmark.keepable(url) else { return nil }
                return .site(node.title, url, added: node.added)
            }
            return .folder(node.title, fresh(node.children ?? [], depth: depth + 1), added: node.added)
        }
    }

    /// Yab's history as places, newest first, web pages only; empty for none.
    /// Nil when the file is refused or doesn't decode.
    static func places(in source: Source) -> [Chromium.Place]? {
        withCopy(of: historyFile, in: source) { read -> [Chromium.Place]? in
            switch read {
            case .missing: return []
            case .refused: return nil
            case .copied(let copy):
                guard let data = try? Data(contentsOf: copy),
                      let visits = try? JSONDecoder().decode([Visit].self, from: data) else { return nil }
                return visits.compactMap { visit -> Chromium.Place? in
                    guard let url = URL(string: visit.url), Bookmark.keepable(url) else { return nil }
                    return Chromium.Place(url: url, title: visit.title, count: max(1, visit.count),
                                          typed: max(0, visit.typed ?? 0), last: min(visit.last, Date()))
                }
                .sorted { $0.last > $1.last }
            }
        }
    }
}
