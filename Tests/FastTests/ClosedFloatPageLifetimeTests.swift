import AppKit
import Darwin
import Testing
import WebKit
@testable import Fast

/// Exercises Browser's real Isolate.run callback and existing delayed-lift
/// seam. The isolated-world answer is controlled; this proves ownership and
/// generation lifetime, not video playback or native system PiP acceptance.
@Suite(.serialized)
@MainActor
struct ClosedFloatPageLifetimeTests {
    @MainActor
    private final class Witness {
        weak var tab: Tab?
        weak var web: NSView?
        init(_ tab: Tab) { self.tab = tab; web = tab.builtPage }
    }

    @MainActor
    private final class Fixture {
        let id = UUID()
        let browser: Browser
        let savedPreference = Store.settings.object(forKey: "float.leave")
        let savedDelay = getenv("YAB_FLOAT_CALLBACK_DELAY").map { String(cString: $0) }

        init() {
            _ = NSApplication.shared
            browser = Browser(windowID: id)
            browser.prefs.floatsOnLeave = true
            setenv("YAB_FLOAT_CALLBACK_DELAY", "5", 1)
        }

        func close() {
            browser.land()
            browser.letGo()
            if let savedPreference { Store.settings.set(savedPreference, forKey: "float.leave") }
            else { Store.settings.removeObject(forKey: "float.leave") }
            if let savedDelay { setenv("YAB_FLOAT_CALLBACK_DELAY", savedDelay, 1) }
            else { unsetenv("YAB_FLOAT_CALLBACK_DELAY") }
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            try? FileManager.default.removeItem(at: Store.file("spaces-window-\(id.uuidString).json"))
        }

        func page(_ token: String) async throws -> Tab {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let tab = Tab(bench: true, configuration: configuration)
            try await load(tab, token: token)
            browser.moveIn(tab)
            return tab
        }

        func load(_ tab: Tab, token: String) async throws {
            let url = URL(string: "https://www.youtube.com/watch?v=lifetime-\(token)")!
            tab.page.navigate(html: "<!doctype html><title>\(token)</title><p>Local lifecycle fixture</p>", base: url)
            let loaded = try await Loaded.until(12) {
                (try? await tab.page.run("document.title")) as? String == token && !tab.page.isLoading
            }
            try #require(loaded, "The local document must load before the callback test")
            tab.setAddressOptimistically(url)
            try #require(!tab.asleep && Players.knows(tab.address))
            let installed = try await tab.page.run("""
                window.__lifetime = { token: '\(token)', on: 0, off: 0 };
                window.__yabFloat = {
                  on: async function() { window.__lifetime.on++; return ['floating', 640, 360]; },
                  off: async function() { window.__lifetime.off++; return 'off'; }
                };
                true;
                """, in: .named("float"))
            try #require(installed as? Bool == true)
        }

        func count(_ tab: Tab, _ verb: String) async throws -> Int {
            let web = try #require(tab.builtPage, "Observation must not materialize a view")
            let value = try await web.run("window.__lifetime.\(verb)", in: .named("float"))
            return try #require(value as? Int, "The isolated-world counter must return an integer, got \(String(describing: value))")
        }

        func begin(_ source: Tab, leavingFor sibling: Tab) async throws -> Date {
            try #require(Store.testing, "The existing callback delay is available only in a disposable test world")
            browser.activeID = source.id
            let started = Date()
            browser.benchLiftPage(source, quietly: true)
            let called = try await Loaded.until(8) { try await self.count(source, "on") == 1 }
            try #require(called, "The native Isolate.run on callback must actually execute")
            try await Task.sleep(for: .milliseconds(100))
            try #require(Date().timeIntervalSince(started) < 1.5,
                         "The fixture must leave time to observe release before the five-second callback")
            // Selection itself is not the input under test, and direct ID
            // assignment avoids requesting a second automatic lift.
            browser.activeID = sibling.id
            return Date()
        }

