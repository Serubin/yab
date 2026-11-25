import AppKit
import Testing
@testable import Fast

/// Put idle tabs to sleep is on until turned off, and being on neither takes
/// a protected tab nor changes what Tidy closes.
@Suite(.serialized)
@MainActor
struct SleepDefaultTests {
    /// `body` with `tabs.sleep` stored as given, absent for nil. It never
    /// awaits, so no other test sees the key changed.
    private func stored<T>(_ value: Bool?, _ body: () throws -> T) rethrows -> T {
        let before = Store.settings.object(forKey: "tabs.sleep")
        defer { Store.settings.set(before, forKey: "tabs.sleep") }
        Store.settings.set(value, forKey: "tabs.sleep")
        return try body()
    }

    /// A window with `count` loaded pages behind the one on screen, its
    /// preferences read with `tabs.sleep` stored as given.
    private func world(_ count: Int, sleep value: Bool? = nil) async throws -> (Browser, [Tab], Tab, () -> Void) {
        let id = UUID(), browser = stored(value) { Browser(windowID: id) }
        let hidden = (0..<count).map { browser.open(URL(string: "about:blank#hidden\($0)")!, foreground: true) }
        let front = browser.open(URL(string: "about:blank#foreground")!, foreground: true)
        for tab in hidden {
            for _ in 0..<100 where tab.loading { try await Task.sleep(nanoseconds: 20_000_000) }
            #expect(!tab.loading)
            #expect(browser.awake(because: tab) == nil)
        }
        browser.recent = []
        let done = {
            for page in browser.tabs { page.close() }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        return (browser, hidden, front, done)
    }

    /// Hidden tabs 1 to 6, one protected each; 0 and 7 are left plain.
    private func protect(_ hidden: [Tab], in browser: Browser) {
        browser.recent = [hidden[1].id]
        hidden[2].pin = "Pinned"
        hidden[3].kept = true
        hidden[4].noisy = true
        hidden[5].setAddressOptimistically(URL(string: "https://web.whatsapp.com/")!)
        hidden[6].visits = 2 + Browser.keepRevisited
    }

    @Test func onUntilTurnedOff() {
        stored(nil) { #expect(Preferences().sleepsTabs) }
        stored(false) { #expect(!Preferences().sleepsTabs) }
        stored(true) { #expect(Preferences().sleepsTabs) }
    }

    @Test func readingTheDefaultStoresNothing() {
        stored(nil) {
            _ = Preferences()
            #expect(Store.settings.object(forKey: "tabs.sleep") == nil)
        }
    }

    @Test func diagnosticsSayWhatTheTimerReads() {
        stored(nil) { #expect(FeedbackDiagnostics.Memory.now().sleepsTabs) }
        stored(false) { #expect(!FeedbackDiagnostics.Memory.now().sleepsTabs) }
        stored(true) { #expect(FeedbackDiagnostics.Memory.now().sleepsTabs) }
    }

    @Test func byDefaultOnlyUnprotectedTabsAreIdle() async throws {
        let (browser, hidden, front, done) = try await world(8)
        defer { done() }
        protect(hidden, in: browser)
        let agent = browser.benchOpen(URL(string: "about:blank#agent")!)
        for _ in 0..<100 where agent.loading { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(browser.prefs.sleepsTabs)
        #expect(browser.awake(because: front) == "on screen")
        #expect(browser.awake(because: agent) == "a bench tab")
        let late = AwakeClock.now + Browser.usualSleepAfter + 60
        let idle = browser.idleTabs(within: Browser.usualSleepAfter, now: late)
        #expect(Set(idle.map(\.id)) == [hidden[0].id, hidden[7].id])
    }

    @Test func byDefaultTheTimerPutsDownOnlyUnprotectedTabs() async throws {
        let (browser, hidden, front, done) = try await world(8)
        defer { done() }
        protect(hidden, in: browser)
        browser.sleepIdle(within: 0)
        for _ in 0..<300 where !(hidden[0].asleep && hidden[7].asleep) { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(hidden[0].asleep && hidden[7].asleep)
        #expect(hidden[1...6].allSatisfy { !$0.asleep })
        #expect(!front.asleep)
    }

    @Test func turnedOffTheTimerPutsNoneDown() async throws {
        let (browser, hidden, _, done) = try await world(2, sleep: false)
        defer { done() }
        #expect(!browser.prefs.sleepsTabs)
        browser.sleepIdle(within: 0)
        // Past the draft probe and the picture, had either been asked for.
        try await Task.sleep(nanoseconds: UInt64(2 * Browser.pageAnswer * 1_000_000_000))
        #expect(hidden.allSatisfy { !$0.asleep })
    }

    /// Tidy closes the same tabs whatever the sleep switch says.
    @Test func tidyStillClosesAnAwakeTabLeftLongEnough() async throws {
        let (browser, hidden, front, done) = try await world(2)
        defer { done() }
        #expect(browser.prefs.sleepsTabs)
        let before = Store.settings.object(forKey: "tabs.tidy")
        defer { Store.settings.set(before, forKey: "tabs.tidy") }
        browser.prefs.tidyAfter = .halfDay
        hidden[1].pin = "Pinned"
        for tab in hidden { tab.touch(at: Date().addingTimeInterval(-13 * 3600)) }
        #expect(!hidden[0].asleep)
        browser.tidy()
        #expect(!browser.tabs.contains { $0 === hidden[0] })
        #expect(browser.tabs.contains { $0 === hidden[1] })
        #expect(browser.tabs.contains { $0 === front })
    }
}
