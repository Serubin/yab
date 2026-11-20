import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Bring In on Settings › Snippets (docs/snippets.md): a menu beside New
// Snippet… of what this Mac has (Text Replacements, Alfred, espanso) with
// how many, Raycast's exported file and any other file; while the list is
// empty the same sources stand in it with a button each. Whichever way, a
// card shows what would come in, each ticked, and Bring In keeps them.

/// What the card shows: where they come from, and each as it would come in.
struct SnippetBringing: Identifiable {
    let id = UUID()
    let source: SnippetSource
    /// Said under the title: a file's name, or where on this Mac.
    let from: String
    var found: [FoundSnippet]
}

/// The Bring In button and its menu, in the list's header.
struct SnippetBringMenu: View {
    @State private var place = DropAnchor.Place()

    var body: some View {
        Button(action: open) {
            HStack(spacing: 4) {
                Text("Bring In")
                Symbol("chevron.down", size: 8, weight: .semibold) // design: the size of DropMenu's ⌄
                    .foregroundStyle(.secondary)
            }
        }
        .settingsButton()
        // Behind the button, where the list hangs from: the button keeps
        // its presses, and the bench finds the menu by its title.
        .background(DropAnchor(place: place, title: "Bring In", press: open, hover: { _ in }))
        .settingsAnchor("snippets-bring-in")
    }

    private enum Pick { case mac(SnippetSource), superhuman, raycast, file }

    private func open() {
        guard let view = place.view, view.window != nil else { return }
        var picks: [Pick] = []
        var lines: [DropList.Line] = []
        for (source, count) in SnippetSource.found() {
            picks.append(.mac(source))
            lines.append(DropList.Line(title: source.title, picture: source.picture(), note: count == 1 ? "1 snippet" : "\(count) snippets"))
        }
        if SnippetSuperhuman.offered {
            picks.append(.superhuman)
            lines.append(DropList.Line(title: "Superhuman", picture: SnippetSource.superhuman.picture(),
                                       note: Agents.preferredName + " reads them in \(Brand.name)"))
        }
        picks.append(.raycast)
        lines.append(DropList.Line(title: "Raycast…", picture: SnippetSource.raycast.picture(), note: "The file its Export Snippets saves"))
        picks.append(.file)
        let doc = NSWorkspace.shared.icon(for: .json).copy() as! NSImage
        doc.size = NSSize(width: 16, height: 16)
        lines.append(DropList.Line(title: "From a File…", picture: doc, note: "Alfred, espanso or TextExpander"))
        let list = DropList(options: lines, chosen: 0, divideBefore: lines.count - 1, inset: DropFace.inset)
        DropPopup.show(list, under: view) { index in
            guard let index, picks.indices.contains(index) else { return }
            switch picks[index] {
            case .mac(let source): SnippetBringIn.fromThisMac(source)
            case .superhuman: SnippetSuperhuman.start()
            case .raycast: SnippetBringIn.chooseFile(raycast: true)
            case .file: SnippetBringIn.chooseFile(raycast: false)
            }
        }
    }
}

@MainActor
enum SnippetBringIn {
    static func fromThisMac(_ source: SnippetSource) {
        let found = source.onThisMac() ?? []
        guard !found.isEmpty else {
            SettingsWindow.shared.toaster.pop("No snippets in \(source.title)", mark: "exclamationmark.triangle")
            return
        }
        SnippetEditing.shared.bring(source, from: source.place, found: found)
    }

    static func chooseFile(raycast: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if raycast {
            panel.allowedContentTypes = [.json]
            panel.message = "Choose the file Raycast’s Export Snippets saved."
        } else {
            panel.allowedContentTypes = [.json, .commaSeparatedText, .plainText]
                + ["yml", "yaml"].compactMap { UTType(filenameExtension: $0) }
            panel.message = "Choose a file of snippets from Raycast, Alfred, espanso or TextExpander."
        }
        panel.prompt = "Choose"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            open(url)
        }
    }

    static func open(_ url: URL) {
        guard let read = SnippetSource.read(file: url), !read.found.isEmpty else {
            SettingsWindow.shared.toaster.pop("No snippets in that file", mark: "exclamationmark.triangle")
            return
        }
        SnippetEditing.shared.bring(read.source, from: url.lastPathComponent, found: read.found)
    }
}

/// While the list is empty: the apps on this Mac with snippets, each with
/// Bring In, and Raycast when it is here; "No snippets yet" when none is.
struct SnippetSourceRows: View {
    @State private var found: [(source: SnippetSource, count: Int)]?

    private var raycast: Bool {
        SnippetSource.raycast.app != nil
    }

