import Foundation
import Testing
@testable import Fast
@testable import MailCore

// What Yab asks Google for (docs/mail.md, OAuth): exactly the three scopes
// in its console, and the warning before Google's page only while the
// review lasts.
struct MailAccountTests {
    func scopes() -> [String] {
        let url = MailClient(id: "id.apps.googleusercontent.com", secret: "")
            .consent(redirect: "http://127.0.0.1:5000/oauth", challenge: "c", state: "s", hint: "me@example.com")
        let scope = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "scope" }?.value ?? ""
        return scope.split(separator: " ").map(String.init)
    }

    /// A new scope is a new review by Google: this fails until someone
    /// decides it on purpose and changes it here too.
    @Test func scopesStayTheSame() {
        #expect(scopes() == ["https://www.googleapis.com/auth/gmail.modify", "https://www.googleapis.com/auth/calendar.events.readonly",
                             "https://www.googleapis.com/auth/calendar.calendarlist.readonly"])
        #expect(MailClient.scopes == scopes().joined(separator: " "))
        #expect(MailClient.shipsCalendarList)
    }

    /// Google refuses its sign-in in a web view Yab draws ("This browser or
    /// app may not be secure", #456): a person's Connect opens the Mac's own
    /// sign-in sheet, an agent's another browser, never a Yab tab or peek.
    /// The page is Google's with PKCE and the loopback redirect the Desktop
    /// client is registered for.
    @MainActor @Test func googleSignInIsNeverAYabTab() {
        let google = MailClient(id: "id.apps.googleusercontent.com", secret: "")
        #expect(OAuthPresenter.choose(for: google, outside: false) == .systemSheet)
        #expect(OAuthPresenter.choose(for: google, outside: true) == .otherBrowser)
        #expect(OAuthPresenter.choose(for: OutlookClient(id: "o"), outside: false) == .tab)
        let page = google.consent(redirect: "http://127.0.0.1:5000/oauth", challenge: "c", state: "s", hint: nil)
        let shown = MailCenter.described(page, presenter: .systemSheet)
        #expect(shown == ["presenter": "systemSheet", "host": "accounts.google.com", "path": "/o/oauth2/v2/auth",
                          "client_id": "present", "redirect": "http://127.0.0.1/oauth", "pkce": "S256"])
        #expect(!GoogleSignInSheet.callbackScheme.hasPrefix("http"))
    }

    /// Once on, the list is asked with the rest, and a grant says whether
    /// it came (Google's page lets each be left out).
    @Test func calendarListIsAskedOnlyWhenOn() {
        #expect(MailClient.scopes(listing: true).hasSuffix(" https://www.googleapis.com/auth/calendar.calendarlist.readonly"))
        #expect(!MailClient.scopes(listing: false).contains("calendarlist"))
        #expect(MailGrant(refresh: "r", access: "a", scopes: MailClient.scopes(listing: true)).calendarList)
        #expect(!MailGrant(refresh: "r", access: "a", scopes: MailClient.scopes(listing: false)).calendarList)
    }

    @Test func underReviewShowsTheWarning() throws {
        let question = try #require(MailClient.warning(underReview: true, place: .settings))
        #expect(question.title == "Google will warn you first")
        #expect(question.lines == ["Press Advanced", "Then Go to Pane (unsafe)"])
        #expect(question.yes == "Continue to Google")
        #expect(question.place == .settings)
        // Approved: no warning, Connect goes straight to Google.
        #expect(MailClient.warning(underReview: false) == nil)
        // And the flag as it ships says which it is.
        #expect((MailClient.warning() != nil) == MailClient.underReview)
    }
}

/// Google's revoke as a test has it: off the network, taking a token back,
/// failing, or no longer knowing the token.
final class RevokeStandIn: URLProtocol {
    enum Answer { case offline, ok, failing, unknown }
    nonisolated(unsafe) static var answer = Answer.offline
    nonisolated(unsafe) static var bodies: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "oauth2.googleapis.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.bodies.append(String(decoding: request.bodyData ?? Data(), as: UTF8.self))
        let (status, body): (Int, String)
        switch Self.answer {
        case .offline:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        case .ok: (status, body) = (200, "")
        case .failing: (status, body) = (503, "{\"error\": \"backend_error\"}")
        case .unknown: (status, body) = (400, "{\"error\": \"invalid_token\", \"error_description\": \"Token expired or revoked\"}")
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Disconnect takes the account's token back at Google; offline, it is
/// kept and asked again at later launches until Google hears it.
@MainActor
@Suite(.serialized)
struct MailRevokeTests {
    @Test func aRevokeOfflineIsAskedAgainUntilGoogleHearsIt() async {
        let settings = UserDefaults(suiteName: "mail-revoke-\(UUID().uuidString)")!
        final class Kept { var items: [String: String] = [:] }
        let kept = Kept()
        let keep = MailRevoke.Keep(save: { token, item in kept.items[item] = token; return true }, token: { kept.items[$0] },
                                   forget: { kept.items[$0] = nil })
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RevokeStandIn.self]
        let session = URLSession(configuration: config)
        RevokeStandIn.bodies = []

        // Offline at Disconnect: kept, and still kept at a later launch offline.
        RevokeStandIn.answer = .offline
        await MailRevoke.revoke("1//refresh-a", settings: settings, keep: keep, session: session)
        #expect(Array(kept.items.values) == ["1//refresh-a"] && settings.stringArray(forKey: MailRevoke.key)?.count == 1)
        await MailRevoke.retry(settings: settings, keep: keep, session: session)
        #expect(kept.items.count == 1)
        // Google failing: kept too.
        RevokeStandIn.answer = .failing
        await MailRevoke.retry(settings: settings, keep: keep, session: session)
        #expect(kept.items.count == 1)
        // Back online: taken back, let go, from the keychain too.
        RevokeStandIn.answer = .ok
        await MailRevoke.retry(settings: settings, keep: keep, session: session)
        #expect(kept.items.isEmpty && settings.stringArray(forKey: MailRevoke.key) == [])
        #expect(RevokeStandIn.bodies.last == "token=1%2F%2Frefresh-a")
        // One Google no longer knows (it ran out while the Mac was away): let go as well.
        RevokeStandIn.answer = .offline
        await MailRevoke.revoke("1//refresh-b", settings: settings, keep: keep, session: session)
        RevokeStandIn.answer = .unknown
        await MailRevoke.retry(settings: settings, keep: keep, session: session)
        #expect(kept.items.isEmpty && settings.stringArray(forKey: MailRevoke.key) == [])
        let asked = RevokeStandIn.bodies.count
        // Nothing left: nothing asked.
        await MailRevoke.retry(settings: settings, keep: keep, session: session)
        #expect(RevokeStandIn.bodies.count == asked)
    }
}
