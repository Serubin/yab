import SwiftUI
// The mail engine is a module of its own (Sources/MailCore), and with it
// YabStore (Store, SQLiteConnection): every file here sees both through
// this one import.
@_exported import MailCore

// Where the app meets the mail engine: what of an engine type speaks the
// app's language, its keys, its questions, SwiftUI's colors, the field's
// rows, kept here, so the engine knows none of them.

extension MailInvite.Answer {
    /// Its key (Keymap's Mail group).
    var action: Shortcut.Action {
        switch self {
        case .accepted: return .mailAccept
        case .tentative: return .mailMaybe
        case .declined: return .mailDecline
        }
    }
}

extension MailRich.Mark {
    var action: Shortcut.Action {
        switch self {
        case .bold: return .mailBold
        case .italic: return .mailItalic
        case .underline: return .mailUnderline
        case .bullets: return .mailBullets
        case .numbers: return .mailNumbers
        case .quote: return .mailQuote
        }
    }
}

extension MailClient {
    /// Before Google's page, while it still warns about Yab: a question
    /// saying so, and the two presses that get past it. Cancel, and nothing
    /// is opened.
    @MainActor
    static func warnFirst(place: Question.Place = .page) async -> Bool {
        guard let question = warning(place: place) else { return true }
        return await Questions.shared.ask(question)
    }

    /// What warnFirst asks while Google reviews Yab; nothing once it has
    /// approved it.
    static func warning(underReview: Bool = MailClient.underReview, place: Question.Place = .page) -> Question? {
        guard underReview else { return nil }
        return Question(
            title: "Google will warn you first",
            detail: "Google is still reviewing \(Brand.name) Mail, so its page says it hasn't verified \(Brand.name). That's expected, and your mail stays on this Mac.",
            lines: ["Press Advanced", "Then Go to \(Brand.name) (unsafe)"],
            lineGlyph: "arrow.right",
            glyph: "envelope", yes: "Continue to Google", place: place)
    }
}

@MainActor
extension MailSlots {
    /// What the calendar said when ⇧⌘A last asked: when, and what is busy
    /// over the next two weeks (nil: no calendar could be read).
    static var kept: (at: Date, busy: [BusyTime]?)?
    private static var reading = false

    /// The calendar read for the field's rows, a minute at most old; the
    /// rows come again once it is.
    static func read() {
        if let kept, Date().timeIntervalSince(kept.at) < 60 { return refresh() }
        guard !reading else { return }
        reading = true
        let now = Date()
        Task { @MainActor in
            let busy = await Meetings.shared.busy(from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(14 * 86_400))
            kept = (Date(), busy)
            reading = false
            refresh()
        }
    }

    /// The field's rows again, while they are the slots.
    private static func refresh() {
        guard let browser = MailDesk.shared.browser, browser.query.place == .mail, browser.query.stock.mail?.mode == .slots else { return }
        browser.query.stock.version += 1
        browser.replaceTyped(browser.typed)
    }
}

extension MailHTML {
    /// The same in a mail's own words, as the letter writes text mail: each
    /// promise lit, its spaces and line ends however the mail has them.
    static func litText(_ text: String, promised quotes: [String]) -> AttributedString {
        var out = AttributedString(text)
        for quote in quotes where !quote.isEmpty {
            let plain = quote.replacingOccurrences(of: "\u{2019}", with: "'")
            let words = plain.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
            guard !words.isEmpty else { continue }
            let pattern = words.joined(separator: "\\s+").replacingOccurrences(of: "'", with: "['\u{2019}]")
            guard let found = text.range(of: pattern, options: .regularExpression), let range = Range(found, in: out) else { continue }
            out[range].backgroundColor = Color.accentColor.opacity(0.18)
        }
        return out
    }
}
