import AppKit

// Yab's spaces and their tabs as places to bring in, read from private copies of its session files.

extension YabBrowser {
    static let spacesFile = "spaces.json"
    static let firstSessionFile = "session.json"
    static let sharedPinsFile = "session-00000000-0000-0000-0000-000000000A11.json"

    /// Only the fields brought in, so a Yab whose files have grown since still decodes.
    private struct SpaceRecord: Decodable {
        struct Paint: Decodable {
            var swatch: String?
            var color: String?
            var grain: Bool?
            var grainAmount: Double?
            var colors: [String]?

            /// The color worn: a preset swatch's own, or the custom one.
            var worn: String? {
                guard let swatch = swatch.flatMap(Swatch.init(rawValue:)), swatch != .custom,
                      let custom = color.flatMap(NSColor.init(hex:)) ?? NSColor(hex: "FFFFFF") else { return color }
                return swatch.color(dark: false, custom: custom).usingColorSpace(.sRGB)?.hex ?? color
            }
            /// Older files say only whether grain was on.
            var amount: Double? { grainAmount ?? grain.map { $0 ? Grain.standard : 0 } }
        }
        var id: UUID
        var name: String
        var icon: String?
        var ownSignIns: Bool?
        var paint: Paint?
    }

    private struct RowRecord: Decodable {
        struct Step: Decodable { var name: String }
        struct Entry: Decodable {
            var url: String
            var title: String?
            var pin: String?
            var name: String?
            var kept: Bool?
            var folderName: String?
            var folderPath: [Step]?
        }
        var tabs: [Entry]
    }

    /// Each of Yab's spaces as a place: its pins, its kept tabs in their folders and
    /// its open tabs. The pins in every space go to the first; a space signed in
    /// on its own keeps its own pins, as it does in Yab. Nil when a file is refused
    /// or doesn't decode; empty when Yab has no tabs.
    static func tabPlaces(in source: Source) -> [TabImport.Place]? {
        let spaces: [SpaceRecord]?
        switch decoded([SpaceRecord].self, from: spacesFile, in: source) {
        case .missing: spaces = nil
        case .refused: return nil
        case .found(let list): spaces = list
        }
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        // Without spaces.json, spaces were never turned on: one row, the first space's.
        let order = spaces ?? [SpaceRecord(id: first, name: "", icon: nil, ownSignIns: nil, paint: nil)]
        var places: [TabImport.Place] = []
        for space in order {
            let file = space.id == first ? firstSessionFile : "session-\(space.id.uuidString).json"
            let row: RowRecord?
            switch decoded(RowRecord.self, from: file, in: source) {
            case .missing: row = nil
            case .refused: return nil
            case .found(let found): row = found
            }
            var place = TabImport.Place(id: "Yab:\(space.id.uuidString)", name: space.name, emoji: space.icon,
                                        color: space.paint?.worn, grain: space.paint?.amount, colors: space.paint?.colors ?? [],
                                        profile: "Default", shared: space.ownSignIns != true, pinned: [], open: [])
            sort(row?.tabs ?? [], into: &place)
            places.append(place)
        }
        if case .found(let shared) = decoded(RowRecord.self, from: sharedPinsFile, in: source), !places.isEmpty {
            var extra = TabImport.Place(id: "", name: "", profile: "Default", shared: true, pinned: [], open: [])
            sort(shared.tabs, into: &extra)
            places[0].pinned = extra.pinned + extra.kept + places[0].pinned
            places[0].left += extra.left
        }
        return places
    }

    private enum Decoded<T> {
        case missing
        case refused
        case found(T)
    }

    private static func decoded<T: Decodable>(_ type: T.Type, from name: String, in source: Source) -> Decoded<T> {
        withCopy(of: name, in: source) { read -> Decoded<T> in
            switch read {
            case .missing: return .missing
            case .refused: return .refused
            case .copied(let copy):
                guard let data = try? Data(contentsOf: copy), let value = try? JSONDecoder().decode(type, from: data) else { return .refused }
                return .found(value)
            }
        }
    }

    /// Pins, kept tabs and open tabs, web pages only; the rest counted as left.
    private static func sort(_ tabs: [RowRecord.Entry], into place: inout TabImport.Place) {
        for tab in tabs {
            guard let url = URL(string: tab.url), url.scheme == "https" || url.scheme == "http" else {
                place.left += 1
                continue
            }
            var entry = TabImport.Entry(url: url, title: tab.title ?? "", name: tab.name)
            if tab.pin != nil {
                place.pinned.append(entry)
            } else if tab.kept == true {
                let steps = (tab.folderPath ?? []).map(\.name) + [tab.folderName].compactMap { $0 }
                entry.folder = steps.isEmpty ? nil : steps.joined(separator: " › ")
                entry.path = steps.count > 1 ? steps : nil
                place.kept.append(entry)
            } else {
                place.open.append(entry)
            }
        }
    }
}
