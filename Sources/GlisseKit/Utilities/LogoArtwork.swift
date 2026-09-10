//
//  LogoArtwork.swift
//  GlisseKit
//
//  The Glissé mark, drawn in code.
//
//  The idea
//  --------
//  The name's acute accent does the work. In "Glissé" the é's accent is a short
//  stroke leaning up and to the right — exactly the shape of something that has
//  just been pushed upward. So the accent becomes the *slider knob*: two vertical
//  tracks (the trackpad's two eligible edges) each carrying an accent instead of
//  the usual round handle, resting at different heights because one is brightness
//  and the other is volume.
//
//  That makes the mark say the name and the function at once, and it survives
//  being 16 pixels wide, which a literal hand or a wordmark does not.
//
//  Drawn rather than shipped as binary art so it stays reviewable, recolours for
//  light and dark, and renders crisply at any size. One implementation feeds the
//  menu bar, the About panel and the .icns file, so they cannot drift apart.
//

import AppKit
import CoreGraphics
import Foundation

public enum LogoArtwork {

    /// Everything is authored in this square and scaled from it, so proportions
    /// are identical at 16 pt and at 1024.
    private static let designSize: CGFloat = 100

    // Track geometry, in design units.
    //
    // The rails are deliberately narrow relative to the accents. First attempt
    // made them the same visual weight and the result read as two slashed bars
    // rather than two sliders — the accent has to overhang the rail to be legible
    // as a handle.
    private static let trackWidth: CGFloat = 12
    private static let trackTop: CGFloat = 88
    private static let trackBottom: CGFloat = 12
    private static let leftTrackCentre: CGFloat = 28
    private static let rightTrackCentre: CGFloat = 72

    /// Where each accent sits along its track. Deliberately unequal: two
    /// independent controls, not a decorative pair.
    private static let leftFill: CGFloat = 0.28
    private static let rightFill: CGFloat = 0.74

    // Accent geometry. Overhangs the rail by roughly a rail-width on each side.
    private static let accentLength: CGFloat = 34
    private static let accentThickness: CGFloat = 14
    /// Gap punched through the rail around each accent, so the accent reads as
    /// sitting on top of it instead of being fused into it.
    private static let accentHalo: CGFloat = 3.5
    /// Leaning up and to the right, like the accent it is taken from. Shallower
    /// than a typographic accent: at 34° the pair read as a busy "//", at 26° they
    /// read as handles that happen to be tilted.
    private static let accentAngle: CGFloat = 26 * .pi / 180

    // MARK: - Mark

