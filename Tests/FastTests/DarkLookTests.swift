import AppKit
import SwiftUI
import Testing
import SyncKit
@testable import Fast

/// A look's dark colors picked apart from its light ones: worn by a dark
/// window, kept with the space and the window's defaults, and nil for a
/// look that never picked them, which deepens the light ones as before.
@MainActor @Suite(.serialized)
struct DarkLookTests {
    private static let sky = SpacePaint(swatch: .custom, color: NSColor(hex: "8DB6E6")!, grain: 0.3, colors: ["B6A6E6"])
    private static let night = SpacePaint.Dark(color: NSColor(hex: "1D2B3A")!, colors: [NSColor(hex: "2E274C")!])

    @Test func withoutDarkColorsTheLightOnesDeepen() throws {
        let paint = Self.sky
        #expect(paint.dark == nil)
        #expect(paint.color(dark: true).hex == NSColor(hex: "8DB6E6")!.deepened.hex)
        #expect(paint.linked(dark: true).map(\.hex) == [NSColor(hex: "B6A6E6")!.deepened.hex])
        #expect(paint.darkWorn == SpacePaint.Dark(color: paint.color(dark: true), colors: paint.linked(dark: true)))
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(paint)) as? [String: Any]
        #expect(object?["dark"] == nil)
    }

    @Test func darkColorsAreWornAsPicked() throws {
        var paint = Self.sky
        paint.dark = Self.night
        #expect(paint.color(dark: false).hex == "8DB6E6")
        #expect(paint.linked(dark: false).map(\.hex) == ["B6A6E6"])
        #expect(paint.color(dark: true).hex == "1D2B3A")
        #expect(paint.linked(dark: true).map(\.hex) == ["2E274C"])
        #expect(paint.darkWorn == Self.night)
        let restored = try JSONDecoder().decode(SpacePaint.self, from: JSONEncoder().encode(paint))
        #expect(restored == paint)
    }

    /// A dark color that doesn't read loses only itself, never the space's look.
    @Test func unreadableDarkColorKeepsTheRest() throws {
        let data = Data(#"{"swatch":"custom","color":"8DB6E6","grain":true,"grainAmount":0.3,"dark":{"color":"nope"}}"#.utf8)
        let decoded = try JSONDecoder().decode(SpacePaint.self, from: data)
        #expect(decoded.dark == nil && decoded.color == "8DB6E6" && decoded.grain == 0.3)
        let extra = Data(#"{"swatch":"custom","color":"8DB6E6","grain":false,"dark":{"color":"101010","colors":["zz","202020","303030","404040"]}}"#.utf8)
        #expect(try JSONDecoder().decode(SpacePaint.self, from: extra).dark?.colors == ["202020", "303030"])
    }

    @Test func noColorFollowsBothAgain() {
        var paint = Self.sky
        paint.dark = Self.night
        paint.wearPlain()
        #expect(paint.dark == nil && paint.color(dark: true).hex == "0F0F0F")
    }

    @Test func wornThroughPreferencesAndKept() throws {
        let keys = Store.settings.dictionaryRepresentation().keys.filter { $0.hasPrefix("backdrop") }
        let saved = Store.settings.dictionaryRepresentation().filter { $0.key.hasPrefix("backdrop") }
        defer {
            for key in Store.settings.dictionaryRepresentation().keys where key.hasPrefix("backdrop") && !keys.contains(key) {
                Store.settings.removeObject(forKey: key)
            }
            for (key, value) in saved { Store.settings.set(value, forKey: key) }
        }
        let prefs = Preferences()
        var paint = Self.sky
        paint.dark = Self.night
        paint.wear(prefs)
        #expect(prefs.lookDark == Self.night)
        #expect(prefs.lookColor(dark: true).hex == "1D2B3A")
        #expect(SpacePaint(prefs).dark == Self.night)
        #expect(Preferences().lookDark == Self.night)
        prefs.lookDark = nil
        #expect(Store.settings.object(forKey: "backdrop.dark") == nil)
        #expect(prefs.lookColor(dark: true).hex == prefs.swatch.color(dark: true, custom: prefs.backdropColor).hex)
    }

    /// The editor's Dark tab: it shows the dark colors as worn, and a change
    /// makes them the look's own, leaving the light ones alone.
    @Test func darkFieldsWriteTheDarkColorsOnly() throws {
        final class Held { var paint: SpacePaint; init(_ paint: SpacePaint) { self.paint = paint } }
        let held = Held(Self.sky)
        let look = LookFields.paint(Binding(get: { held.paint }, set: { held.paint = $0 }))
        let dark = try #require(look.dark)
        let fields = look.darkened(dark)
        #expect(fields.color.wrappedValue.hex == held.paint.color(dark: true).hex)
        #expect(fields.plain == nil)
        fields.color.wrappedValue = NSColor(hex: "222831")!
        #expect(held.paint.dark?.color == "222831")
        #expect(held.paint.dark?.colors == [NSColor(hex: "B6A6E6")!.deepened.hex])
        #expect(held.paint.color == "8DB6E6" && held.paint.colors == ["B6A6E6"])
        fields.colors.wrappedValue = []
        #expect(held.paint.dark?.colors == [] && held.paint.colors == ["B6A6E6"])
        dark.wrappedValue = nil
        #expect(held.paint.color(dark: true).hex == NSColor(hex: "8DB6E6")!.deepened.hex)
    }

    /// The card's Light or Dark tab is worn on a space that goes with
    /// Appearance, never on one held light or dark, and is never kept.
    @Test func cardTabIsWornNotKept() {
        #expect(Preferences.worn(mode: "", preview: .light) == "light")
        #expect(Preferences.worn(mode: "", preview: nil) == "")
        #expect(Preferences.worn(mode: "dark", preview: .light) == "dark")
        let prefs = Preferences()
        let mode = prefs.lookMode
        defer { prefs.lookMode = mode; prefs.lookPreview = nil }
        prefs.lookMode = ""
        prefs.lookPreview = .light
        #expect(SpacePaint.worn(prefs).mode == "light")
        #expect(SpacePaint(prefs).mode == "")
        #expect(Store.settings.string(forKey: "backdrop.mode") == "")
    }

    /// A space's dark colors travel in its paint record, which the iPhone keeps whole.
    @Test func spaceDarkColorsSync() throws {
        var paint = Self.sky
        paint.dark = Self.night
        let space = Space(id: UUID(), name: "Night", icon: "🌙", ownSignIns: false, paint: paint)
        let fields = try #require(SyncShapes.spaces([space], orders: [:])[space.id.uuidString])
        var record = SyncKit.Record(collection: SyncCollection.space, id: space.id.uuidString)
        record.update(to: fields, clock: Clock(device: "second-mac", now: { 10 }))
        let back = try #require(SyncShapes.spaces(from: [record]).first)
        #expect(back.paint?.dark == Self.night)
        let phone = try #require(SyncSpace(record))
        #expect(phone.paint?.raw.object?["dark"] != nil)
    }

    /// Only a space's paint record syncs; the window's dark default stays on this Mac.
    @Test func windowDarkDefaultStaysLocal() {
        #expect(SyncShapes.localSpaceKeys.contains("backdrop.dark"))
        #expect(!SyncShapes.syncs("backdrop.dark"))
    }
}
