import Foundation
import CryptoKit
import SQLite3
import SwiftUI

/// Aside's Markdown knowledge and completed conversations are portable.
/// Account credentials, model settings and automation permissions are not
/// imported. Conversations are archived, with no resumable external id.
enum AsideImport {
    static let bundle = "at.studio.AsideBrowser"
    static var users: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aside/u") }

    struct Note {
        let path: String
        let text: String
    }

    struct Found {
        var notes: [Note] = []
        var chats: [Chat] = []
        var skipped = 0
        var errors: [String] = []
    }

    static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func read(in root: URL = users) -> Found {
        let fm = FileManager.default
        let accounts = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? [])
            .filter { safe($0, directory: true) }.sorted { $0.path < $1.path }
        var found = Found()
        for account in accounts {
            let owner = fingerprint(account.lastPathComponent)
            let memory = account.appendingPathComponent("memory")
            let files = safe(memory, directory: true) ? fm.enumerator(at: memory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) : nil
            while let file = files?.nextObject() as? URL {
                let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
                if values?.isSymbolicLink == true { files?.skipDescendants(); continue }
                guard file.pathExtension.lowercased() == "md", values?.isRegularFile == true else { continue }
                guard (values?.fileSize ?? Int.max) <= Memory.fileLimit,
                      let text = try? String(contentsOf: file, encoding: .utf8), !text.isEmpty else {
                    found.skipped += 1
                    continue
                }
                let relative = String(file.path.dropFirst(memory.path.count + 1))
                let kind = relative.split(separator: "/").first.map(String.init) ?? "concepts"
                let destination = Memory.kinds.contains(kind) ? kind : relative == "USER.md" ? "users" : "agent"
                let slug = "aside-\(owner)-\(fingerprint(relative))"
                found.notes.append(Note(path: "\(destination)/\(slug).md", text: text))
            }
            let db = account.appendingPathComponent("state.db")
            if safe(db, directory: false) {
                do { found.chats += try conversations(in: db, owner: owner) }
                catch { found.skipped += 1; found.errors.append(error.localizedDescription) }
                found.notes += (try? routines(in: db, owner: owner)) ?? []
            }
        }
        return found
    }

    private static func safe(_ file: URL, directory: Bool) -> Bool {
        guard let values = try? file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]),
              values.isSymbolicLink != true else { return false }
        return directory ? values.isDirectory == true : values.isRegularFile == true
    }

    /// Imported notes have names of their own. Existing Yab briefs and
    /// edited notes stay intact; changed source text gets another version.
    static func take(_ notes: [Note], into folder: URL = Memory.folder) -> (added: Int, skipped: Int) {
        let fm = FileManager.default
        let existing = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
        var total = 0
        for case let file as URL in existing?.allObjects ?? [] where file.pathExtension == "md" {
            total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        var added = 0, skipped = 0
        for note in notes {
            let parts = note.path.split(separator: "/")
            guard parts.count == 2, Memory.kinds.contains(String(parts[0])),
                  parts[1].hasPrefix("aside-"), !note.path.contains(".."), !note.text.isEmpty else { skipped += 1; continue }
            var file = folder.appendingPathComponent(note.path)
            if fm.fileExists(atPath: file.path) {
                if (try? String(contentsOf: file, encoding: .utf8)) == note.text { continue }
                file = file.deletingPathExtension().appendingPathExtension(fingerprint(note.text) + ".md")
                if (try? String(contentsOf: file, encoding: .utf8)) == note.text { continue }
            }
            let size = note.text.utf8.count
            guard size <= Memory.fileLimit, total + size <= Memory.totalLimit,
                  !fm.fileExists(atPath: file.path) else { skipped += 1; continue }
            do {
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(note.text.utf8).write(to: file, options: .withoutOverwriting)
                total += size
                added += 1
            } catch { skipped += 1 }
        }
        return (added, skipped)
    }

    /// The snapshot can retain WAL mode. Its private handle must be able
    /// to create the temporary journal; the source itself stays read-only.
    static func conversations(in file: URL, owner: String) throws -> [Chat] {
        let copy = try Chromium.copyWithLog(file)
        defer { Chromium.removeWithLog(copy) }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle else {
            let error = Chromium.sqliteFailure(handle, at: "Aside snapshot open")
            if let handle { sqlite3_close(handle) }
            throw error
        }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT s.id, s.title, s.created_at, s.updated_at, t.id,
               t.user_message, t.final_assistant_message, t.started_at, t.finished_at
        FROM sessions s JOIN session_turns t ON t.session_id = s.id
        WHERE COALESCE(s.incognito, 0) = 0 AND COALESCE(s.ephemeral, 0) = 0
        ORDER BY s.created_at, s.id, t.id
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Chromium.sqliteFailure(db, at: "Aside conversations query")
        }
        defer { sqlite3_finalize(statement) }
        func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
        func date(_ column: Int32) -> Date { Date(timeIntervalSince1970: sqlite3_column_double(statement, column)) }
        var chats: [String: Chat] = [:], order: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let original = text(0), id = "aside-\(owner)-\(fingerprint(original))"
            let asked = message(text(5)), answer = message(text(6))
            guard !asked.isEmpty || !answer.isEmpty else { continue }
            if chats[id] == nil {
                order.append(id)
                chats[id] = Chat(id: id, title: text(1).isEmpty ? Chat.title(from: asked) : text(1), began: .other,
                                 cli: "aside", items: [], archived: true, state: "done", answer: "", started: date(2), updated: date(3))
            }
            let turn = text(4)
            if !asked.isEmpty { chats[id]?.items.append(ChatItem(id: id + "-\(turn)-asked", kind: .asked, text: asked, state: .done, began: date(7))) }
            if !answer.isEmpty {
                chats[id]?.items.append(ChatItem(id: id + "-\(turn)-answer", kind: .message, text: answer, state: .done, ended: date(8)))
                chats[id]?.answer = answer
            }
        }
        return order.compactMap { chats[$0] }
    }

    /// Keep automation definitions as readable notes. Aside's event
    /// triggers and time zones do not map exactly to Yab's scheduler.
    static func routines(in file: URL, owner: String) throws -> [Note] {
        let copy = try Chromium.copyWithLog(file)
        defer { Chromium.removeWithLog(copy) }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close(handle) }
            throw Chromium.Trouble.unreadable
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = "SELECT id, name, prompt, rrule, timezone, state, trigger_kind FROM routines WHERE deleted_at IS NULL ORDER BY id"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
        var notes: [Note] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let name = text(1), prompt = text(2)
            guard !prompt.isEmpty else { continue }
            let body = "# Aside routine: \(name.isEmpty ? "Untitled" : name)\n\nImported for reference. This routine is not scheduled in \(Brand.name).\n\n"
                + "Schedule: \(text(3))\nTime zone: \(text(4))\nSource state: \(text(5))\nTrigger: \(text(6))\n\n## Task\n\n\(prompt)\n"
            notes.append(Note(path: "agent/aside-\(owner)-routine-\(fingerprint(text(0))).md", text: body))
        }
        return notes
    }

    /// Aside persists arrays of role/content messages. Only human and
    /// assistant text is carried into the transcript, never tool state.
    static func message(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) else { return raw }
        func words(_ value: Any) -> String {
            if let text = value as? String { return text }
            if let array = value as? [Any] { return array.map(words).filter { !$0.isEmpty }.joined(separator: "\n\n") }
            guard let object = value as? [String: Any] else { return "" }
            if let role = object["role"] as? String, role != "user" && role != "assistant" { return "" }
            if let content = object["content"] { return words(content) }
            return object["type"] as? String == "text" ? object["text"] as? String ?? "" : ""
        }
        return words(value)
    }

    @MainActor static func keep(_ chats: [Chat]) -> Int {
        var added = 0
        for chat in chats where Chats.shared.chat(chat.id) == nil {
            // A shelf that is still loading must not overwrite a chat the
            // user has already imported and edited on disk.
            guard !FileManager.default.fileExists(atPath: Chats.folder.appendingPathComponent(chat.id + ".json").path) else { continue }
            Chats.shared.keep(chat)
            added += 1
        }
        return added
    }
}

/// The same transfer is available after onboarding, in Bring In and Memory.
struct AsideBringer: View {
    @State private var found: AsideImport.Found?
    @State private var busy = false
    @State private var said: String?

    var body: some View {
        Group {
            if let found, !found.notes.isEmpty || !found.chats.isEmpty {
                SettingsRow("Aside memory and chats", detail: said ?? "\(found.notes.count) memory notes and \(found.chats.count) chats to archive.") {
                    if busy { ProgressView().controlSize(.small) }
                    else { Button("Bring In", action: bring).settingsButton() }
                }
                .settingsAnchor("bring-aside")
            }
        }
        .task {
            guard found == nil else { return }
            let result = await Task.detached(priority: .utility) { AsideImport.read() }.value
            found = result
        }
    }

    private func bring() {
        guard !busy else { return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = AsideImport.read()
            let notes = AsideImport.take(found.notes)
            DispatchQueue.main.async {
                let chats = AsideImport.keep(found.chats)
                MemoryShelf.shared.reload()
                var text = "\(notes.added) new memory notes, \(chats) archived chats"
                let skipped = notes.skipped + found.skipped
                if skipped > 0 { text += "; \(skipped) items couldn't be imported" }
                said = text
                busy = false
            }
        }
    }
}