    /// The bare mark. `foreground` draws the accents and the filled part of each
    /// track; the empty part of the track is drawn from the same colour at low
    /// alpha, so a single colour is enough and template images work.
    public static func drawMark(in context: CGContext,
                                size: CGFloat,
                                foreground: NSColor,
                                trackAlpha: CGFloat = 0.26) {
        let scale = size / designSize
        context.saveGState()
        context.scaleBy(x: scale, y: scale)

        // Transparency layer, and it is load-bearing.
        //
        // The halo around each accent is punched with `.destinationOut`, which
        // removes alpha. Without an isolating layer that punch goes through
        // everything already drawn — including the icon's slate — leaving actual
        // holes in the artwork. Over a dark backdrop those holes read as black
        // outlines around the knobs, which is exactly the "black border" this
        // fixes. Inside a layer the punch only affects the mark's own pixels, so
        // the gap reveals the slate instead of the page.
        context.beginTransparencyLayer(auxiliaryInfo: nil)

        // Below roughly 28 pt the rail is under 2 physical pixels and the halo gap
        // falls under one, so the whole mark turns to mush. The compact variant
        // trades refinement for weight: fatter rail, fatter accent, hairline gap.
        let compact = size < 28
        let railWidth = compact ? 16.0 : trackWidth
        let halo = compact ? 2.0 : accentHalo
        let accentSpan = compact ? 30.0 : accentLength
        let accentDepth = compact ? 17.0 : accentThickness
        let emptyAlpha = compact ? max(trackAlpha, 0.38) : trackAlpha
        let filledAlpha: CGFloat = compact ? 0.80 : 0.72

        for (centre, fill) in [(leftTrackCentre, leftFill), (rightTrackCentre, rightFill)] {
            let track = CGRect(x: centre - railWidth / 2,
                               y: trackBottom,
                               width: railWidth,
                               height: trackTop - trackBottom)
            let capsule = CGPath(roundedRect: track,
                                 cornerWidth: railWidth / 2,
                                 cornerHeight: railWidth / 2,
                                 transform: nil)

            // Empty groove.
            context.addPath(capsule)
            context.setFillColor(foreground.withAlphaComponent(emptyAlpha).cgColor)
            context.fillPath()

            // Filled portion, clipped to the capsule so the ends stay round.
            // Pushed to full strength: at low contrast the rail read as uniform
            // grey and the level was invisible.
            context.saveGState()
            context.addPath(capsule)
            context.clip()
            context.setFillColor(foreground.withAlphaComponent(filledAlpha).cgColor)
            context.fill(CGRect(x: track.minX,
                                y: track.minY,
                                width: track.width,
                                height: track.height * fill))
            context.restoreGState()

            let knobY = track.minY + track.height * fill

            func accentPath(padding: CGFloat) -> CGPath {
                let length = accentSpan + padding * 2
                let thickness = accentDepth + padding * 2
                let rect = CGRect(x: -length / 2, y: -thickness / 2,
                                  width: length, height: thickness)
                var transform = CGAffineTransform(translationX: centre, y: knobY)
                    .rotated(by: accentAngle)
                return CGPath(roundedRect: rect,
                              cornerWidth: thickness / 2,
                              cornerHeight: thickness / 2,
                              transform: &transform)
            }

            // Punch a gap through the rail first. Works on any background and in a
            // template image, because it removes alpha rather than painting over.
            context.saveGState()
            context.setBlendMode(.destinationOut)
            context.addPath(accentPath(padding: halo))
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            context.restoreGState()

            // The accent itself.
            context.addPath(accentPath(padding: 0))
            context.setFillColor(foreground.cgColor)
            context.fillPath()
        }

        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// Monochrome mark for the menu bar. Returned as a template image so macOS
    /// tints it for light, dark and highlighted states.
    public static func menuBarImage(pointSize: CGFloat = 16) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize),
                            flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            drawMark(in: context, size: pointSize, foreground: .black, trackAlpha: 0.30)
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - App icon

    /// The mark on a slate, sized for an .icns member.
    public static func appIcon(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }

            let unit = size / 1024
            let inset = 92 * unit
            let body = CGRect(x: inset, y: inset,
                              width: size - inset * 2, height: size - inset * 2)
            let corner = 200 * unit

            let slate = CGPath(roundedRect: body,
                               cornerWidth: corner, cornerHeight: corner,
                               transform: nil)

            // Slate: a cool blue-grey gradient, so the white mark carries.
            context.saveGState()
            context.addPath(slate)
            context.clip()
            let colours = [
                NSColor(calibratedRed: 0.29, green: 0.38, blue: 0.53, alpha: 1).cgColor,
                NSColor(calibratedRed: 0.09, green: 0.12, blue: 0.19, alpha: 1).cgColor,
            ] as CFArray
            if let space = CGColorSpace(name: CGColorSpace.sRGB),
               let gradient = CGGradient(colorsSpace: space, colors: colours,
                                        locations: [0, 1]) {
                context.drawLinearGradient(gradient,
                                           start: CGPoint(x: body.midX, y: body.maxY),
                                           end: CGPoint(x: body.midX, y: body.minY),
                                           options: [])
            }
            context.restoreGState()