        func mark(_ event: String, source: UUID, began: Date) {
            let row: [String: Any] = ["event": event, "source": source.uuidString,
                                     "elapsed_ms": Date().timeIntervalSince(began) * 1000]
            if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
                FileHandle.standardError.write(Data("CLOSED_FLOAT_TEST ".utf8) + data + Data("\n".utf8))
            }
        }

        func afterDelay(_ began: Date) async throws {
            // The existing seam delays native completion by five seconds.
            // No WKWebView or census result is held across this wait.
            let left = 5.7 - Date().timeIntervalSince(began)
            if left > 0 { try await Task.sleep(for: .seconds(left)) }
        }

        func expectSibling(_ sibling: Tab, token: String) async throws {
            #expect(browser.tabs.contains { $0 === sibling })
            #expect(!sibling.gone && !sibling.floating)
            #expect(try await count(sibling, "on") == 0)
            #expect(try await count(sibling, "off") == 0)
            #expect(try await sibling.page.run("document.title") as? String == token)
        }

        func closeAndDrop(_ source: inout Tab?) {
            autoreleasepool {
                if let source { browser.close(source) }
            }
            source = nil
        }
    }

    @Test(.enabled(if: !ForcedEngine.chromium, "WebKit-only: the delayed Browser.lift/land callback uses native Isolate and WK fullscreen state; Chromium currently refuses this path")) func aClosedSourceAndItsOriginalPageReleaseBeforeTheDelayedAnswer() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let sibling = try await fixture.page("release-sibling")
        var source: Tab? = try await fixture.page("release-source")
        let witness = Witness(try #require(source))
        let sourceID = try #require(source).id
        let began = try await fixture.begin(try #require(source), leavingFor: sibling)
        fixture.mark("close.drop", source: sourceID, began: began)
        fixture.closeAndDrop(&source)
        let released = try await Loaded.until(3) { witness.tab == nil && witness.web == nil }
        fixture.mark("release.observed", source: sourceID, began: began)
        #expect(released, "A delayed float answer must not own a closed Tab or its original PageView")
        #expect(Date().timeIntervalSince(began) < 5, "Release must precede the controlled delayed completion")
        try await fixture.afterDelay(began)
        #expect(witness.tab == nil && witness.web == nil)
        #expect(fixture.browser.floating == nil && !fixture.browser.floater.showing)
        try await fixture.expectSibling(sibling, token: "release-sibling")
    }

    @Test(.enabled(if: !ForcedEngine.chromium, "WebKit-only: the delayed Browser.lift/land callback uses native Isolate and WK fullscreen state; Chromium currently refuses this path")) func aLateAnswerCannotRematerializeAnIntentionallyRetainedClosedTab() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let sibling = try await fixture.page("closed-sibling")
        let source = try await fixture.page("closed-source")
        defer { source.close() } // Also clean a baseline's resurrected view.
        let witness = Witness(source)
        let began = try await fixture.begin(source, leavingFor: sibling)
        fixture.mark("close.retained", source: source.id, began: began)
        autoreleasepool { fixture.browser.close(source) }
        #expect(source.gone && source.builtPage == nil)
        try await fixture.afterDelay(began)
        fixture.mark("closed.answer.waited", source: source.id, began: began)
        #expect(source.gone && source.builtPage == nil, "A rejected late answer must not obtain tab.page")
        #expect(witness.web == nil)
        #expect(!source.floating && fixture.browser.floating == nil && !fixture.browser.floater.showing)
        try await fixture.expectSibling(sibling, token: "closed-sibling")
    }

    @Test(.enabled(if: !ForcedEngine.chromium, "WebKit-only: the delayed Browser.lift/land callback uses native Isolate and WK fullscreen state; Chromium currently refuses this path")) func aLateAnswerCannotActOnAReplacementViewOfTheSameTab() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let sibling = try await fixture.page("replacement-sibling")
        let source = try await fixture.page("replacement-old")
        let old = Witness(source)
        let began = try await fixture.begin(source, leavingFor: sibling)
        fixture.mark("replace.view", source: source.id, began: began)
        // A real local fresh-view transition, with no external navigation.
        source.goFresh(to: URL(string: "about:blank#replacement")!)
        try await fixture.load(source, token: "replacement-new")
        #expect(source.builtPage !== old.web)
        let replacement = Witness(source)
        try await fixture.afterDelay(began)
        #expect(source.builtPage === replacement.web && old.web == nil)
        #expect(try await fixture.count(source, "on") == 0)
        #expect(try await fixture.count(source, "off") == 0)
        #expect(!source.floating && fixture.browser.floating == nil && !fixture.browser.floater.showing)
        try await fixture.expectSibling(sibling, token: "replacement-sibling")
    }

    @Test(.enabled(if: !ForcedEngine.chromium, "WebKit-only: the delayed Browser.lift/land callback uses native Isolate and WK fullscreen state; Chromium currently refuses this path")) func aNewProvisionalNavigationInTheSameViewInvalidatesTheOldAnswer() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let sibling = try await fixture.page("navigation-sibling")
        let source = try await fixture.page("navigation-old")
        let same = Witness(source)
        let navigation = source.askedAt
        let began = try await fixture.begin(source, leavingFor: sibling)
        fixture.mark("navigate.sameView", source: source.id, began: began)
        try await fixture.load(source, token: "navigation-new")
        try #require(source.builtPage === same.web && source.askedAt != navigation,
                     "Real local navigation must advance the generation while keeping the view")
        try await fixture.afterDelay(began)
        #expect(source.builtPage === same.web)
        #expect(try await fixture.count(source, "on") == 0)
        #expect(try await fixture.count(source, "off") == 0)
        #expect(!source.floating && fixture.browser.floating == nil && !fixture.browser.floater.showing)
        try await fixture.expectSibling(sibling, token: "navigation-sibling")
    }

    @Test(.enabled(if: !ForcedEngine.chromium, "WebKit-only: the delayed Browser.lift/land callback uses native Isolate and WK fullscreen state; Chromium currently refuses this path")) func aLateAnswerBelongsToTheBrowserThatStillOwnsThePage() async throws {
        let origin = Fixture()
        defer { origin.close() }
        let destination = Fixture()
        defer { destination.close() }
        let sibling = try await origin.page("move-origin-sibling")
        let destinationSibling = try await destination.page("move-destination-sibling")
        let source = try await origin.page("move-source")
        let same = Witness(source)
        let navigation = source.askedAt
        let began = try await origin.begin(source, leavingFor: sibling)
        origin.mark("move.browser", source: source.id, began: began)
        origin.browser.moveOut(source)
        destination.browser.moveIn(source)
        try #require(source.delegate === destination.browser && source.builtPage === same.web
                     && source.askedAt == navigation,
                     "Transfer must change only Browser ownership, preserving the live page generation")
        // Preserve an owned PiP state at the destination. This is a state
        // control; actual native PiP is covered by FloatPiPTests.
        source.pictureInPicture = true
        defer { source.pictureInPicture = false }
        try await origin.afterDelay(began)
        origin.mark("move.answer.waited", source: source.id, began: began)
        #expect(!origin.browser.everyTab.contains { $0 === source })
        #expect(destination.browser.everyTab.contains { $0 === source })
        #expect(source.delegate === destination.browser && source.builtPage === same.web)
        #expect(!source.gone && !source.asleep && source.pictureInPicture && !source.floating)
        #expect(try await destination.count(source, "on") == 1)
        #expect(try await destination.count(source, "off") == 0,
                "The former owner's late callback must not undo the destination's live document")
        #expect(origin.browser.floating == nil && !origin.browser.floater.showing)
        #expect(destination.browser.floating == nil && !destination.browser.floater.showing)
        try await origin.expectSibling(sibling, token: "move-origin-sibling")
        try await destination.expectSibling(destinationSibling, token: "move-destination-sibling")
    }

    @Test(.enabled(if: !ForcedEngine.chromium, "WebKit-only: the delayed Browser.lift/land callback uses native Isolate and WK fullscreen state; Chromium currently refuses this path")) func aValidExplicitForegroundLiftKeepsItsOwnedPageAndReturnsIt() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let sibling = try await fixture.page("valid-sibling")
        let source = try await fixture.page("valid-source")
        let same = Witness(source)
        fixture.browser.activeID = source.id
        fixture.browser.benchLiftPage(source, quietly: false)
        let lifted = try await Loaded.until(8) {
            fixture.browser.floating == source.id && fixture.browser.floater.showing
        }
        #expect(lifted && source.floating && source.builtPage === same.web)
        #expect(fixture.browser.activeID == source.id)
        #expect(try await fixture.count(source, "on") == 1)
        fixture.browser.land(home: true)
        let landed = try await Loaded.until(5) { try await fixture.count(source, "off") == 1 }
        #expect(landed && !source.gone && source.builtPage === same.web)
        #expect(!source.floating && fixture.browser.floating == nil)
        try await fixture.expectSibling(sibling, token: "valid-sibling")
    }

    @Test func anOwnedSystemPiPStateSuppressesAutomaticLiftWithoutDiscardingTheSource() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let source = try await fixture.page("pip-state")
        let same = Witness(source)
        // This is the existing ownership-state guard, not a claim that the
        // fixture entered the system's native Picture-in-Picture window.
        source.pictureInPicture = true
        defer { source.pictureInPicture = false }
        fixture.browser.leavingSpace()
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await fixture.count(source, "on") == 0)
        #expect(!source.gone && source.builtPage === same.web && source.pictureInPicture)
        #expect(fixture.browser.floating == nil && !fixture.browser.floater.showing)
    }

    /// This entry is admitted only through the existing AppKit runner, whose
    /// named-world environment precedes its subprocess and NSApplication.
    /// Refuse unnamed worlds and an unsuccessful suite, before Fixture's
    /// property initializers can touch preferences or construct a Browser.
    private static func requireReturnStillWorld() throws {
        let env = ProcessInfo.processInfo.environment
        let world = try #require(env["YAB_CHECK_WORLD"])
        try #require(env["YAB_FARM_WORKER"] == "1" && !world.isEmpty
                     && world != "test" && world != "1"
                     && world.count < 80 && world.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        let probe = "appkit-gate-" + world
        try #require(env["YAB_PROBE"] == probe && env["YAB_HISTORY"] == "own")
        let expected = "net.serubin.pane.test." + probe.lowercased()
        let suite = try #require(UserDefaults(suiteName: expected), "Never fall back to standard defaults")
        try #require(Store.testing && Store.world == probe.lowercased())
        try #require(Store.settings !== UserDefaults.standard, "Refuse the production fallback")
        let key = "test.949.suite." + UUID().uuidString, value = UUID().uuidString
        suite.set(value, forKey: key)
        defer { suite.removeObject(forKey: key) }
        try #require(Store.settings.string(forKey: key) == value, "The actual Store must read the exact isolated suite")
    }

    /// Actual native capture -> actual Browser.land, not a copied predicate.
    /// A matching red pre-lift still must not cover the blue page on return.
    /// This controls the page's contents, not playback or held callbacks.
    @Test(.enabled(if: !ForcedEngine.chromium, "WebKit-only: returning-video still-cache matching requires native WK snapshots"),
          .enabled(if: ProcessInfo.processInfo.environment["YAB_PROBE"]?.hasPrefix("appkit-gate-") == true))
    func returningVideoDropsItsMatchingStillButOtherLandingsKeepTheirs() async throws {
        try Self.requireReturnStillWorld()
        let wasOn = PageStills.on
        PageStills.on = true
        defer { PageStills.on = wasOn }
        for mode in ["video-home", "video-away", "call-home"] {
            let fixture = Fixture()
            defer { fixture.close() }
            let source = try await fixture.page("still-" + mode)
            let sibling = try await fixture.page("other-" + mode)
            let otherOwner = UUID()
            let stage = StageView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
            stage.wantsLayer = true
            let screen = try #require(TestScreen.screen)
            let window = NSWindow(contentRect: NSRect(x: screen.visibleFrame.minX + 40,
                                                     y: screen.visibleFrame.minY + 40, width: 640, height: 360),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = stage
            window.orderFront(nil)
            defer {
                PageStills.shared.forget(source.id)
                PageStills.shared.forget(otherOwner)
                window.close()
            }
            let web = try #require(source.webKitOnly("Native still cache fixture", build: false))
            stage.show(web, of: source.id)
            stage.layoutSubtreeIfNeeded()
            try await web.run("document.body.style.background = '#d82030'; document.body.innerHTML = '<h1>Before floating</h1>'")
            let key = PageStills.key(web, on: stage)
            try #require(key.size.width >= 32 && key.size.height >= 32)
            PageStills.shared.take(web, owner: source.id, key: key, shy: false)
            PageStills.shared.take(web, owner: otherOwner, key: key, shy: false)
            let seeded = try await Loaded.until(20) {
                PageStills.shared.has(source.id, matching: key) && PageStills.shared.has(otherOwner, matching: key)
            }
            try #require(seeded, "Real WebKit snapshots and IOSurface conversion must finish before lift")
            let out = ProcessInfo.processInfo.environment["YAB_FARM_OUT"].map { URL(fileURLWithPath: $0) }
            if let out, let image = PageStills.shared.picture(of: source.id),
               let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: out.appendingPathComponent(mode + "-cached.png"))
            }
            fixture.browser.activeID = source.id
            if mode == "call-home" {
                // Production Browser.putOut selects its call branch. This is a
                // call-kind ownership control, not a meeting/provider test.
                fixture.browser.putOut(source, web: web)
            } else {
                fixture.browser.benchLiftPage(source, quietly: false)
            }
            let lifted = try await Loaded.until(8) {
                fixture.browser.floating == source.id && fixture.browser.floater.showing
                    && web.window != nil && web.window !== window
            }
            try #require(lifted, "The owned page must really be attached before native capture")
            // The real page changes while away. Its cached frame still
            // matches the return stage's address, size, appearance and scroll.
            stage.show(sibling.page, of: sibling.id)
            try await web.run("document.body.style.background = '#126bd8'; document.body.innerHTML = '<h1>While floating</h1>'")
            let live = try await web.takeSnapshot(configuration: nil)
            if let out, let tiff = live.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: out.appendingPathComponent(mode + "-live.png"))
            }
            // Optional continuous capture by the repository's existing
            // ScreenCaptureKit recorder. The golden runner requires frames;
            // the ordinary unit shard does not need Screen Recording.
            var film: Process?
            if mode == "video-home", let out,
               let executable = ProcessInfo.processInfo.environment["YAB_PIP_RETURN_FILM"] {
                let log = out.appendingPathComponent("film.log")
                try Data().write(to: log)
                let handle = try FileHandle(forWritingTo: log)
                defer { try? handle.close() }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = [String(window.windowNumber), "3", out.appendingPathComponent("film").path]
                process.standardOutput = handle
                process.standardError = handle
                try process.run()
                film = process
                let ready = try await Loaded.until(15) {
                    ((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("ready")
                }
                try #require(ready, "The continuous recorder must produce a real frame before returning")
            }
            defer { if let film, film.isRunning { film.terminate() } }
            let returnedAt = CACurrentMediaTime()
            fixture.browser.land(home: mode != "video-away")
            let retained = PageStills.shared.has(source.id, matching: key)
            if mode == "video-home" {
                #expect(!PageStills.shared.has(source.id, matching: key),
                        "Returning video must not retain its matching pre-return frame")
            } else {
                #expect(PageStills.shared.has(source.id, matching: key), "No-home and call-kind stills stay intact")
            }
            #expect(PageStills.shared.has(otherOwner, matching: key), "Never drop another owner's still")
            #expect(!source.gone && source.builtPage === web && !source.floating && fixture.browser.floating == nil)
            stage.show(web, of: source.id)
            let showedStill = stage.showsStill
            if mode == "video-home" { #expect(!showedStill, "The return stage must not put the old red frame over the changed page") }
            let row: [String: Any] = ["mode": mode, "retained": retained,
                                      "stage_still": showedStill, "returned_at": returnedAt]
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            FileHandle.standardError.write(Data("PIP_RETURN_STILL ".utf8) + data + Data("\n".utf8))
            if mode == "video-away" {
                fixture.browser.land(home: true) // Nothing floating: ordinary land is a no-op for this still.
                #expect(PageStills.shared.has(source.id, matching: key))
            }
            if let film {
                let ended = try await Loaded.until(20) { !film.isRunning }
                try #require(ended && film.terminationStatus == 0, "The native film must finish completely")
            }
        }
    }
}
