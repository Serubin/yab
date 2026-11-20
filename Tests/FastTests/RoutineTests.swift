import Foundation
import Testing
@testable import Fast

// Routines as Settings says them, and the ones it suggests from the sites
// you use.
struct RoutineTests {
    static let us = Locale(identifier: "en_US")

    /// Said with the narrow spaces a Mac puts before AM, read as plain ones.
    static func say(_ when: String) -> String {
        Routines.say(when, locale: us).replacingOccurrences(of: "\u{202F}", with: " ")
    }

    @Test func whenInWords() {
        #expect(Self.say("weekdays 9:00") == "Weekdays at 9:00 AM")
        #expect(Self.say("daily 18:30") == "Every day at 6:30 PM")
        #expect(Self.say("weekends 10:00") == "Weekends at 10:00 AM")
        #expect(Self.say("mon 8:15") == "Mondays at 8:15 AM")
        #expect(Self.say("fri,mon,wed 8:00") == "Mondays, Wednesdays and Fridays at 8:00 AM")
        #expect(Self.say("sun,sat 9:00") == "Weekends at 9:00 AM")
        #expect(Routines.say("hourly") == "Every hour")
        #expect(Routines.say("every 2h") == "Every 2 hours")
        #expect(Routines.say("every 30m") == "Every 30 minutes")
        #expect(Routines.say("whenever") == "whenever")
        #expect(Routines.clock(21 * 60, locale: Locale(identifier: "en_GB")) == "21:00")
    }

    @Test func ideasFollowTheSitesYouUse() {
        let visits = ["github.com": 40, "www.github.com": 3, "mail.google.com": 12, "app.slack.com": 2, "acme.slack.com": 2, "linear.app": 4]
        // Most used first; a site under five visits isn't offered, and
        // Slack's are counted across its hosts.
        #expect(RoutineIdea.offered(visits: visits, set: [], declined: []).map(\.id) == ["github", "mail"])
        #expect(RoutineIdea.offered(visits: visits.merging(["x.slack.com": 1]) { $1 }, set: [], declined: []).map(\.id)
            == ["github", "mail", "slack"])
        // Put away, or already set up: not offered again.
        #expect(RoutineIdea.offered(visits: visits, set: [], declined: ["github"]).map(\.id) == ["mail"])
        let github = RoutineIdea.all.first { $0.id == "github" }!
        let set = Routine(id: "a", when: github.when, prompt: github.task.uppercased(), last: nil)
        #expect(RoutineIdea.offered(visits: visits, set: [set], declined: []).map(\.id) == ["mail"])
        // Three at most.
        let busy = Dictionary(uniqueKeysWithValues: RoutineIdea.all.compactMap(\.site).map { ($0, 9) })
        #expect(RoutineIdea.offered(visits: busy, set: [], declined: []).count == 3)
    }

    @Test func aNewYabGetsTheOneForAnyone() {
        #expect(RoutineIdea.offered(visits: [:], set: [], declined: []) == [RoutineIdea.anyone])
        #expect(RoutineIdea.offered(visits: ["example.com": 90], set: [], declined: []) == [RoutineIdea.anyone])
        // Not once there are routines, or once put away.
        let one = Routine(id: "a", when: "daily 9:00", prompt: "read the news", last: nil)
        #expect(RoutineIdea.offered(visits: [:], set: [one], declined: []).isEmpty)
        #expect(RoutineIdea.offered(visits: [:], set: [], declined: ["brief"]).isEmpty)
    }

    @Test func everyIdeaReads() {
        for idea in RoutineIdea.all + [RoutineIdea.anyone] {
            #expect(Routines.schedule(idea.when) != nil, "\(idea.id)")
            #expect(idea.title.count <= 44, "\(idea.id)")
        }
    }
}