            // Hairline rim, so the silhouette holds on a light wallpaper.
            context.saveGState()
            context.addPath(slate)
            context.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.17).cgColor)
            context.setLineWidth(6 * unit)
            context.strokePath()
            context.restoreGState()

            // Mark, inset within the slate.
            let markSize = body.width * 0.58
            context.saveGState()
            context.translateBy(x: body.midX - markSize / 2, y: body.midY - markSize / 2)
            drawMark(in: context, size: markSize, foreground: .white, trackAlpha: 0.24)
            context.restoreGState()

            return true
        }
    }

    // MARK: - Wordmark

    /// "Glissé", with the accent drawn as the mark's accent rather than the
    /// font's, so the word and the symbol are visibly the same object.
    public static func wordmark(pointSize: CGFloat, color: NSColor) -> NSImage {
        // Set "Glisse" and add our own accent above the final e.
        let base = "Glisse"
        let font = NSFont.systemFont(ofSize: pointSize, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .kern: pointSize * 0.012,
        ]
        let attributed = NSAttributedString(string: base, attributes: attributes)
        let textSize = attributed.size()

        // Room above the cap line for the accent.
        let accentHeadroom = pointSize * 0.30
        let canvas = NSSize(width: ceil(textSize.width) + pointSize * 0.10,
                            height: ceil(textSize.height + accentHeadroom))

        return NSImage(size: canvas, flipped: false) { _ in
            attributed.draw(at: NSPoint(x: 0, y: 0))

            guard let context = NSGraphicsContext.current?.cgContext else { return true }

            // Locate the final "e" so the accent lands over it rather than at a
            // guessed offset.
            let prefix = NSAttributedString(string: String(base.dropLast()),
                                            attributes: attributes)
            let lastGlyph = NSAttributedString(string: String(base.last!),
                                               attributes: attributes)
            let centreX = prefix.size().width + lastGlyph.size().width / 2
            let baselineTop = font.ascender

            let length = pointSize * 0.32
            let thickness = pointSize * 0.13

            context.saveGState()
            context.translateBy(x: centreX, y: baselineTop + accentHeadroom * 0.30)
            context.rotate(by: accentAngle)
            let accent = CGRect(x: -length / 2, y: -thickness / 2,
                                width: length, height: thickness)
            context.addPath(CGPath(roundedRect: accent,
                                   cornerWidth: thickness / 2,
                                   cornerHeight: thickness / 2,
                                   transform: nil))
            context.setFillColor(color.cgColor)
            context.fillPath()
            context.restoreGState()

            return true
        }
    }

    /// Mark beside the wordmark, for the About panel.
    public static func lockup(pointSize: CGFloat, color: NSColor) -> NSImage {
        let markSize = pointSize * 1.45
        let word = wordmark(pointSize: pointSize, color: color)
        let gap = pointSize * 0.42
        let canvas = NSSize(width: markSize + gap + word.size.width,
                            height: max(markSize, word.size.height))

        return NSImage(size: canvas, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            context.saveGState()
            context.translateBy(x: 0, y: (canvas.height - markSize) / 2)
            drawMark(in: context, size: markSize, foreground: color, trackAlpha: 0.26)
            context.restoreGState()

            word.draw(at: NSPoint(x: markSize + gap,
                                  y: (canvas.height - word.size.height) / 2),
                      from: .zero,
                      operation: .sourceOver,
                      fraction: 1)
            return true
        }
    }

    // MARK: - Icon export

    /// Sizes an .icns needs.
    public static let iconVariants: [(name: String, pixels: CGFloat)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]

    /// Writes an .iconset directory. Used by `make icon`.
    public static func exportIconSet(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        for variant in iconVariants {
            let image = appIcon(size: variant.pixels)
            guard let data = pngData(for: image, pixels: variant.pixels) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try data.write(to: directory.appendingPathComponent("\(variant.name).png"))
        }
    }

    /// Renders at an exact pixel size, bypassing the screen's backing scale.
    public static func pngData(for image: NSImage, pixels: CGFloat) -> Data? {
        let count = Int(pixels)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                        pixelsWide: count,
                                        pixelsHigh: count,
                                        bitsPerSample: 8,
                                        samplesPerPixel: 4,
                                        hasAlpha: true,
                                        isPlanar: false,
                                        colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0,
                                        bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }

    /// Renders any image at an explicit pixel size, for non-square art.
    public static func pngData(for image: NSImage, scale: CGFloat) -> Data? {
        let width = Int(image.size.width * scale)
        let height = Int(image.size.height * scale)
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                        pixelsWide: width,
                                        pixelsHigh: height,
                                        bitsPerSample: 8,
                                        samplesPerPixel: 4,
                                        hasAlpha: true,
                                        isPlanar: false,
                                        colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0,
                                        bitsPerPixel: 0) else { return nil }
        rep.size = image.size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }
}
