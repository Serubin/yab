import Foundation

// Network's words: the filter as Chromium reads it, the request copied as
// cURL, PowerShell, fetch and HAR as Chromium writes them, a HAR brought back
// in, and the request for an agent, its secrets out (DevNet.swift).

// MARK: - the filter

/// Chrome's Network filter: words that must all match, `key:value` terms,
/// `-` before a term for its opposite, `/regex/` for the address, Invert for
/// the whole; the type chips, More filters and a stretch of the overview.
struct NetFilter: Equatable {
    var text = ""
    var invert = false
    /// Empty for All.
    var types: Set<NetCategory> = []
    var hideData = false
    var hideExtensions = false
    var onlyBlocked = false
    var onlyThirdParty = false
    /// A stretch of the overview, on the inspector's clock.
    var range: ClosedRange<Double>?

    /// The keys Chrome's filter takes, for its completions.
    static let keys = ["domain", "has-overrides", "has-request-header", "has-response-header", "is", "larger-than", "method", "mime-type",
                       "mixed-content", "priority", "resource-type", "response-header-set-cookie", "scheme", "set-cookie-domain",
                       "set-cookie-name", "set-cookie-value", "status-code", "url", "cookie-domain", "cookie-name", "cookie-path", "cookie-value"]

    var isActive: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty || invert || !types.isEmpty || hideData || hideExtensions || onlyBlocked || onlyThirdParty || range != nil }

    struct Term {
        let negated: Bool
        let key: String?
        let value: String
        let regex: NSRegularExpression?
    }

    static func terms(_ text: String) -> [Term] {
        text.split(whereSeparator: \.isWhitespace).map(String.init).compactMap { word in
            var word = word
            let negated = word.count > 1 && word.hasPrefix("-")
            if negated { word.removeFirst() }
            if word.count > 2, word.hasPrefix("/"), word.hasSuffix("/") {
                let pattern = String(word.dropFirst().dropLast())
                return Term(negated: negated, key: nil, value: pattern, regex: try? NSRegularExpression(pattern: pattern, options: .caseInsensitive))
            }
            if let colon = word.firstIndex(of: ":") {
                let key = word[..<colon].lowercased()
                if keys.contains(key) { return Term(negated: negated, key: key, value: String(word[word.index(after: colon)...]), regex: nil) }
            }
            return Term(negated: negated, key: nil, value: word, regex: nil)
        }
    }

    /// Whether the row is listed. `page` is the page's own address, for
    /// 3rd-party requests and mixed content; `overridden` says which kind of
    /// override an address has.
    func admits(_ row: NetRow, page: URL?, overridden: (String) -> String?) -> Bool {
        if !types.isEmpty, !types.contains(row.category) { return false }
        let url = row.url
        if hideData, url.hasPrefix("data:") || url.hasPrefix("blob:") { return false }
        if hideExtensions, url.hasPrefix("safari-web-extension:") || url.hasPrefix("webkit-extension:") || url.hasPrefix("chrome-extension:") { return false }
        if onlyBlocked, row.resource.blockedBy == nil || row.hop != nil { return false }
        if onlyThirdParty, Self.origin(url) == Self.origin(page?.absoluteString ?? "") { return false }
        if let range {
            let span = row.span
            let end = span.end ?? .infinity
            if end < range.lowerBound || span.start > range.upperBound { return false }
        }
        let words = Self.terms(text)
        guard !words.isEmpty else { return true }
        let all = words.allSatisfy { term in
            let hit = matches(term, row, page: page, overridden: overridden)
            return term.negated ? !hit : hit
        }
        return invert ? !all : all
    }

    private func matches(_ term: Term, _ row: NetRow, page: URL?, overridden: (String) -> String?) -> Bool {
        let v = term.value.lowercased()
        guard let key = term.key else {
            if let regex = term.regex {
                return regex.firstMatch(in: row.url, range: NSRange(row.url.startIndex..., in: row.url)) != nil
            }
            return row.url.lowercased().contains(v)
        }
        let r = row.resource
        switch key {
        case "domain": return Self.glob(v).map { $0.firstMatch(in: row.host.lowercased(), range: NSRange(row.host.startIndex..., in: row.host)) != nil } ?? false
        case "has-response-header": return row.responseHeaders.contains { $0.name.lowercased() == v }
        case "has-request-header": return row.requestHeaders.contains { $0.name.lowercased() == v }
        case "has-overrides":
            let kind = overridden(row.url)
            switch v {
            case "no": return kind == nil
            case "yes": return kind != nil
            case "content": return kind == "content" || kind == "both"
            case "headers": return kind == "headers" || kind == "both"
            default: return false
            }
        case "is":
            switch v {
            case "running": return row.pending
            case "from-cache": return row.fromCache
            case "service-worker-intercepted": return r.source == "service-worker"
            default: return false
            }
        case "larger-than":
            guard let limit = Self.bytes(v) else { return false }
            return row.transferred > limit || row.size > limit
        case "method": return row.method.lowercased() == v
        case "mime-type": return r.mime.lowercased() == v
        case "mixed-content":
            guard page?.scheme == "https", row.scheme == "http" else { return false }
            return v == "all" || v == "displayed" && !row.failed || v == "blocked" && row.failed
        case "priority": return r.priority.lowercased() == v
        case "resource-type": return row.typeLabel.lowercased() == v || r.type == v
        case "scheme": return row.scheme.lowercased() == v
        case "status-code": return String(row.status) == v
        case "url": return row.url.lowercased().contains(v)
        case "response-header-set-cookie": return setCookies(row).contains { $0.lowercased().contains(v) }
        case "set-cookie-name": return setCookies(row).compactMap { NetCookie.parse(set: $0) }.contains { $0.name.lowercased() == v }
        case "set-cookie-value": return setCookies(row).compactMap { NetCookie.parse(set: $0) }.contains { $0.value.lowercased() == v }
        case "set-cookie-domain": return setCookies(row).compactMap { NetCookie.parse(set: $0) }.contains { $0.domain.lowercased() == v }
        case "cookie-name": return NetCookie.request(row).contains { $0.name.lowercased() == v }
        case "cookie-value": return NetCookie.request(row).contains { $0.value.lowercased() == v }
        case "cookie-domain": return NetCookie.request(row).isEmpty ? false : row.host.lowercased() == v
        case "cookie-path": return NetCookie.request(row).isEmpty ? false : v == "/"
        default: return false
        }
    }

    private func setCookies(_ row: NetRow) -> [String] {
        row.responseHeaders.filter { $0.name.lowercased() == "set-cookie" }.flatMap { $0.value.components(separatedBy: "\n") }
    }

    static func glob(_ pattern: String) -> NSRegularExpression? {
        let escaped = NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*")
        return try? NSRegularExpression(pattern: "^" + escaped + "$", options: .caseInsensitive)
    }

    /// 1000, 10k, 1M: Chrome's sizes, k a thousand and m a million.
    static func bytes(_ text: String) -> Int? {
        let t = text.lowercased()
        let factor: Double = t.hasSuffix("k") ? 1000 : t.hasSuffix("m") ? 1_000_000 : 1
        let digits = factor == 1 ? t : String(t.dropLast())
        return Double(digits).map { Int($0 * factor) }
    }

    static func origin(_ url: String) -> String {
        guard let parts = URLComponents(string: url), let scheme = parts.scheme, let host = parts.host else { return "" }
        return "\(scheme)://\(host)" + (parts.port.map { ":\($0)" } ?? "")
    }

    /// What the field could take next: the keys, or what came after one.
    static func completions(_ text: String, rows: [NetRow]) -> [String] {
        let last = text.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        let word = last.hasPrefix("-") ? String(last.dropFirst()) : last
        guard !word.isEmpty, !text.hasSuffix(" ") else { return [] }
        guard let colon = word.firstIndex(of: ":") else {
            return keys.filter { $0.hasPrefix(word.lowercased()) && $0 != word }.map { $0 + ":" }
        }
        let key = word[..<colon].lowercased()
        let typed = word[word.index(after: colon)...].lowercased()
        var values: [String] = []
        switch key {
        case "is": values = ["running", "from-cache", "service-worker-intercepted", "service-worker-initiated", "preloaded"]
        case "has-overrides": values = ["yes", "no", "content", "headers"]
        case "mixed-content": values = ["all", "displayed", "blocked", "block-overridden"]
        case "larger-than": values = ["1k", "10k", "100k", "1M"]
        case "priority": values = ["Low", "Medium", "High"]
        default:
            var seen = Set<String>()
            for row in rows {
                let value: String?
                switch key {
                case "domain": value = row.host
                case "method": value = row.method
                case "status-code": value = row.status > 0 ? String(row.status) : nil
                case "mime-type": value = row.resource.mime.isEmpty ? nil : row.resource.mime
                case "resource-type": value = row.resource.type
                case "scheme": value = row.scheme
                default: value = nil
                }
                if let value, !value.isEmpty, seen.insert(value).inserted { values.append(value) }
            }
        }
        return values.filter { $0.lowercased().hasPrefix(typed) && $0.lowercased() != typed }.prefix(10).map { "\(key):\($0)" }
    }
}