    var body: some View {
        Group {
            if let found, !found.isEmpty || raycast || SnippetSuperhuman.offered {
                ForEach(Array(found.enumerated()), id: \.offset) { _, one in
                    row(one.source, detail: (one.count == 1 ? "1 snippet" : "\(one.count) snippets") + " from " + one.source.place) {
                        Button("Bring In") { SnippetBringIn.fromThisMac(one.source) }
                            .settingsButton()
                    }
                }
                if SnippetSuperhuman.offered {
                    row(.superhuman, detail: Agents.preferredName + " reads them from Superhuman in \(Brand.name)") {
                        Button("Bring In") { SnippetSuperhuman.start() }
                            .settingsButton()
                    }
                }
                if raycast {
                    row(.raycast, detail: "Import a file saved with Export Snippets.") {
                        Button("Choose File…") { SnippetBringIn.chooseFile(raycast: true) }
                            .settingsButton()
                    }
                }
            } else {
                Text("No snippets yet")
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            _ = await Shell.find()
            let read = await Task.detached(priority: .userInitiated) { SnippetSource.found() }.value
            found = read
        }
    }

    private func row(_ source: SnippetSource, detail: String, @ViewBuilder button: @escaping () -> some View) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: source.picture(20))
                .resizable()
                .frame(width: 20, height: 20)
            SettingsRow(source.title, detail: detail, trailing: button)
        }
        .settingsAnchor("snippets-source:" + source.rawValue)
    }
}

/// The card over the pane: where they come from, each found one ticked
/// with its name after ";", its words and what changed on the way in;
/// Cancel and Bring In at the foot, as every card's.
struct SnippetBringCard: View {
    @State private var found: [FoundSnippet]
    private let bringing: SnippetBringing

    init(bringing: SnippetBringing) {
        self.bringing = bringing
        _found = State(initialValue: bringing.found)
    }

    private var taking: Int { found.filter(\.take).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: CardFrame.wellGap) {
                Image(nsImage: bringing.source.picture(CardFrame.well))
                    .resizable()
                    .frame(width: CardFrame.well, height: CardFrame.well)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bring In from \(bringing.source.title)")
                        .font(CardFrame.title)
                    Text((found.count == 1 ? "1 snippet" : "\(found.count) snippets") + " · " + bringing.from)
                        .font(CardFrame.detail)
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            ThreadScrollView {
                VStack(spacing: 0) {
                    ForEach($found) { $one in
                        line($one)
                        if one.id != found.last?.id { Divider() }
                    }
                }
            }
            .scrollIndicators(.automatic)
            .padding(.top, CardFrame.inset)
            .frame(maxHeight: .infinity)
            buttons
                .padding(.top, CardFrame.buttonGap)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardFrame()
        .onExitCommand { SnippetEditing.shared.close() }
    }

    private func line(_ one: Binding<FoundSnippet>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle("", isOn: one.take)
                .toggleStyle(.checkbox)
                .labelsHidden()
            Text(";" + one.wrappedValue.name)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .frame(width: 128, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(MailSnippet(name: "", body: one.wrappedValue.body).gist)
                    .lineLimit(1)
                    .foregroundStyle(one.wrappedValue.take ? Palette.ink : Palette.muted)
                if let note = one.wrappedValue.note {
                    Text(note)
                        .font(.system(size: 11.5))
                        .foregroundStyle(one.wrappedValue.odd ? Color(nsColor: .systemOrange) : Palette.muted) // design: a note that something didn't come across
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 13))
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { one.wrappedValue.take.toggle() }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Spacer()
            Button { SnippetEditing.shared.close() } label: {
                HStack(spacing: 6) {
                    Text("Cancel")
                    KeyGlyphs(keys: "esc", size: CardFrame.words, tint: nil, rest: 0.6)
                }
            }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.yab(.secondary, CardFrame.button))
            .fixedSize()
            Button(action: bringIn) {
                HStack(spacing: 6) {
                    Text(taking == 1 ? "Bring In 1" : "Bring In \(taking)")
                    KeyGlyphs(keys: "⌘↩", size: CardFrame.words, tint: nil, rest: 0.6).transaction { $0.animation = nil }
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.yab(.primary, CardFrame.button))
            .fixedSize()
            .disabled(taking == 0)
        }
    }

    private func bringIn() {
        SnippetEditing.shared.brought(MailSnippets.shared.bringIn(found))
    }
}

/// Superhuman keeps its snippets on its servers with no export: an agent
/// opens its web app in Yab, signed in as you are there, reads Settings ›
/// Snippets without changing anything, and answers them as JSON for the
/// card. Out of sight (a sealed run); a card says it is reading meanwhile.
@MainActor
enum SnippetSuperhuman {
    static let site = URL(string: "https://mail.superhuman.com")!

    /// Where it reads: Superhuman's app, or a probe's stand-in page.
    static var home: URL {
        if Store.testing, let page = ProcessInfo.processInfo.environment["YAB_SUPERHUMAN_URL"], let url = URL(string: page) { return url }
        return site
    }

