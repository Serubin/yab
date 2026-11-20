import Foundation

// IMAP4rev1 as Yab speaks it (RFC 3501, docs/mail-providers.md, M3): a
// response read off the line whole, literals and all, into values; a
// command written with its tag and its literals; and the commands the
// sync and the ops send. CAPABILITY, LOGIN and AUTHENTICATE PLAIN, ID,
// ENABLE, LIST with SPECIAL-USE (RFC 6154), SELECT with CONDSTORE (RFC
// 7162), STATUS, UID SEARCH, UID FETCH, UID STORE, UID MOVE (RFC 6851) or
// COPY and \Deleted and UID EXPUNGE (UIDPLUS, RFC 4315), APPEND, CREATE,
// RENAME, DELETE, IDLE (RFC 2177).

/// One value of a response: an atom, a string (quoted or a literal), a
/// parenthesized list, or NIL.
public indirect enum IMAPValue: Equatable, Sendable {
    case atom(String)
    case string(Data)
    case list([IMAPValue])
    case none

    public var text: String? {
        switch self {
        case .atom(let a): return a
        case .string(let d): return String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self)
        default: return nil
        }
    }

    public var data: Data? {
        switch self {
        case .string(let d): return d
        case .atom(let a): return Data(a.utf8)
        default: return nil
        }
    }

    public var items: [IMAPValue] {
        if case .list(let l) = self { return l }
        return []
    }

    public var number: Int64? { text.flatMap { Int64($0) } }
}

/// A response line from the server, literals inside it.
public struct IMAPResponse: Equatable, Sendable {
    /// "*", "+", or the tag of the command it ends.
    public var tag: String
    /// What follows the tag, read into values. A status's text is the rest.
    public var values: [IMAPValue]
    /// OK, NO, BAD, BYE or PREAUTH for a status response; nil for data.
    public var status: String?
    /// A status's code, as "UIDVALIDITY 3857529045" or "ALERT".
    public var code: String?
    public var text: String

    /// "* 4 EXISTS": its number and its word.
    public var numbered: (Int64, String)? {
        guard tag == "*", values.count >= 2, let n = values[0].number, let word = values[1].text else { return nil }
        return (n, word.uppercased())
    }

    /// "* LIST …": its word.
    public var word: String? {
        guard tag == "*", let first = values.first?.text else { return nil }
        return first.uppercased()
    }
}

public enum IMAPRead {
    /// A whole response from its bytes: a line, a literal's bytes inside
    /// it as {n}CRLF and n bytes.
    public static func parse(_ bytes: Data) -> IMAPResponse {
        var reader = Reader(bytes: [UInt8](bytes))
        let tag = reader.atom()
        reader.space()
        // A status response, tagged or not: its code and its text.
        let save = reader.at
        let first = reader.atom().uppercased()
        if ["OK", "NO", "BAD", "BYE", "PREAUTH"].contains(first) {
            reader.space()
            var code: String?
            if reader.peek == 91 { // [
                code = reader.bracket()
                reader.space()
            }
            return IMAPResponse(tag: tag, values: [], status: first, code: code, text: reader.rest())
        }
        if tag == "+" {
            reader.at = save
            return IMAPResponse(tag: tag, values: [], status: nil, code: nil, text: reader.rest())
        }
        reader.at = save
        var values: [IMAPValue] = []
        while !reader.done {
            reader.space()
            if reader.done { break }
            values.append(reader.value())
        }
        return IMAPResponse(tag: tag, values: values, status: nil, code: nil, text: "")
    }

    struct Reader {
        let bytes: [UInt8]
        var at = 0
        var done: Bool { at >= bytes.count }
        var peek: UInt8? { at < bytes.count ? bytes[at] : nil }

        mutating func space() { while at < bytes.count, bytes[at] == 32 { at += 1 } }

        mutating func rest() -> String {
            let out = String(decoding: bytes[min(at, bytes.count)...], as: UTF8.self)
            at = bytes.count
            return out
        }

        /// "[" … "]" as its words inside.
        mutating func bracket() -> String {
            at += 1
            var depth = 1
            let start = at
            while at < bytes.count {
                if bytes[at] == 91 { depth += 1 }
                if bytes[at] == 93 { depth -= 1; if depth == 0 { break } }
                at += 1
            }
            let out = String(decoding: bytes[start..<min(at, bytes.count)], as: UTF8.self)
            if at < bytes.count { at += 1 }
            return out
        }