// MARK: - cookies

struct NetCookie: Equatable {
    var name: String
    var value: String
    var domain = ""
    var path = ""
    var expires = "Session"
    var httpOnly = false
    var secure = false
    var sameSite = ""
    var partitioned = false
    var priority = "Medium"
    var size: Int { name.count + value.count }

    /// The request's Cookie header, cookie by cookie.
    static func request(_ row: NetRow) -> [NetCookie] {
        guard let header = row.requestHeaders.value("Cookie") else { return [] }
        let host = row.host
        return header.split(separator: ";").compactMap { part in
            let pair = part.trimmingCharacters(in: .whitespaces)
            guard let eq = pair.firstIndex(of: "=") else { return pair.isEmpty ? nil : NetCookie(name: pair, value: "", domain: host, path: "/") }
            return NetCookie(name: String(pair[..<eq]), value: String(pair[pair.index(after: eq)...]), domain: host, path: "/")
        }
    }

    /// The response's Set-Cookie headers; those that don't read as a cookie
    /// are Chrome's malformed ones.
    static func response(_ row: NetRow) -> (cookies: [NetCookie], malformed: [String]) {
        let lines = row.responseHeaders.filter { $0.name.lowercased() == "set-cookie" }.flatMap { $0.value.components(separatedBy: "\n") }
        var cookies: [NetCookie] = []
        var malformed: [String] = []
        for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            if var cookie = parse(set: line) {
                if cookie.domain.isEmpty { cookie.domain = row.host }
                cookies.append(cookie)
            } else {
                malformed.append(line)
            }
        }
        return (cookies, malformed)
    }

    static func parse(set line: String) -> NetCookie? {
        let parts = line.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = parts.first, let eq = first.firstIndex(of: "="), eq != first.startIndex else { return nil }
        var cookie = NetCookie(name: String(first[..<eq]), value: String(first[first.index(after: eq)...]))
        for attribute in parts.dropFirst() {
            let pieces = attribute.split(separator: "=", maxSplits: 1).map(String.init)
            let key = pieces[0].lowercased()
            let value = pieces.count > 1 ? pieces[1] : ""
            switch key {
            case "domain": cookie.domain = value
            case "path": cookie.path = value
            case "expires": cookie.expires = value
            case "max-age": cookie.expires = value
            case "httponly": cookie.httpOnly = true
            case "secure": cookie.secure = true
            case "samesite": cookie.sameSite = value
            case "partitioned": cookie.partitioned = true
            case "priority": cookie.priority = value
            default: break
            }
        }
        if cookie.path.isEmpty { cookie.path = "/" }
        return cookie
    }
}

