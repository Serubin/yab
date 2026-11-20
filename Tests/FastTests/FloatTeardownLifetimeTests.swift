import AppKit
import Testing
@testable import Fast

/// Executed only by the dedicated fresh-process deferred check, never the
/// ordinary suite union. The process owns its spare panel and Wrapped ledger.
// Ordinary broad shards retain a truthful skip for this NEW dedicated
// fixture. Its mandatory card check rejects skips and executes every case.
// Decide from strings only, before touching Store or any fixture state.
@Suite(.serialized, .enabled(if:
    ProcessInfo.processInfo.environment["YAB_PIP_LIFETIME_WORLD"]?.hasPrefix("appkit-gate-pip-lifetime-") == true &&
    ProcessInfo.processInfo.environment["YAB_PIP_LIFETIME_WORLD"] == ProcessInfo.processInfo.environment["YAB_PROBE"] &&
    ProcessInfo.processInfo.environment["YAB_PROBE"] == ProcessInfo.processInfo.environment["YAB_CHECK_WORLD"].map({ "appkit-gate-" + $0 }) &&
    ProcessInfo.processInfo.processName == "swiftpm-testing-helper-appkit"
))
@MainActor
struct FloatTeardownLifetimeTests {
    @MainActor
    private final class Fixture {
        let domain: String
        let saved: [String: Any]?
        var floaters: [Floater] = []
        var panels: [NSWindow] = []
        let stage: NSView

        init() throws {
            let env = ProcessInfo.processInfo.environment
            let expected = try #require(env["YAB_PIP_LIFETIME_WORLD"])
            try #require(expected.hasPrefix("appkit-gate-pip-lifetime-"))
            try #require(UUID(uuidString: String(expected.dropFirst("appkit-gate-pip-lifetime-".count))) != nil)
            try #require(Store.testing && Store.unitTests && Store.world == expected)
            try #require(ProcessInfo.processInfo.processName == "swiftpm-testing-helper-appkit")
            try #require(Store.settings !== UserDefaults.standard)
            _ = NSApplication.shared
            try #require(!NSScreen.screens.isEmpty)
            stage = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
            domain = "net.serubin.pane.test.\(expected)"
            saved = Store.settings.persistentDomain(forName: domain)
            Store.settings.removeObject(forKey: "float.frame")
            Store.settings.set(false, forKey: "float.snapToEdges")
        }

        func page() -> NSView {
            NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        }

        func add(_ floater: Floater) {
            if !floaters.contains(where: { $0 === floater }) { floaters.append(floater) }
        }

        func lift(_ page: NSView, with floater: Floater, whole: Bool) async throws -> NSWindow {
            add(floater)
            floater.lift(page, shape: CGSize(width: 440, height: 247), whole: whole)
            // All Panel instances in this exact fresh helper belong to this
            // suite, including its own spare from an earlier serialized case.
            for panel in NSApp.windows where Floater.owns(panel) && !panels.contains(where: { $0 === panel }) {
                panels.append(panel)
            }
            try await FloatTeardownLifetimeTests.eventually { Floater.owns(page.window) }
            let panel = try #require(page.window)
            try #require(panel.isVisible)
            try #require(page.superview != nil)
            #expect(whole ? page.superview === panel.contentView : page.superview !== panel.contentView)
            return panel
        }

        func close() async throws {
            defer {
                for panel in panels { panel.orderOut(nil) }
                if let saved { Store.settings.setPersistentDomain(saved, forName: domain) }
                else { Store.settings.removePersistentDomain(forName: domain) }
            }
            for floater in floaters { floater.drop() }
            // This marker is queued after every own release/arrival/spare
            // deadline. Do not restore preferences or discard the world early.
            await FloatTeardownLifetimeTests.after(0.55)
            #expect(floaters.allSatisfy { !$0.showing && !$0.homing })
            if let last = panels.last { #expect(!last.isVisible) }
            // Wrapped's private utility save retains only this unique world;
            // the wrapper retains that world through process exit.
        }
    }

