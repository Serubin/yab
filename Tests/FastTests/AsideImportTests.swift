import Foundation
import SQLite3
import Testing
@testable import Fast

struct AsideImportTests {
    @Test func memoryImportPreservesExistingNotesIsRepeatableAndSkipsSymlinks() throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        try fixture.write("users/account/memory/USER.md", Data("# Imported user\n\nLikes concise answers.\n".utf8))
        try fixture.write("users/account/memory/projects/project.md", Data("# Project\n\nA project note.\n".utf8))
        try fixture.write("users/account/credentials.json", Data("must never import this".utf8))
        try fixture.write("secret.md", Data("not memory".utf8))
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("users/account/memory/outside.md"), withDestinationURL: fixture.root.appendingPathComponent("secret.md"))
        let folder = fixture.root.appendingPathComponent("target")
        try fixture.write("target/USER.md", Data("Existing Yab user".utf8))
        let found = AsideImport.read(in: fixture.root.appendingPathComponent("users"))
        #expect(found.notes.count == 2)
        #expect(found.notes.allSatisfy { $0.path.hasPrefix("users/aside-") || $0.path.hasPrefix("projects/aside-") })
        #expect(AsideImport.take(found.notes, into: folder).added == 2)
        #expect(AsideImport.take(found.notes, into: folder).added == 0)
        #expect(try String(contentsOf: folder.appendingPathComponent("USER.md"), encoding: .utf8) == "Existing Yab user")
        let note = try #require(found.notes.first)
        try Data("Edited in Yab".utf8).write(to: folder.appendingPathComponent(note.path))
        #expect(AsideImport.take([note], into: folder).added == 1)
        #expect(AsideImport.take([note], into: folder).added == 0)
        #expect(try String(contentsOf: folder.appendingPathComponent(note.path), encoding: .utf8) == "Edited in Yab")
    }

    @Test func sizeAndPathLimitsAreReportedWithoutTruncatingNotes() throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let folder = fixture.root.appendingPathComponent("target")
        let result = AsideImport.take([
            AsideImport.Note(path: "agent/aside-big.md", text: String(repeating: "a", count: Memory.fileLimit + 1)),
            AsideImport.Note(path: "../aside-escape.md", text: "escape"),
            AsideImport.Note(path: "agent/aside-valid.md", text: "small note"),
        ], into: folder)
        #expect(result.added == 1)
        #expect(result.skipped == 2)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("aside-escape.md").path))
    }

    @Test func savedTurnsBecomeArchivedChatsAndPrivateSessionsStayOut() throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let db = try fixture.database("account/state.db", """
        PRAGMA journal_mode=WAL;
        CREATE TABLE sessions(id TEXT,title TEXT,created_at INTEGER,updated_at INTEGER,incognito INTEGER,ephemeral INTEGER);
        CREATE TABLE session_turns(id INTEGER,session_id TEXT,user_message TEXT,final_assistant_message TEXT,started_at INTEGER,finished_at INTEGER);
        INSERT INTO sessions VALUES('visible','Research',1700000000,1700000200,0,0),('private','Private',1700000000,1700000200,1,0);
        INSERT INTO session_turns VALUES
        (1,'visible','[{"role":"user","content":"Find the docs"}]','[{"role":"assistant","content":[{"type":"text","text":"Found docs"},{"type":"thinking","text":"private reasoning"}]}]',1700000000,1700000100),
        (2,'visible','Another question','Another answer',1700000100,1700000200),
        (3,'private','Private question','Private answer',1700000000,1700000200);
        """)
        defer { sqlite3_close(db) }
        let chats = try AsideImport.conversations(in: fixture.root.appendingPathComponent("account/state.db"), owner: "fixture")
        let chat = try #require(chats.first)
        #expect(chats.count == 1)
        #expect(chat.archived == true && chat.thread == nil && chat.state == "done")
        #expect(chat.items.map(\.text) == ["Find the docs", "Found docs", "Another question", "Another answer"])
        #expect(chat.answer == "Another answer")
        #expect(chat.started.timeIntervalSince1970 == 1700000000)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try fixture.write("chats/\(chat.id).json", encoder.encode(chat))
        #expect(Chats.read(fixture.root.appendingPathComponent("chats")).first == chat)
    }

    @Test func conversationsAreReadEvenWhenNoMemoryFolderExists() throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let db = try fixture.database("users/account/state.db", """
        CREATE TABLE sessions(id TEXT,title TEXT,created_at INTEGER,updated_at INTEGER,incognito INTEGER,ephemeral INTEGER);
        CREATE TABLE session_turns(id INTEGER,session_id TEXT,user_message TEXT,final_assistant_message TEXT,started_at INTEGER,finished_at INTEGER);
        INSERT INTO sessions VALUES('one','One',1700000000,1700000000,0,0);
        INSERT INTO session_turns VALUES(1,'one','Question','Answer',1700000000,1700000000);
        """)
        defer { sqlite3_close(db) }
        #expect(AsideImport.read(in: fixture.root.appendingPathComponent("users")).chats.count == 1)
    }

    @Test func routineDefinitionsKeepTheirOriginalTimezoneAndAreReferenceNotes() throws {
        let fixture = ImportFixture()
        defer { fixture.remove() }
        let db = try fixture.database("state.db", """
        CREATE TABLE routines(id TEXT,name TEXT,prompt TEXT,rrule TEXT,timezone TEXT,state TEXT,trigger_kind TEXT,deleted_at INTEGER);
        INSERT INTO routines VALUES('one','Monthly report','Read monthly results','FREQ=MONTHLY;BYMONTHDAY=5','America/Los_Angeles','draft','schedule',NULL);
        INSERT INTO routines VALUES('deleted','Deleted','Ignore','FREQ=DAILY','UTC','active','schedule',1);
        """)
        defer { sqlite3_close(db) }
        let notes = try AsideImport.routines(in: fixture.root.appendingPathComponent("state.db"), owner: "fixture")
        #expect(notes.count == 1)
        #expect(notes[0].text.contains("FREQ=MONTHLY;BYMONTHDAY=5"))
        #expect(notes[0].text.contains("America/Los_Angeles"))
        #expect(notes[0].text.contains("not scheduled in Pane"))
    }
}