// MARK: - copied as Chromium copies

enum NetCopy {
    /// The pseudo headers HTTP/2 shows, which no one sends by hand.
    private static func sendable(_ headers: [NetHeader]) -> [NetHeader] {
        headers.filter { !$0.name.hasPrefix(":") }
    }

    private static func shell(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Copy as cURL: everything the page sent, its cookies with -b, as
    /// Chrome's bash form.
    static func curl(_ row: NetRow) -> String {
        var parts = ["curl \(shell(row.url))"]
        if row.method != "GET" { parts.append("-X \(shell(row.method))") }
        var compressed = false
        for header in sendable(row.requestHeaders) {
            let name = header.name.lowercased()
            if name == "content-length" { continue }
            if name == "accept-encoding" { compressed = true; continue }
            if name == "cookie" { parts.append("-b \(shell(header.value))"); continue }
            parts.append("-H \(shell("\(name): \(header.value)"))")
        }
        if let body = row.hop == nil ? row.resource.postData : nil { parts.append("--data-raw \(shell(body))") }
        if compressed { parts.append("--compressed") }
        return parts.joined(separator: " \\\n  ")
    }

    /// Copy as PowerShell.
    static func powerShell(_ row: NetRow) -> String {
        func ps(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "`", with: "``").replacingOccurrences(of: "\"", with: "`\"").replacingOccurrences(of: "$", with: "`$") + "\"" }
        let headers = sendable(row.requestHeaders).filter { !["user-agent", "host", "content-length", "cookie", "connection", "content-type"].contains($0.name.lowercased()) }
        var out = "$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession\n"
        if let agent = row.requestHeaders.value("User-Agent") { out += "$session.UserAgent = \(ps(agent))\n" }
        if let cookie = row.requestHeaders.value("Cookie") {
            for part in cookie.split(separator: ";") {
                let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                out += "$session.Cookies.Add((New-Object System.Net.Cookie(\(ps(pair[0])), \(ps(pair[1])), \"/\", \(ps(row.host)))))\n"
            }
        }
        out += "Invoke-WebRequest -UseBasicParsing -Uri \(ps(row.url)) `\n-Method \(ps(row.method)) `\n-WebSession $session"
        if !headers.isEmpty {
            out += " `\n-Headers @{\n" + headers.map { "\(ps($0.name))=\(ps($0.value))" }.joined(separator: "\n  ") + "\n}"
        }
        if let type = row.requestHeaders.value("Content-Type") { out += " `\n-ContentType \(ps(type))" }
        if let body = row.hop == nil ? row.resource.postData : nil { out += " `\n-Body \(ps(body))" }
        return out
    }