        /// An atom: up to a space or a parenthesis; brackets inside it
        /// (BODY[HEADER.FIELDS (DATE)]) kept whole, and a partial's <0.512>.
        mutating func atom() -> String {
            let start = at
            var depth = 0
            while at < bytes.count {
                let b = bytes[at]
                if b == 91 { depth += 1 } else if b == 93 { depth = max(0, depth - 1) } else if depth == 0, b == 32 || b == 40 || b == 41 { break }
                at += 1
            }
            return String(decoding: bytes[start..<at], as: UTF8.self)
        }

        mutating func value() -> IMAPValue {
            guard let b = peek else { return .none }
            switch b {
            case 40: // (
                at += 1
                var items: [IMAPValue] = []
                while at < bytes.count {
                    space()
                    if peek == 41 { at += 1; break }
                    if done { break }
                    items.append(value())
                }
                return .list(items)
            case 34: // "
                at += 1
                var out: [UInt8] = []
                while at < bytes.count, bytes[at] != 34 {
                    if bytes[at] == 92, at + 1 < bytes.count { at += 1 }
                    out.append(bytes[at])
                    at += 1
                }
                at += 1
                return .string(Data(out))
            case 123: // {n} or {n+}, then CRLF and n bytes
                var end = at + 1
                while end < bytes.count, bytes[end] != 125 { end += 1 }
                let count = Int(String(decoding: bytes[(at + 1)..<min(end, bytes.count)], as: UTF8.self).replacingOccurrences(of: "+", with: "")) ?? 0
                // A "{" with no "}" after it, or a size past the bytes left
                // (or below zero), takes what is there: never a range that
                // runs backwards (crash #110).
                at = min(end + 1, bytes.count)
                if at < bytes.count, bytes[at] == 13 { at += 1 }
                if at < bytes.count, bytes[at] == 10 { at += 1 }
                let stop = at + min(max(0, count), bytes.count - at)
                let out = Data(bytes[at..<stop])
                at = stop
                return .string(out)
            default:
                let a = atom()
                if a.isEmpty {
                    // A stray ")" or the like: stepped over.
                    at += 1
                    return .none
                }
                return a.uppercased() == "NIL" ? .none : .atom(a)
            }
        }
    }

    /// FETCH's attributes as a name-to-value map: "UID", "FLAGS",
    /// "BODY[HEADER]", "MODSEQ".
    public static func fetch(_ response: IMAPResponse) -> [String: IMAPValue]? {
        guard let (_, word) = response.numbered, word == "FETCH", response.values.count >= 3 else { return nil }
        let items = response.values[2].items
        var out: [String: IMAPValue] = [:]
        var at = 0
        while at + 1 < items.count {
            if let name = items[at].text?.uppercased() {
                // BODY[]<0> as BODY[]: the partial's origin isn't asked for.
                let bare = name.replacingOccurrences(of: #"<\d+>$"#, with: "", options: .regularExpression)
                out[bare.replacingOccurrences(of: "BODY.PEEK", with: "BODY")] = items[at + 1]
            }
            at += 2
        }
        return out
    }
}

// MARK: - folder names

/// IMAP's modified UTF-7 for folder names (RFC 3501, 5.1.3): "Entwürfe" is
/// "Entw&APw-rfe".
public enum IMAPName {
    public static func encode(_ name: String) -> String {
        var out = ""
        var pending: [UInt16] = []
        func flush() {
            guard !pending.isEmpty else { return }
            var bytes: [UInt8] = []
            for unit in pending { bytes.append(UInt8(unit >> 8)); bytes.append(UInt8(unit & 0xFF)) }
            let b64 = Data(bytes).base64EncodedString().replacingOccurrences(of: "/", with: ",").replacingOccurrences(of: "=", with: "")
            out += "&" + b64 + "-"
            pending.removeAll()
        }
        for scalar in name.unicodeScalars {
            if scalar.value >= 0x20, scalar.value <= 0x7E {
                flush()
                out += scalar == "&" ? "&-" : String(scalar)
            } else {
                pending += Array(String(scalar).utf16)
            }
        }
        flush()
        return out
    }

