import Foundation

// A line to a mail server, IMAP's or SMTP's (docs/mail-providers.md, M3):
// TCP with TLS from the first byte (993, 465), or TLS begun on the way
// (STARTTLS, 587 and 143), lines and counted bytes read off it. A
// URLSessionStreamTask carries it, because it alone of the system's own
// can begin TLS on a line already open (startSecureConnection), which
// iCloud's and most submission servers' 587 needs; Network.framework sets
// TLS once, when a connection starts. Plain TCP only to this Mac, for the
// test worlds' fake servers.

/// How a server's line is kept private.
public enum MailSecurity: String, Codable, Sendable, Equatable {
    /// TLS from the first byte (IMAPS 993, SMTPS 465).
    case tls
    /// Plain, then STARTTLS before anything is said (587, 143).
    case starttls
    /// Plain: only to this Mac (a test world's fake, Proton Bridge).
    case none
}

/// What went wrong reaching a mail server, said the same way by the
/// probe (mail_probe), the setup sheet and the sync.
public enum MailServerTrouble: Error, Equatable, Sendable {
    case dnsNotFound
    case tcpRefused
    case tlsFailed(String)
    case authRejected(String)
    case appPasswordRequired(String)
    case imapDisabled(String)
    case capabilityMissing(String)
    case quotaExceeded(String)
    case timedOut(String)
    case offline
    case closed
    case refused(String)
    case unreadable(String)

    /// The name agents and the probe read.
    public var hint: String {
        switch self {
        case .dnsNotFound: return "dnsNotFound"
        case .tcpRefused: return "tcpRefused"
        case .tlsFailed: return "tlsFailed"
        case .authRejected: return "authRejected"
        case .appPasswordRequired: return "appPasswordRequired"
        case .imapDisabled: return "imapDisabled"
        case .capabilityMissing: return "capabilityMissing"
        case .quotaExceeded: return "quotaExceeded"
        case .timedOut: return "timedOut"
        case .offline: return "offline"
        case .closed: return "closed"
        case .refused: return "refused"
        case .unreadable: return "unreadable"
        }
    }

    /// What the server said, when it said something.
    public var said: String {
        switch self {
        case .tlsFailed(let s), .authRejected(let s), .appPasswordRequired(let s), .imapDisabled(let s), .capabilityMissing(let s),
             .quotaExceeded(let s), .timedOut(let s), .refused(let s), .unreadable(let s):
            return s
        default: return ""
        }
    }

    /// For a person, in a line.
    public var words: String {
        switch self {
        case .dnsNotFound: return "No server by that name"
        case .tcpRefused: return "The server didn’t take the connection"
        case .tlsFailed: return "The server’s certificate isn’t one \(Brand.name) can trust"
        case .authRejected: return "The server didn’t accept the password"
        case .appPasswordRequired: return "This account needs an app password"
        case .imapDisabled: return "IMAP is turned off for this mailbox"
        case .capabilityMissing(let what): return "The server can’t \(what)"
        case .quotaExceeded: return "The mailbox is full"
        case .timedOut: return "The server didn’t answer"
        case .offline: return "This Mac is offline"
        case .closed: return "The server closed the connection"
        case .refused(let s): return s.isEmpty ? "The server refused" : s
        case .unreadable: return "The server’s answer couldn’t be read"
        }
    }

    /// The server's own words about a refused sign-in, read for what they
    /// mean: an app password wanted, IMAP turned off, a full mailbox.
    public static func login(_ text: String) -> MailServerTrouble {
        let low = text.lowercased()
        if low.contains("application-specific") || low.contains("app-specific") || low.contains("app password")
            || low.contains("application password") || low.contains("web login required") || low.contains("[alert] please log in via your web browser") {
            return .appPasswordRequired(text)
        }
        if low.contains("imap") && (low.contains("disabled") || low.contains("not enabled") || low.contains("turned off") || low.contains("enable imap")) {
            return .imapDisabled(text)
        }
        if low.contains("[overquota]") || low.contains("quota") { return .quotaExceeded(text) }
        return .authRejected(text)
    }

