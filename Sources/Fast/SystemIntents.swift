import AppIntents
import Foundation

/// Actions for the macOS Shortcuts app. The app's URL and window handoff
/// already handles calls made before its first browser window exists.
struct OpenPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Page in Pane"
    static let description = IntentDescription("Open a web address in Pane.")
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Web Address") var address: URL

    func perform() async throws -> some IntentResult {
        guard Bookmark.keepable(address) else { throw OpenPageError.invalidAddress }
        await MainActor.run { Links.take(address) }
        return .result()
    }
}

private enum OpenPageError: Error, LocalizedError {
    case invalidAddress
    var errorDescription: String? { "Enter an HTTP or HTTPS web address." }
}

struct NewTabIntent: AppIntent {
    static let title: LocalizedStringResource = "New Tab in Pane"
    static let description = IntentDescription("Open a new tab in Pane.")
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult {
        await MainActor.run { Links.requestNewTab() }
        return .result()
    }
}