    private static func after(_ seconds: Double) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { continuation.resume() }
        }
    }

    private static func turn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private static func eventually(_ predicate: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 2
        while !predicate() && ProcessInfo.processInfo.systemUptime < end {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(predicate())
    }

    private func withFixture(_ body: @MainActor (Fixture) async throws -> Void) async throws {
        let fixture = try Fixture()
        do {
            try await body(fixture)
            try await fixture.close()
        } catch {
            do { try await fixture.close() } catch { Issue.record(error) }
            throw error
        }
    }

    @Test(arguments: [false, true])
    func oldViewLossKeepsReplacement(whole: Bool) async throws {
        try await withFixture { fixture in
            let floater = Floater(), a = fixture.page(), b = fixture.page()
            let panel = try await fixture.lift(a, with: floater, whole: whole)
            floater.release()
            // Real Ground/Lens.willRemoveSubview queues the production drop.
            fixture.stage.addSubview(a)
            floater.drop()
            floater.lift(b, shape: CGSize(width: 440, height: 247), whole: whole)
            await Self.turn()
            #expect(floater.showing && !floater.homing)
            try await Self.eventually { b.window === panel }
            #expect(a.superview === fixture.stage)
        }
    }

    @Test(arguments: [false, true])
    func oldViewLossKeepsReusedPageAndPanel(whole: Bool) async throws {
        try await withFixture { fixture in
            let floater = Floater(), page = fixture.page()
            let panel = try await fixture.lift(page, with: floater, whole: whole)
            let oldGround = try #require(panel.contentView)
            floater.release()
            fixture.stage.addSubview(page)
            floater.drop()
            floater.lift(page, shape: CGSize(width: 440, height: 247), whole: whole)
            let newGround = try #require(panel.contentView)
            try #require(newGround !== oldGround && panel.alphaValue > 0)
            // Occlusion may leave B pending rather than already in its Lens
            // or Ground. Both are real accepted lifetimes; homing prevents
            // arrive() from changing this actual placement during the turn.
            let parent = page.superview, window = page.window
            floater.release()
            await Self.turn()
            #expect(floater.showing && floater.homing)
            #expect(panel.contentView === newGround)
            #expect(page.superview === parent && page.window === window)
            try await Self.eventually { !floater.showing }
            try await Self.eventually { !panel.isVisible }
        }
    }

    @Test(arguments: [false, true])
    func matchingViewLossStillDrops(whole: Bool) async throws {
        try await withFixture { fixture in
            let floater = Floater(), page = fixture.page()
            _ = try await fixture.lift(page, with: floater, whole: whole)
            floater.release()
            fixture.stage.addSubview(page)
            await Self.turn()
            #expect(!floater.showing && !floater.homing)
            #expect(page.superview === fixture.stage)
        }
    }

    @Test(arguments: [false, true])
    func releaseFallbackDropsUnclaimedOwner(whole: Bool) async throws {
        try await withFixture { fixture in
            let floater = Floater(), page = fixture.page()
            let panel = try await fixture.lift(page, with: floater, whole: whole)
            floater.release()
            #expect(floater.showing && floater.homing)
            try await Self.eventually { !floater.showing }
            #expect(!floater.homing && page.window == nil)
            // Actual deferred spare ordering must finish too, not just alpha0.
            try await Self.eventually { !panel.isVisible }
        }
    }

    @Test(arguments: [false, true])
    func oldFallbackCannotShortenReplacementRelease(whole: Bool) async throws {
        try await withFixture { fixture in
            let floater = Floater(), page = fixture.page()
            let panel = try await fixture.lift(page, with: floater, whole: whole)
            let oldGround = try #require(panel.contentView)
            let began = ProcessInfo.processInfo.systemUptime
            floater.release()
            floater.drop()
            // Do not await B's arrival: an occluded reused panel can still
            // be waiting for its0.3s fallback when B itself is sent home.
            floater.lift(page, shape: CGSize(width: 440, height: 247), whole: whole)
            let newGround = try #require(panel.contentView)
            try #require(newGround !== oldGround && panel.alphaValue > 0)
            // Leave a measurable gap between the actual0.4s deadlines. A
            // starved host is an invalid fixture, never synthetic success.
            let wait = max(0, began + 0.2 - ProcessInfo.processInfo.systemUptime)
            await Self.after(wait)
            try #require(ProcessInfo.processInfo.systemUptime < began + 0.3)
            let releasedB = ProcessInfo.processInfo.systemUptime
            let parent = page.superview, window = page.window
            floater.release()
            await Self.after(max(0, began + 0.45 - ProcessInfo.processInfo.systemUptime))
            try #require(ProcessInfo.processInfo.systemUptime < releasedB + 0.37)
            #expect(floater.showing && floater.homing)
            #expect(panel.contentView === newGround)
            #expect(page.superview === parent && page.window === window)
            try await Self.eventually { !floater.showing }
            try await Self.eventually { !panel.isVisible }
        }
    }

    @Test(arguments: [false, true])
    func queuedLossAfterDropDoesNotResurrect(whole: Bool) async throws {
        try await withFixture { fixture in
            let floater = Floater(), page = fixture.page()
            _ = try await fixture.lift(page, with: floater, whole: whole)
            floater.release()
            fixture.stage.addSubview(page)
            floater.drop()
            await Self.turn()
            #expect(!floater.showing && !floater.homing)
            #expect(page.superview === fixture.stage)
        }
    }

    @Test(arguments: [false, true])
    func separateFloatersStayIndependent(whole: Bool) async throws {
        try await withFixture { fixture in
            let a = Floater(), b = Floater(), pageA = fixture.page(), pageB = fixture.page()
            _ = try await fixture.lift(pageA, with: a, whole: whole)
            let panelB = try await fixture.lift(pageB, with: b, whole: whole)
            a.release()
            fixture.stage.addSubview(pageA)
            await Self.turn()
            #expect(!a.showing)
            #expect(b.showing && !b.homing && pageB.window === panelB)
        }
    }
}