    /// Copy as fetch, for a page's console; with `node`, Copy as fetch
    /// (Node.js), its cookies and referrer as headers.
    static func fetch(_ row: NetRow, node: Bool) -> String {
        let forbidden: Set<String> = ["accept-charset", "accept-encoding", "access-control-request-headers", "access-control-request-method", "connection",
                                      "content-length", "cookie", "cookie2", "date", "dnt", "expect", "host", "keep-alive", "origin", "referer", "te",
                                      "trailer", "transfer-encoding", "upgrade", "via", "user-agent"]
        var headers: [(String, String)] = []
        for header in sendable(row.requestHeaders) {
            let name = header.name.lowercased()
            if node {
                if ["host", "content-length", "connection", "accept-encoding"].contains(name) { continue }
            } else if forbidden.contains(name) || name.hasPrefix("sec-") || name.hasPrefix("proxy-") { continue }
            headers.append((name, header.value))
        }
        func json(_ text: String) -> String {
            (try? String(data: JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes]), encoding: .utf8)).map { String($0.dropFirst().dropLast()) } ?? "\"\""
        }
        var lines: [String] = []
        lines.append("  \"headers\": {" + (headers.isEmpty ? "}" : "\n" + headers.map { "    \(json($0.0)): \(json($0.1))" }.joined(separator: ",\n") + "\n  }"))
        if !node, let referer = row.requestHeaders.value("Referer") {
            lines.append("  \"referrer\": \(json(referer))")
            if !row.resource.referrerPolicy.isEmpty { lines.append("  \"referrerPolicy\": \(json(row.resource.referrerPolicy))") }
        }
        lines.append("  \"body\": " + ((row.hop == nil ? row.resource.postData : nil).map(json) ?? "null"))
        lines.append("  \"method\": \(json(row.method))")
        if !node {
            lines.append("  \"mode\": \(json(row.requestHeaders.value("Sec-Fetch-Mode") ?? "cors"))")
            lines.append("  \"credentials\": \(json(row.requestHeaders.value("Cookie") != nil ? "include" : "omit"))")
        }
        return "fetch(\(json(row.url)), {\n" + lines.joined(separator: ",\n") + "\n});"
    }

    /// Copy as preload element; nil where Chrome would grey it out.
    static func preload(_ row: NetRow) -> String? {
        guard row.method == "GET", row.scheme == "http" || row.scheme == "https", row.resource.type != "document", row.hop == nil else { return nil }
        let kind: String
        switch row.resource.type {
        case "script": kind = "script"
        case "stylesheet": kind = "style"
        case "font": kind = "font"
        case "image": kind = "image"
        default: kind = "fetch"
        }
        let crossorigin = kind == "font" || kind == "fetch" || NetFilter.origin(row.url) != NetFilter.origin(row.requestHeaders.value("Referer") ?? row.url)
        return "<link rel=\"preload\" href=\"\(row.url.replacingOccurrences(of: "\"", with: "&quot;"))\" as=\"\(kind)\"\(crossorigin ? " crossorigin" : "")>"
    }

    static func headers(_ list: [NetHeader]) -> String {
        list.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
    }

    static func stack(_ row: NetRow) -> String? {
        let stack = row.resource.initiator.stack
        guard !stack.isEmpty else { return nil }
        return stack.map { "\($0.function) @ \($0.url):\($0.line):\($0.column)" }.joined(separator: "\n")
    }

    // MARK: for an agent

    private static func secret(_ header: String) -> Bool {
        let name = header.lowercased()
        return name == "cookie" || name == "set-cookie" || name == "authorization" || name == "proxy-authorization"
            || name.contains("api-key") || name.contains("token") || name.contains("secret")
    }

    /// Copy for Agent: each request as Markdown, what went and what came,
    /// its timing and who asked for it, cookies, keys and tokens out.
    static func agent(_ rows: [NetRow], bodies: [Int: NetBody], page: URL?) -> String {
        var out = rows.count == 1 ? "" : "# \(rows.count) requests on \(DevCopy.where_(page))\n\n"
        for row in rows {
            let time = row.duration.map(NetFormat.time) ?? "pending"
            out += "## \(row.method) \(DevCopy.clean(row.url)) → \(row.statusLabel) \(row.statusText)".trimmingCharacters(in: .whitespaces) + " (\(time))\n"
            if rows.count == 1 { out += "Page: \(DevCopy.where_(page))\n" }
            out += "Type: \(row.typeLabel)"
            let initiator = row.initiatorLabel
            out += " · Initiator: \(initiator.place)\(initiator.kind.isEmpty ? "" : " (\(initiator.kind))")"
            if !row.resource.proto.isEmpty { out += " · \(row.resource.proto)" }
            out += "\n"
            if row.failed, !row.resource.failure.isEmpty { out += "Error: \(DevCopy.clean(row.resource.failure))\n" }
            if let phases = row.phases, phases.total > 0 {
                let parts = NetPhases.Phase.allCases.compactMap { phase -> String? in
                    let v = phases.value(phase)
                    return v >= 0.5 ? "\(phase.rawValue) \(NetFormat.time(v))" : nil
                }
                if !parts.isEmpty { out += "Timing: " + parts.joined(separator: ", ") + "\n" }
            }
            let sent = row.requestHeaders.filter { !$0.name.hasPrefix(":") }
            if !sent.isEmpty {
                out += "\nRequest headers:\n" + sent.map { "  \($0.name): \(secret($0.name) ? "[removed]" : DevCopy.clean($0.value))" }.joined(separator: "\n") + "\n"
            }
            if let body = row.hop == nil ? row.resource.postData : nil, !body.isEmpty { out += "\nSent:\n\(DevCopy.clean(body))\n" }
            let got = row.responseHeaders
            if !got.isEmpty {
                out += "\nResponse headers:\n" + got.map { "  \($0.name): \(secret($0.name) ? "[removed]" : DevCopy.clean($0.value))" }.joined(separator: "\n") + "\n"
            }
            if row.hop == nil {
                if let body = bodies[row.resource.id] {
                    if let error = body.error {
                        out += "\nResponse body unavailable: \(DevCopy.clean(error))\n"
                    } else {
                        out += body.base64 ? "\nGot (base64):\n\(body.text)\n" : "\nGot:\n\(DevCopy.clean(body.text))\n"
                    }
                } else {
                    out += row.pending ? "\nResponse body pending.\n" : "\nResponse body unavailable.\n"
                }
            }
            if row.hop == nil, !row.resource.initiator.stack.isEmpty {
                out += "\nStack:\n" + row.resource.initiator.stack.map { "  \($0.function) · \(DevCopy.clean($0.url)):\($0.line):\($0.column)" }.joined(separator: "\n") + "\n"
            }
            out += "\n"
        }
        return out.trimmingCharacters(in: .newlines) + "\n"
    }
}

