// The disk image's window, drawn rather than exported, like the icon. The
// welcome's ground, the brand's ink, bare as the welcome's is. One icon sits
// in the middle, Open yab, which the Finder draws, its name on the
// welcome's white pill, and under it one line saying what to do. Nothing to
// drag, no arrow, no second place.
//
// When yab opens, its first window takes this one's place on the same
// ground (Sources/Fast/Arrival.swift), so the
// image's window seems to become the browser.
//
// Run by build.sh:  swift Installer/background.swift <folder>
// It writes background.png and background@2x.png; build.sh folds them into
// one background.tiff with tiffutil. The size and the icon's place are the
// ones in Installer/dmg.py and Installer/Open/Handoff.swift, change one,
// change them all.

import AppKit
import CoreImage

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

/// The window's content, in points.
let size = CGSize(width: 640, height: 400)
let ground = NSColor(srgbRed: 0x14 / 255.0, green: 0x14 / 255.0, blue: 0x14 / 255.0, alpha: 1)
/// Where the Finder writes the icon's name, its center, from the top of
/// the content, for a 128-point icon centered at y 170 and 13-point labels,
/// and the pill it sits on.
let labelY: CGFloat = 253.5
let pillSize = CGSize(width: 104, height: 28)

func draw(scale: Int) -> NSBitmapImageRep {
    let pixels = CGSize(width: size.width * CGFloat(scale), height: size.height * CGFloat(scale))
    // The ground, drawn as the picture the pill and the line go on.
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let raw = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8,
                        bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    raw.setFillColor(ground.cgColor)
    raw.fill(CGRect(origin: .zero, size: pixels))
    raw.translateBy(x: 0, y: pixels.height)
    raw.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    let unblurred = CIImage(cgImage: raw.makeImage()!).clampedToExtent()
    let blurred = unblurred.applyingGaussianBlur(sigma: 28 * Double(scale) / 2).cropped(to: CGRect(origin: .zero, size: pixels))
    let lit = CIContext(options: [.workingColorSpace: space]).createCGImage(blurred, from: blurred.extent)!

    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.cgContext.draw(lit, in: CGRect(origin: .zero, size: size))

    // The Finder writes the icon's name in black on any window with a
    // picture behind it, whatever the picture, on this ground, all but
    // invisible. So the name gets
    // the welcome's one button to sit on: a white pill where the Finder
    // writes it, and "Open yab" reads as the thing to press.
    let pill = CGRect(x: 320 - pillSize.width / 2, y: size.height - labelY - pillSize.height / 2,
                      width: pillSize.width, height: pillSize.height)
    let shape = NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.white.withAlphaComponent(0.12)
    shadow.shadowBlurRadius = 12
    shadow.shadowOffset = CGSize(width: 0, height: -4)
    shadow.set()
    NSColor.white.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: .white, ending: NSColor(white: 0.86, alpha: 1))!.draw(in: shape, angle: -90)

    // What to do, once, under it.
    func line(_ words: String, size points: CGFloat, weight: NSFont.Weight, alpha: CGFloat, y: CGFloat) {
        let base = NSFont.systemFont(ofSize: points, weight: weight)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: points) } ?? base
        let text = NSAttributedString(string: words, attributes: [
            .font: font, .foregroundColor: NSColor.white.withAlphaComponent(alpha),
        ])
        let box = text.size()
        text.draw(at: CGPoint(x: (size.width - box.width) / 2, y: size.height - y - box.height / 2))
    }
    line("Double-click. That's it.", size: 20, weight: .semibold, alpha: 0.94, y: 318)
    line("Pane moves itself into Applications and opens.", size: 13, weight: .regular, alpha: 0.5, y: 345)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (scale, name) in [(1, "background.png"), (2, "background@2x.png")] {
    try! draw(scale: scale).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}
