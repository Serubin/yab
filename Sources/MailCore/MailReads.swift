import Foundation

// Read-receipt pixels that upstream Yab users put in mail sent to this
// person: stripped before showing, so reading their mail here never reports
// an open to upstream's site.

public enum MailReads {
    /// HTML as this Mac shows it, upstream Yab's read-status pictures out,
    /// whatever Block tracking pixels says.
    public static func strip(_ html: String) -> String {
        guard html.range(of: "/o/", options: .literal) != nil else { return html }
        let host = NSRegularExpression.escapedPattern(for: "yetanotherbrowser.com")
        let pattern = "<img\\b[^>]*" + host + "/o/[A-Za-z0-9_-]{21}[AQgw]\\.gif[^>]*>"
        return html.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
    }
}
