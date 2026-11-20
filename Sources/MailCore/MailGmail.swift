import Foundation
import os

// Gmail's REST API, the calls the sync and the ops make (docs/mail.md,
// Sync). Every call takes a fresh token from the account and goes again on
// 429 and 5xx, a little later each time, as Google asks. A history id too
// old to follow is its own error: the sync starts again from nothing.
//
// Gmail meters each user of Yab's Google project: 6,000 quota units a
// minute (Cloud console, Gmail API quotas, "Units per minute per user"), a
// thread fetched costing 40 and a message 20. Calls go through the
// account's MailPace, which spends at most 80 a second, and a refusal for
// going too fast (403 rateLimitExceeded or 429) is waited out, the whole
// account waiting with it, instead of failing the sync that asked.

public enum MailTrouble: Error, Equatable {
    /// The history id is older than Gmail keeps: sync from nothing.
    case stale
    /// Gmail kept saying slow down: come back in a few minutes.
    case limited
    /// The token was refused: the account needs signing in again.
    case signedOut
    case status(Int)
    case unreadable
    case offline(String)
    /// The store on disk wouldn't take what came (full disk, a broken file):
    /// the sync stops where it is, so what didn't land is fetched again.
    case store
}

public struct MailGmail: Sendable {
    public static let log = Logger(subsystem: Store.productionBundleID, category: "Mail")
    public var base = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/")!
    /// Never the app's shared session, whose cache on disk would keep what
    /// Gmail answers: an account's engine gives each its own line (MailWire).
    public var session: URLSession = MailGmail.uncached
    /// The account's access token, fresh.
    public var token: @Sendable () async throws -> String
    /// How many times a call goes again on 429 and 5xx, and the first wait.
    public var tries = 3
    public var wait: TimeInterval = 0.5
    /// The account's quota, shared by every call it makes; nil in tests.
    public var pace: MailPace?
    /// Tries when Gmail says slow down, which wants patience: 2, 4, 8, 16,
    /// 32 s, past the minute Gmail counts in.
    public var limitTries = 6

    // MARK: - calls

    public func profile() async throws -> (address: String, history: String) {
        let got = try await call("profile")
        guard let address = got["emailAddress"] as? String else { throw MailTrouble.unreadable }
        return (address, Self.string(got["historyId"]))
    }