    /// A system error said as one of these.
    public static func from(_ error: Error, step: String) -> MailServerTrouble {
        if let trouble = error as? MailServerTrouble { return trouble }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return .dnsNotFound
            case NSURLErrorCannotConnectToHost: return .tcpRefused
            case NSURLErrorTimedOut: return .timedOut(step)
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: return .offline
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateNotYetValid, NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorClientCertificateRejected,
                 NSURLErrorClientCertificateRequired:
                return .tlsFailed(ns.localizedDescription)
            default: break
            }
        }
        // Secure Transport's and Network's own (errSSL…, -9800 to -9899).
        if (ns.domain == NSOSStatusErrorDomain || ns.domain == "kCFStreamErrorDomainSSL"), (-9899 ... -9800).contains(ns.code) {
            return .tlsFailed(ns.localizedDescription)
        }
        if ns.domain == NSPOSIXErrorDomain {
            switch Int32(ns.code) {
            case ECONNREFUSED: return .tcpRefused
            case ETIMEDOUT: return .timedOut(step)
            case ENETUNREACH, EHOSTUNREACH: return .offline
            default: break
            }
        }
        if ns.domain == "kCFErrorDomainCFNetwork" || ns.domain == kCFErrorDomainCFNetwork as String {
            if ns.code == 2 { return .dnsNotFound }
        }
        return .unreadable(ns.localizedDescription)
    }
}

/// A test world's stand-ins for real providers' servers
/// (evals/mail/providers.py): `mail.fake.hosts` in the world's settings maps
/// a host the app found by its own means (imap.mail.me.com, smtp.zoho.com)
/// to a fake's port on this Mac, so Add Account finds iCloud and Zoho as it
/// does for a person and reaches a fake, plain. Nothing outside a --test run.
public enum MailStandIn {
    public static let key = "mail.fake.hosts"

    static func ports() -> [String: Int] {
        guard Store.testing, let text = Store.settings.string(forKey: key),
              let map = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return [:] }
        var out: [String: Int] = [:]
        for (host, port) in map { if let port = (port as? NSNumber)?.intValue { out[host.lowercased()] = port } }
        return out
    }

    /// A host a fake stands in for.
    public static func covers(_ host: String) -> Bool { ports()[host.lowercased()] != nil }

    /// Where a line to `host` really goes: the fake's port, plain, when one
    /// stands in for it.
    public static func route(_ host: String, _ port: Int, _ security: MailSecurity) -> (String, Int, MailSecurity, Bool) {
        guard let local = ports()[host.lowercased()] else { return (host, port, security, false) }
        return ("127.0.0.1", local, .none, true)
    }
}

