import Foundation
import Testing
@testable import Fast
@testable import MailCore

// A list row's words before its time (docs/mail.md, The mail space): the
// day a mail names ("by Fri", "2d late"), an invitation's next meeting
// ("Fri 2:00 PM"), the stretches of time a long list is headed by, and the
// foot pill saying what the keys do to the rows picked.
struct MailRowWordsTests {
    private let calendar = Calendar.current
    private func day(_ offset: Int, hour: Int = 10, from now: Date) -> Date {
        let start = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .hour, value: hour, to: calendar.date(byAdding: .day, value: offset, to: start)!)!
    }

    @Test func aDueDayIsSaidInWordsAndLateInOrange() {
        let now = day(0, hour: 12, from: Date())
        #expect(MailDesk.dueWords(day(0, from: now), now: now) == ("due today", false))
        #expect(MailDesk.dueWords(day(1, from: now), now: now) == ("by tomorrow", false))
        #expect(MailDesk.dueWords(day(-2, from: now), now: now) == ("2d late", true))
        let soon = MailDesk.dueWords(day(4, from: now), now: now)
        #expect(soon.words.hasPrefix("by ") && !soon.late)
        let far = MailDesk.dueWords(day(20, from: now), now: now)
        #expect(far.words.hasPrefix("by ") && far.words.count > 5)
    }

    @Test func aRowWithADueDaySaysItBeforeItsTime() {
        let now = day(0, hour: 12, from: Date())
        let row = MailDesk.Row(account: "a", thread: "t", who: "Mark", whoFull: "Mark Chen", subject: "Deck", line: "By Friday?",
                               at: now, unread: true, count: 1, when: "", snoozed: false, scheduled: nil)
        #expect(row.due(nil).soon.isEmpty)
        #expect(row.due(day(-1, from: now), now: now).soon == "1d late")
        #expect(row.due(day(-1, from: now), now: now).soonLate)
    }

    @Test func aMeetingIsSaidByItsDayAndTime() {
        let now = day(0, hour: 8, from: Date())
        #expect(MailDesk.meetWords(day(0, hour: 14, from: now), allDay: false, now: now).hasPrefix("Today "))
        #expect(MailDesk.meetWords(day(1, hour: 9, from: now), allDay: false, now: now).hasPrefix("Tomorrow "))
        #expect(MailDesk.meetWords(day(1, hour: 0, from: now), allDay: true, now: now) == "Tomorrow")
        #expect(MailDesk.meetWords(day(12, hour: 14, from: now), allDay: false, now: now).contains(", "))
    }

    @Test func aThreadsInvitationMeetsUntilItIsOverOrCalledOff() {
        let store = MailStore(file: MailStore.memory)
        let ics = MailInviteTests.google
        store.keepInvite(message: "m1", thread: "t1", at: Date(timeIntervalSince1970: 1_790_000_000), ics: ics)
        store.keepInvite(message: "m2", thread: "t2", at: Date(timeIntervalSince1970: 1_790_000_000),
                         ics: ics.replacingOccurrences(of: "METHOD:REQUEST", with: "METHOD:CANCEL").replacingOccurrences(of: "7kukuq", with: "other"))
        let before = ISO8601DateFormatter().date(from: "2026-10-05T09:00:00Z")!
        let after = ISO8601DateFormatter().date(from: "2026-10-07T09:00:00Z")!
        let meets = store.meets(among: ["t1", "t2", "t3"], now: before)
        #expect(Set(meets.keys) == ["t1"])
        #expect(meets["t1"]?.start == ISO8601DateFormatter().date(from: "2026-10-06T12:00:00Z"))
        #expect(store.meets(among: ["t1"], now: after).isEmpty)
    }

    @Test func aLongListIsHeadedByStretchesOfTime() {
        let now = day(0, hour: 18, from: Date())
        #expect(MailListView.when(day(0, hour: 9, from: now), now: now) == "Today")
        #expect(MailListView.when(day(-1, from: now), now: now) == "Yesterday")
        #expect(MailListView.when(day(-3, from: now), now: now) == "This Week")
        let old = MailListView.when(day(-80, from: now), now: now)
        #expect(!["Today", "Yesterday", "This Week", "Earlier This Month"].contains(old))
        #expect(MailListView.grouping("other") == "when")
        #expect(MailListView.grouping("sent") == "when")
        #expect(MailListView.grouping("needs") == nil)
        #expect(MailListView.grouping("waiting") == nil)
    }

    @Test func headingsCountTheirRowsOnce() {
        let now = day(0, hour: 18, from: Date())
        let rows = [day(0, hour: 9, from: now), day(0, hour: 8, from: now), day(-1, from: now)].enumerated().map { n, at in
            MailDesk.Row(account: "a", thread: "t\(n)", who: "W", whoFull: "W", subject: "S", line: "", at: at,
                         unread: false, count: 1, when: "", snoozed: false, scheduled: nil)
        }
        #expect(MailListView.heading(rows, at: 0, by: "when", now: now) == "Today · 2")
        #expect(MailListView.heading(rows, at: 1, by: "when", now: now) == nil)
        #expect(MailListView.heading(rows, at: 2, by: "when", now: now) == "Yesterday · 1")
    }
}
