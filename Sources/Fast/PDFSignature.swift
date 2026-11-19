import YabStore
import AppKit
import PDFKit
import Security

// A signature for PDFs (docs/pdf-sign.md): drawn with a finger on the
// trackpad, with the mouse, or typed in a hand's font, as Preview makes
// one; kept in the keychain as a picture with nothing behind the ink, and
// put on a page as a note that draws that picture.

/// The ink of a signature: the pen's dark blue the frames draw it in.
enum SignatureInk {
    static let color = NSColor(srgbRed: 0x0B / 255.0, green: 0x2F / 255.0, blue: 0x8A / 255.0, alpha: 1)
    /// Pixels a point in the kept picture: sharp at any size a page shows it.
    static let scale: CGFloat = 3
    /// The fonts a typed name is written in, as Preview offers three.
    static let hands = ["Snell Roundhand", "Savoye LET", "Bradley Hand"]
}

/// The lines of a signature as drawn: strokes of points, each with when.
struct PenInk: Equatable {
    struct Point: Equatable {
        var x: CGFloat
        var y: CGFloat
        var t: TimeInterval
        var at: CGPoint { CGPoint(x: x, y: y) }
    }

    var strokes: [[Point]] = []

    var isEmpty: Bool { strokes.allSatisfy { $0.count < 2 } }

    mutating func begin(_ p: CGPoint, at t: TimeInterval) { strokes.append([Point(x: p.x, y: p.y, t: t)]) }

    mutating func add(_ p: CGPoint, at t: TimeInterval) {
        guard !strokes.isEmpty else { return begin(p, at: t) }
        if let last = strokes[strokes.count - 1].last, hypot(last.x - p.x, last.y - p.y) < 0.6 { return }
        strokes[strokes.count - 1].append(Point(x: p.x, y: p.y, t: t))
    }

    /// The pen's width, thinner as it goes faster, as ink on paper is.
    static func width(speed: CGFloat, base: CGFloat) -> CGFloat {
        let thin = base * 0.45
        return max(thin, min(base, base - speed * 0.0016 * base))
    }

    /// The stroke smoothed through its points (Catmull-Rom), with the
    /// pen's width at each: what is drawn, and what is kept.
    static func smooth(_ stroke: [Point], base: CGFloat, steps: Int = 6) -> [(CGPoint, CGFloat)] {
        guard stroke.count > 1 else { return stroke.map { ($0.at, base) } }
        var out: [(CGPoint, CGFloat)] = []
        var width = base
        for i in 0..<(stroke.count - 1) {
            let p0 = stroke[max(0, i - 1)].at, p1 = stroke[i].at, p2 = stroke[i + 1].at, p3 = stroke[min(stroke.count - 1, i + 2)].at
            let dt = max(0.001, stroke[i + 1].t - stroke[i].t)
            let speed = hypot(p2.x - p1.x, p2.y - p1.y) / CGFloat(dt)
            let wanted = PenInk.width(speed: speed, base: base)
            for s in 0..<steps {
                let t = CGFloat(s) / CGFloat(steps)
                let t2 = t * t, t3 = t2 * t
                let x = 0.5 * ((2 * p1.x) + (-p0.x + p2.x) * t + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3)
                let y = 0.5 * ((2 * p1.y) + (-p0.y + p2.y) * t + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3)
                width += (wanted - width) * 0.25
                out.append((CGPoint(x: x, y: y), width))
            }
        }
        out.append((stroke[stroke.count - 1].at, width))
        return out
    }

    /// Drawn into a context, in the pad's points.
    func draw(in context: CGContext, color: NSColor = SignatureInk.color, base: CGFloat = 2.6) {
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in strokes {
            let line = PenInk.smooth(stroke, base: base)
            if line.count == 1, let dot = line.first {
                context.fillEllipse(in: CGRect(x: dot.0.x - dot.1 / 2, y: dot.0.y - dot.1 / 2, width: dot.1, height: dot.1))
                continue
            }
            for i in 1..<line.count {
                context.setLineWidth((line[i - 1].1 + line[i].1) / 2)
                context.move(to: line[i - 1].0)
                context.addLine(to: line[i].0)
                context.strokePath()
            }
        }
        context.restoreGState()
    }

    /// Where the ink is, in the pad's points.
    var extent: CGRect {
        let all = strokes.flatMap { $0 }
        guard let first = all.first else { return .zero }
        var r = CGRect(origin: first.at, size: .zero)
        for p in all { r = r.union(CGRect(origin: p.at, size: .zero)) }
        return r
    }
}

/// A signature as kept and as put on a page: its picture and its size in points.
struct Signature: Equatable {
    /// "Yab Signature 1", its name in the keychain.
    var id: String
    var png: Data
    var initials = false

    var image: CGImage? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Its size in points, its picture being three pixels a point.
    var size: CGSize {
        guard let image else { return CGSize(width: 160, height: 50) }
        return CGSize(width: CGFloat(image.width) / SignatureInk.scale, height: CGFloat(image.height) / SignatureInk.scale)
    }

    /// The ink as a picture with nothing behind it, cut to the ink and a
    /// little air round it.
    static func picture(of ink: PenInk, base: CGFloat = 2.6) -> Data? {
        guard !ink.isEmpty else { return nil }
        let air = base * 2
        let extent = ink.extent.insetBy(dx: -air, dy: -air)
        return render(size: extent.size) { context in
            context.translateBy(x: -extent.minX, y: -extent.minY)
            ink.draw(in: context, base: base)
        }
    }