/// One line to a server: lines in, lines and bytes out.
public actor MailSocket {
    public nonisolated let host: String
    public nonisolated let port: Int
    /// A test world's fake answering for a provider's host (MailStandIn):
    /// plain, so no STARTTLS is begun on it.
    public nonisolated let standIn: Bool
    private let task: URLSessionStreamTask
    private var buffer = Data()
    private var open = true
    /// A byte read since the line, or its TLS, began: the line is set up.
    /// Until then a wait is timed here, not by the stream task (`io`).
    private var settled = false
    /// How long one read may wait (IDLE reads wait longer, `read(timeout:)`).
    public var timeout: TimeInterval = 30
    /// Bytes read and written, for the bench.
    public private(set) var read = 0
    public private(set) var written = 0

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config)
    }()

    /// A line opened, TLS begun at once for `.tls`. STARTTLS's own begins
    /// with `secure()` once the server has said yes.
    public init(host: String, port: Int, security: MailSecurity) throws {
        let (host, port, security, standIn) = MailStandIn.route(host, port, security)
        if security == .none, !MailSocket.local(host) {
            throw MailServerTrouble.tlsFailed("A plain line goes only to this Mac")
        }
        self.host = host
        self.port = port
        self.standIn = standIn
        task = MailSocket.session.streamTask(withHostName: host, port: port)
        task.resume()
        if security == .tls { task.startSecureConnection() }
    }

    public static func local(_ host: String) -> Bool {
        ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased())
    }

    /// TLS from here on (after STARTTLS's yes).
    public func secure() {
        buffer.removeAll()
        settled = false
        task.startSecureConnection()
    }

    public func set(timeout: TimeInterval) { self.timeout = timeout }

    public func close() {
        guard open else { return }
        open = false
        task.cancel()
    }

    private func fill(timeout wait: TimeInterval?) async throws {
        guard open else { throw MailServerTrouble.closed }
        let (data, eof): (Data?, Bool)
        do {
            (data, eof) = try await io(wait ?? timeout) { task, wait, done in
                task.readData(ofMinLength: 1, maxLength: 1 << 16, timeout: wait) { data, eof, error in
                    done(error.map { .failure($0) } ?? .success((data, eof)))
                }
            }
        } catch Deadline.passed {
            throw MailServerTrouble.timedOut("read")
        } catch {
            open = false
            throw MailServerTrouble.from(error, step: "read")
        }
        if let data, !data.isEmpty {
            settled = true
            buffer.append(data)
            read += data.count
        } else if eof {
            open = false
            throw MailServerTrouble.closed
        } else {
            // Nothing in the time given.
            throw MailServerTrouble.timedOut("read")
        }
    }

    /// One line, its CRLF (or a bare LF) left off.
    public func line(timeout wait: TimeInterval? = nil) async throws -> Data {
        while true {
            if let at = buffer.firstIndex(of: 10) {
                var line = buffer[buffer.startIndex..<at]
                if line.last == 13 { line = line.dropLast() }
                let out = Data(line)
                buffer.removeSubrange(buffer.startIndex...at)
                return out
            }
            // A line past a megabyte is no line a server sends.
            if buffer.count > 1 << 20 { throw MailServerTrouble.unreadable("a line too long") }
            try await fill(timeout: wait)
        }
    }

    /// Exactly `count` bytes: an IMAP literal.
    public func bytes(_ count: Int) async throws -> Data {
        while buffer.count < count { try await fill(timeout: nil) }
        let out = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return out
    }

    public func write(_ data: Data) async throws {
        guard open else { throw MailServerTrouble.closed }
        do {
            try await io(timeout) { task, wait, done in
                task.write(data, timeout: wait) { error in done(error.map { .failure($0) } ?? .success(())) }
            }
            written += data.count
        } catch Deadline.passed {
            throw MailServerTrouble.timedOut("write")
        } catch {
            open = false
            throw MailServerTrouble.from(error, step: "write")
        }
    }

    public func write(_ text: String) async throws { try await write(Data(text.utf8)) }

    public var isOpen: Bool { open }

    // MARK: - one read or write

    // A read or write the stream task timed out before its line was set up
    // stays in CFNetwork's queue: when the task is then cancelled, or the
    // line fails, -[__NSCFTCPIOStreamTask
    // _onqueue_connectionEstablishedWithError:callbackReferent:] answers it
    // again, which resumed the async overlay's continuation a second time
    // or reached a freed object (crash #107, row 1140; a read timed out at
    // once and cancelled was answered twice about one time in five,
    // scratch stress on renderer-2). So until a byte has come the task is
    // given no timeout, the wait is timed here and a wait that passes ends
    // the line; and every answer is taken once.

    private enum Deadline: Error { case passed }

    private func io<T>(_ wait: TimeInterval,
                       _ start: (URLSessionStreamTask, TimeInterval, @escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        let own = !settled
        let once = Once<T>()
        let task = self.task
        do {
            return try await withCheckedThrowingContinuation { continuation in
                once.continuation = continuation
                // 0: the stream task never times it out.
                start(task, own ? 0 : wait) { once.resume($0) }
                if own {
                    DispatchQueue.global().asyncAfter(deadline: .now() + wait) {
                        if once.resume(.failure(Deadline.passed)) { task.cancel() }
                    }
                }
            }
        } catch Deadline.passed {
            // The task was cancelled under its pending call: the line is done.
            open = false
            throw Deadline.passed
        }
    }

    /// A continuation resumed by whichever answer comes first.
    private final class Once<T>: @unchecked Sendable {
        private let lock = NSLock()
        var continuation: CheckedContinuation<T, Error>?

        @discardableResult
        func resume(_ result: Result<T, Error>) -> Bool {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            guard let continuation else { return false }
            continuation.resume(with: result)
            return true
        }
    }
}