    public static func decode(_ name: String) -> String {
        var out = ""
        var at = name.startIndex
        while at < name.endIndex {
            let c = name[at]
            if c == "&", let dash = name[at...].firstIndex(of: "-") {
                let inner = String(name[name.index(after: at)..<dash])
                if inner.isEmpty {
                    out += "&"
                } else {
                    var b64 = inner.replacingOccurrences(of: ",", with: "/")
                    while b64.count % 4 != 0 { b64 += "=" }
                    if let data = Data(base64Encoded: b64) {
                        let bytes = [UInt8](data)
                        var units: [UInt16] = []
                        var i = 0
                        while i + 1 < bytes.count { units.append(UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])); i += 2 }
                        out += String(decoding: units, as: UTF16.self)
                    } else {
                        out += "&" + inner + "-"
                    }
                }
                at = name.index(after: dash)
            } else {
                out.append(c)
                at = name.index(after: at)
            }
        }
        return out
    }
}

// MARK: - the client

/// One folder as LIST gives it.
public struct IMAPFolder: Equatable, Sendable {
    /// As the server names it (modified UTF-7), for its commands.
    public var name: String
    public var delimiter: String
    public var attributes: Set<String>
    /// For a person: decoded, "/" between levels.
    public var shown: String {
        let decoded = IMAPName.decode(name)
        return delimiter.isEmpty || delimiter == "/" ? decoded : decoded.replacingOccurrences(of: delimiter, with: "/")
    }
    public var selectable: Bool { !attributes.contains("\\noselect") && !attributes.contains("\\nonexistent") }
}

/// What SELECT said of a folder.
public struct IMAPSelected: Equatable, Sendable {
    public var exists: Int64 = 0
    public var validity: Int64 = 0
    public var next: Int64 = 0
    /// HIGHESTMODSEQ, where CONDSTORE is; 0 without.
    public var modseq: Int64 = 0
}

