import Foundation
import Testing
@testable import Fast
@testable import MailCore
import MailCoreFakes

// Upstream Yab's read-status pictures in mail that comes here: stripped
// before showing, so reading it never reports an open.
struct MailReadsTests {
    @Test func upstreamPictureNeverLoadsHere() {
        let token = "vkXLJgW_Nr695oSEGijw_Q"
        let ours = "<img src=\"https://yetanotherbrowser.com/o/\(token).gif\" width=\"1\" height=\"1\" alt=\"\" style=\"border:0;width:1px;height:1px\">"
        let picture = "<img src=\"https://fold.studio/deck.png\" width=\"600\" alt=\"Deck\">"
        // Upstream's picture goes, a real one stays.
        #expect(MailReads.strip("<div>Numbers.</div>" + picture + ours) == "<div>Numbers.</div>" + picture)
        // A reply quoting it, as Gmail's proxy writes the address; another site's /o/ stays.
        let proxied = "<img src=\"https://ci3.googleusercontent.com/meips/ADKq_Nb=s0-d-e1-ft#https://yetanotherbrowser.com/o/\(token).gif\" width=\"1\">"
        let elsewhere = "<img src=\"https://cdn.example.com/o/\(token).gif\">"
        #expect(MailReads.strip("<blockquote>Hi" + proxied + "</blockquote>" + elsewhere) == "<blockquote>Hi</blockquote>" + elsewhere)
        // Shown in a thread, whatever Block tracking pixels says (on here): never there.
        #expect(!MailHTML.clean("<p>Hi</p>" + ours).contains(token))
    }

    @Test func sentMailCarriesNoPictureEvenWithUpstreamsSettingOn() async throws {
        let (store, gmail, fake) = world()
        store.set("reads", "on")
        let anna = MailPerson(name: "Anna Lindqvist", address: "anna@fold.studio")
        try await send(MailDraft(id: "new:1", to: [anna], subject: "On", body: "Plain words."), store: store, gmail: gmail)
        let raw = try #require(fake.sent.last)
        #expect(!raw.contains("yetanotherbrowser.com"))
        let tree = try #require(MIMETree(raw))
        #expect(tree.type == "text/plain" && tree.text == "Plain words.")
    }

    // MARK: - worlds

    /// A store and a Gmail of its own, on a host no other suite asks.
    func world() -> (MailStore, MailGmail, FakeGmail) {
        let fake = FakeGmail()
        let host = "reads-" + UUID().uuidString.prefix(8).lowercased()
        FakeGmail.serve(fake, at: host)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeGmailProtocol.self]
        let gmail = MailGmail(base: URL(string: "https://\(host)/gmail/v1/users/me/")!, session: URLSession(configuration: config),
                              token: { "token" }, tries: 3, wait: 0.01)
        let store = MailStore(file: MailStore.memory)
        store.set("me", "me@example.com")
        return (store, gmail, fake)
    }

    /// A message's HTML part, its base64 undone.
    func html(_ raw: String) throws -> String {
        let tree = try #require(MIMETree(raw))
        return try #require(tree.parts.first { $0.type == "text/html" }).text
    }

    /// A draft sent now, through the journal, as ⌘↩ sends it once its undo window is over.
    func send(_ draft: MailDraft, store: MailStore, gmail: MailGmail) async throws {
        var draft = draft
        if draft.messageID.isEmpty { draft.messageID = MailCompose.messageID(from: "me@example.com") }
        store.save(draft)
        MailOps.act(.send, thread: draft.id, in: store)
        try await MailOps.flush(store, gmail: gmail)
    }
}
