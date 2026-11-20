import AppKit
import CoreServices
import Foundation
import PDFKit
import UniformTypeIdentifiers

// Files mail carries (docs/mail.md, Files): what each message's parts say
// of them, read when the message comes whole (MailGmail.message) and kept in
// the store's `files`; their bytes fetched from Gmail the first time they
// are wanted (messages.attachments.get, 20 units, through the account's
// MailPace) and kept on this Mac in mail/<account>.noindex/files/<message>/<part>/,
// under their own names, every account's together under 500 MB, the ones
// opened longest ago going first. Those of the last thirty days under 10 MB
// are fetched ahead in the background, a little of the
// quota at a time, so a chip opens and a picture in a mail draws without
// waiting. Disconnect deletes them with the store. Mail kept by its headers
// has no parts to read: one search (has:attachment) says which of it carries
// files, so its row shows a clip before it is opened.

/// A file a message carries: an attachment, or a picture its words draw
/// (`inline`: its Content-ID is named in the mail's HTML), which is no chip.
public struct MailFile: Equatable, Hashable, Sendable {
    /// Its part of the message, as Gmail numbers them ("1", "0.2").
    public var part: String
    public var name: String
    public var mime: String
    /// Bytes, as Gmail counts them.
    public var size: Int
    /// What Gmail fetches its bytes by (messages.attachments.get); "" when
    /// they came in the message itself.
    var attachmentID = ""
    /// Its Content-ID without the brackets; "" when it has none.
    var contentID = ""
    public var inline = false
    /// Bytes that came in the message itself; never kept in the store.
    public var data: Data? = nil

    /// A picture the mail's words draw (its Content-ID named in the HTML:
    /// Apple Mail's pasted pictures, Gmail's "[image: image.png]"): no chip,
    /// but a file all the same.
    public var drawn: Bool { inline && !contentID.isEmpty }

    /// Listed for agents and in Files: attachments and the pictures the
    /// words draw, not an invitation's text/calendar beside the words.
    public var listed: Bool { !inline || drawn }

    /// Its size as people read it: "340 KB", "1.2 MB".
    public var said: String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }

    /// Its kind, by its name first (what the Mac opens it with), else by
    /// what the mail said it is.
    public var type: UTType {
        let ext = (name as NSString).pathExtension
        return (ext.isEmpty ? nil : UTType(filenameExtension: ext)) ?? UTType(mimeType: mime) ?? .data
    }

    /// One of a message's parts as a file: one with a name, one said to be
    /// an attachment, a message attached whole, or anything but words with
    /// a Content-ID (a picture the words draw); nil for the words and for
    /// parts that only hold others. `path`: its place, when Gmail gave none.
    public static func part(_ part: [String: Any], at path: String) -> MailFile? {
        let mime = (part["mimeType"] as? String ?? "").lowercased()
        guard !mime.hasPrefix("multipart/") else { return nil }
        let headers = MailMime.headers(part["headers"])
        let disposition = MailMime.parameters(headers["content-disposition"] ?? "")
        let type = MailMime.parameters(headers["content-type"] ?? "")
        let name = MailMime.filename(part["filename"] as? String ?? "", disposition: disposition.params, type: type.params)
        let contentID = MailMime.contentID(headers["content-id"] ?? "")
        let words = mime == "text/plain" || mime == "text/html"
        let attached = disposition.value.lowercased() == "attachment"
        guard !name.isEmpty || attached || mime == "message/rfc822" || (!contentID.isEmpty && !words) else { return nil }
        let body = part["body"] as? [String: Any] ?? [:]
        let id = body["attachmentId"] as? String ?? ""
        let given = part["partId"] as? String ?? ""
        return MailFile(part: given.isEmpty ? path : given, name: name.isEmpty ? unnamed(mime) : name,
                        mime: mime.isEmpty ? "application/octet-stream" : mime, size: MailMime.int(body["size"]),
                        attachmentID: id, contentID: contentID,
                        data: id.isEmpty ? (body["data"] as? String).flatMap(MailGmail.bytes) : nil)
    }

    /// A name for a file that came without one, from its kind:
    /// "Image.png", "Attachment.pdf", "Message.eml".
    static func unnamed(_ mime: String) -> String {
        if mime == "message/rfc822" { return "Message.eml" }
        let stem = mime.hasPrefix("image/") ? "Image" : "Attachment"
        guard let ext = UTType(mimeType: mime)?.preferredFilenameExtension else { return stem }
        return stem + "." + ext
    }

    /// The files of a message as its words draw them: inline where its HTML
    /// names their Content-ID, a chip otherwise.
    public static func marked(_ files: [MailFile], html: String?) -> [MailFile] {
        let drawn = html.map(MailHTML.cids) ?? []
        return files.map { file in
            var file = file
            file.inline = !file.contentID.isEmpty && drawn.contains(file.contentID.lowercased())
            return file
        }
    }

    /// Parts in their message's order: "0.2" before "0.10", "1" after both.
    public static func ordered(_ a: String, _ b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        return x.lexicographicallyPrecedes(y)
    }
}