    /// Thread ids for a search, a page at a time.
    public func threads(query: String, labels: [String] = [], page: String? = nil, max: Int = 500) async throws -> (ids: [String], next: String?) {
        var items = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "maxResults", value: String(max))]
        items += labels.map { URLQueryItem(name: "labelIds", value: $0) }
        if let page { items.append(URLQueryItem(name: "pageToken", value: page)) }
        let got = try await call("threads", items)
        let ids = (got["threads"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        return (ids, got["nextPageToken"] as? String)
    }

    /// A thread's messages: headers only, or with their bodies.
    public func thread(_ id: String, full: Bool) async throws -> [MailMessage] {
        let got = try await call("threads/\(id)", Self.format(full))
        return (got["messages"] as? [[String: Any]] ?? []).compactMap { Self.message($0, full: full) }
    }

    /// Message ids for a search, a page at a time, newest first, with the
    /// thread each is in. A first sync takes mail by the message: most
    /// threads are one mail, and a message costs half what a thread does.
    public func messages(query: String, labels: [String] = [], page: String? = nil, max: Int = 500) async throws
        -> (ids: [String], threads: [String], next: String?) {
        var items = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "maxResults", value: String(max))]
        items += labels.map { URLQueryItem(name: "labelIds", value: $0) }
        if let page { items.append(URLQueryItem(name: "pageToken", value: page)) }
        let got = try await call("messages", items)
        let found = (got["messages"] as? [[String: Any]] ?? []).compactMap { one -> (String, String)? in
            guard let id = one["id"] as? String else { return nil }
            return (id, one["threadId"] as? String ?? "")
        }
        return (found.map(\.0), found.map(\.1), got["nextPageToken"] as? String)
    }

    /// The labels of the mailbox, Gmail's and yours (labels.list, one unit):
    /// their ids, names, colors and whether Gmail's own list shows them. A
    /// search names a label by its name, the store keeps its id.
    public func labels() async throws -> [MailLabel] {
        let got = try await call("labels")
        return (got["labels"] as? [[String: Any]] ?? []).compactMap(Self.label)
    }

    /// One label with how many threads carry it and how many of those are
    /// unread (labels.get, one unit): the column's counts.
    public func label(id: String) async throws -> MailLabel {
        guard let label = Self.label(try await call("labels/\(id)")) else { throw MailTrouble.unreadable }
        return label
    }

    /// A label of the person's made (labels.create, 5 units): L's and V's
    /// Create. One by that name there already (made since the list was
    /// read, here or elsewhere) is that one.
    public func makeLabel(named name: String) async throws -> MailLabel {
        do {
            let made = try await call("labels", method: "POST", body: ["name": name, "labelListVisibility": "labelShow", "messageListVisibility": "show"])
            guard let label = Self.label(made) else { throw MailTrouble.unreadable }
            return label
        } catch MailTrouble.status(409) {
            guard let there = try await labels().first(where: { $0.name.lowercased() == name.lowercased() }) else { throw MailTrouble.status(409) }
            return there
        }
    }

    /// A label of the person's given another name (labels.patch, 5 units):
    /// the label as Gmail has it now. A name another label has is a 409.
    public func renameLabel(id: String, to name: String) async throws -> MailLabel {
        guard let label = Self.label(try await call("labels/\(id)", method: "PATCH", body: ["name": name])) else { throw MailTrouble.unreadable }
        return label
    }

    /// A label of the person's shown in Gmail's list of labels, or hidden
    /// there (labels.patch, 5 units): "labelShow" or "labelHide", as Gmail's
    /// own "In label list" sets it; mail's column follows the same setting.
    /// The label as Gmail has it now.
    public func showLabel(id: String, _ shown: String) async throws -> MailLabel {
        guard let label = Self.label(try await call("labels/\(id)", method: "PATCH", body: ["labelListVisibility": shown])) else { throw MailTrouble.unreadable }
        return label
    }

    /// A label of the person's deleted (labels.delete, 5 units): gone from
    /// the list and off every message it was on, the mail itself kept. One
    /// gone already (a retry whose first answer was lost) is done.
    public func deleteLabel(id: String) async throws {
        do {
            _ = try await call("labels/\(id)", method: "DELETE")
        } catch MailTrouble.status(404) {}
    }

    /// A Label resource as the store keeps it; its type said by its id
    /// when Gmail leaves it out.
    public static func label(_ one: [String: Any]) -> MailLabel? {
        guard let id = one["id"] as? String, let name = one["name"] as? String else { return nil }
        let color = one["color"] as? [String: Any]
        return MailLabel(id: id, name: name, type: one["type"] as? String ?? (id.hasPrefix("Label_") ? "user" : "system"),
                         color: color?["backgroundColor"] as? String ?? "", textColor: color?["textColor"] as? String ?? "",
                         shown: one["labelListVisibility"] as? String ?? "labelShow",
                         unread: (one["threadsUnread"] as? NSNumber)?.intValue, threads: (one["threadsTotal"] as? NSNumber)?.intValue)
    }

    /// One message: its headers only, or with its body.
    public func message(_ id: String, full: Bool) async throws -> MailMessage? {
        Self.message(try await call("messages/\(id)", Self.format(full)), full: full)
    }

    /// A file's bytes (MailFile.attachmentID), base64url as Gmail sends
    /// them: 20 units, whatever its size.
    public func attachment(message: String, id: String) async throws -> Data {
        let got = try await call("messages/\(message)/attachments/\(id)")
        guard let data = (got["data"] as? String).flatMap(Self.bytes) else { throw MailTrouble.unreadable }
        return data
    }

    private static func format(_ full: Bool) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "format", value: full ? "full" : "metadata")]
        if !full {
            let names = ["From", "To", "Cc", "Subject", "Date", "Message-ID", "In-Reply-To", "References", "List-Unsubscribe", "List-Unsubscribe-Post"]
            items += (names + MailStore.late.map(\.header).filter { !names.contains($0) })
                .map { URLQueryItem(name: "metadataHeaders", value: $0) }
        }
        return items
    }

    public struct Change {
        public var added: Set<String> = []
        public var deleted: Set<String> = []
        public var labeled: [(message: String, add: Set<String>, remove: Set<String>)] = []
        /// The threads the added ones are in.
        public var threads: Set<String> = []
    }

    /// What changed since a history id, and the id to ask from next.
    public func history(since start: String) async throws -> (Change, String) {
        var change = Change()
        var page: String?
        var last = start
        repeat {
            var items = [URLQueryItem(name: "startHistoryId", value: start)]
            if let page { items.append(URLQueryItem(name: "pageToken", value: page)) }
            let got: [String: Any]
            do {
                got = try await call("history", items)
            } catch MailTrouble.status(404) {
                throw MailTrouble.stale
            }
            for record in got["history"] as? [[String: Any]] ?? [] {
                for added in record["messagesAdded"] as? [[String: Any]] ?? [] {
                    guard let message = added["message"] as? [String: Any], let id = message["id"] as? String else { continue }
                    change.added.insert(id)
                    change.deleted.remove(id)
                    if let thread = message["threadId"] as? String { change.threads.insert(thread) }
                }
                for deleted in record["messagesDeleted"] as? [[String: Any]] ?? [] {
                    guard let id = (deleted["message"] as? [String: Any])?["id"] as? String else { continue }
                    change.deleted.insert(id)
                    change.added.remove(id)
                }
                for (key, adds) in [("labelsAdded", true), ("labelsRemoved", false)] {
                    for item in record[key] as? [[String: Any]] ?? [] {
                        guard let id = (item["message"] as? [String: Any])?["id"] as? String else { continue }
                        let labels = Set(item["labelIds"] as? [String] ?? [])
                        change.labeled.append((id, adds ? labels : [], adds ? [] : labels))
                    }
                }
            }
            last = Self.string(got["historyId"]).isEmpty ? last : Self.string(got["historyId"])
            page = got["nextPageToken"] as? String
        } while page != nil
        return (change, last)
    }

    /// Labels on and off every message of a thread.
    func modify(thread id: String, add: [String], remove: [String]) async throws {
        _ = try await call("threads/\(id)/modify", method: "POST", body: ["addLabelIds": add, "removeLabelIds": remove])
    }

    /// Labels on and off one message: what an op on messages falls back to
    /// when Gmail refuses its batch for a message gone since. 5 units.
    func modify(message id: String, add: [String], remove: [String]) async throws {
        _ = try await call("messages/\(id)/modify", method: "POST", body: ["addLabelIds": add, "removeLabelIds": remove])
    }

    /// A label's id by its name, made when Gmail has none: yab/Snoozed.
    public func label(named name: String) async throws -> String {
        let got = try await call("labels")
        if let found = (got["labels"] as? [[String: Any]] ?? []).first(where: { $0["name"] as? String == name }),
           let id = found["id"] as? String { return id }
        let made = try await call("labels", method: "POST", body: ["name": name, "labelListVisibility": "labelShow", "messageListVisibility": "show"])
        guard let id = made["id"] as? String else { throw MailTrouble.unreadable }
        return id
    }

    public func trash(thread id: String) async throws {
        _ = try await call("threads/\(id)/trash", method: "POST", body: [:])
    }

    /// Out of Trash, as Gmail does it: not back in the inbox by itself.
    public func untrash(thread id: String) async throws {
        _ = try await call("threads/\(id)/untrash", method: "POST", body: [:])
    }

    /// Labels on and off up to a thousand messages in one call, whatever
    /// threads they are in: an act on many (MailOps.bulk). 50 units, where
    /// a thread's modify is 10.
    func batchModify(ids: [String], add: [String], remove: [String]) async throws {
        _ = try await call("messages/batchModify", method: "POST", body: ["ids": ids, "addLabelIds": add, "removeLabelIds": remove])
    }

    // MARK: - the wire

    /// `again`: whether a failed call may simply go again. Not a send: a
    /// send Gmail took but didn't answer would go twice; the journal asks
    /// Sent first instead (MailOps). A path under "upload/" goes by
    /// Google's door for media (`upload`), the same path under
    /// /upload/gmail/v1/users/me, its bytes as they are.
    public func call(_ path: String, _ items: [URLQueryItem] = [], method: String = "GET", body: [String: Any]? = nil,
              upload: (data: Data, type: String)? = nil, again: Bool = true) async throws -> [String: Any] {
        guard Self.plain(path), Self.method(path, method) != nil else { throw MailTrouble.status(400) }
        let tries = again ? self.tries : 1
        var url = path.hasPrefix("upload/") ? Self.uploads(base).appendingPathComponent(String(path.dropFirst(7))) : base.appendingPathComponent(path)
        if !items.isEmpty, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.queryItems = items
            url = parts.url ?? url
        }
        var delay = wait
        var slowed = 0
        var attempt = 0
        while true {
            // A call no longer wanted (a fetch ahead of a thread left behind)
            // takes no quota, and goes nowhere once its turn comes.
            try Task.checkCancellation()
            await pace?.take(Self.cost(path, method: method))
            try Task.checkCancellation()
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.httpMethod = method
            request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
            if let body {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            if let upload {
                request.httpBody = upload.data
                request.setValue(upload.type, forHTTPHeaderField: "Content-Type")
            }
            let data: Data, response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                if attempt >= tries - 1 { throw MailTrouble.offline(error.localizedDescription) }
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                delay *= 2
                attempt += 1
                continue
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var reason = ""
            if !(200..<300).contains(status) {
                // Google's reason for a refusal, a word of its own, in the
                // open; its message only in private, as it can repeat what
                // was asked (an address, a label's name).
                let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
                reason = ((error?["errors"] as? [[String: Any]])?.first?["reason"] as? String) ?? (error?["status"] as? String) ?? ""
                let words = error?["message"] as? String ?? ""
                Self.log.error("\(method, privacy: .public) \(path.split(separator: "/").first.map(String.init) ?? path, privacy: .public) \(status) \(reason, privacy: .public) \(words, privacy: .private)")
            }
            let after = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            switch status {
            case 200..<300:
                if data.isEmpty { return [:] }
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MailTrouble.unreadable }
                return object
            case 401: throw MailTrouble.signedOut
            case 429, 403 where Self.slowDown.contains(reason):
                // Too fast: the account waits, then this goes again. A send
                // Gmail refused went nowhere, so it may go again too.
                let pause = after ?? Double(1 << slowed) * max(wait, 0.01) * 4
                guard slowed < limitTries - 1, pause <= 60 else { throw MailTrouble.limited }
                await pace?.cool(pause)
                try await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
                slowed += 1
            case 500..<600:
                guard attempt < tries - 1 else { throw MailTrouble.status(status) }
                try await Task.sleep(nanoseconds: UInt64((after ?? delay) * 1_000_000_000))
                delay *= 2
                attempt += 1
            default: throw MailTrouble.status(status)
            }
        }
    }

    /// Google's reasons for "slow down", as against a real refusal.
    static let slowDown: Set<String> = ["rateLimitExceeded", "userRateLimitExceeded", "RESOURCE_EXHAUSTED"]

    /// Google's door for media beside the API's own: the same address with
    /// /upload before its path (gmail.googleapis.com/upload/gmail/v1/users/me/).
    static func uploads(_ base: URL) -> URL {
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        parts.path = "/upload" + parts.path
        return parts.url ?? base
    }

    /// A path as it may go to Gmail: its words and ids, each of letters,
    /// digits, - and _, as Gmail's ids are (hex, base64url, Label_7). With
    /// `method` knowing the call (`call` asks both), an id a mail's HTML or
    /// an agent made up, climbing out of its place ("..") or into another
    /// (a slash), never leaves the Mac.
    public static func plain(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }

    /// Google's answers are mail and meetings: never in a cache on disk, no
    /// cookie kept or sent, TLS 1.2 at least. For the asks that aren't an
    /// account engine's own (Connect, `yab mail flush`, the calendar).
    public static let uncached = URLSession(configuration: MailWire.configuration())

    /// An error as mail's log says it in the open: what kind, and its code.
    /// Never what an error carries besides, such as the address it asked or
    /// a file's path, with the account and the file's name in it.
    public static func said(_ error: Error) -> String {
        if let trouble = error as? MailTrouble { return "\(trouble)" }
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }

    /// What each of Gmail's methods costs of a user's quota, as Google's
    /// table has it (developers.google.com/workspace/gmail/api/reference/quota,
    /// last updated 2026-09-10): every method Yab calls or is about to. The
    /// table has changed before (threads.get went from 10 to 40, a trash
    /// from 10 to 20), so a new call is checked against it again.
    public static let quota: [String: Int] = [
        "getProfile": 1, "history.list": 2,
        "labels.list": 1, "labels.get": 1, "labels.create": 5, "labels.update": 5, "labels.delete": 5,
        "messages.list": 5, "messages.get": 20, "messages.attachments.get": 20, "messages.modify": 5,
        "messages.batchModify": 50, "messages.send": 100, "messages.trash": 20, "messages.untrash": 5,
        "threads.list": 10, "threads.get": 40, "threads.modify": 10, "threads.trash": 20, "threads.untrash": 10,
        "drafts.list": 5, "drafts.get": 20, "drafts.create": 10, "drafts.update": 15, "drafts.delete": 10, "drafts.send": 100,
        "settings.sendAs.list": 1, "settings.sendAs.get": 1,
    ]

    /// Gmail's name for a call: its path under users/me and its HTTP method.
    /// A media upload ("upload/messages/send", the same path under
    /// /upload/gmail/v1/users/me) is the same method by another door. Nil
    /// for a call the table doesn't know.
    public static func method(_ path: String, _ method: String) -> String? {
        var parts = path.split(separator: "/").map(String.init)
        if parts.first == "upload" { parts.removeFirst() }
        guard let resource = parts.first else { return nil }
        let action = parts.count > 2 ? parts[2] : ""
        switch (resource, parts.count, method) {
        case ("profile", 1, "GET"): return "getProfile"
        case ("history", 1, "GET"): return "history.list"
        case ("labels", 1, "GET"): return "labels.list"
        case ("labels", 1, "POST"): return "labels.create"
        case ("labels", 2, "GET"): return "labels.get"
        case ("labels", 2, "PUT"), ("labels", 2, "PATCH"): return "labels.update"
        case ("labels", 2, "DELETE"): return "labels.delete"
        case ("messages", 1, "GET"): return "messages.list"
        case ("messages", 2, "POST") where parts[1] == "send" || parts[1] == "batchModify": return "messages." + parts[1]
        case ("messages", 2, "GET"): return "messages.get"
        case ("messages", 3, "POST") where ["modify", "trash", "untrash"].contains(action): return "messages." + action
        case ("messages", 4, "GET") where action == "attachments": return "messages.attachments.get"
        case ("threads", 1, "GET"): return "threads.list"
        case ("threads", 2, "GET"): return "threads.get"
        case ("threads", 3, "POST") where ["modify", "trash", "untrash"].contains(action): return "threads." + action
        case ("drafts", 1, "GET"): return "drafts.list"
        case ("drafts", 1, "POST"): return "drafts.create"
        case ("drafts", 2, "POST") where parts[1] == "send": return "drafts.send"
        case ("drafts", 2, "GET"): return "drafts.get"
        case ("drafts", 2, "PUT"): return "drafts.update"
        case ("drafts", 2, "DELETE"): return "drafts.delete"
        case ("settings", 2, "GET") where parts[1] == "sendAs": return "settings.sendAs.list"
        case ("settings", 3, "GET") where parts[1] == "sendAs": return "settings.sendAs.get"
        default: return nil
        }
    }

    /// What a call costs of the user's quota. One the table doesn't know
    /// counts as dear as a send, so it can't overrun the quota unseen;
    /// MailGmailCostTests fails on it first.
    public static func cost(_ path: String, method: String) -> Int {
        Self.method(path, method).flatMap { quota[$0] } ?? 100
    }

    // MARK: - reading a message

    public static func string(_ any: Any?) -> String {
        if let text = any as? String { return text }
        if let number = any as? NSNumber { return number.stringValue }
        return ""
    }

    /// A message resource as the store keeps it.
    public static func message(_ json: [String: Any], full: Bool) -> MailMessage? {
        guard let id = json["id"] as? String, let thread = json["threadId"] as? String else { return nil }
        let payload = json["payload"] as? [String: Any] ?? [:]
        var headers: [String: String] = [:]
        for header in payload["headers"] as? [[String: Any]] ?? [] {
            guard let name = header["name"] as? String, let value = header["value"] as? String else { continue }
            if headers[name.lowercased()] == nil { headers[name.lowercased()] = value }
        }
        let millis = Double(string(json["internalDate"])) ?? 0
        var message = MailMessage(
            id: id, thread: thread,
            from: MailPerson.one(headers["from"] ?? "") ?? MailPerson(name: "", address: ""),
            to: MailPerson.list(headers["to"] ?? ""), cc: MailPerson.list(headers["cc"] ?? ""),
            subject: headers["subject"] ?? "", snippet: HTMLText.plain(json["snippet"] as? String ?? ""),
            date: Date(timeIntervalSince1970: millis / 1000),
            labels: Set(json["labelIds"] as? [String] ?? []),
            rfcID: headers["message-id"] ?? "", inReplyTo: headers["in-reply-to"] ?? "", references: headers["references"] ?? "",
            listUnsubscribe: headers["list-unsubscribe"] != nil,
            replyTo: MailPerson.list(headers["reply-to"] ?? ""),
            unsubscribe: headers["list-unsubscribe"] ?? "", unsubscribePost: headers["list-unsubscribe-post"] ?? "")
        if full {
            var read = Parts()
            parts(payload, at: "", into: &read)
            message.html = read.html
            message.text = read.plain ?? read.html.map(HTMLText.plain) ?? message.snippet
            // An invitation's own text/calendar beside the words is none of
            // the mail's files to show: the card over the mail says it.
            message.files = MailFile.marked(read.files, html: read.html).map { file in
                var file = file
                if read.alternatives.contains(file.part) { file.inline = true }
                return file
            }
            message.attached = message.files?.contains { !$0.inline }
            message.calendar = read.calendar
        }
        return message
    }

    /// What a message's parts hold: its words, its files, and an invitation.
    private struct Parts {
        public var plain: String?
        public var html: String?
        public var files: [MailFile] = []
        /// The iCalendar object it carries in itself (RFC 6047), the one
        /// that says its method first.
        public var calendar: String?
        var calendarSaysMethod = false
        /// Parts that are an invitation's text/calendar beside the words,
        /// kept as files only to be fetched: never a chip.
        var alternatives: Set<String> = []
    }

    /// The first text/plain and text/html parts, however deep, and every
    /// file beside them (MailFile.part): a message attached whole is one
    /// file, not opened. An invitation (text/calendar, or an .ics file) is
    /// read where its words came in the message; one that came by an
    /// attachment id is a file, fetched when its thread is opened.
    /// `path`: where the part is, as Gmail numbers them.
    private static func parts(_ part: [String: Any], at path: String, into read: inout Parts) {
        let type = (part["mimeType"] as? String ?? "").lowercased()
        let body = part["body"] as? [String: Any] ?? [:]
        let headers = MailMime.headers(part["headers"])
        let contentType = MailMime.parameters(headers["content-type"] ?? type)
        let name = (part["filename"] as? String ?? "").lowercased()
        if type == "text/calendar" || type == "application/ics" || name.hasSuffix(".ics") {
            let method = contentType.params["method"] != nil
            if let data = body["data"] as? String, let bytes = bytes(data), read.calendar == nil || (method && !read.calendarSaysMethod) {
                read.calendar = MailMime.decode(bytes, charset: contentType.params["charset"] ?? "utf-8")
                read.calendarSaysMethod = method
            }
            if MailFile.part(part, at: path) == nil {
                // Beside the words, nameless: a file only to fetch its words by.
                if let id = body["attachmentId"] as? String, body["data"] == nil {
                    let given = part["partId"] as? String ?? ""
                    let file = MailFile(part: given.isEmpty ? path : given, name: "invite.ics", mime: "text/calendar",
                                        size: MailMime.int(body["size"]), attachmentID: id, inline: true)
                    read.files.append(file)
                    read.alternatives.insert(file.part)
                }
                return
            }
        }
        if let file = MailFile.part(part, at: path) {
            read.files.append(file)
            return
        }
        if let data = body["data"] as? String, let text = decode(data) {
            if type == "text/plain", read.plain == nil { read.plain = text }
            if type == "text/html", read.html == nil { read.html = text }
        }
        for (n, child) in (part["parts"] as? [[String: Any]] ?? []).enumerated() {
            parts(child, at: path.isEmpty ? "\(n)" : "\(path).\(n)", into: &read)
        }
    }

    /// Gmail's base64url, with its padding or without, as bytes.
    public static func bytes(_ text: String) -> Data? {
        var bytes = Array(text.utf8)
        for at in bytes.indices {
            if bytes[at] == 45 { bytes[at] = 43 } else if bytes[at] == 95 { bytes[at] = 47 }
        }
        while bytes.count % 4 != 0 { bytes.append(61) }
        return Data(base64Encoded: Data(bytes), options: .ignoreUnknownCharacters)
    }

    /// Gmail's base64url, without padding.
    public static func decode(_ text: String) -> String? {
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 { base += "=" }
        return Data(base64Encoded: base).map { String(decoding: $0, as: UTF8.self) }
    }

    public static func encode(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public init(base: URL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/")!, session: URLSession = MailGmail.uncached, token: @escaping @Sendable () async throws -> String, tries: Int = 3, wait: TimeInterval = 0.5, pace: MailPace? = nil, limitTries: Int = 6) {
        self.base = base
        self.session = session
        self.token = token
        self.tries = tries
        self.wait = wait
        self.pace = pace
        self.limitTries = limitTries
    }
}

