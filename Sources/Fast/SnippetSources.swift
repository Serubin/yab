import AppKit
import Foundation
import SQLite3

// Snippets kept by another app, brought into Yab's (docs/snippets.md,
// "Bring In"). Text Replacements, Alfred and espanso keep theirs in files
// on this Mac and are read where they are; Raycast's own store is
// encrypted and TextExpander's is in its cloud, so theirs come from the
// file each one exports. Nothing here asks macOS for access: none of these
// places is behind a permission, and an exported file is the one chosen in
// an open panel.

/// Where a snippet was kept before.
enum SnippetSource: String, CaseIterable, Identifiable {
    case textReplacements, raycast, alfred, espanso, textExpander, superhuman

    var id: String { rawValue }

    var title: String {
        switch self {
        case .textReplacements: "Text Replacements"
        case .raycast: "Raycast"
        case .alfred: "Alfred"
        case .espanso: "espanso"
        case .textExpander: "TextExpander"
        case .superhuman: "Superhuman"
        }
    }

    /// Where on this Mac they are, said under the source's name.
    var place: String {
        switch self {
        case .textReplacements: "System Settings › Keyboard"
        case .raycast: "Raycast’s Export Snippets"
        case .alfred: "Alfred’s Snippets"
        case .espanso: "espanso’s match files"
        case .textExpander: "TextExpander’s exported group"
        case .superhuman: "Superhuman, read by Claude in \(Brand.name)"
        }
    }

    private var bundle: String? {
        switch self {
        case .textReplacements: nil
        case .raycast: "com.raycast.macos"
        case .alfred: "com.runningwithcrayons.Alfred"
        case .espanso: "com.federicoterzi.espanso"
        case .textExpander: "com.smileonmymac.textexpander"
        case .superhuman: "com.superhuman.electron"
        }
    }

    /// The app it belongs to, for its icon: System Settings for macOS's own.
    var app: URL? {
        if self == .textReplacements { return URL(fileURLWithPath: "/System/Applications/System Settings.app") }
        return bundle.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    /// Its app's icon at a menu row's size, or a document's when the app
    /// is not on this Mac.
    @MainActor func picture(_ side: CGFloat = 16) -> NSImage {
        // Superhuman is a site for most: its app's icon ships in Yab
        // (Resources/Sites), so the row looks the same without the app.
        let shipped = self == .superhuman
            ? Bundle.main.url(forResource: "superhuman.com", withExtension: "png", subdirectory: "Sites").flatMap(NSImage.init(contentsOf:))
            : nil
        let icon = app.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? shipped ?? NSWorkspace.shared.icon(for: .json)
        let image = icon.copy() as! NSImage
        image.size = NSSize(width: side, height: side)
        return image
    }

    /// Read where it keeps them on this Mac; nil for one that only an
    /// exported file brings.
    nonisolated func onThisMac(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [FoundSnippet]? {
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        switch self {
        case .textReplacements:
            return SnippetSource.textReplacements(db: home.appendingPathComponent("Library/KeyboardServices/TextReplacements.db"))
        case .alfred:
            return SnippetSource.alfredPreferences(support: support).map(SnippetSource.alfred(folder:))
        case .espanso:
            let match = support.appendingPathComponent("espanso/match", isDirectory: true)
            return FileManager.default.fileExists(atPath: match.path) ? SnippetSource.espanso(folder: match) : nil
        case .raycast, .textExpander, .superhuman:
            return nil
        }
    }

    /// The ones with snippets on this Mac now, and how many each has.
    nonisolated static func found(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [(source: SnippetSource, count: Int)] {
        allCases.compactMap { source in
            guard let found = source.onThisMac(home: home), !found.isEmpty else { return nil }
            return (source, found.count)
        }
    }

    /// A file another app exported, told apart by what is in it.
    nonisolated static func read(file url: URL) -> (source: SnippetSource, found: [FoundSnippet])? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let kind = url.pathExtension.lowercased()
        if kind == "yml" || kind == "yaml" {
            return String(data: data, encoding: .utf8).map { (.espanso, espanso(yaml: $0)) }
        }
        if kind == "csv" || kind == "txt" {
            return String(data: data, encoding: .utf8).map { (.textExpander, textExpander(csv: $0)) }
        }
        if let raycast = raycast(json: data) { return (.raycast, raycast) }
        if let one = alfred(json: data) { return (.alfred, [one]) }
        return nil
    }
}

/// A snippet found in another app, as it would come in.
struct FoundSnippet: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var body: String
    /// What changed on the way in, or what didn't come across.
    var note: String?
    /// The note says something didn't come across as it was.
    var odd = false
    /// Ticked to bring in.
    var take = true
    /// A mail snippet's own (Superhuman's): whom it is to and its subject.
    var to = ""
    var cc = ""
    var bcc = ""
    var subject = ""
}

// MARK: - names

extension SnippetSource {
    /// A name ";" takes in a page's box (snippets.js): letters, digits, _
    /// and -, up to 40. The keyword's marks in front go (";sig", ":sig",
    /// "!sig"); with nothing left, the first words of its title or words.
    nonisolated static func name(keyword: String?, else fallback: String) -> String {
        let kept: (String) -> String = { text in
            String(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }.map(Character.init))
        }
        if let keyword {
            let trimmed = keyword.drop { !$0.isLetter && !$0.isNumber }
            let name = kept(String(trimmed))
            if !name.isEmpty { return String(name.prefix(40)) }
        }
        let words = fallback.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(3)
            .joined(separator: "-")
        return words.isEmpty ? "snippet" : String(words.prefix(24))
    }
}

