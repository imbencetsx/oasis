import AppKit
import CoreText

// Render the installer artwork directly; no font installation is required.
guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: swift make-dmg-background.swift FONT OUTPUT")
}
let fontURL = URL(fileURLWithPath: CommandLine.arguments[1])
CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
guard let titleFont = NSFont(name: "GeistMono-Regular", size: 42),
      let bodyFont = NSFont(name: "GeistMono-Regular", size: 13),
      let smallFont = NSFont(name: "GeistMono-Regular", size: 11) else {
    fatalError("Geist Mono could not be loaded")
}
let size = NSSize(width: 720, height: 460)
// Single 2x PNG: Finder stretches one image to fill the window, so render
// at 1440x920 physical pixels for sharp Retina text. One resolution avoids
// Finder picking the 1x TIFF representation on Retina and upscaling (blur).
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 1440, pixelsHigh: 920,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Could not create installer canvas")
}
// Tell Finder this 1440x920px image covers a 720x460pt window (144dpi).
// Without this Finder treats pixels as points and shows the art at 2x zoom.
bitmap.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.cgContext.scaleBy(x: 2.0, y: 2.0)
context.cgContext.setShouldAntialias(true)
context.cgContext.interpolationQuality = CGInterpolationQuality.high
    // Light field: Finder always draws icon labels in dark text, so the art
    // stays light (iTerm2/VLC-style) to keep [oasis] and Applications readable.
    // Vertical gradient, drawn in point space (context is pre-scaled 2x).
    let top = NSColor(srgbRed: 247.0/255, green: 248.0/255, blue: 252.0/255, alpha: 1)
    let bottom = NSColor(srgbRed: 232.0/255, green: 234.0/255, blue: 242.0/255, alpha: 1)
    for row in 0..<Int(size.height) {
        let t = CGFloat(row) / size.height
        let c = NSColor(srgbRed: top.redComponent + (bottom.redComponent - top.redComponent) * t,
                        green: top.greenComponent + (bottom.greenComponent - top.greenComponent) * t,
                        blue: top.blueComponent + (bottom.blueComponent - top.blueComponent) * t,
                        alpha: 1)
        c.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: CGFloat(row), width: size.width, height: 1)).fill()
    }
    func centered(_ text: String, x: CGFloat = 360, y: CGFloat, font: NSFont, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let width = (text as NSString).size(withAttributes: attributes).width
        (text as NSString).draw(at: NSPoint(x: x - width / 2, y: y), withAttributes: attributes)
    }
    let ink = NSColor(srgbRed: 23.0/255, green: 26.0/255, blue: 44.0/255, alpha: 1)
    let muted = NSColor(srgbRed: 99.0/255, green: 105.0/255, blue: 133.0/255, alpha: 1)
    let faint = NSColor(srgbRed: 139.0/255, green: 145.0/255, blue: 170.0/255, alpha: 1)
    centered("[oasis]", y: 340, font: titleFont, color: ink)
    centered("a calmer place for the web.", y: 310, font: bodyFont, color: muted)
    // Finder places the app and Applications shortcut on either side of this arrow.
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 325, y: 225))
    arrow.line(to: NSPoint(x: 395, y: 225))
    arrow.move(to: NSPoint(x: 385, y: 235))
    arrow.line(to: NSPoint(x: 395, y: 225))
    arrow.line(to: NSPoint(x: 385, y: 215))
    arrow.lineWidth = 1.5
    muted.setStroke()
    arrow.stroke()
// NOTE: no custom "[oasis]"/"Applications" captions here on purpose.
// Finder draws those icon labels itself in dark text; baking them into
// the artwork would double-render under the real icons.
centered("drag [oasis] to Applications", y: 96, font: bodyFont, color: muted)
centered("macOS 26+", y: 42, font: smallFont, color: faint)
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode installer artwork")
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