// MARK: - HAR

enum NetHAR {
    /// HAR 1.2 of the rows, Chrome's fields with them. Sanitized leaves out
    /// Cookie, Set-Cookie and Authorization, and the streams' messages.
    static func archive(_ rows: [NetRow], bodies: [Int: NetBody], page: URL?, contentLoaded: Double?, loaded: Double?, sanitized: Bool) -> [String: Any] {
        let origin = rows.map(\.span.start).filter { $0 > 0 }.min() ?? 0
        let wallOrigin = rows.compactMap { row -> Double? in
            guard let wall = row.resource.wall, let sent = row.resource.sent else { return nil }
            return wall - (sent - origin)
        }.first ?? Date().timeIntervalSince1970
        func date(_ moment: Double) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: Date(timeIntervalSince1970: wallOrigin + (moment - origin)))
        }
        func kept(_ headers: [NetHeader]) -> [[String: Any]] {
            headers.filter { !(sanitized && ["cookie", "set-cookie", "authorization"].contains($0.name.lowercased())) }
                .map { ["name": $0.name, "value": $0.value] }
        }
        var entries: [[String: Any]] = []
        for row in rows {
            let r = row.resource
            let phases = row.phases ?? NetPhases()
            var request: [String: Any] = [
                "method": row.method, "url": row.url, "httpVersion": r.proto.isEmpty ? "HTTP/1.1" : r.proto,
                "headers": kept(row.requestHeaders),
                "queryString": (URLComponents(string: row.url)?.queryItems ?? []).map { ["name": $0.name, "value": $0.value ?? ""] },
                "cookies": sanitized ? [] : NetCookie.request(row).map { ["name": $0.name, "value": $0.value] },
                "headersSize": row.hop == nil && r.requestHeaderBytes > 0 ? r.requestHeaderBytes : -1,
                "bodySize": row.hop == nil ? (r.postData?.utf8.count ?? 0) : 0,
            ]
            if row.hop == nil, let body = r.postData {
                request["postData"] = ["mimeType": r.postType ?? row.requestHeaders.value("Content-Type") ?? "", "text": body]
            }
            var content: [String: Any] = ["size": row.size, "mimeType": r.mime]
            if row.hop == nil, let body = bodies[r.id], body.error == nil {
                content["text"] = body.text
                if body.base64 { content["encoding"] = "base64" }
            }
            let response: [String: Any] = [
                "status": row.status, "statusText": row.statusText, "httpVersion": r.proto.isEmpty ? "HTTP/1.1" : r.proto,
                "headers": kept(row.responseHeaders),
                "cookies": sanitized ? [] : NetCookie.response(row).cookies.map { ["name": $0.name, "value": $0.value, "path": $0.path, "domain": $0.domain, "httpOnly": $0.httpOnly, "secure": $0.secure] },
                "content": content,
                "redirectURL": row.responseHeaders.value("Location") ?? "",
                "headersSize": row.hop == nil && r.responseHeaderBytes > 0 ? r.responseHeaderBytes : -1,
                "bodySize": row.hop == nil ? r.responseBodyBytes : 0,
                "_transferSize": row.transferred,
            ]
            let span = row.span
            var entry: [String: Any] = [
                "startedDateTime": date(span.start),
                "time": row.duration ?? 0,
                "request": request,
                "response": response,
                "cache": [String: Any](),
                "timings": [
                    "blocked": phases.queueing + phases.stalled, "dns": phases.dns > 0 ? phases.dns : -1,
                    "connect": phases.initialConnection > 0 ? phases.initialConnection : -1, "ssl": phases.ssl > 0 ? phases.ssl : -1,
                    "send": phases.sending, "wait": phases.waiting, "receive": phases.download,
                ],
                "_initiator": ["type": r.initiator.kind.rawValue, "url": r.initiator.url, "lineNumber": r.initiator.line],
                "_priority": r.priority.capitalized,
                "_resourceType": r.type,
            ]
            if !r.remote.isEmpty { entry["serverIPAddress"] = r.remote.replacingOccurrences(of: #"^\[|\](:\d+)?$|:\d+$"#, with: "", options: .regularExpression) }
            if !r.connection.isEmpty { entry["connection"] = r.connection }
            if row.fromCache { entry["_fromCache"] = r.source == "memory-cache" ? "memory" : "disk" }
            if !r.frames.isEmpty {
                entry["_webSocketMessages"] = r.frames.map { ["type": $0.outgoing ? "send" : "receive", "time": $0.wall, "opcode": $0.opcode, "data": $0.data ?? ""] as [String: Any] }
            }
            if !r.events.isEmpty, !sanitized {
                entry["_eventSourceMessages"] = r.events.map { ["eventName": $0.type, "eventId": $0.id, "data": $0.data, "time": $0.wall] as [String: Any] }
            }
            entries.append(entry)
        }
        var pageTimings: [String: Any] = [:]
        if let at = contentLoaded { pageTimings["onContentLoad"] = (at - origin) * 1000 }
        if let at = loaded { pageTimings["onLoad"] = (at - origin) * 1000 }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return ["log": [
            "version": "1.2",
            "creator": ["name": Brand.name, "version": version],
            "pages": [["startedDateTime": date(origin), "id": "page_1", "title": page?.absoluteString ?? "", "pageTimings": pageTimings]],
            "entries": entries.map { var e = $0; e["pageref"] = "page_1"; return e },
        ] as [String: Any]]
    }

    static func data(_ archive: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: archive, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// A HAR file's entries as resources, to be listed as imported.
    static func resources(from data: Data) -> [NetResource]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let log = root["log"] as? [String: Any], let entries = log["entries"] as? [[String: Any]] else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var out: [NetResource] = []
        for (index, entry) in entries.enumerated() {
            guard let request = entry["request"] as? [String: Any], let response = entry["response"] as? [String: Any] else { continue }
            var r = NetResource(id: index + 1)
            r.imported = true
            r.url = request["url"] as? String ?? ""
            r.method = request["method"] as? String ?? "GET"
            r.status = (response["status"] as? NSNumber)?.intValue ?? 0
            r.statusText = response["statusText"] as? String ?? ""
            r.proto = response["httpVersion"] as? String ?? ""
            r.requestHeaders = (request["headers"] as? [[String: Any]] ?? []).compactMap { h in (h["name"] as? String).map { NetHeader(name: $0, value: h["value"] as? String ?? "") } }
            r.responseHeaders = (response["headers"] as? [[String: Any]] ?? []).compactMap { h in (h["name"] as? String).map { NetHeader(name: $0, value: h["value"] as? String ?? "") } }
            let content = response["content"] as? [String: Any] ?? [:]
            r.mime = content["mimeType"] as? String ?? ""
            r.size = (content["size"] as? NSNumber)?.intValue ?? 0
            r.transferred = (response["_transferSize"] as? NSNumber)?.intValue ?? (response["bodySize"] as? NSNumber)?.intValue ?? 0
            if let post = request["postData"] as? [String: Any] { r.postData = post["text"] as? String; r.postType = post["mimeType"] as? String }
            r.type = (entry["_resourceType"] as? String).map { $0 == "xhr" || $0 == "fetch" ? $0 : $0 } ?? "other"
            r.priority = (entry["_priority"] as? String ?? "").lowercased()
            r.remote = entry["serverIPAddress"] as? String ?? ""
            r.connection = entry["connection"] as? String ?? ""
            if let cache = entry["_fromCache"] as? String { r.source = cache == "memory" ? "memory-cache" : "disk-cache" } else { r.source = "network" }
            let started = (entry["startedDateTime"] as? String).flatMap { formatter.date(from: $0) ?? plain.date(from: $0) }?.timeIntervalSince1970 ?? 0
            let time = (entry["time"] as? NSNumber)?.doubleValue ?? 0
            let t = entry["timings"] as? [String: Any] ?? [:]
            func ms(_ key: String) -> Double { max(0, (t[key] as? NSNumber)?.doubleValue ?? 0) / 1000 }
            var at = started
            var timing = NetResource.Timing(start: started)
            at += ms("blocked"); timing.fetchStart = started
            if ms("dns") > 0 { timing.dnsStart = at; at += ms("dns"); timing.dnsEnd = at }
            if ms("connect") > 0 {
                timing.connectStart = at
                let ssl = ms("ssl")
                if ssl > 0 { timing.secureStart = at + ms("connect") - ssl }
                at += ms("connect"); timing.connectEnd = at
            }
            at += ms("send")
            timing.requestStart = at
            at += ms("wait"); timing.responseStart = at
            at += ms("receive"); timing.responseEnd = at
            r.timing = timing
            r.sent = started
            r.wall = started
            r.ended = started + time / 1000
            r.finished = r.status > 0
            r.failed = r.status == 0
            if let messages = entry["_webSocketMessages"] as? [[String: Any]] {
                r.frames = messages.map { NetResource.Frame(outgoing: ($0["type"] as? String) == "send", opcode: ($0["opcode"] as? NSNumber)?.intValue ?? 1,
                                                            data: $0["data"] as? String, length: ($0["data"] as? String)?.count ?? 0,
                                                            wall: ($0["time"] as? NSNumber)?.doubleValue ?? 0) }
            }
            if let messages = entry["_eventSourceMessages"] as? [[String: Any]] {
                r.events = messages.map { NetResource.Event(id: $0["eventId"] as? String ?? "", type: $0["eventName"] as? String ?? "message",
                                                            data: $0["data"] as? String ?? "", wall: ($0["time"] as? NSNumber)?.doubleValue ?? 0) }
            }
            if let initiator = entry["_initiator"] as? [String: Any] {
                r.initiator.kind = (initiator["type"] as? String).flatMap(NetResource.Initiator.Kind.init) ?? .other
                r.initiator.url = initiator["url"] as? String ?? ""
                r.initiator.line = (initiator["lineNumber"] as? NSNumber)?.intValue ?? 0
            }
            out.append(r)
        }
        return out
    }
}
