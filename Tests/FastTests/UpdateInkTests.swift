import Foundation
import Testing
@testable import Fast

// What the update's note says in each phase, what its button says, and
// that the arrow finds the button whichever side of the note it is on.
struct UpdateInkTests {
    static let changelog = URL(string: "https://example.com/changelog")

    @Test func theNoteSaysWhatThereIsToDo() {
        let ready = UpdateInk.words(.ready(version: "1.2"), halloween: false)
        #expect(ready?.first == "Pane 1.2 is here!")
        #expect(ready?.second == "restart to update")
        #expect(ready?.aside == "not now")
        #expect(ready?.mark == .heart)

        let back = UpdateInk.words(.updated(version: "1.2", changelog: Self.changelog), halloween: false)
        #expect(back?.first == "you're on 1.2!")
        #expect(back?.second == "have a look")
        #expect(back?.aside == "got it")
        #expect(back?.mark == .tick)

        let plain = UpdateInk.words(.updated(version: "1.2", changelog: nil))
        #expect(plain?.second == "all fresh")
        #expect(plain?.aside == nil)
    }

    @Test func onHalloweenTheNoteWearsAPumpkin() throws {
        let ready = UpdateInk.words(.ready(version: "0.0.31"), halloween: true)
        #expect(ready?.mark == .pumpkin)
        #expect(ready?.second == "restart to update")
        let back = UpdateInk.words(.updated(version: "0.0.31", changelog: Self.changelog), halloween: true, dressed: false)
        #expect(back?.mark == .pumpkin)
        #expect(back?.second == "dress it up")
        // Once dressed, or once the page was opened from it, it doesn't ask again.
        let again = UpdateInk.words(.updated(version: "0.33.0", changelog: Self.changelog), halloween: true, dressed: true)
        #expect(again?.mark == .pumpkin)
        #expect(again?.second == "have a look")
        let sheet = UpdateInk.Sheet(words: try #require(ready), origin: CGPoint(x: 20, y: 20), button: CGRect(x: 300, y: 0, width: 60, height: 22))
        #expect(sheet.mark.count > 20)
    }

    @Test func theUpdateNoteReturnsToNormalOutsideOctober31() {
        for (month, day, festive) in [(10, 23, false), (10, 30, false), (10, 31, true), (11, 1, false)] {
            let date = HalloweenTests.day(month, day)
            let halloween = Halloween.isDay(at: date)
            let ready = UpdateInk.words(.ready(version: "0.37.2"), halloween: halloween)
            let updated = UpdateInk.words(.updated(version: "0.37.2", changelog: Self.changelog), halloween: halloween, dressed: false)
            #expect(ready?.mark == (festive ? .pumpkin : .heart))
            #expect(updated?.mark == (festive ? .pumpkin : .tick))
            #expect(updated?.second == (festive ? "dress it up" : "have a look"))
        }
    }

    @Test func nothingIsWrittenWhileItRestarts() {
        #expect(UpdateInk.words(.restarting(version: "1.2")) == nil)
        #expect(UpdateInk.words(.none) == nil)
    }

    @Test func theButtonOnlyChangesItsWords() {
        #expect(UpdateInk.button(.ready(version: "1.2")) == "Update")
        #expect(UpdateInk.button(.restarting(version: "1.2")) == "Restarting…")
        #expect(UpdateInk.button(.updated(version: "1.2", changelog: Self.changelog)) == "What's new ↗")
        #expect(UpdateInk.button(.updated(version: "1.2", changelog: nil)) == "Got it")
        #expect(UpdateInk.button(.none) == nil)
    }

    /// With the tabs on top the note is under the button: the arrow goes
    /// up into the loop from below.
    @Test func underTheStripTheArrowGoesUp() throws {
        let button = CGRect(x: 800, y: 8, width: 58, height: 24)
        let words = try #require(UpdateInk.words(.ready(version: "1.2")))
        let sheet = UpdateInk.Sheet(words: words, origin: UpdateInk.under(button), button: button)
        let tip = try #require(sheet.arrow.first?.last)
        #expect(tip.y > button.maxY)
        #expect(tip.x > button.minX && tip.x < button.maxX)
        #expect(sheet.second.maxX < tip.x)
    }

    /// In the column the note is over the button: the arrow comes down.
    @Test func inTheColumnTheArrowComesDown() throws {
        let button = CGRect(x: 138, y: 86, width: 60, height: 28)
        let words = try #require(UpdateInk.words(.ready(version: "1.2")))
        let sheet = UpdateInk.Sheet(words: words, origin: CGPoint(x: 14, y: 0), button: button, place: .side)
        let tip = try #require(sheet.arrow.first?.last)
        #expect(tip.y < UpdateInk.loop(button).minY)
        #expect(tip.x > button.minX && tip.x < button.maxX)
        // The second line starts a little in; the loop stays inside a
        // 208 point column whose foot ends 10 from its edge.
        #expect(sheet.second.minX == 14 + UpdateInk.indent)
        #expect(sheet.loop.allSatisfy { $0.x < 208 - 3 && $0.x > 0 })
    }

    @Test func theNoteNeverStartsOffThePage() {
        #expect(UpdateInk.under(CGRect(x: 40, y: 8, width: 58, height: 24)).x == 16)
    }
}
