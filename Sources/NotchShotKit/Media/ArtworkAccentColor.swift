import AppKit

/// Picks a bright, saturated accent from album artwork for use on the black
/// notch surface. Work is intentionally tiny and runs only when artwork changes.
@MainActor
enum ArtworkAccentColor {
    static let fallback = NSColor.white

    static func extract(from image: NSImage?) -> NSColor {
        guard let image,
              image.size.width > 0,
              image.size.height > 0,
              let bitmap = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: 12,
                  pixelsHigh: 12,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              ),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return fallback
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.imageInterpolation = .high
        image.draw(
            in: CGRect(x: 0, y: 0, width: 12, height: 12),
            from: CGRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1
        )
        graphics.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        struct HueBucket {
            var score = 0.0
            var red = 0.0
            var green = 0.0
            var blue = 0.0
            var weight = 0.0
        }

        var buckets = Array(repeating: HueBucket(), count: 12)
        for y in 0..<12 {
            for x in 0..<12 {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                var hue: CGFloat = 0
                var saturation: CGFloat = 0
                var brightness: CGFloat = 0
                var alpha: CGFloat = 0
                pixel.getHue(
                    &hue,
                    saturation: &saturation,
                    brightness: &brightness,
                    alpha: &alpha
                )
                guard alpha > 0.2, saturation > 0.12, brightness > 0.06 else { continue }

                let index = min(Int(hue * CGFloat(buckets.count)), buckets.count - 1)
                let weight = Double(alpha * (0.25 + saturation) * (0.4 + brightness))
                buckets[index].score += weight * Double(saturation)
                buckets[index].red += Double(pixel.redComponent) * weight
                buckets[index].green += Double(pixel.greenComponent) * weight
                buckets[index].blue += Double(pixel.blueComponent) * weight
                buckets[index].weight += weight
            }
        }

        guard let dominant = buckets.max(by: { $0.score < $1.score }), dominant.weight > 0 else {
            return fallback
        }

        let sampled = NSColor(
            srgbRed: dominant.red / dominant.weight,
            green: dominant.green / dominant.weight,
            blue: dominant.blue / dominant.weight,
            alpha: 1
        )
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        sampled.getHue(
            &hue,
            saturation: &saturation,
            brightness: &brightness,
            alpha: &alpha
        )

        // Preserve the cover's hue, then enforce measured contrast against the
        // pure-black island. Brightness alone is not enough for saturated blue
        // artwork, whose relative luminance can remain surprisingly low.
        //
        // The colour is built directly in sRGB rather than through
        // NSColor(hue:...), which lives in the device space: converting that to
        // sRGB shifts saturation by a few points depending on the display
        // profile, which made the saturation floor below unverifiable in CI.
        let lifted = Self.srgbColor(
            hue: hue,
            saturation: min(max(saturation, 0.55), 0.92),
            brightness: min(max(brightness, 0.68), 0.96)
        )
        let readable = NotchShotColorPolicy.readableAccentOnBlack(lifted)
        return Self.preservingSaturation(readable, floor: 0.56)
    }

    /// Blending toward white for contrast can leave the accent just under the
    /// notch's saturation floor, and how far depends on the display profile.
    /// Rebuild at the floor, raising brightness only as far as the contrast
    /// target needs, so the floor holds on every machine.
    private static func preservingSaturation(_ color: NSColor, floor: CGFloat) -> NSColor {
        guard let srgb = color.usingColorSpace(.sRGB) else { return color }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        srgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        guard saturation > 0.05, saturation < floor else { return srgb }
        var candidateBrightness = brightness
        var candidate = Self.srgbColor(hue: hue, saturation: floor, brightness: candidateBrightness)
        while NotchShotColorPolicy.contrastRatio(candidate, .black)
            < NotchShotColorPolicy.minimumTextContrast,
            candidateBrightness < 1 {
            candidateBrightness = min(1, candidateBrightness + 0.02)
            candidate = Self.srgbColor(hue: hue, saturation: floor, brightness: candidateBrightness)
        }
        return candidate
    }

    /// HSB to sRGB without routing through a device colour space.
    private static func srgbColor(
        hue: CGFloat,
        saturation: CGFloat,
        brightness: CGFloat
    ) -> NSColor {
        let chroma = brightness * saturation
        let sextant = (hue - hue.rounded(.down)) * 6
        let second = chroma * (1 - abs(sextant.truncatingRemainder(dividingBy: 2) - 1))
        let match = brightness - chroma
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        switch sextant {
        case ..<1: (red, green, blue) = (chroma, second, 0)
        case ..<2: (red, green, blue) = (second, chroma, 0)
        case ..<3: (red, green, blue) = (0, chroma, second)
        case ..<4: (red, green, blue) = (0, second, chroma)
        case ..<5: (red, green, blue) = (second, 0, chroma)
        default: (red, green, blue) = (chroma, 0, second)
        }
        return NSColor(
            srgbRed: red + match,
            green: green + match,
            blue: blue + match,
            alpha: 1
        )
    }

    static func contrastAgainstBlack(_ color: NSColor) -> CGFloat {
        NotchShotColorPolicy.contrastRatio(color, .black)
    }
}
