import AppKit

/// A factory advertises only engines it can actually construct. A restored
/// choice unavailable in this build falls back to WebKit without starting it.
@MainActor
struct PageEngineFactory {
    let kinds: Set<PageEngineKind>
    let make: @MainActor (Tab, PageEngineKind) -> any PageHandle
    let sites: SiteEngineSettings
    let followsGlobalSelection: Bool

    init(kinds: Set<PageEngineKind>, sites: SiteEngineSettings? = nil, followsGlobalSelection: Bool = false,
         make: @escaping @MainActor (Tab, PageEngineKind) -> any PageHandle) {
        self.kinds = kinds
        self.sites = sites ?? .shared
        self.followsGlobalSelection = followsGlobalSelection
        self.make = make
    }

    static var requestedEngine: PageEngineKind? {
        PageEngineSelection.requested(defaults: Store.settings.string(forKey: PageEngineSelection.key),
                                      environment: PageEngineSelection.environment,
                                      permitted: Store.development || Store.testing,
                                      bundledChromium: PageEngineSelection.bundledChromium)
    }

    static var chromiumEnabled: Bool { requestedEngine == .chromium }

    /// Payload capability is independent of the global default. A persisted
    /// site override and a native adopted tab must still work under WebKit.
    static var chromiumAvailable: Bool {
        PageEngineSelection.supportsChromium && (PageEngineSelection.bundledChromium || chromiumEnabled)
    }

    static var standard: PageEngineFactory {
        EngineSwitchGlobal.install()
        return PageEngineFactory(kinds: chromiumAvailable ? [.webKit, .chromium] : [.webKit], followsGlobalSelection: true) { tab, kind in
            PageEngineSelection.record(kind)
            if kind == .chromium { return ChromiumPage(tab: tab) }
            return tab.buildWebKitPage()
        }
    }

    func resolved(_ kind: PageEngineKind) -> PageEngineKind {
        kinds.contains(kind) ? kind : .webKit
    }
}

/// The current committed entry, independent of an engine's back-stack token.
struct PageHistoryEntry: Equatable, Codable, Sendable {
    var url: URL
    var title: String
}

/// Copied colors can travel with an out-of-process engine's state events.
struct PageColor: Equatable, Codable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double
}

/// State reads are local mirrors. An engine never waits on its process to
/// answer a UI read, and neither WebKit values nor engine objects cross here.
enum PageStateChange: Equatable, Codable, Sendable {
    case title(String?)
    case url(URL?)
    case loading(Bool)
    case back(Bool)
    case forward(Bool)
    case theme(PageColor?)
    case underPage(PageColor?)
    case camera(PageMediaState)
    case microphone(PageMediaState)
    case screen(PageMediaState)
    case fullscreen(Bool)
}

@MainActor
protocol PageStateEvents: AnyObject {
    func page(_ page: any PageHandle, changed state: PageStateChange)
}
