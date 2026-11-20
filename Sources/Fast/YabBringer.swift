import SwiftUI

/// Settings' row for an upstream Yab install: its bookmarks and history
/// brought in from copies of its files; passwords come by Yab's own CSV.
struct YabBringer: View {
    @ObservedObject var browser: Browser
    let anchor: String

    private enum Stage: Equatable {
        case counting
        case idle
        case bringing(String)
        case said(String)
    }
    @State private var stage: Stage = .counting
    @State private var sources: [YabBrowser.Source] = []

    /// Where Yab keeps its export, for the row and the panel that picks the file.
    static let passwordsHow = "The CSV from Yab: Settings › Passwords, then Export Passwords…"

    var body: some View {
        if !sources.isEmpty || stage == .counting {
            SettingsRow("Bring in from Yab", detail: detail) { button }
                .settingsAnchor(anchor)
                .task { find() }
        }
    }

    @ViewBuilder
    private var button: some View {
        switch stage {
        case .bringing:
            ProgressView().controlSize(.small)
        default:
            Menu("Bring In") {
                if sources.count > 1 {
                    Button("All Browsers") { bring(sources) }
                    Divider()
                }
                ForEach(sources) { source in
                    Button(source.name) { bring([source]) }
                }
            }
            .settingsButton()
            .fixedSize()
            .disabled(sources.isEmpty)
        }
    }

    private var detail: String {
        switch stage {
        case .counting, .idle:
            return "Bookmarks and history. For passwords, export them in Yab (Settings › Passwords › Export Passwords…) and choose Yab under Bring passwords in."
        case .bringing(let name):
            return "Reading \(name)’s bookmarks and history…"
        case .said(let text):
            return text
        }
    }

    private func find() {
        DispatchQueue.global(qos: .userInitiated).async {
            let found = YabBrowser.installed()
            DispatchQueue.main.async {
                sources = found
                if stage == .counting { stage = .idle }
            }
        }
    }

    /// Each install's bookmarks and then its history, in turn, then one line for all of it.
    private func bring(_ picked: [YabBrowser.Source]) {
        var queue = picked
        var marks = 0
        var places = 0
        var unread: [String] = []
        func next() {
            guard !queue.isEmpty else {
                let names = picked.map(\.name).joined(separator: " and ")
                let line = FirefoxBringer.line(bookmarks: marks, places: places, from: names)
                stage = .said(unread.isEmpty ? line : (unread.joined(separator: " ") + " " + line))
                return
            }
            let source = queue.removeFirst()
            stage = .bringing(source.name)
            browser.takeBookmarks(from: source, quiet: true) { added in
                if let added { marks += added } else { unread.append("Couldn't read \(source.name)'s bookmarks.") }
                browser.takePlaces(from: source) { count in
                    if let count { places += count } else { unread.append("Couldn't read \(source.name)'s history.") }
                    next()
                }
            }
        }
        next()
    }
}
