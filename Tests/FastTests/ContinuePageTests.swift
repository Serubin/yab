import Foundation
import Testing
@testable import SyncKit

/// Which pages Handoff offers to the other device, and what it takes back.
struct ContinuePageTests {
    private func url(_ text: String) -> URL { URL(string: text)! }

    @Test func aWebPageIsOfferedWithItsTitleAndSpace() {
        let page = ContinuePage.page(url: url("https://example.com/a?b=1"), title: "  Example  ", space: "SPACE-1")
        #expect(page == .init(url: url("https://example.com/a?b=1"), title: "Example", space: "SPACE-1"))
        #expect(page?.userInfo == ["space": "SPACE-1"])
    }

    @Test func aPageWithNoTitleIsNamedByItsHost() {
        #expect(ContinuePage.page(url: url("https://example.com/x"), title: " ", space: nil)?.title == "example.com")
        #expect(ContinuePage.page(url: url("https://example.com/x"), title: "t", space: " ")?.space == nil)
    }

    @Test func aLongTitleIsCut() {
        let title = String(repeating: "a", count: 500)
        #expect(ContinuePage.page(url: url("https://example.com"), title: title, space: nil)?.title.count == 200)
    }

    @Test func onlyWebPagesAnotherDeviceCanReachAreOffered() {
        for text in ["about:blank", "file:///Users/me/a.html", "yab://settings", "javascript:alert(1)",
                     "chrome-extension://abc/page.html", "http://localhost:3000/", "http://127.0.0.1/",
                     "http://app.localhost/", "http://[::1]:8080/", "https://user:secret@example.com/"] {
            #expect(ContinuePage.page(url: url(text), title: "t", space: nil) == nil, "\(text)")
        }
        #expect(ContinuePage.page(url: nil, title: "t", space: nil) == nil)
        #expect(ContinuePage.page(url: url("http://192.168.1.5/"), title: "t", space: nil) != nil)
    }

    @Test func aPageThatArrivesIsReadBackWithItsSpace() {
        let arrival = ContinuePage.arrival(webpageURL: url("https://example.com/p"), userInfo: ["space": "S"])
        #expect(arrival == .init(url: url("https://example.com/p"), space: "S"))
        #expect(ContinuePage.arrival(webpageURL: url("https://example.com/p"), userInfo: nil)?.space == nil)
        #expect(ContinuePage.arrival(webpageURL: url("https://example.com/p"), userInfo: ["space": 5])?.space == nil)
    }

    @Test func whatArrivesIsTrustedNoFurtherThanAnyAddress() {
        for text in ["javascript:alert(1)", "file:///etc/passwd", "pane-boost://abc", "data:text/html,hi",
                     "https://user:pw@example.com/"] {
            #expect(ContinuePage.arrival(webpageURL: url(text), userInfo: nil) == nil, "\(text)")
        }
        #expect(ContinuePage.arrival(webpageURL: nil, userInfo: nil) == nil)
    }

    @Test func oneAddressInAnotherFormIsOnePage() {
        #expect(ContinuePage.same(url("https://www.Example.com/a/"), url("http://example.com/a")))
        #expect(ContinuePage.same(url("https://example.com/a#top"), url("https://example.com/a")))
        #expect(ContinuePage.same(url("https://example.com"), url("https://example.com/")))
        #expect(!ContinuePage.same(url("https://example.com/a?v=1"), url("https://example.com/a?v=2")))
        #expect(!ContinuePage.same(url("https://example.com/a"), url("https://example.com/b")))
        #expect(!ContinuePage.same(url("https://example.com:8443/a"), url("https://example.com/a")))
    }

    @Test func aSpaceIsTheSameInEitherCase() {
        #expect(ContinuePage.sameSpace("0a1b", "0A1B"))
        #expect(!ContinuePage.sameSpace("0a1b", "0a1c"))
    }
}