    /// A typed name in a hand's font, as a picture.
    static func picture(typing name: String, hand: String, size: CGFloat = 40) -> Data? {
        let words = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return nil }
        let font = NSFont(name: hand, size: size) ?? NSFont.systemFont(ofSize: size)
        let text = NSAttributedString(string: words, attributes: [.font: font, .foregroundColor: SignatureInk.color])
        let line = CTLineCreateWithAttributedString(text)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let glyphs = CTLineGetImageBounds(line, nil)
        let left = min(0, glyphs.minX), right = max(width, glyphs.maxX)
        let air = size * 0.12
        let box = CGSize(width: ceil(right - left + air * 2), height: ceil(ascent + descent + air * 2))
        return render(size: box) { context in
            context.textPosition = CGPoint(x: air - left, y: air + descent)
            CTLineDraw(line, context)
        }
    }

    private static func render(size: CGSize, _ draw: (CGContext) -> Void) -> Data? {
        let scale = SignatureInk.scale
        let width = max(1, Int(ceil(size.width * scale))), height = max(1, Int(ceil(size.height * scale)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        draw(context)
        guard let image = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    /// Where it goes in a signature box: as tall as a hand writes on such a
    /// line (two thirds of the box, at most 40 points), its shape kept,
    /// from the box's left, standing on its line.
    func fitted(in box: CGRect) -> CGRect {
        let own = size
        guard own.width > 0, own.height > 0 else { return box }
        let room = CGRect(x: box.minX + 4, y: box.minY + 2, width: box.width - 8, height: min(40, box.height * 0.66))
        let scale = min(room.height / own.height, room.width / own.width)
        let w = own.width * scale, h = own.height * scale
        return CGRect(x: room.minX, y: room.minY, width: w, height: h)
    }

    /// Its size where there is no box: about as tall as a written line.
    func standing(at point: CGPoint, height: CGFloat = 36) -> CGRect {
        let own = size
        let w = own.height > 0 ? own.width * height / own.height : 120
        return CGRect(x: point.x - w / 2, y: point.y - height / 2, width: w, height: height)
    }
}

/// A signature on a page: a note that draws its picture, and nothing of
/// the stamp's own.
final class PDFSignatureStamp: PDFAnnotation {
    var picture: CGImage?
    private(set) var png: Data?

    convenience init(_ signature: Signature, bounds: CGRect) {
        self.init(bounds: bounds, forType: .stamp, withProperties: nil)
        picture = signature.image
        png = signature.png
        contents = signature.id
        setValue("Yab", forAnnotationKey: .textLabel)
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let picture else { return }
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(picture, in: bounds)
        context.restoreGState()
    }
}

// MARK: - kept

/// Where signatures are kept: the keychain, or a test's memory.
protocol SignatureShelf: AnyObject {
    func all() -> [Signature]
    @discardableResult func keep(_ png: Data, initials: Bool) -> Signature?
    func forget(_ id: String)
}

/// The keychain, as the Wallet keeps a card: a secret per signature, named
/// "Yab Signature 1" (initials "Yab Initials 1"), this Mac only.
final class SignatureKeychain: SignatureShelf {
    static let shared = SignatureKeychain()

    private let label = Store.name
    private var service: String { Bundle.main.bundleIdentifier.map { "\(label) · signatures · \($0)" } ?? "\(label) · signatures" }

    private var mine: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrLabel as String: label]
    }

    func all() -> [Signature] {
        var query = mine
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        let status = Vault.quietly { Keychain.copyMatching(query as CFDictionary, &out) }
        guard status == errSecSuccess, let rows = out as? [[String: Any]] else { return [] }
        return rows.compactMap { row -> (Signature, Date)? in
            guard let id = row[kSecAttrAccount as String] as? String, let data = row[kSecValueData as String] as? Data else { return nil }
            let made = row[kSecAttrCreationDate as String] as? Date ?? .distantPast
            return (Signature(id: id, png: data, initials: id.hasPrefix("\(Brand.name) Initials")), made)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    @discardableResult
    func keep(_ png: Data, initials: Bool) -> Signature? {
        let stem = initials ? "\(Brand.name) Initials" : "\(Brand.name) Signature"
        let taken = Set(all().map(\.id))
        var n = 1
        while taken.contains("\(stem) \(n)") { n += 1 }
        let id = "\(stem) \(n)"
        var item = mine
        item[kSecAttrAccount as String] = id
        item[kSecValueData as String] = png
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecAttrDescription as String] = initials ? "Initials" : "Signature"
        let status = Vault.quietly { Keychain.add(item as CFDictionary, nil) }
        guard status == errSecSuccess else {
            NSLog("PDF signature: keychain add failed (%d)", status)
            return nil
        }
        return Signature(id: id, png: png, initials: initials)
    }

    func forget(_ id: String) {
        var item = mine
        item[kSecAttrAccount as String] = id
        _ = Vault.quietly { Keychain.delete(item as CFDictionary) }
    }
}

/// Signatures kept in memory only: unit tests, and a probe that must not
/// leave one in a keychain.
final class SignatureMemory: SignatureShelf {
    private var kept: [Signature] = []

    func all() -> [Signature] { kept }

    @discardableResult
    func keep(_ png: Data, initials: Bool) -> Signature? {
        let stem = initials ? "\(Brand.name) Initials" : "\(Brand.name) Signature"
        let n = kept.filter { $0.initials == initials }.count + 1
        let made = Signature(id: "\(stem) \(n)", png: png, initials: initials)
        kept.insert(made, at: 0)
        return made
    }

    func forget(_ id: String) { kept.removeAll { $0.id == id } }
}
