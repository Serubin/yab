import Foundation
import Darwin

/// Launch arguments use UserDefaults' argument domain, so LaunchServices does
/// not have to preserve an environment variable. Installed CEF builds accept
/// an explicit preference and with none are on Chromium: Auto, for a new
/// install and for an update from a WebKit-only version alike. Environment
/// overrides stay development-only.
enum PageEngineSelection {
    static let key = "YabPageEngine"

    static var supportsChromium: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    static var bundledChromium: Bool {
        #if arch(arm64)
        let root = Bundle.main.bundleURL.appendingPathComponent("Contents")
        return FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("MacOS/PaneCore").path)
            && FileManager.default.fileExists(atPath: root.appendingPathComponent("Frameworks/Chromium Embedded Framework.framework").path)
        #else
        return false
        #endif
    }

    @MainActor static func record(_ kind: PageEngineKind) {
        guard Store.testing,
              let path = UserDefaults.standard.string(forKey: "YabParityTrace")
                ?? ProcessInfo.processInfo.environment["YAB_PARITY_TRACE"] else { return }
        let row = "{\"engine\":\"\(kind.rawValue)\",\"pid\":\(ProcessInfo.processInfo.processIdentifier)}\n"
        let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        row.withCString { pointer in _ = write(descriptor, pointer, strlen(pointer)) }
    }

    static func requested(defaults: String?, environment: String?, permitted: Bool,
                          bundledChromium: Bool = false,
                          supportsChromium: Bool = Self.supportsChromium) -> PageEngineKind? {
        guard permitted || bundledChromium else { return nil }
        let choice = [defaults, permitted ? environment : nil].compactMap { value in
            value.flatMap(PageEngineKind.init(rawValue:))
        }.first
        // Refuse the hidden opt-in even in development/test worlds on Intel
        // (including an Intel slice running under Rosetta). Never launch an
        // arm64-only helper from an unsupported app slice.
        if choice == .chromium, !supportsChromium { return .webKit }
        return choice ?? (bundledChromium && supportsChromium ? .chromium : nil)
    }
}