// A task typed with its when, the editor's menus, and what a row says.
struct RoutineWordsTests {
    @Test func phrasesThatAreRoutines() {
        #expect(Routines.phrase("every weekday at 10 tell me which of these wait on my review")! == ("weekdays 10:00", "tell me which of these wait on my review"))
        #expect(Routines.phrase("Every morning, check my mail for anything urgent")! == ("daily 9:00", "check my mail for anything urgent"))
        #expect(Routines.phrase("every evening summarize what changed in Linear")! == ("daily 18:00", "summarize what changed in Linear"))
        #expect(Routines.phrase("on Fridays at 4pm: list what I shipped this week")! == ("fri 16:00", "list what I shipped this week"))
        #expect(Routines.phrase("every 2 hours check the deploys")! == ("every 2h", "check the deploys"))
        #expect(Routines.phrase("hourly check the status page")! == ("hourly", "check the status page"))
        #expect(Routines.phrase("daily at 8:30 find new jobs on Hacker News")! == ("daily 8:30", "find new jobs on Hacker News"))
        #expect(Routines.phrase("on weekdays at 10:30, what's new in Linear")! == ("weekdays 10:30", "what's new in Linear"))
    }

    @Test func phrasesThatAreNot() {
        #expect(Routines.phrase("every day I read the news about AI") == nil)
        #expect(Routines.phrase("find flights to Lisbon") == nil)
        #expect(Routines.phrase("every weekday at 10") == nil)
        #expect(Routines.phrase("every 30 hours check it") == nil)
        #expect(Routines.phrase("everyday objects in design") == nil)
    }

    @Test func menusAndBack() {
        #expect(RoutineWhen.split("weekdays 9:00").repeats == "weekdays")
        #expect(RoutineWhen.split("mon,wed,fri 8:15").repeats == RoutineWhen.onDays)
        #expect(RoutineWhen.split("mon,wed,fri 8:15").days == [2, 4, 6])
        #expect(RoutineWhen.join(RoutineWhen.onDays, 8 * 60 + 15, [6, 2, 4]) == "mon,wed,fri 8:15")
        #expect(RoutineWhen.join("hourly", 540, []) == "hourly")
        #expect(RoutineWhen.join("on open", 540, []) == "on open")
        #expect(RoutineWhen.join("daily", 9 * 60 + 5, []) == "daily 9:05")
        #expect(Routines.schedule("on open") == .opens)
        #expect(Routines.say("on open") == "When Pane opens")
    }

    @Test func aRowsWords() {
        var routine = Routine(id: "a", when: "weekdays 9:00", prompt: "check my mail", last: nil)
        let now = Date()
        routine.ended = now
        routine.found = 2
        #expect(Routines.status(routine, live: false, now: now).hasSuffix("· 2 things for you"))
        routine.found = 0
        routine.said = "Nothing new."
        #expect(Routines.status(routine, live: false, now: now).hasSuffix("· nothing new"))
        #expect(Routines.status(routine, live: true, now: now) == "Running now")
        // A run that couldn't finish says why when its last line does.
        routine.found = nil
        routine.said = "You've hit your usage limit · resets 5pm"
        #expect(Routines.status(routine, live: false, now: now).hasSuffix("· couldn’t finish: plan out of room"))
        routine.said = "Something odd happened"
        #expect(Routines.status(routine, live: false, now: now).hasSuffix("· couldn’t finish"))
        routine.said = nil
        #expect(Routines.status(routine, live: false, now: now).hasSuffix("· couldn’t finish"))
        routine.off = true
        #expect(Routines.status(routine, live: false, now: now) == "Off")
        #expect(Routines.nothing("Nothing new."))
        #expect(Routines.nothing("# Nothing new"))
        #expect(!Routines.nothing("# Two things need you"))
        #expect(Routine.name(from: "Check my mail for anything urgent: a question waiting") == "Check my mail for anything urgent…")
        #expect(Routine.name(from: "tell me which stories are new") == "Tell me which stories are new")
    }
}

// A routine's findings say whose they are.
struct RoutineRowsTests {
    @Test func aFindingSaysItsRoutine() {
        var found = Hints.Found(id: "found.x", title: "Figma couldn't charge your card", detail: "The team plan pauses Friday",
                                url: "https://mail.google.com/mail/u/0/#inbox/abc", at: Date())
        found.by = "Morning check"
        let hint = Hints.visible([found], now: Date(), lastVisit: { _ in nil }).first
        #expect(hint?.detail == "Morning check · The team plan pauses Friday")
        found.by = nil
        #expect(Hints.visible([found], now: Date(), lastVisit: { _ in nil }).first?.detail == "The team plan pauses Friday")
    }
}