/// MIME's own words, as mail's headers write them: a header's parameters,
/// names in RFC 2231's and RFC 2047's encodings, Content-IDs.
public enum MailMime {
    /// A part's headers by their names, lowercased; the first of each.
    public static func headers(_ any: Any?) -> [String: String] {
        var out: [String: String] = [:]
        for header in any as? [[String: Any]] ?? [] {
            guard let name = header["name"] as? String, let value = header["value"] as? String else { continue }
            if out[name.lowercased()] == nil { out[name.lowercased()] = value }
        }
        return out
    }

    public static func int(_ any: Any?) -> Int { (any as? NSNumber)?.intValue ?? Int(MailGmail.string(any)) ?? 0 }

    /// A header's value and its parameters, their names lowercased:
    /// `attachment; filename="a b.pdf"` is ("attachment", ["filename":
    /// "a b.pdf"]). A quote keeps a semicolon in a value; a backslash in one
    /// keeps what follows it.
    public static func parameters(_ header: String) -> (value: String, params: [String: String]) {
        let unfolded = header.replacingOccurrences(of: "\r\n", with: "").replacingOccurrences(of: "\n", with: "")
        var pieces: [String] = []
        var current = ""
        var quoted = false, escaped = false
        for char in unfolded {
            if escaped {
                current.append(char)
                escaped = false
            } else if char == "\\", quoted {
                escaped = true
            } else if char == "\"" {
                quoted.toggle()
                current.append(char)
            } else if char == ";", !quoted {
                pieces.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        pieces.append(current)
        var params: [String: String] = [:]
        for piece in pieces.dropFirst() {
            guard let equals = piece.firstIndex(of: "=") else { continue }
            let key = piece[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var value = piece[piece.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            if !key.isEmpty, params[key] == nil { params[key] = value }
        }
        return (pieces.first?.trimmingCharacters(in: .whitespaces) ?? "", params)
    }

    /// A file's name, wherever its message put it: Gmail's own reading (its
    /// `filename`, decoded already, mostly), else Content-Disposition's
    /// filename and Content-Type's name, in RFC 2231's encoding (filename*=,
    /// whole or in pieces) or RFC 2047's (=?UTF-8?B?…?=), in any charset the
    /// Mac knows.
    public static func filename(_ given: String, disposition: [String: String], type: [String: String]) -> String {
        for candidate in [given, extended(disposition, "filename") ?? "", disposition["filename"] ?? "",
                          extended(type, "name") ?? "", type["name"] ?? ""] {
            let name = words(candidate).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        return ""
    }

    /// RFC 2231's value of a parameter: name*=charset'language'%XX…, or in
    /// pieces, name*0*=…; name*1*=…; name*2=…, each one encoded when its
    /// name ends in *. Nil when it isn't written so.
    static func extended(_ params: [String: String], _ name: String) -> String? {
        var charset = "utf-8"
        var bytes = Data()
        if let whole = params[name + "*"] {
            let (set, value) = language(whole)
            charset = set ?? charset
            bytes = percent(value)
        } else {
            var pieces: [(n: Int, value: String, encoded: Bool)] = []
            for (key, value) in params where key.hasPrefix(name + "*") {
                var rest = key.dropFirst(name.count + 1)
                let encoded = rest.hasSuffix("*")
                if encoded { rest = rest.dropLast() }
                guard let n = Int(rest) else { continue }
                pieces.append((n, value, encoded))
            }
            guard !pieces.isEmpty else { return nil }
            for piece in pieces.sorted(by: { $0.n < $1.n }) {
                var value = piece.value
                if piece.n == 0, piece.encoded {
                    let (set, rest) = language(value)
                    charset = set ?? charset
                    value = rest
                }
                bytes += piece.encoded ? percent(value) : Data(value.utf8)
            }
        }
        return decode(bytes, charset: charset)
    }

    /// charset'language'value as its charset and value.
    private static func language(_ text: String) -> (String?, String) {
        let parts = text.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return (nil, text) }
        return (parts[0].isEmpty ? nil : String(parts[0]), String(parts[2]))
    }

    /// %XX as its byte; everything else as it is.
    private static func percent(_ text: String) -> Data {
        var out = Data()
        let bytes = Array(text.utf8)
        var at = 0
        while at < bytes.count {
            if bytes[at] == 37, at + 2 < bytes.count, let high = hex(bytes[at + 1]), let low = hex(bytes[at + 2]) {
                out.append(high << 4 | low)
                at += 3
            } else {
                out.append(bytes[at])
                at += 1
            }
        }
        return out
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }

    /// The encoding a charset names, as IANA writes them ("UTF-8",
    /// "windows-1252", "ISO-8859-2"); nil for one the Mac doesn't know.
    static func encoding(_ charset: String) -> String.Encoding? {
        let cf = CFStringConvertIANACharSetNameToEncoding(charset.trimmingCharacters(in: .whitespaces) as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    public static func decode(_ bytes: Data, charset: String) -> String {
        if let encoding = encoding(charset), let text = String(data: bytes, encoding: encoding) { return text }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static let encoded = try! NSRegularExpression(pattern: #"=\?([^?\s]+)\?([bBqQ])\?([^?\s]*)\?="#)

    /// RFC 2047's encoded words (=?charset?B?…?= and =?charset?Q?…?=) as
    /// their words. The space between two of them goes, as the RFC says,
    /// and the bytes of neighbors in one charset are read together, for
    /// mailers that cut a letter in two.
    public static func words(_ text: String) -> String {
        guard text.contains("=?") else { return text }
        let whole = text as NSString
        var out = ""
        var at = 0
        var pending = Data(), pendingSet = ""
        var lastWord = false
        func flush() {
            guard !pending.isEmpty else { return }
            out += decode(pending, charset: pendingSet)
            pending = Data()
        }
        for match in encoded.matches(in: text, range: NSRange(location: 0, length: whole.length)) {
            let between = whole.substring(with: NSRange(location: at, length: match.range.location - at))
            if !(lastWord && between.allSatisfy(\.isWhitespace)) {
                flush()
                out += between
            }
            // RFC 2231 lets a language follow the charset: UTF-8*ru.
            let charset = whole.substring(with: match.range(at: 1)).split(separator: "*").first.map(String.init) ?? ""
            let payload = whole.substring(with: match.range(at: 3))
            let bytes = whole.substring(with: match.range(at: 2)).uppercased() == "B" ? base64(payload) : quoted(payload)
            if let bytes {
                if !pending.isEmpty, pendingSet.lowercased() != charset.lowercased() { flush() }
                pending += bytes
                pendingSet = charset
                lastWord = true
            } else {
                flush()
                out += whole.substring(with: match.range)
                lastWord = false
            }
            at = NSMaxRange(match.range)
        }
        flush()
        return out + whole.substring(from: at)
    }

    private static func base64(_ text: String) -> Data? {
        var padded = text
        while padded.utf8.count % 4 != 0 { padded += "=" }
        return Data(base64Encoded: padded)
    }

    /// Q: _ for a space, =XX for a byte.
    private static func quoted(_ text: String) -> Data? {
        var out = Data()
        let bytes = Array(text.utf8)
        var at = 0
        while at < bytes.count {
            switch bytes[at] {
            case 95: out.append(32); at += 1
            case 61:
                guard at + 2 < bytes.count, let high = hex(bytes[at + 1]), let low = hex(bytes[at + 2]) else { return nil }
                out.append(high << 4 | low)
                at += 3
            default: out.append(bytes[at]); at += 1
            }
        }
        return out
    }

    /// A Content-ID as a mail's words name it (cid:x): without its brackets
    /// or the space around it.
    static func contentID(_ header: String) -> String {
        var id = header.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.hasPrefix("<"), id.hasSuffix(">") { id = String(id.dropFirst().dropLast()) }
        return id.trimmingCharacters(in: .whitespaces)
    }
}

/// One account's files on this Mac: where each is kept, fetched from Gmail
/// the first time it is wanted, once however many ask at once, and the
/// newest fetched ahead.
public actor MailFiles {
    public nonisolated let store: MailStore
    /// The account's server: Gmail, or another behind the seam (MailProvider).
    public nonisolated let provider: any MailProvider
    /// mail/<account>.noindex/files: a folder for each message, one in it for each
    /// part, the file under its own name, so Quick Look, the app that opens
    /// it and a drag to the Finder all have its name and kind.
    public nonisolated let folder: URL
    /// Every account's files keep under this together.
    public static let cap: Int64 = 500 << 20
    /// What is fetched ahead: the last thirty days' files under 10 MB.
    static let aheadDays: Double = 30
    static let aheadUnder = 10 << 20
    /// Between two files fetched ahead, one at a time: 20 units in two
    /// seconds, an eighth of what MailPace spends in them.
    public var pause: TimeInterval = 2
    private var going: [String: Task<URL, Error>] = [:]
    private var fetchingAhead = false
    /// Files fetched from Gmail, ahead or asked for, for the bench and tests.
    public private(set) var fetched = 0

    public init(store: MailStore, provider: any MailProvider, folder: URL) {
        self.store = store
        self.provider = provider
        self.folder = folder
    }

    /// Where an account's files live: beside its store, out of Spotlight,
    /// mail/<account>.noindex/files (MailStore.beside).
    public static func folder(for store: MailStore) -> URL? {
        store.file == MailStore.memory ? nil : MailStore.beside(store.file).appendingPathComponent("files", isDirectory: true)
    }

    /// Where every account's files are, for the cap: mail/.
    public nonisolated var root: URL { folder.deletingLastPathComponent().deletingLastPathComponent() }

    func setPause(_ seconds: TimeInterval) { pause = seconds }

    // MARK: - a file

    /// Where a file of a message is kept, there or not.
    public nonisolated func place(_ file: MailFile, message: String) -> URL {
        folder.appendingPathComponent(MailFiles.safe(message), isDirectory: true)
            .appendingPathComponent(MailFiles.safe(file.part), isDirectory: true)
            .appendingPathComponent(MailFiles.safe(file.name))
    }

    /// The file, when it is here already.
    public nonisolated func kept(_ file: MailFile, message: String) -> URL? {
        let url = place(file, message: message)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// A file on this Mac, fetched from Gmail first when it isn't here. For
    /// the cap it counts as opened now, or, only fetched ahead (`at`), as
    /// of when its mail came.
    public func file(_ file: MailFile, message: String, at: Date? = nil) async throws -> URL {
        let url = place(file, message: message)
        if FileManager.default.fileExists(atPath: url.path) {
            if at == nil { MailFiles.date(url, Date()) }
            return url
        }
        let key = message + "/" + file.part
        if let going = going[key] {
            // Asked for while it was being fetched ahead: opened now all the same.
            let url = try await going.value
            if at == nil { MailFiles.date(url, Date()) }
            return url
        }
        let task = Task { try await self.fetch(file, message: message, to: url, at: at ?? Date(), ahead: at != nil) }
        going[key] = task
        defer { going[key] = nil }
        return try await task.value
    }

    /// A file's bytes by its message and part: what a forward carries of the
    /// mail it forwards (P0.1's sending half).
    public func data(message: String, part: String) async throws -> Data {
        guard let file = try await parts(of: message).first(where: { $0.part == part }) else { throw MailTrouble.status(404) }
        return try Data(contentsOf: try await self.file(file, message: message))
    }

    /// A message's files: as the store has them, or the message whole from
    /// Gmail once, when its parts weren't read (kept by its headers, or
    /// before files were kept).
    public func parts(of message: String) async throws -> [MailFile] {
        if let files = store.files(message: message) { return files }
        return try await again(message)?.files ?? []
    }

    /// A picture a mail's words draw by Content-ID (MailCid): its file and
    /// kind. Found among the message's parts, or another message's of its
    /// thread (a reply draws what the mail it quotes did); the message read
    /// whole from Gmail first when its parts aren't known.
    public func picture(message: String, cid: String) async throws -> (url: URL, mime: String) {
        let wanted = MailMime.contentID(cid).lowercased()
        let matches = { (file: MailFile) in file.contentID.lowercased() == wanted }
        var found = try await parts(of: message).first(where: matches).map { (message, $0) }
        if found == nil, let thread = store.message(message)?.thread {
            for other in store.messages(thread: thread) where other.id != message {
                if let file = other.files?.first(where: matches) { found = (other.id, file); break }
            }
        }
        guard let found else { throw MailTrouble.status(404) }
        return (try await self.file(found.1, message: found.0), found.1.mime)
    }

    /// Its bytes from Gmail, written where it is kept, whole or not at all.
    private func fetch(_ file: MailFile, message: String, to url: URL, at: Date, ahead: Bool) async throws -> URL {
        let bytes: Data
        if let data = file.data {
            bytes = data
        } else if file.attachmentID.isEmpty {
            bytes = try await again(file, of: message)
        } else {
            do {
                bytes = try await provider.attachment(message: message, id: file.attachmentID)
            } catch MailTrouble.status(let code) where code == 400 || code == 404 {
                // The id Gmail gave for a file can stop working: the message
                // again, and the id it has now.
                bytes = try await again(file, of: message)
            }
        }
        let fm = FileManager.default
        let into = url.deletingLastPathComponent()
        try fm.createDirectory(at: into, withIntermediateDirectories: true)
        let partial = into.appendingPathComponent(".partial-" + UUID().uuidString)
        try bytes.write(to: partial)
        if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
        try fm.moveItem(at: partial, to: url)
        MailFiles.quarantine(url)
        MailFiles.date(url, at)
        fetched += 1
        // Fetched ahead keeps under the cap by itself; one asked for may pass it.
        if !ahead { MailFiles.sweep(root) }
        return url
    }

    /// A message whole from Gmail, kept: its parts read, its files' ids as
    /// Gmail has them now. What the person did that Gmail hasn't heard yet
    /// stays done (MailOps.layOver).
    @discardableResult
    private func again(_ message: String) async throws -> MailMessage? {
        guard let fresh = try await provider.message(message, full: true) else { return nil }
        store.put([fresh])
        MailOps.layOver(store)
        return fresh
    }

    private func again(_ file: MailFile, of message: String) async throws -> Data {
        guard let now = try await again(message)?.files?.first(where: { $0.part == file.part }) else { throw MailTrouble.status(404) }
        if let data = now.data { return data }
        guard !now.attachmentID.isEmpty else { throw MailTrouble.unreadable }
        return try await provider.attachment(message: message, id: now.attachmentID)
    }

    // MARK: - ahead

    /// Fetched ahead after a sync, off the main thread, when nothing else
    /// of it is. Utility, not background: its pause and MailPace keep it
    /// polite, and the background's own was starved for minutes on a busy
    /// Mac.
    public nonisolated func ahead() {
        Task.detached(priority: .utility) { await self.fetchAhead() }
    }

    /// The last thirty days' files under 10 MB, newest mail first, fetched
    /// one at a time, `pause` apart, while every account's files keep under
    /// four fifths of the cap, until Gmail says slow down; a picture its
    /// words draw as well as a chip. A file never opened counts as opened
    /// when its mail came, so the cap lets it go before one that was.
    /// Not in Low Power Mode.
    public func fetchAhead(now: Date = Date()) async {
        guard !fetchingAhead else { return }
        fetchingAhead = true
        defer { fetchingAhead = false }
        // After most syncs every one is here already: no walk of the folder then.
        let wanted = store.filesAhead(since: now.addingTimeInterval(-MailFiles.aheadDays * 86_400), under: MailFiles.aheadUnder, limit: 300)
            .filter { kept($0.file, message: $0.message) == nil }
        guard !wanted.isEmpty else { return }
        var room = MailFiles.cap * 4 / 5 - MailFiles.weight(root)
        for one in wanted {
            if Task.isCancelled || ProcessInfo.processInfo.isLowPowerModeEnabled { return }
            guard kept(one.file, message: one.message) == nil else { continue }
            guard room > Int64(one.file.size) else { return }
            do {
                _ = try await file(one.file, message: one.message, at: one.at)
                room -= Int64(one.file.size)
            } catch MailTrouble.limited {
                return
            } catch MailTrouble.signedOut {
                return
            } catch {
                continue
            }
            if pause > 0 { try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000)) }
        }
    }

    // MARK: - the cap

    /// Every account's files kept under `root` (mail/<account>.noindex/files/…):
    /// where, how big, and when last opened.
    public nonisolated static func kept(in root: URL) -> [(url: URL, size: Int64, at: Date)] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var out: [(URL, Int64, Date)] = []
        for account in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let files = account.appendingPathComponent("files", isDirectory: true)
            guard let walk = fm.enumerator(at: files, includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in walk where !url.lastPathComponent.hasPrefix(".partial") {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                out.append((url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast))
            }
        }
        return out
    }

    /// What every account's files weigh together.
    public nonisolated static func weight(_ root: URL) -> Int64 { kept(in: root).reduce(0) { $0 + $1.size } }

    /// What one account's files weigh (Settings › Mail).
    public nonisolated static func weight(of folder: URL) -> Int64 {
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walk { total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        return total
    }

    /// Every account's files kept under `cap`: the ones opened longest ago
    /// go first, and the folders they leave empty. What stays, in bytes.
    @discardableResult
    public nonisolated static func sweep(_ root: URL, cap: Int64 = MailFiles.cap) -> Int64 {
        sweeping.lock()
        defer { sweeping.unlock() }
        let found = kept(in: root)
        var total = found.reduce(0) { $0 + $1.size }
        guard total > cap else { return total }
        let fm = FileManager.default
        for one in found.sorted(by: { $0.at < $1.at }) where total > cap {
            guard (try? fm.removeItem(at: one.url)) != nil else { continue }
            total -= one.size
            let part = one.url.deletingLastPathComponent()
            for folder in [part, part.deletingLastPathComponent()] where (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? fm.removeItem(at: folder)
            }
        }
        return total
    }

    private static let sweeping = NSLock()

    /// Marked as a mail's attachment, as Mail marks what it saves: macOS
    /// asks before an app or a script from mail runs. Its copies in
    /// Downloads and in the Finder (a drag) keep the mark.
    public nonisolated static func quarantine(_ url: URL) {
        var values = URLResourceValues()
        values.quarantineProperties = [kLSQuarantineAgentNameKey as String: "\(Brand.name)",
                                       kLSQuarantineTypeKey as String: kLSQuarantineTypeEmailAttachment as String]
        var marked = url
        try? marked.setResourceValues(values)
    }

    /// When a file counts as last opened, for the cap.
    public nonisolated static func date(_ url: URL, _ at: Date) {
        try? FileManager.default.setAttributes([.modificationDate: at], ofItemAtPath: url.path)
    }

    /// A name as a folder or a file can have it: no slash, no colon, no
    /// leading dot, not empty, not longer than a disk takes.
    public nonisolated static func safe(_ name: String) -> String {
        var out = String(name.map { "/:\\".contains($0) || $0.isNewline || ($0.asciiValue.map { $0 < 32 } ?? false) ? "-" : $0 })
        while out.hasPrefix(".") { out.removeFirst() }
        out = out.trimmingCharacters(in: .whitespaces)
        if out.utf8.count > 200 {
            let ext = (out as NSString).pathExtension
            let stem = String((out as NSString).deletingPathExtension.prefix(150))
            out = ext.isEmpty ? stem : stem + "." + ext
        }
        return out.isEmpty ? "_" : out
    }

    // MARK: - each account's

    private static let lock = NSLock()
    private static var live: [String: MailFiles] = [:]

    /// The files of an account whose store this is, while it is connected
    /// (MailCenter.make): what its sync fetches ahead into.
    public static func attached(to store: MailStore) -> MailFiles? {
        lock.lock()
        defer { lock.unlock() }
        return live[store.file.path]
    }

    /// An account's files, kept beside its store; nil for a store kept in
    /// memory, which has nowhere to keep them.
    @discardableResult
    public static func attach(_ store: MailStore, provider: any MailProvider, folder: URL? = nil) -> MailFiles? {
        guard let folder = folder ?? MailFiles.folder(for: store) else { return nil }
        let files = MailFiles(store: store, provider: provider, folder: folder)
        lock.lock()
        defer { lock.unlock() }
        live[store.file.path] = files
        return files
    }

    /// The account's files, as attached, or attached now.
    public static func of(_ store: MailStore, _ provider: any MailProvider) -> MailFiles? {
        attached(to: store) ?? attach(store, provider: provider)
    }

    /// Gmail's, as the tests make them.
    public init(store: MailStore, gmail: MailGmail, folder: URL) { self.init(store: store, provider: gmail, folder: folder) }
    @discardableResult
    public static func attach(_ store: MailStore, gmail: MailGmail, folder: URL? = nil) -> MailFiles? { attach(store, provider: gmail, folder: folder) }

    /// Disconnect: the account's files gone from this Mac, its folder with
    /// them.
    public static func drop(_ account: String) {
        let store = MailStore.file(for: account)
        lock.lock()
        live[store.path] = nil
        lock.unlock()
        try? FileManager.default.removeItem(at: MailStore.beside(store))
        try? FileManager.default.removeItem(at: store.deletingPathExtension())
    }

    // MARK: - words of a file

    /// The most of a file's words an agent is given (mail_file).
    public static let wordsCap = 20_000

    /// The words of a file, for an agent: a PDF's text (PDFKit), a text
    /// file's in whatever charset it came in, a page's words, or a document
    /// the Mac reads (RTF, Word); nil for anything else.
    public nonisolated static func text(of url: URL, file: MailFile) -> String? {
        text(of: url, type: file.type, mime: file.mime)
    }

    /// The same for a file on this Mac known only by its kind: a download's
    /// (Files' words inside).
    public nonisolated static func text(of url: URL, type: UTType, mime: String = "") -> String? {
        if type.conforms(to: .pdf) { return PDFDocument(url: url)?.string }
        if type.conforms(to: .html) {
            return (try? String(contentsOf: url, encoding: .utf8)).map(HTMLText.plain)
        }
        if type.conforms(to: .rtf) || type.conforms(to: .rtfd) || ["doc", "docx", "odt"].contains(type.preferredFilenameExtension ?? "") {
            return (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        }
        let plain = type.conforms(to: .text) || mime.hasPrefix("text/")
            || ["application/json", "application/xml", "application/csv", "application/yaml", "application/x-yaml", "message/rfc822"].contains(mime)
        guard plain, let data = try? Data(contentsOf: url) else { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        var used: String.Encoding = .utf8
        if let text = try? String(contentsOf: url, usedEncoding: &used) { return text }
        return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1)
    }

    /// A file's mark as the Finder draws its kind, kept by kind.
    @MainActor
    public static func icon(_ file: MailFile) -> NSImage { icon(file.type) }

    /// The Finder's mark for a kind of file, kept once drawn: a mail's
    /// file's, or a draft's (MailDraftChips).
    @MainActor
    public static func icon(_ type: UTType) -> NSImage {
        if let kept = icons[type.identifier] { return kept }
        let icon = NSWorkspace.shared.icon(for: type)
        icons[type.identifier] = icon
        return icon
    }

    @MainActor private static var icons: [String: NSImage] = [:]
}

extension MailSync {
    /// Which mail of the inbox and of the last sixty days carries files, by
    /// one search (has:attachment, 5 units a page of 500), for mail kept by
    /// its headers, whose parts aren't read: its row shows a clip before it
    /// is opened. At a first sync, once for a store kept before files were,
    /// and when an older store's inbox has all come (`fillInbox`); mail that
    /// comes after comes whole, its parts read, and mail a search brings
    /// by its headers is marked with it (`search`).
    func markFiles() async throws {
        var ids: [String] = []
        var page: String?
        repeat {
            let got = try await gmail.messages(query: "has:attachment (in:inbox OR newer_than:\(days)d) -in:spam -in:trash", page: page)
            ids += got.ids
            page = got.next
        } while page != nil
        store.markAttached(ids)
        store.set("attachments", "1")
    }

    /// A store kept before files were: which of its mail carries them, once.
    /// True when it asked: the rows' clips are news for the lists.
    func markFilesOnce() async throws -> Bool {
        guard store.value("attachments") == nil else { return false }
        try await markFiles()
        return true
    }
}