/// A connection to one IMAP server, signed in, commands one at a time.
public actor IMAPClient {
    public let socket: MailSocket
    public private(set) var capabilities: Set<String> = []
    public private(set) var selected: String?
    public private(set) var enabled: Set<String> = []
    private var tagNumber = 0
    /// Untagged responses that came while nothing asked (EXISTS, EXPUNGE,
    /// FETCH of flags), for IDLE and for the sync to notice.
    public private(set) var unasked: [IMAPResponse] = []
    /// The commands sent, by their first word, for the bench and the tests.
    public private(set) var sent: [String: Int] = [:]

    public init(socket: MailSocket) {
        self.socket = socket
    }

    public func has(_ capability: String) -> Bool { capabilities.contains(capability.uppercased()) }

    /// The greeting and its capabilities; TLS begun for STARTTLS.
    public func greet(security: MailSecurity) async throws {
        let hello = try await response()
        guard hello.tag == "*", hello.status == "OK" || hello.status == "PREAUTH" else {
            throw MailServerTrouble.refused(hello.text)
        }
        if let code = hello.code, code.uppercased().hasPrefix("CAPABILITY") { learn(code) }
        if capabilities.isEmpty { try await capability() }
        if security == .starttls, !socket.standIn {
            guard has("STARTTLS") else { throw MailServerTrouble.capabilityMissing("begin TLS (STARTTLS)") }
            _ = try await run("STARTTLS")
            await socket.secure()
            try await capability()
        }
    }

    private func learn(_ words: String) {
        capabilities = Set(words.split(separator: " ").dropFirst().map { $0.uppercased() })
    }

    public func capability() async throws {
        let got = try await run("CAPABILITY")
        for one in got.untagged where one.word == "CAPABILITY" {
            capabilities = Set(one.values.dropFirst().compactMap { $0.text?.uppercased() })
        }
    }

    /// Signed in by AUTHENTICATE PLAIN where offered, else LOGIN; `auth`
    /// `.login` for LOGIN first where the server takes it (iCloud, #441),
    /// `.plain` for PLAIN. A refusal read for what it means
    /// (MailServerTrouble.login), a BYE with words in place of a NO too; a
    /// line closed with nothing said throws `.closed`, for the caller to try
    /// the other way on a new line.
    public func login(user: String, password: String, auth: MailPasswordWay? = nil) async throws {
        if has("LOGINDISABLED"), !has("AUTH=PLAIN") { throw MailServerTrouble.capabilityMissing("sign in with a password") }
        let plain = has("AUTH=PLAIN") && (auth != .login || has("LOGINDISABLED"))
        let result: (untagged: [IMAPResponse], done: IMAPResponse)
        do {
            if plain {
                let plain = Data(("\u{0}" + user + "\u{0}" + password).utf8).base64EncodedString()
                if has("SASL-IR") {
                    result = try await run("AUTHENTICATE PLAIN " + plain, secret: true)
                } else {
                    result = try await run("AUTHENTICATE PLAIN", continuation: Data((plain + "\r\n").utf8), secret: true)
                }
            } else {
                result = try await run("LOGIN", .quoted(user), .quoted(password), secret: true)
            }
        } catch MailServerTrouble.refused(let said) {
            throw MailServerTrouble.login(said)
        }
        if let code = result.done.code, code.uppercased().hasPrefix("CAPABILITY") { learn(code) } else { try await capability() }
    }

    /// ID (RFC 2971): some servers (163.com, some hosts) won't go on without it.
    public func id() async {
        guard has("ID") else { return }
        _ = try? await run("ID (\"name\" \"\(Brand.name)\" \"vendor\" \"\(Brand.name)\")")
    }

    /// ENABLE CONDSTORE and QRESYNC where offered (RFC 5161).
    public func enable() async {
        guard has("ENABLE") else { return }
        var wanted: [String] = []
        if has("CONDSTORE") { wanted.append("CONDSTORE") }
        guard !wanted.isEmpty, let got = try? await run("ENABLE " + wanted.joined(separator: " ")) else { return }
        for one in got.untagged where one.word == "ENABLED" { enabled.formUnion(one.values.dropFirst().compactMap { $0.text?.uppercased() }) }
        if enabled.isEmpty { enabled = Set(wanted) }
    }

    public var condstore: Bool { has("CONDSTORE") }

    /// Every folder, with SPECIAL-USE's attributes where the server gives them.
    public func list() async throws -> [IMAPFolder] {
        let special = has("SPECIAL-USE")
        let got = try await run(special ? "LIST \"\" \"*\" RETURN (SPECIAL-USE)" : "LIST \"\" \"*\"")
        var out: [IMAPFolder] = []
        for one in got.untagged where one.word == "LIST" && one.values.count >= 4 {
            let attributes = Set(one.values[1].items.compactMap { $0.text?.lowercased() })
            let delimiter = one.values[2].text ?? ""
            guard let name = one.values[3].text else { continue }
            out.append(IMAPFolder(name: name, delimiter: delimiter, attributes: attributes))
        }
        return out
    }

    /// A folder opened, read-write; what it holds and its marks of change.
    @discardableResult
    public func select(_ folder: String, readOnly: Bool = false) async throws -> IMAPSelected {
        let verb = readOnly ? "EXAMINE" : "SELECT"
        let got = try await run(verb, .quoted(folder), .raw(condstore ? " (CONDSTORE)" : ""))
        selected = folder
        var out = IMAPSelected()
        for one in got.untagged + [got.done] {
            if let (n, word) = one.numbered, word == "EXISTS" { out.exists = n }
            if let code = one.code {
                let parts = code.split(separator: " ")
                guard parts.count >= 2, let n = Int64(parts[1]) else { continue }
                switch parts[0].uppercased() {
                case "UIDVALIDITY": out.validity = n
                case "UIDNEXT": out.next = n
                case "HIGHESTMODSEQ": out.modseq = n
                default: break
                }
            }
        }
        return out
    }

    /// STATUS: how many messages, unread, the next UID, the validity.
    public func status(_ folder: String) async throws -> (messages: Int, unseen: Int, next: Int64, validity: Int64, modseq: Int64) {
        let items = "(MESSAGES UNSEEN UIDNEXT UIDVALIDITY" + (condstore ? " HIGHESTMODSEQ)" : ")")
        let got = try await run("STATUS", .quoted(folder), .raw(" " + items))
        var out = (messages: 0, unseen: 0, next: Int64(0), validity: Int64(0), modseq: Int64(0))
        for one in got.untagged where one.word == "STATUS" && one.values.count >= 3 {
            let pairs = one.values[2].items
            var at = 0
            while at + 1 < pairs.count {
                let n = pairs[at + 1].number ?? 0
                switch pairs[at].text?.uppercased() {
                case "MESSAGES": out.messages = Int(n)
                case "UNSEEN": out.unseen = Int(n)
                case "UIDNEXT": out.next = n
                case "UIDVALIDITY": out.validity = n
                case "HIGHESTMODSEQ": out.modseq = n
                default: break
                }
                at += 2
            }
        }
        return out
    }

    /// UID SEARCH: the UIDs that match, ascending.
    public func search(_ criteria: String) async throws -> [Int64] {
        try await search(pieces: [.raw(criteria)])
    }

    /// UID SEARCH of pieces: words as they are, strings quoted (or, not
    /// 7-bit, as literals with CHARSET UTF-8 said first).
    public func search(pieces: [Arg]) async throws -> [Int64] {
        let wide = pieces.contains { if case .quoted(let s) = $0 { return !IMAPClient.quotable(s) } else { return false } }
        let got = try await run(wide ? "UID SEARCH CHARSET UTF-8 " : "UID SEARCH ", arguments: pieces)
        var out: [Int64] = []
        for one in got.untagged where one.word == "SEARCH" {
            out += one.values.dropFirst().compactMap(\.number)
        }
        return out.sorted()
    }

    /// UID FETCH of a set, each message's attributes by name, by its UID.
    public func fetch(_ set: String, _ items: String, changedSince: Int64? = nil) async throws -> [Int64: [String: IMAPValue]] {
        var command = "UID FETCH " + set + " " + items
        if let changedSince, condstore { command += " (CHANGEDSINCE \(changedSince))" }
        let got = try await run(command)
        var out: [Int64: [String: IMAPValue]] = [:]
        for one in got.untagged {
            guard let attributes = IMAPRead.fetch(one), let uid = attributes["UID"]?.number else { continue }
            out[uid, default: [:]].merge(attributes) { _, new in new }
        }
        return out
    }

    /// Flags on or off (UID STORE, quietly).
    public func store(_ set: String, add: Bool, flags: [String]) async throws {
        guard !flags.isEmpty else { return }
        _ = try await run("UID STORE " + set + (add ? " +FLAGS.SILENT (" : " -FLAGS.SILENT (") + flags.joined(separator: " ") + ")")
    }

    /// Moved to another folder: UID MOVE, or COPY then \Deleted and an
    /// expunge of those alone (UIDPLUS) or of the folder. The UIDs they
    /// have there, when the server says (COPYUID).
    public func move(_ set: String, to folder: String) async throws -> [Int64: Int64] {
        let done: IMAPResponse
        var codes: [String] = []
        if has("MOVE") {
            let got = try await run("UID MOVE " + set + " ", .quoted(folder))
            done = got.done
            codes = (got.untagged + [got.done]).compactMap(\.code)
        } else {
            let got = try await run("UID COPY " + set + " ", .quoted(folder))
            done = got.done
            codes = [got.done.code].compactMap { $0 }
            try await store(set, add: true, flags: ["\\Deleted"])
            if has("UIDPLUS") { _ = try await run("UID EXPUNGE " + set) } else { _ = try await run("EXPUNGE") }
        }
        _ = done
        for code in codes where code.uppercased().hasPrefix("COPYUID") {
            let parts = code.split(separator: " ")
            guard parts.count >= 4 else { continue }
            let from = IMAPSet.uids(String(parts[2])), to = IMAPSet.uids(String(parts[3]))
            guard from.count == to.count else { continue }
            return Dictionary(zip(from, to), uniquingKeysWith: { a, _ in a })
        }
        return [:]
    }

    /// A message put into a folder (Sent, after SMTP): its UID there when
    /// the server says (APPENDUID).
    public func append(_ folder: String, message: Data, flags: [String]) async throws -> Int64? {
        let got = try await run("APPEND", .quoted(folder), .raw(" (" + flags.joined(separator: " ") + ") "), .literal(message))
        if let code = got.done.code, code.uppercased().hasPrefix("APPENDUID") {
            let parts = code.split(separator: " ")
            if parts.count >= 3 { return Int64(parts[2]) }
        }
        return nil
    }

    public func create(_ folder: String) async throws { _ = try await run("CREATE", .quoted(folder)) }
    public func rename(_ folder: String, to: String) async throws { _ = try await run("RENAME", .quoted(folder), .raw(" "), .quoted(to)) }
    public func delete(_ folder: String) async throws { _ = try await run("DELETE", .quoted(folder)) }

    public func logout() async {
        _ = try? await run("LOGOUT")
        await socket.close()
    }

    public func noop() async throws { _ = try await run("NOOP") }

    /// IDLE until the server tells of a change or `seconds` pass: true when
    /// it told (EXISTS, EXPUNGE, FETCH). DONE ends it either way.
    public func idle(seconds: TimeInterval) async throws -> Bool {
        guard has("IDLE") else { throw MailServerTrouble.capabilityMissing("tell of new mail (IDLE)") }
        let tag = nextTag()
        try await socket.write(tag + " IDLE\r\n")
        count("IDLE")
        let go = try await response()
        guard go.tag == "+" else { throw MailServerTrouble.refused(go.text) }
        var told = false
        let until = Date().addingTimeInterval(seconds)
        while !told {
            let left = until.timeIntervalSinceNow
            guard left > 0 else { break }
            do {
                let one = try await response(timeout: left)
                if let (_, word) = one.numbered, ["EXISTS", "EXPUNGE", "FETCH"].contains(word) { told = true }
                if one.tag == "*", one.status == "BYE" { throw MailServerTrouble.closed }
            } catch MailServerTrouble.timedOut {
                break
            }
        }
        try await socket.write("DONE\r\n")
        while true {
            let one = try await response()
            if one.tag == tag {
                guard one.status == "OK" else { throw MailServerTrouble.refused(one.text) }
                break
            }
        }
        return told
    }

    // MARK: - the wire

    /// A piece of a command: words as they are, a quoted string (a literal
    /// when it can't be quoted), or bytes as a literal.
    public enum Arg {
        case raw(String)
        case quoted(String)
        case literal(Data)
    }

    private func nextTag() -> String {
        tagNumber += 1
        return "Y\(tagNumber)"
    }

    private func count(_ command: String) {
        let word = command.split(separator: " ").prefix(command.hasPrefix("UID") ? 2 : 1).joined(separator: " ").uppercased()
        sent[word, default: 0] += 1
    }

    /// One command, its untagged answers and its tagged end. NO and BAD
    /// throw, with what the server said.
    public func run(_ head: String, _ args: Arg..., continuation: Data? = nil, secret: Bool = false) async throws
        -> (untagged: [IMAPResponse], done: IMAPResponse) {
        try await run(head, arguments: args, continuation: continuation, secret: secret)
    }

    public func run(_ head: String, arguments args: [Arg], continuation: Data? = nil, secret: Bool = false) async throws
        -> (untagged: [IMAPResponse], done: IMAPResponse) {
        let tag = nextTag()
        count(head)
        // The command in pieces: each literal waits for the server's "+"
        // unless LITERAL+ lets it go at once.
        var pieces: [(Data, literal: Bool)] = []
        var current = Data((tag + " " + head).utf8)
        let plus = has("LITERAL+") || has("LITERAL-")
        for arg in args {
            switch arg {
            case .raw(let words):
                current.append(Data(words.utf8))
            case .quoted(let text):
                if !current.isEmpty, current.last != 32, current.last != 40 { current.append(32) }
                if IMAPClient.quotable(text) {
                    current.append(Data(("\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"").utf8))
                } else {
                    let bytes = Data(text.utf8)
                    current.append(Data("{\(bytes.count)\(plus ? "+" : "")}\r\n".utf8))
                    pieces.append((current, !plus))
                    current = bytes
                }
            case .literal(let bytes):
                current.append(Data("{\(bytes.count)\(plus ? "+" : "")}\r\n".utf8))
                pieces.append((current, !plus))
                current = bytes
            }
        }
        current.append(Data("\r\n".utf8))
        pieces.append((current, false))
        var untagged: [IMAPResponse] = []
        for (bytes, waits) in pieces {
            try await socket.write(bytes)
            guard waits else { continue }
            // The server's go-ahead for the literal.
            while true {
                let one = try await response()
                if one.tag == "+" { break }
                if one.tag == tag { throw MailServerTrouble.refused(one.text) }
                untagged.append(one)
            }
        }
        var continued = false
        while true {
            let one = try await response()
            if one.tag == "+" {
                // AUTHENTICATE's challenge: what it was given to say, once.
                guard let continuation, !continued else {
                    try await socket.write("*\r\n")
                    continue
                }
                continued = true
                try await socket.write(continuation)
                continue
            }
            if one.tag == tag {
                if one.status == "OK" { return (untagged, one) }
                throw MailServerTrouble.refused(one.text)
            }
            if one.tag == "*", one.status == "BYE", !head.hasPrefix("LOGOUT") {
                // A sign-in refused with a BYE keeps what it said (#441).
                let said = one.text.trimmingCharacters(in: .whitespaces)
                if head.hasPrefix("AUTHENTICATE") || head.hasPrefix("LOGIN"), !said.isEmpty { throw MailServerTrouble.refused(said) }
                throw MailServerTrouble.closed
            }
            untagged.append(one)
            if one.numbered.map({ ["EXISTS", "EXPUNGE"].contains($0.1) }) == true || (one.numbered?.1 == "FETCH" && !head.contains("FETCH")) {
                unasked.append(one)
            }
        }
    }

    public func takeUnasked() -> [IMAPResponse] {
        defer { unasked = [] }
        return unasked
    }

    /// A string IMAP takes in quotes: 7-bit, no CR or LF.
    static func quotable(_ text: String) -> Bool {
        text.utf8.allSatisfy { $0 >= 32 && $0 < 127 }
    }

    /// One response, whole: a line, and for each literal it ends with,
    /// that many bytes and the line after.
    func response(timeout: TimeInterval? = nil) async throws -> IMAPResponse {
        var whole = Data()
        var line = try await socket.line(timeout: timeout)
        while true {
            whole.append(line)
            guard let count = IMAPClient.literal(at: line) else { break }
            whole.append(Data("\r\n".utf8))
            whole.append(try await socket.bytes(count))
            line = try await socket.line()
        }
        return IMAPRead.parse(whole)
    }

    /// The size a line's last literal says, {123} at its end.
    static func literal(at line: Data) -> Int? {
        guard line.last == 125, let open = line.lastIndex(of: 123) else { return nil }
        let inside = String(decoding: line[(open + 1)..<(line.endIndex - 1)], as: UTF8.self).replacingOccurrences(of: "+", with: "")
        guard let count = Int(inside), count >= 0 else { return nil }
        return count
    }
}

/// UID sets as IMAP writes them: "1:4,7,9:12".
public enum IMAPSet {
    public static func string(_ uids: [Int64]) -> String {
        let sorted = Array(Set(uids)).sorted()
        var out: [String] = []
        var start: Int64?, last: Int64?
        for uid in sorted {
            if let l = last, uid == l + 1 { last = uid; continue }
            if let s = start, let l = last { out.append(s == l ? "\(s)" : "\(s):\(l)") }
            start = uid
            last = uid
        }
        if let s = start, let l = last { out.append(s == l ? "\(s)" : "\(s):\(l)") }
        return out.joined(separator: ",")
    }

    public static func uids(_ set: String) -> [Int64] {
        var out: [Int64] = []
        for piece in set.split(separator: ",") {
            let ends = piece.split(separator: ":").compactMap { Int64($0) }
            if ends.count == 2 {
                let (a, b) = (min(ends[0], ends[1]), max(ends[0], ends[1]))
                if b - a < 100_000 { out += Array(a...b) }
            } else if let one = ends.first {
                out.append(one)
            }
        }
        return out
    }

    /// A long list in sets a command can carry, a few hundred UIDs each.
    public static func chunks(_ uids: [Int64], size: Int = 200) -> [[Int64]] {
        let sorted = uids.sorted()
        return stride(from: 0, to: sorted.count, by: size).map { Array(sorted[$0..<min(sorted.count, $0 + size)]) }
    }
}