// MARK: - placeholders

extension SnippetSource {
    /// Raycast's and Alfred's placeholders as Yab's: the caret's place and
    /// an argument become a place to fill by hand, plain {clipboard} and
    /// {date} stay, and the rest ({selection}, {time}, a date with its own
    /// format) are left as written, which the note says.
    nonisolated static func placeholders(_ text: String) -> (body: String, note: String?, odd: Bool) {
        let mark = try! NSRegularExpression(pattern: "\\{([A-Za-z_]+)((?:[ :][^{}\\n]*)?)\\}")
        let whole = text as NSString
        var out = ""
        var at = 0
        var places: [String] = []
        var left: [String] = []
        for match in mark.matches(in: text, range: NSRange(location: 0, length: whole.length)) {
            out += whole.substring(with: NSRange(location: at, length: match.range.location - at))
            at = match.range.location + match.range.length
            let token = whole.substring(with: match.range)
            let name = whole.substring(with: match.range(at: 1)).lowercased()
            let rest = whole.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            switch name {
            case "cursor":
                out += "{{…}}"
                if !places.contains("{cursor}") { places.append("{cursor}") }
            case "argument":
                let named = rest.range(of: "name=\"([^\"]{1,80})\"", options: .regularExpression)
                    .map { String(rest[$0].dropFirst(6).dropLast()) }
                out += "{{" + (named ?? "…") + "}}"
                if !places.contains("{argument}") { places.append("{argument}") }
            case "clipboard":
                out += "{clipboard}"
            case "date" where rest.isEmpty:
                out += "{date}"
            case _ where MailSnippets.variables.contains(name) && rest.isEmpty:
                out += token
            default:
                out += token
                if !left.contains("{\(name)}") { left.append("{\(name)}") }
            }
        }
        out += whole.substring(from: at)
        if !left.isEmpty { return (out, left.joined(separator: ", ") + (left.count == 1 ? " stays as written" : " stay as written"), true) }
        if places.isEmpty { return (out, nil, false) }
        return (out, places.joined(separator: " and ") + (places.count == 1 ? " is a place to type over" : " are places to type over"), false)
    }
}

// MARK: - the readers

extension SnippetSource {
    /// macOS's Text Replacements, as System Settings keeps them: a copy
    /// of the database read, the deleted left out, oldest first.
    nonisolated static func textReplacements(db: URL) -> [FoundSnippet]? {
        guard FileManager.default.fileExists(atPath: db.path), let temp = try? Chromium.copyWithLog(db) else { return nil }
        defer { Chromium.removeWithLog(temp) }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(temp.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else { return nil }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        let sql = "SELECT ZSHORTCUT, ZPHRASE FROM ZTEXTREPLACEMENTENTRY WHERE IFNULL(ZWASDELETED, 0) = 0 ORDER BY ZTIMESTAMP"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        var found: [FoundSnippet] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let shortcut = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            let phrase = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            guard !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            found.append(FoundSnippet(name: name(keyword: shortcut, else: phrase), body: phrase))
        }
        return found
    }

    /// Raycast's Export Snippets: [{name, text, keyword, tags}].
    nonisolated static func raycast(json data: Data) -> [FoundSnippet]? {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              !rows.isEmpty, rows.allSatisfy({ $0["text"] is String }) else { return nil }
        return rows.compactMap { row in
            let text = row["text"] as? String ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let title = row["name"] as? String ?? ""
            let words = placeholders(text)
            return FoundSnippet(name: name(keyword: row["keyword"] as? String, else: title.isEmpty ? text : title),
                                body: words.body, note: words.note, odd: words.odd)
        }
    }

