import AppKit
import Foundation
import PDFKit
import Testing
import WebKit
@testable import Fast

/// Real local PDF loading and PDFPaper.start establish the native document.
/// These tests exercise Space Under and manual pin-close ownership, not drawing or measured RAM.
@Suite(.serialized)
@MainActor
struct PDFPageLifetimeTests {
    @MainActor
    private final class Witness {
        weak var tab: Tab?
        weak var document: PDFDocument?
        weak var web: PageView?

        init(_ tab: Tab, document: PDFDocument) {
            self.tab = tab
            self.document = document
            web = tab.built
        }
    }

    @MainActor
    private final class Fixture {
        let id = UUID()
        let browser: Browser
        let window: NSWindow
        let folder: URL
        let input: URL
        let originalBytes: Data
        private let suite: String
        private let defaults: [String: Any]?
        private let spacesBytes: Data?
        private let sharing: Set<UUID>
        private let pageCounts: [UUID: Int]
        private let current: UUID
        private var made: [UUID] = []

        init() throws {
            // PDFPaper.start reads Wallet in this namespace. The canonical
            // appkit gate supplies a unique job world, never the user's one.
            try #require(Store.testing)
            let world = try #require(Store.world)
            let job = try #require(ProcessInfo.processInfo.environment["YAB_FARM_JOB"])
            try #require(!job.isEmpty && world.hasPrefix("appkit-gate-") && world.contains(job.lowercased()),
                         "Run in the canonical gate's disposable per-job Store/Wallet namespace")
            suite = "net.serubin.pane.test.\(world)"
            defaults = Store.settings.persistentDomain(forName: suite)
            spacesBytes = try? Data(contentsOf: Store.file("spaces.json"))
            sharing = Spaces.sharing
            pageCounts = Spaces.pageCounts
            current = Spaces.current
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-owner-\(id.uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            input = folder.appendingPathComponent("Local contract.pdf")
            originalBytes = try #require(PDFSignTests.contract().dataRepresentation())
            try originalBytes.write(to: input, options: .atomic)
            browser = Browser(windowID: id)
            browser.prefs.usesSpaces = true
            browser.prefs.downloads = folder.appendingPathComponent("Saved", isDirectory: true)
            window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 900, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 650))
            window.orderFront(nil)
        }

        func close() {
            // Baseline Under intentionally survives the failed assertion.
            // Clear that owner only during cleanup, after all observations.
            browser.under?.tab.close()
            browser.settleUnder()
            browser.letGo()
            window.close()
            Store.settings.setPersistentDomain(defaults ?? [:], forName: suite)
            if let spacesBytes { try? spacesBytes.write(to: Store.file("spaces.json"), options: .atomic) }
            else { try? FileManager.default.removeItem(at: Store.file("spaces.json")) }
            Spaces.sharing = sharing
            Spaces.pageCounts = pageCounts
            Spaces.current = current
            let names = ["session-window-\(id.uuidString).json", "spaces-window-\(id.uuidString).json"]
                + made.map { "session-window-\(id.uuidString)-\($0.uuidString).json" }
            for name in names { try? FileManager.default.removeItem(at: Store.file(name)) }
            try? FileManager.default.removeItem(at: folder)
        }

        func pdf(_ url: URL? = nil, selecting: Bool = true) async throws -> Tab {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            // A regular tab parks in its Space; bench tabs travel with it.
            let tab = Tab(configuration: configuration, factory: .webKitOnly)
            browser.moveIn(tab, selecting: selecting)
            requireNativeWebKitFixture(tab, "PDFPageLifetimeTests").frame = NSRect(x: 0, y: 0, width: 900, height: 650)
            window.contentView?.addSubview(requireNativeWebKitFixture(tab, "PDFPageLifetimeTests"))
            try await load(tab, url: url ?? input)
            return tab
        }

        func load(_ tab: Tab, url: URL) async throws {
            let web = try #require(tab.built)
            web.loadFileURL(url, allowingReadAccessTo: folder)
            try await waitForPDF(tab, url: url)
        }

        func waitForPDF(_ tab: Tab, url: URL) async throws {
            let web = try #require(tab.built)
            let loaded = try await Loaded.until(15) {
                !web.isLoading && web.url?.path == url.path && tab.address?.path == url.path && tab.paper.pdf
            }
            try #require(loaded, "Native local PDF must commit through Browser and establish paper.pdf: \(url.lastPathComponent)")
            try #require(!tab.bench && !tab.gone && !tab.asleep && tab.built === web)
        }

        func house(_ tab: Tab) throws {
            let web = try #require(tab.built, "Reopen must create its own view before the fixture houses it")
            web.frame = NSRect(x: 0, y: 0, width: 900, height: 650)
            window.contentView?.addSubview(web)
        }

        func start(_ tab: Tab) async throws {
            try #require(tab.paper.pdf && tab.paper.desk == nil && !tab.paper.starting)
            var answered = false
            tab.paper.start(tab, shelf: SignatureMemory()) { _ in answered = true }
            let ready = try await Loaded.until(12) {
                answered && !tab.paper.starting && tab.paper.desk != nil
            }
            try #require(ready, "Actual PDFPaper.start must publish its native PDFDesk")
            try #require(tab.paper.desk?.document.pageCount == 1)
        }

        func witness(_ source: Tab?) throws -> Witness {
            try autoreleasepool {
                let tab = try #require(source)
                let document = try #require(tab.paper.desk?.document,
                                            "A real owned PDFDocument must exist before the release test")
                return Witness(tab, document: document)
            }
        }

        func emptySpace(under source: Tab) throws {
            try #require(browser.active === source)
            let from = browser.spaceID
            let empty = browser.addSpace(named: "PDF owner empty", icon: "doc", ownSignIns: false)
            made.append(empty)
            try #require(browser.spaceID == empty && browser.active == nil && browser.underTab === source,
                         "The real empty-Space switch must establish Under")
            try #require(browser.parked[from]?.tabs.contains { $0 === source } == true)
        }

        func closeElsewhereAndDrop(_ source: inout Tab?) throws {
            try autoreleasepool {
                let closing = try #require(source)
                try #require(browser.parkedTabs.contains { $0 === closing })
                browser.closeElsewhere(closing)
                try #require(closing.gone && closing.built == nil,
                             "The existing parked close must actually close the source")
                source = nil
            }
        }

        func fill(_ tab: Tab, with value: String) throws {
            try autoreleasepool {
                let desk = try #require(tab.paper.desk)
                desk.focus(PDFSignTests.index(desk, "Name"))
                desk.draft = value
                desk.commitField()
            }
        }

        func value(_ tab: Tab) throws -> String {
            try autoreleasepool {
                let desk = try #require(tab.paper.desk)
                return desk.boxes[PDFSignTests.index(desk, "Name")].value
            }
        }

        func retainedDocument(_ tab: Tab?) throws -> PDFDocument {
            let source = try #require(tab)
            return try #require(source.paper.desk?.document)
        }

        func words(_ document: PDFDocument) -> String { document.string ?? "" }

        func mark(_ event: String, _ witness: Witness) {
            let row: [String: Any] = ["event": event, "tab_alive": witness.tab != nil,
                                     "pdf_alive": witness.document != nil, "original_web_alive": witness.web != nil]
            if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
                FileHandle.standardError.write(Data("PDF_OWNER_TEST ".utf8) + data + Data("\n".utf8))
            }
        }

        func rested(_ tab: Tab, pin: String?, kept: Bool, home: URL?) throws {
            try #require(browser.tabs.contains { $0 === tab }, "Manual close keeps this exact row Tab")
            #expect(tab.pin == pin && tab.kept == kept && tab.home == home)
            #expect(tab.asleep && !tab.gone && tab.built == nil)
            #expect(tab.pending == home)
            #expect(try Data(contentsOf: input) == originalBytes)
        }

        func wakeRested(_ tab: Tab) async throws {
            browser.select(tab)
            let made = try await Loaded.until(12) { tab.built != nil && !tab.asleep }
            try #require(made, "Selecting the same put-down row must really rebuild its view")
            try house(tab)
            try await waitForPDF(tab, url: input)
            try await start(tab)
            #expect(browser.active === tab && browser.tabs.contains { $0 === tab })
            #expect(try Data(contentsOf: input) == originalBytes)
        }

        func draft(_ tab: Tab, _ text: String) throws {
            try autoreleasepool {
                let desk = try #require(tab.paper.desk)
                desk.focus(PDFSignTests.index(desk, "Name"))
                desk.draft = text
            }
        }

        func emptyWriting(_ tab: Tab) throws {
            try autoreleasepool {
                let desk = try #require(tab.paper.desk)
                try #require(desk.write(on: 0, at: CGPoint(x: 180, y: 400)) != nil)
                try #require(!desk.changed && desk.writing != nil && desk.note.isEmpty)
            }
        }

        func markRest(_ event: String, _ witness: Witness) {
            let tab = witness.tab
            let row: [String: Any] = [
                "event": event, "tab_alive": tab != nil, "pdf_alive": witness.document != nil,
                "original_web_alive": witness.web != nil, "desk_alive": tab?.paper.desk != nil,
                "same_row_owner": tab.map { t in browser.tabs.contains { $0 === t } } ?? false,
                "asleep": tab?.asleep ?? false, "gone": tab?.gone ?? false,
                "built_alive": tab?.built != nil
            ]
            if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
                FileHandle.standardError.write(Data("PDF_REST_TEST ".utf8) + data + Data("\n".utf8))
            }
        }
    }

    @Test func closingTheParkedUnderReleasesItsTabAndNativePDFDocument() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        var source: Tab? = try await fixture.pdf()
        try await fixture.start(try #require(source))
        let witness = try fixture.witness(source)
        try fixture.emptySpace(under: try #require(source))
        fixture.mark("before.closeElsewhere", witness)
        try fixture.closeElsewhereAndDrop(&source)
        let released = try await Loaded.until(8) { witness.tab == nil && witness.document == nil }
        fixture.mark("after.release.wait", witness)
        #expect(released, "An ordinarily closed parked PDF must not remain owned by the empty Space's Under")
        #expect(fixture.browser.underTab == nil)
        // Original WK release is recorded, not claimed as a separate RAM fix.
    }

    @Test func closingAnotherPDFKeepsTheLiveUnderEditorAndItsUndo() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let live = try await fixture.pdf()
        try await fixture.start(live)
        try fixture.fill(live, with: "Live editor")
        let liveWitness = try fixture.witness(live)
        let sibling = try await fixture.pdf(selecting: false)
        try await fixture.start(sibling)
        try fixture.fill(sibling, with: "Independent same-file editor")
        #expect(live.paper.desk?.document !== sibling.paper.desk?.document)
        #expect(try fixture.value(live) == "Live editor")
        #expect(try fixture.value(sibling) == "Independent same-file editor")
        sibling.paper.desk?.undo()
        #expect(try fixture.value(sibling) == "")
        sibling.paper.desk?.redo()
        #expect(try fixture.value(sibling) == "Independent same-file editor")
        try fixture.emptySpace(under: live)
        fixture.browser.closeElsewhere(sibling)
        #expect(fixture.browser.underTab === live && !live.gone)
        #expect(live.paper.desk?.document === liveWitness.document)
        #expect(try fixture.value(live) == "Live editor")
        live.paper.desk?.undo()
        #expect(try fixture.value(live) == "")
        live.paper.desk?.redo()
        #expect(try fixture.value(live) == "Live editor")
        #expect(try Data(contentsOf: fixture.input) == fixture.originalBytes)
    }

    @Test func anExternalDocumentOwnerKeepsItsAnnotationsAfterTheTabReleases() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        var source: Tab? = try await fixture.pdf()
        try await fixture.start(try #require(source))
        try fixture.fill(try #require(source), with: "External owner")
        let document = try fixture.retainedDocument(source)
        let witness = try fixture.witness(source)
        try fixture.emptySpace(under: try #require(source))
        fixture.mark("external.before.closeElsewhere", witness)
        try fixture.closeElsewhereAndDrop(&source)
        let released = try await Loaded.until(8) { witness.tab == nil }
        fixture.mark("external.after.release.wait", witness)
        #expect(released, "The extra PDFDocument owner must not keep a closed Tab through Under")
        #expect(witness.document === document)
        #expect(document.page(at: 0)?.annotations.contains { $0.fieldName == "Name" && $0.widgetStringValue == "External owner" } == true)
        #expect(try Data(contentsOf: fixture.input) == fixture.originalBytes)
    }

    @Test func aCommittedReplacementReleasesTheOldEditorAndCanStartANewOne() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let source = try await fixture.pdf()
        try await fixture.start(source)
        let old = try fixture.witness(source)
        let replacement = fixture.folder.appendingPathComponent("Replacement.pdf")
        try PDFSignTests.contract().dataRepresentation()!.write(to: replacement)
        try await fixture.load(source, url: replacement)
        #expect(source.paper.desk == nil)
        let released = try await Loaded.until(8) { old.document == nil }
        #expect(released, "A real new PDF commit must release the previous PDFDesk document")
        #expect(source.built === old.web && !source.gone)
        try await fixture.start(source)
        try fixture.fill(source, with: "Replacement editor")
        #expect(try fixture.value(source) == "Replacement editor")
        source.paper.desk?.undo()
        #expect(try fixture.value(source) == "")
    }

    @Test(.enabled(if: !ForcedEngine.chromium, "WebKit-only: the reopened PDF is a PDFKit view inside a WKWebView-backed page")) func doneSavesAReadBackFileAndReopenPreservesItWithoutChangingTheOriginal() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        var source: Tab? = try await fixture.pdf()
        try await fixture.start(try #require(source))
        try fixture.fill(try #require(source), with: "Saved PDF owner")
        let saved = try autoreleasepool {
            let saving = try #require(source)
            return try #require(saving.paper.done(saving, browser: fixture.browser))
        }
        // Done already calls tab.go. Observe that navigation without
        // introducing a second load that could conceal a broken transition.
        try await fixture.waitForPDF(try #require(source), url: saved)
        let savedBytes = try Data(contentsOf: saved)
        try autoreleasepool {
            let readBack = try #require(PDFDocument(url: saved))
            #expect(fixture.words(readBack).contains("Saved PDF owner"))
            #expect(fixture.words(readBack).contains("Master Services Agreement"))
            #expect(readBack.page(at: 0)?.annotations.isEmpty == true)
        }
        try fixture.emptySpace(under: try #require(source))
        let sourceID = try #require(source).id
        try fixture.closeElsewhereAndDrop(&source)
        let ghost = try #require(fixture.browser.ghosts.last)
        try #require(ghost.url.path == saved.path, "The real parked close must remember the Done output")
        fixture.browser.reopen(from: ghost)
        let reopened = try #require(fixture.browser.active)
        try #require(reopened.id != sourceID && fixture.browser.tabs.contains { $0 === reopened })
        let made = try await Loaded.until(12) { reopened.built != nil }
        try #require(made, "Browser.reopen must materialize the restored PDF view")
        try fixture.house(reopened)
        try await fixture.waitForPDF(reopened, url: saved)
        try await fixture.start(reopened)
        #expect(fixture.words(try fixture.retainedDocument(reopened)).contains("Saved PDF owner"))
        #expect(try Data(contentsOf: saved) == savedBytes)
        #expect(try Data(contentsOf: fixture.input) == fixture.originalBytes)
    }

    @Test func manuallyClosingACleanPinnedPDFReleasesOnlyItsNativeDocument() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let source = try await fixture.pdf()
        try await fixture.start(source)
        try #require(fixture.browser.pin(source) === source)
        let pin = source.pin, home = source.home
        try #require(pin != nil && home == fixture.input)
        let witness = try fixture.witness(source)
        fixture.markRest("pin.before.close", witness)
        fixture.browser.close(source)
        try fixture.rested(source, pin: pin, kept: false, home: home)
        let released = try await Loaded.until(8) { witness.document == nil }
        fixture.markRest("pin.after.release.wait", witness)
        #expect(released, "A manually put-down clean pin keeps its row, not its native PDFDocument")
        try await fixture.wakeRested(source)
        #expect(source.pin == pin && source.home == home && !source.kept)
    }

    @Test func manuallyClosingACleanKeptPDFReleasesOnlyItsNativeDocument() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let source = try await fixture.pdf()
        try await fixture.start(source)
        fixture.browser.keepTabs([source])
        let home = source.home
        try #require(source.kept && source.pin == nil && home == fixture.input)
        let witness = try fixture.witness(source)
        fixture.markRest("kept.before.close", witness)
        fixture.browser.close(source)
        try fixture.rested(source, pin: nil, kept: true, home: home)
        let released = try await Loaded.until(8) { witness.document == nil }
        fixture.markRest("kept.after.release.wait", witness)
        #expect(released, "A manually put-down clean kept row must release its native PDFDocument")
        try await fixture.wakeRested(source)
        #expect(source.kept && source.pin == nil && source.home == home)
    }

    @Test func manuallyClosingAGroupReleasesItsCleanPDFDocuments() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let pin = try await fixture.pdf()
        try await fixture.start(pin)
        try #require(fixture.browser.pin(pin) === pin)
        let kept = try await fixture.pdf(selecting: false)
        try await fixture.start(kept)
        fixture.browser.keepTabs([kept])
        let letter = pin.pin, pinHome = pin.home, keptHome = kept.home
        try #require(letter != nil && kept.kept && pinHome == fixture.input && keptHome == fixture.input)
        let first = try fixture.witness(pin), second = try fixture.witness(kept)
        fixture.markRest("group.pin.before.close", first)
        fixture.markRest("group.kept.before.close", second)
        fixture.browser.close([pin, kept])
        try fixture.rested(pin, pin: letter, kept: false, home: pinHome)
        try fixture.rested(kept, pin: nil, kept: true, home: keptHome)
        let released = try await Loaded.until(8) { first.document == nil && second.document == nil }
        fixture.markRest("group.pin.after.release.wait", first)
        fixture.markRest("group.kept.after.release.wait", second)
        #expect(released, "A real manual group close releases both clean native documents while keeping both rows")
    }

    @Test func manualClosePreservesDirtyAndRedoOnlyPDFEditors() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let committed = try await fixture.pdf()
        try await fixture.start(committed)
        try fixture.fill(committed, with: "Committed edit")
        try #require(fixture.browser.pin(committed) === committed)
        let committedWitness = try fixture.witness(committed)
        fixture.browser.close(committed)
        #expect(committed.paper.desk?.document === committedWitness.document)
        #expect(committed.paper.desk?.changed == true)
        #expect(try fixture.value(committed) == "Committed edit")
        committed.paper.desk?.undo()
        #expect(try fixture.value(committed) == "")
        committed.paper.desk?.redo()
        #expect(try fixture.value(committed) == "Committed edit")

        let draft = try await fixture.pdf()
        try await fixture.start(draft)
        try fixture.draft(draft, "Uncommitted edit")
        fixture.browser.keepTabs([draft])
        let draftWitness = try fixture.witness(draft)
        fixture.browser.close(draft)
        #expect(draft.paper.desk?.document === draftWitness.document)
        #expect(draft.paper.desk?.draft == "Uncommitted edit" && draft.paper.desk?.changed == true)
        draft.paper.desk?.undo()
        #expect(draft.paper.desk?.draft == "")

        let redo = try await fixture.pdf()
        try await fixture.start(redo)
        try fixture.fill(redo, with: "Redo survives")
        redo.paper.desk?.undo()
        try #require(redo.paper.desk?.changed == false && redo.paper.desk?.undone.isEmpty == false)
        try #require(fixture.browser.pin(redo) === redo)
        let redoWitness = try fixture.witness(redo)
        fixture.browser.close(redo)
        #expect(redo.paper.desk?.document === redoWitness.document)
        #expect(redo.paper.desk?.changed == false && redo.paper.desk?.undone.isEmpty == false)
        redo.paper.desk?.redo()
        #expect(try fixture.value(redo) == "Redo survives")
        #expect(try Data(contentsOf: fixture.input) == fixture.originalBytes)
    }

    @Test func manualClosePreservesAnEmptyTextDraftAndAnOpenSignatureSheet() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let writing = try await fixture.pdf()
        try await fixture.start(writing)
        try fixture.emptyWriting(writing)
        fixture.browser.keepTabs([writing])
        let writingWitness = try fixture.witness(writing)
        fixture.browser.close(writing)
        #expect(writing.paper.desk?.document === writingWitness.document)
        #expect(writing.paper.desk?.changed == false && writing.paper.desk?.writing != nil)
        #expect(writing.paper.desk?.note == "")

        let sheet = try await fixture.pdf()
        try await fixture.start(sheet)
        sheet.paper.desk?.openSheet()
        sheet.paper.desk?.pad.name = "Unsaved signature"
        try #require(sheet.paper.desk?.changed == false && sheet.paper.desk?.sheet == true)
        try #require(fixture.browser.pin(sheet) === sheet)
        let sheetWitness = try fixture.witness(sheet)
        fixture.browser.close(sheet)
        #expect(sheet.paper.desk?.document === sheetWitness.document)
        #expect(sheet.paper.desk?.sheet == true && sheet.paper.desk?.pad.name == "Unsaved signature")
        #expect(try Data(contentsOf: fixture.input) == fixture.originalBytes)
    }

    @Test func anExternalPDFOwnerKeepsItsAnnotationsAcrossManualClose() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let source = try await fixture.pdf()
        try await fixture.start(source)
        try #require(fixture.browser.pin(source) === source)
        let document = try fixture.retainedDocument(source)
        let page = try #require(document.page(at: 0))
        let annotation = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 120, height: 30),
                                       forType: .freeText, withProperties: nil)
        annotation.contents = "External annotation"
        page.addAnnotation(annotation)
        try #require(source.paper.desk?.changed == false)
        let witness = try fixture.witness(source)
        fixture.markRest("external.before.close", witness)
        fixture.browser.close(source)
        try fixture.rested(source, pin: source.pin, kept: false, home: source.home)
        fixture.markRest("external.after.close", witness)
        #expect(witness.document === document)
        #expect(annotation.contents == "External annotation")
        #expect(page.annotations.contains { $0 === annotation })
        #expect(document.pageCount == 1)
        #expect(try Data(contentsOf: fixture.input) == fixture.originalBytes)
    }

    @Test func closingAnotherPinAndParkingASpaceKeepTheLivePDFEditor() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let live = try await fixture.pdf()
        try await fixture.start(live)
        try fixture.fill(live, with: "Live editor stays")
        let liveWitness = try fixture.witness(live)
        let other = try await fixture.pdf(selecting: false)
        try await fixture.start(other)
        try #require(fixture.browser.pin(other) === other)
        fixture.browser.close(other)
        #expect(fixture.browser.active === live && !live.asleep)
        #expect(live.paper.desk?.document === liveWitness.document)
        #expect(try fixture.value(live) == "Live editor stays")
        try fixture.emptySpace(under: live)
        #expect(fixture.browser.underTab === live && !live.gone && !live.asleep)
        #expect(live.paper.desk?.document === liveWitness.document)
        live.paper.desk?.undo()
        #expect(try fixture.value(live) == "")
        live.paper.desk?.redo()
        #expect(try fixture.value(live) == "Live editor stays")
        #expect(try Data(contentsOf: fixture.input) == fixture.originalBytes)
    }

    @Test func anOrdinaryRestKeepsItsCompletedPDFEditor() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let source = try await fixture.pdf()
        try await fixture.start(source)
        let witness = try fixture.witness(source)
        source.rest()
        #expect(source.asleep && source.built == nil && !source.gone)
        #expect(source.paper.desk != nil && witness.document != nil)
        #expect(source.paper.desk?.document === witness.document)

        let sleeping = try await fixture.pdf()
        try await fixture.start(sleeping)
        let sleepingWitness = try fixture.witness(sleeping)
        sleeping.sleep(picture: nil)
        #expect(sleeping.asleep && sleeping.built == nil && !sleeping.gone)
        #expect(sleeping.paper.desk != nil && sleepingWitness.document != nil)
        #expect(sleeping.paper.desk?.document === sleepingWitness.document)
        #expect(try Data(contentsOf: fixture.input) == fixture.originalBytes)
    }
}