    /// Offered with an agent to ask, to someone who has Superhuman: its app
    /// on this Mac, or its web app in their history.
    static var offered: Bool {
        // Before the agents are looked for, offered on the chance; start
        // says so when there is none.
        guard Shell.cached == nil || Agents.installed else { return false }
        if Store.testing, ProcessInfo.processInfo.environment["YAB_SUPERHUMAN_URL"] != nil { return true }
        return SnippetSource.superhuman.app != nil || !History.current.pages(on: ["mail.superhuman.com"], limit: 1).isEmpty
    }

    static func prompt(_ url: URL) -> String {
        """
        Read the user's snippets from Superhuman, in \(Brand.name), to bring them into \(Brand.name)'s own snippets. Change nothing in Superhuman.
        1. Open \(url.absoluteString) in \(Brand.name): it is signed in as the user is there. If it shows only a sign-in page you can't get past with sign_in, stop and answer exactly {"error": "signin"}.
        2. Go to Superhuman's snippets: Settings, then Snippets (or ⌘K and "Snippets"). Read every snippet, scrolling and opening each one when the list shows only part of it: its name; its words exactly as written, line breaks kept and variables such as {first_name} left as they are; and To, Cc, Bcc and Subject when it has them.
        3. Never edit, send, create, share or delete anything there.
        Answer with only a JSON array, nothing before or after it: [{"name": "", "body": "", "to": "", "cc": "", "bcc": "", "subject": ""}]. [] when there are none.
        """
    }

    static func start() {
        let editing = SnippetEditing.shared
        if let under = editing.reading, under.state.live { return }
        guard Shell.cached != nil else {
            Task { @MainActor in
                _ = await Shell.find()
                if Agents.installed { start() } else { TaskLine.connect() }
            }
            return
        }
        guard Agents.installed else { TaskLine.connect(); return }
        // A probe may name the agent (its plan out of room on the farm).
        let cli = Store.testing ? ProcessInfo.processInfo.environment["YAB_SUPERHUMAN_CLI"] : nil
        let session = Agents.shared.run(prompt: prompt(home), cli: cli, access: "browser", quiet: true,
                                        name: "Superhuman snippets", sealed: true, resume: nil)
        editing.card = nil
        editing.bring = nil
        editing.reading = session
        editing.readingNow = ""
        Task { @MainActor in
            let until = Date().addingTimeInterval(600)
            while session.state.live, Date() < until {
                // The card put away: the agent stops too.
                guard editing.reading === session else { _ = Agents.shared.stop(session.id); return }
                if editing.readingNow != session.now { editing.readingNow = session.now }
                try? await Task.sleep(for: .milliseconds(300))
            }
            if session.state.live { _ = Agents.shared.stop(session.id) }
            guard editing.reading === session else { return }
            editing.reading = nil
            ended(session)
        }
    }

    /// The last run's end and answer, for the bench.
    static var last: (state: String, answer: String)?

    private static func ended(_ session: Agents.Session) {
        let toaster = SettingsWindow.shared.toaster
        let answer = session.result
        last = (session.state.rawValue, answer)
        if session.state == .done, let found = SnippetSource.superhuman(answer: answer) {
            if found.isEmpty {
                toaster.pop("No snippets in Superhuman", mark: "exclamationmark.triangle")
            } else {
                SnippetEditing.shared.bring(.superhuman, from: home.host() ?? "Superhuman", found: found)
            }
        } else if answer.contains("\"signin\"") {
            toaster.pop("Sign in to Superhuman in \(Brand.name) first", mark: "person.crop.circle.badge.exclamationmark")
        } else if session.state == .failed, let said = answer.split(whereSeparator: \.isNewline).first, !said.isEmpty, said.count < 120 {
            // The agent's own words: out of room, not signed in.
            toaster.pop(String(said), mark: "exclamationmark.triangle")
        } else if session.state != .stopped {
            toaster.pop("Couldn’t read Superhuman’s snippets", mark: "exclamationmark.triangle")
        }
    }
}

/// While the agent reads Superhuman: the card's frame with what it is
/// doing now, and Stop.
struct SnippetReadingCard: View {
    let now: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: CardFrame.wellGap) {
                Image(nsImage: SnippetSource.superhuman.picture(CardFrame.well))
                    .resizable()
                    .frame(width: CardFrame.well, height: CardFrame.well)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reading Superhuman’s snippets")
                        .font(CardFrame.title)
                    // Its own words while it has some beyond "… is working".
                    Text(now.isEmpty || now.hasSuffix(" is working") ? Agents.preferredName + " is opening Superhuman in \(Brand.name)" : now)
                        .font(CardFrame.detail)
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ProgressView()
                    .controlSize(.small)
            }
            HStack {
                Spacer()
                Button { SnippetEditing.shared.close() } label: {
                    HStack(spacing: 6) {
                        Text("Stop")
                        KeyGlyphs(keys: "esc", size: CardFrame.words, tint: nil, rest: 0.6)
                    }
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.yab(.secondary, CardFrame.button))
                .fixedSize()
            }
            .padding(.top, CardFrame.buttonGap)
        }
        .cardFrame()
        .onExitCommand { SnippetEditing.shared.close() }
    }
}