    /// One of Alfred's snippet files: {"alfredsnippet": {snippet, keyword, name}}.
    nonisolated static func alfred(json data: Data) -> FoundSnippet? {
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let one = top["alfredsnippet"] as? [String: Any],
              let text = one["snippet"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let title = one["name"] as? String ?? ""
        let words = placeholders(text)
        return FoundSnippet(name: name(keyword: one["keyword"] as? String, else: title.isEmpty ? text : title),
                            body: words.body, note: words.note, odd: words.odd)
    }

    /// Alfred's preferences: in Application Support, or the synced folder
    /// its prefs.json names.
    nonisolated static func alfredPreferences(support: URL) -> URL? {
        let alfred = support.appendingPathComponent("Alfred", isDirectory: true)
        if let data = try? Data(contentsOf: alfred.appendingPathComponent("prefs.json")),
           let prefs = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let current = prefs["current"] as? String, FileManager.default.fileExists(atPath: current) {
            return URL(fileURLWithPath: current, isDirectory: true)
        }
        let local = alfred.appendingPathComponent("Alfred.alfredpreferences", isDirectory: true)
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }

    /// Every collection under Alfred's snippets folder.
    nonisolated static func alfred(folder preferences: URL) -> [FoundSnippet] {
        let snippets = preferences.appendingPathComponent("snippets", isDirectory: true)
        guard let walk = FileManager.default.enumerator(at: snippets, includingPropertiesForKeys: nil) else { return [] }
        return walk.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "json" }
            .sorted { $0.path < $1.path }
            .compactMap { (try? Data(contentsOf: $0)).flatMap(alfred(json:)) }
    }

    /// Every match file of espanso's.
    nonisolated static func espanso(folder: URL) -> [FoundSnippet] {
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return walk.compactMap { $0 as? URL }
            .filter { ["yml", "yaml"].contains($0.pathExtension) }
            .sorted { $0.path < $1.path }
            .flatMap { url in (try? String(contentsOf: url, encoding: .utf8)).map(espanso(yaml:)) ?? [] }
    }