/// One account's share of Gmail's quota, spent evenly: calls wait their turn
/// at up to 80 units a second, 4,800 a minute under Google's 6,000. After a
/// quiet while up to `burst` units go at once, so a search of Gmail or a
/// thread opened doesn't wait out the even pace (800: ten seconds' worth,
/// which leaves any minute under 6,000). When Gmail says slow down, every
/// call of the account waits it out and the rate halves, then comes back
/// over the next minute: another Mac on the same account, or a quota Google
/// lowered, finds its own pace.
public actor MailPace {
    /// Units an account spends at once after a quiet while: with 80 a
    /// second, no minute goes past 6,000 (1,100 + 80 × 60 = 5,900). As
    /// much as the first screen after Connect takes in one go: the inbox's
    /// newest 50 mails (20 each), their list and the account (MailSync).
    public static let burst: Double = 1_100

    private var next = Date.distantPast
    private var halved = Date.distantPast
    private var tended = Date()
    public nonisolated let top: Double
    private var low: Double
    public let burst: Double

    public init(rate: Double = 80, burst: Double = 0) {
        top = rate
        low = rate
        self.burst = burst
    }

    /// The rate now: back to the top a minute after it was halved to nothing.
    public var rate: Double { min(top, low + top * max(0, Date().timeIntervalSince(tended)) / 60) }

    public func take(_ cost: Int) async {
        let now = Date()
        low = rate
        tended = now
        // Time not spent lately is spent now, up to the burst.
        let at = max(now.addingTimeInterval(-burst / low), next)
        next = at.addingTimeInterval(Double(cost) / low)
        let wait = at.timeIntervalSince(now)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }

    func cool(_ seconds: TimeInterval) {
        let now = Date()
        next = max(next, now.addingTimeInterval(seconds))
        // Once for the calls refused together, not once for each.
        if now.timeIntervalSince(halved) > 5 {
            halved = now
            low = max(top / 8, rate / 2)
            tended = now.addingTimeInterval(seconds)
        }
    }
}
