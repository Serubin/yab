import Foundation

/// The artwork shared by the Mac and iPhone. Stored identifiers and native
/// alternate names stay stable when an icon's name or place changes.
public enum AppIconCatalog: String, CaseIterable, Identifiable, Sendable {
    case flat = "07-flat"
    case original
    case paneSolo = "pane-solo"
    case paneTwoPills = "pane-two-pills"
    case paneInverse = "pane-inverse"
    case paneMidnight = "pane-midnight"
    case paneOldFriend = "pane-old-friend"
    case watercolorGlass = "08-watercolor-glass"
    case opal = "01-prismatic-frost"
    case chrome = "02-liquid-mercury"
    case amber = "04-prism-spectral"
    case redEnamel = "06-ember"
    case pumpkin = "16-halloween-pumpkin"
    case ghost = "17-halloween-ghost"
    case mummy = "18-halloween-mummy"
    case witch = "19-halloween-witch"
    case waxSeal = "11-wax-seal"
    case bracelet = "12-friendship-bracelet"
    case ticket = "13-golden-ticket"
    case yearbook = "14-yearbook"
    case arcade = "15-arcade"
    case firstEdition = "20-first-edition"
    case charm

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .flat: "Flat"
        case .original: "Default"
        case .paneSolo: "Solo"
        case .paneTwoPills: "Two Pills"
        case .paneInverse: "Inverse"
        case .paneMidnight: "Midnight"
        case .paneOldFriend: "Old Friend"
        case .watercolorGlass: "Watercolor Glass"
        case .opal: "Opal"
        case .chrome: "Smoked Chrome"
        case .amber: "Amber"
        case .redEnamel: "Red Enamel"
        case .pumpkin: "Pumpkin"
        case .ghost: "Ghost"
        case .mummy: "Mummy"
        case .witch: "Witch"
        case .waxSeal: "Wax Seal"
        case .bracelet: "Friendship Bracelet"
        case .ticket: "Golden Ticket"
        case .yearbook: "Yearbook"
        case .arcade: "Arcade"
        case .firstEdition: "First Edition"
        case .charm: "Best Friends"
        }
    }

    /// Flat is the iPhone's primary icon; nil asks UIKit to restore it.
    public var alternateName: String? {
        switch self {
        case .flat: nil
        case .original: "YabOriginal"
        case .paneSolo: "PaneSolo"
        case .paneTwoPills: "PaneTwoPills"
        case .paneInverse: "PaneInverse"
        case .paneMidnight: "PaneMidnight"
        case .paneOldFriend: "PaneOldFriend"
        case .watercolorGlass: "YabWatercolorGlass"
        case .opal: "YabOpal"
        case .chrome: "YabSmokedChrome"
        case .amber: "YabAmber"
        case .redEnamel: "YabRedEnamel"
        case .pumpkin: "YabPumpkin"
        case .ghost: "YabGhost"
        case .mummy: "YabMummy"
        case .witch: "YabWitch"
        case .waxSeal: "YabWaxSeal"
        case .bracelet: "YabFriendshipBracelet"
        case .ticket: "YabGoldenTicket"
        case .yearbook: "YabYearbook"
        case .arcade: "YabArcade"
        case .firstEdition: "YabFirstEdition"
        case .charm: "YabCharm"
        }
    }

    public var previewName: String {
        switch self {
        case .flat: "AppIconPreview.flat"
        case .original: "AppIconPreview.original"
        case .paneSolo: "AppIconPreview.solo"
        case .paneTwoPills: "AppIconPreview.twoPills"
        case .paneInverse: "AppIconPreview.inverse"
        case .paneMidnight: "AppIconPreview.midnight"
        case .paneOldFriend: "AppIconPreview.oldFriend"
        case .watercolorGlass: "AppIconPreview.watercolorGlass"
        case .opal: "AppIconPreview.opal"
        case .chrome: "AppIconPreview.smokedChrome"
        case .amber: "AppIconPreview.amber"
        case .redEnamel: "AppIconPreview.redEnamel"
        case .pumpkin: "AppIconPreview.pumpkin"
        case .ghost: "AppIconPreview.ghost"
        case .mummy: "AppIconPreview.mummy"
        case .witch: "AppIconPreview.witch"
        case .waxSeal: "AppIconPreview.waxSeal"
        case .bracelet: "AppIconPreview.bracelet"
        case .ticket: "AppIconPreview.ticket"
        case .yearbook: "AppIconPreview.yearbook"
        case .arcade: "AppIconPreview.arcade"
        case .firstEdition: "AppIconPreview.firstEdition"
        case .charm: "AppIconPreview.charm"
        }
    }

    /// Repository source, including the Icon Composer documents that own
    /// Flat and First Edition's layer placement.
    public var artworkPath: String {
        switch self {
        case .original: "Icon/pane.icon"
        case .paneSolo: "Icon/PaneAlternates/pane-solo.icon"
        case .paneTwoPills: "Icon/PaneAlternates/pane-two-pills.icon"
        case .paneInverse: "Icon/PaneAlternates/pane-inverse.icon"
        case .paneMidnight: "Icon/PaneAlternates/pane-midnight.icon"
        case .paneOldFriend: "Icon/PaneAlternates/pane-old-friend.icon"
        case .flat: "Icon/Alternates/07-flat.icon"
        case .watercolorGlass: "Icon/Alternates/08-watercolor-glass.png"
        case .opal: "Icon/Alternates/01-prismatic-frost.png"
        case .chrome: "Icon/Alternates/02-liquid-mercury.png"
        case .amber: "Icon/Alternates/04-prism-spectral.png"
        case .redEnamel: "Icon/Alternates/06-ember.png"
        case .pumpkin: "Icon/Alternates/16-halloween-pumpkin.png"
        case .ghost: "Icon/Alternates/17-halloween-ghost.png"
        case .mummy: "Icon/Alternates/18-halloween-mummy.png"
        case .witch: "Icon/Alternates/19-halloween-witch.png"
        case .waxSeal: "Icon/Alternates/11-wax-seal.png"
        case .bracelet: "Icon/Alternates/12-friendship-bracelet.png"
        case .ticket: "Icon/Alternates/13-golden-ticket.png"
        case .yearbook: "Icon/Alternates/14-yearbook.png"
        case .arcade: "Icon/Alternates/15-arcade.png"
        case .firstEdition: "Icon/Alternates/20-first-edition.icon"
        case .charm: "Icon/Alternates/90-charm-ground.png"
        }
    }

    public var halloween: Bool {
        switch self {
        case .pumpkin, .ghost, .mummy, .witch: true
        default: false
        }
    }

    public var friendCount: Int? {
        switch self {
        case .waxSeal: 1
        case .bracelet: 3
        case .ticket: 7
        case .yearbook: 10
        default: nil
        }
    }

    public var isReward: Bool {
        switch self {
        case .chrome, .amber, .redEnamel, .waxSeal, .bracelet, .ticket, .yearbook, .arcade, .firstEdition, .charm: true
        default: false
        }
    }

    /// The left half is yours; silver is the right half before a friend chooses.
    public static let charmColors = ["mint", "lilac", "sky", "rose", "coral", "lemon", "indigo"]

    private static func charmPair(left: String, right: String?) -> (String, String) {
        let left = charmColors.contains(left) ? left : "mint"
        let right = right.map { charmColors.contains($0) || $0 == "silver" ? $0 : "mint" } ?? "silver"
        return (left, right)
    }

    /// iOS changes these prepared, together-state icons only on an explicit choice.
    public static func charmAlternateName(left: String, right: String?) -> String {
        let (left, right) = charmPair(left: left, right: right)
        if left == "mint", right == "silver" { return "YabCharm" }
        return "YabCharm_\(left)_\(right)"
    }

    public static func charmPreviewName(left: String, right: String?) -> String {
        let (left, right) = charmPair(left: left, right: right)
        if left == "mint", right == "silver" { return "AppIconPreview.charm" }
        return "AppIconPreview.charm.\(left).\(right)"
    }

    public static var charmAlternates: [String] {
        charmColors.flatMap { left in
            (charmColors + ["silver"]).map { right in charmAlternateName(left: left, right: right) }
        }
    }

    public static let grantPrefix = "appearance.appIcon.unlocked."
    public var grantKey: String { Self.grantPrefix + rawValue }

    /// The first moment the seasonal icons leave, in the person's calendar.
    public static func halloweenEnd(using calendar: Calendar = .current) -> Date {
        var day = DateComponents()
        day.year = 2026
        day.month = 11
        day.day = 3
        return calendar.date(from: day) ?? .distantPast
    }

    public static func halloweenAvailable(at date: Date) -> Bool {
        date < halloweenEnd()
    }

    public static func validReceipt(_ value: String?) -> Bool {
        guard let value, value.count == 64 else { return false }
        return value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