    /// espanso's matches: each `- trigger:` (or `triggers:`, the first)
    /// with its `replace:`, quoted, plain or a `|` block. `$|$` is the
    /// caret's place; a match with `vars` keeps its {{…}}, which Yab
    /// asks for by hand; forms and images are left out.
    nonisolated static func espanso(yaml: String) -> [FoundSnippet] {
        var found: [FoundSnippet] = []
        var item: [String: String] = [:]
        var keyIndent = -1
        var lines = yaml.components(separatedBy: .newlines)[...]

        func finish() {
            defer { item = [:] }
            guard let replace = item["replace"], !replace.isEmpty, item["form"] == nil else { return }
            let trigger = item["trigger"] ?? item["triggers"] ?? ""
            var body = replace.replacingOccurrences(of: "$|$", with: "{{…}}")
            var note: String? = body == replace ? nil : "$|$ is a place to type over"
            var odd = false
            if item["vars"] != nil, body.contains("{{") {
                body = body.replacingOccurrences(of: "{{clipboard}}", with: "{clipboard}")
                note = "Its variables are places to fill by hand"
                odd = true
            }
            found.append(FoundSnippet(name: name(keyword: trigger, else: replace), body: body, note: note, odd: odd))
        }

        // An item is "- key: value" and the keys under it at the same
        // indent as its first; a line further left ends it.
        while let line = lines.popFirst() {
            let indent = line.prefix { $0 == " " }.count
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text.hasPrefix("#") { continue }
            if text.hasPrefix("- "), keyIndent < 0 || indent < keyIndent, text.contains(": ") || text.hasSuffix(":") {
                finish()
                keyIndent = indent + 2
                text = String(text.dropFirst(2))
            } else if keyIndent >= 0, indent < keyIndent {
                finish()
                keyIndent = -1
                continue
            } else if indent != keyIndent {
                continue
            }
            guard keyIndent >= 0, let colon = text.firstIndex(of: ":") else { continue }
            let key = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if key == "triggers" {
                // [":a", ":b"] on its line, or "- :a" lines under it.
                if value.hasPrefix("[") {
                    value = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).components(separatedBy: ",").first ?? ""
                } else {
                    var first: String?
                    while let next = lines.first, next.prefix(while: { $0 == " " }).count >= keyIndent,
                          next.trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                        lines.removeFirst()
                        if first == nil { first = String(next.trimmingCharacters(in: .whitespaces).dropFirst(2)) }
                    }
                    value = first ?? ""
                }
                item[key] = unquoted(value.trimmingCharacters(in: .whitespaces))
            } else if value.hasPrefix("|") || value.hasPrefix(">") {
                // A block: the lines further in than its key, their
                // common indent taken off; "|" keeps the breaks, ">" folds.
                var block: [String] = []
                var inner: Int?
                while let next = lines.first {
                    let nextIndent = next.prefix { $0 == " " }.count
                    let blank = next.trimmingCharacters(in: .whitespaces).isEmpty
                    if !blank, nextIndent <= keyIndent { break }
                    lines.removeFirst()
                    if blank { block.append(""); continue }
                    let cut = inner ?? nextIndent
                    inner = cut
                    block.append(String(next.dropFirst(min(cut, nextIndent))))
                }
                while block.last == "" { block.removeLast() }
                item[key] = block.joined(separator: value.hasPrefix(">") ? " " : "\n")
            } else if key == "vars" || key == "form" || key == "image_path" {
                item[key] = value.isEmpty ? "yes" : value
            } else {
                item[key] = unquoted(value)
            }
        }
        finish()
        return found
    }

    /// A YAML scalar as written on one line: "…" with its escapes, '…'
    /// with '' for ', or bare.
    nonisolated static func unquoted(_ value: String) -> String {
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            var out = ""
            var escaped = false
            for c in value.dropFirst().dropLast() {
                if escaped {
                    switch c {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    default: out.append(c)
                    }
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else {
                    out.append(c)
                }
            }
            return out
        }
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return value
    }

    /// A TextExpander group exported as CSV: abbreviation, content, label.
    /// %clipboard and %| come across; its other fill-ins stay as written.
    nonisolated static func textExpander(csv: String) -> [FoundSnippet] {
        csvRows(csv).compactMap { row in
            guard row.count >= 2 else { return nil }
            let content = row[1]
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            var body = content.replacingOccurrences(of: "%clipboard", with: "{clipboard}")
                .replacingOccurrences(of: "%|", with: "{{…}}")
            let left = body.range(of: "%[a-zA-Z(\\[{]", options: .regularExpression) != nil
            body = body.replacingOccurrences(of: "%%", with: "%")
            let label = row.count > 2 ? row[2] : ""
            return FoundSnippet(name: name(keyword: row[0], else: label.isEmpty ? content : label), body: body,
                                note: left ? "Its fill-ins stay as written" : body.contains("{{…}}") ? "%| is a place to type over" : nil,
                                odd: left)
        }
    }

    /// Rows of a CSV file: quoted fields may hold commas, line breaks and
    /// "" for a quote.
    nonisolated static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = Array(text)[...]
        while let c = chars.popFirst() {
            if quoted {
                if c == "\"" {
                    if chars.first == "\"" { field.append("\""); chars.removeFirst() } else { quoted = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                quoted = true
            } else if c == "," {
                row.append(field)
                field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field)
                field = ""
                if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                row = []
            } else {
                field.append(c)
            }
        }
        row.append(field)
        if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        return rows
    }

    /// What an agent read from Superhuman's Settings › Snippets: a JSON
    /// array of {name, body, to, cc, bcc, subject}, found anywhere in its
    /// answer. Its variables as Yab's: {first_name} stays, a full name is
    /// {name}, the sender's own is {my_name}; the rest stay as written.
    nonisolated static func superhuman(answer: String) -> [FoundSnippet]? {
        guard let start = answer.firstIndex(of: "["), let end = answer.lastIndex(of: "]"), start < end,
              let rows = (try? JSONSerialization.jsonObject(with: Data(answer[start...end].utf8))) as? [[String: Any]] else { return nil }
        let same: [String: String] = ["first_name": "first_name", "full_name": "name", "name": "name",
                                      "my_first_name": "my_name", "my_name": "my_name", "my_full_name": "my_name"]
        let mark = try! NSRegularExpression(pattern: "\\{([A-Za-z_]+)\\}")
        return rows.compactMap { row in
            let text = (row["body"] as? String ?? "").replacingOccurrences(of: "\r\n", with: "\n")
            let field: (String) -> String = { (row[$0] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            let mailish = [field("to"), field("cc"), field("bcc"), field("subject")].contains { !$0.isEmpty }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || mailish else { return nil }
            let whole = text as NSString
            var body = ""
            var at = 0
            var left: [String] = []
            for match in mark.matches(in: text, range: NSRange(location: 0, length: whole.length)) {
                body += whole.substring(with: NSRange(location: at, length: match.range.location - at))
                at = match.range.location + match.range.length
                let name = whole.substring(with: match.range(at: 1)).lowercased()
                if let ours = same[name] {
                    body += "{" + ours + "}"
                } else {
                    body += whole.substring(with: match.range)
                    if !left.contains("{\(name)}") { left.append("{\(name)}") }
                }
            }
            body += whole.substring(from: at)
            let title = field("name")
            var one = FoundSnippet(name: name(keyword: nil, else: title.isEmpty ? text : title), body: body,
                                   note: left.isEmpty ? (!mailish ? nil : [field("to"), field("cc"), field("bcc")].contains { !$0.isEmpty }
                                                ? "In Mail only, with whom it is to" : "In Mail only, with its subject")
                                       : left.joined(separator: ", ") + (left.count == 1 ? " stays as written" : " stay as written"),
                                   odd: !left.isEmpty)
            one.to = field("to")
            one.cc = field("cc")
            one.bcc = field("bcc")
            one.subject = field("subject")
            return one
        }
    }
}
