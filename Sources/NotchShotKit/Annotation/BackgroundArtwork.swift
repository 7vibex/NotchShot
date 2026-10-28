import CoreGraphics
import Foundation
import simd

/// Backdrops NotchShot paints itself instead of shipping as images.
///
/// Painting at the canvas's own size keeps them sharp at any padding or aspect
/// ratio, and adds nothing to the app bundle. Every one is seeded, so the same
/// capture exports to the same pixels every time.
public enum BackgroundArtwork: String, Codable, Sendable, CaseIterable, Identifiable {
    /// The island's own black, with the glow its glass picks up.
    case notch
    /// The app icon's sky: blue into lavender into pink.
    case dawn
    case aurora
    /// Cobalt with white stippled clouds and sparkles, like an engraving.
    case cobalt
    case lagoon
    case peach
    case blueprint
    case carbon

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .notch: "Notch"
        case .dawn: "Dawn"
        case .aurora: "Aurora"
        case .cobalt: "Cobalt"
        case .lagoon: "Lagoon"
        case .peach: "Peach"
        case .blueprint: "Blueprint"
        case .carbon: "Carbon"
        }
    }

    /// Dark scenes take a heavier shadow; on a light one it would look dirty.
    public var isDark: Bool {
        switch self {
        case .notch, .aurora, .cobalt, .blueprint, .carbon: true
        case .dawn, .lagoon, .peach: false
        }
    }
}

enum BackgroundArtworkRenderer {
    /// Paints `artwork` over `rect` of a y-up, pixel-space context.
    static func draw(_ artwork: BackgroundArtwork, in context: CGContext, rect: CGRect, scale: CGFloat) {
        guard rect.width >= 1, rect.height >= 1 else { return }
        let scale = max(scale, 0.25)
        let style = Style.of(artwork)

        // Soft scenes are painted small and scaled up: nothing in them has an
        // edge, and it keeps slider drags cheap. Stipple dots need one painted
        // pixel per point to stay crisp.
        let points = CGSize(width: rect.width / scale, height: rect.height / scale)
        let cap: CGFloat = style.stipple == nil ? 1_200 : 2_400
        let fit = min(1, cap / max(points.width, points.height))
        let width = max(1, Int((points.width * fit).rounded()))
        let height = max(1, Int((points.height * fit).rounded()))

        if let image = bitmap(artwork, style: style, width: width, height: height) {
            context.saveGState()
            context.clip(to: rect)
            context.interpolationQuality = style.stipple == nil ? .high : .none
            context.draw(image, in: rect)
            context.restoreGState()
        }

        if style.sparkles > 0 {
            drawSparkles(count: style.sparkles, seed: style.seed, in: context, rect: rect, scale: scale)
        }
        if style.grid {
            drawGrid(in: context, rect: rect, scale: scale)
        }
    }

    // MARK: Styles

    struct Blob {
        var center: SIMD2<Float>
        var radius: Float
        var color: SIMD3<Float>
        var opacity: Float
    }

    struct Stipple {
        var ink: SIMD3<Float>
    }

    struct Style {
        /// Top-to-bottom stops, or top-left to bottom-right when `diagonal`.
        var stops: [(Float, SIMD3<Float>)]
        var diagonal = false
        var blobs: [Blob] = []
        var grain: Float = 0
        var stipple: Stipple?
        var sparkles = 0
        var grid = false
        var seed: UInt32

        static func of(_ artwork: BackgroundArtwork) -> Style {
            switch artwork {
            case .notch:
                Style(
                    stops: [(0, rgb(0x000000)), (1, rgb(0x0B0B12))],
                    blobs: [
                        Blob(center: [0.12, 0.08], radius: 0.55, color: rgb(0x3A2F9E), opacity: 0.55),
                        Blob(center: [0.92, 0.95], radius: 0.6, color: rgb(0x0F5F78), opacity: 0.45),
                        Blob(center: [0.55, 1.1], radius: 0.45, color: rgb(0x6C2BD9), opacity: 0.25),
                    ],
                    grain: 0.025,
                    seed: 11
                )
            case .dawn:
                Style(
                    stops: [(0, rgb(0x8CC6FF)), (0.55, rgb(0xB4A9FF)), (1, rgb(0xFFB8D6))],
                    blobs: [
                        Blob(center: [0.5, 0.78], radius: 0.45, color: rgb(0xFFFFFF), opacity: 0.35),
                        Blob(center: [0.08, 0.18], radius: 0.38, color: rgb(0xA6E1FF), opacity: 0.5),
                        Blob(center: [0.95, 0.3], radius: 0.4, color: rgb(0xFFD6EC), opacity: 0.45),
                    ],
                    grain: 0.015,
                    seed: 23
                )
            case .aurora:
                Style(
                    stops: [(0, rgb(0x050B1A)), (1, rgb(0x0A1630))],
                    blobs: [
                        Blob(center: [0.2, 0.25], radius: 0.45, color: rgb(0x19D3A2), opacity: 0.55),
                        Blob(center: [0.78, 0.18], radius: 0.5, color: rgb(0x7B5CFF), opacity: 0.55),
                        Blob(center: [0.6, 0.88], radius: 0.55, color: rgb(0x1E90FF), opacity: 0.4),
                        Blob(center: [0.04, 0.92], radius: 0.4, color: rgb(0x00E0C6), opacity: 0.3),
                    ],
                    grain: 0.03,
                    seed: 37
                )
            case .cobalt:
                Style(
                    stops: [(0, rgb(0x2433FF)), (1, rgb(0x1622D2))],
                    blobs: [
                        Blob(center: [0.5, -0.08], radius: 0.5, color: rgb(0x5361FF), opacity: 0.5),
                    ],
                    stipple: Stipple(ink: rgb(0xF2F4FF)),
                    sparkles: 7,
                    seed: 41
                )
            case .lagoon:
                Style(
                    stops: [(0, rgb(0x00C6D7)), (1, rgb(0x0072B5))],
                    diagonal: true,
                    blobs: [
                        Blob(center: [0.85, 0.15], radius: 0.42, color: rgb(0x7CF5E0), opacity: 0.5),
                        Blob(center: [0.12, 0.88], radius: 0.45, color: rgb(0x0049A8), opacity: 0.45),
                        Blob(center: [0.5, 0.5], radius: 0.35, color: rgb(0x38E1FF), opacity: 0.25),
                    ],
                    grain: 0.015,
                    seed: 53
                )
            case .peach:
                Style(
                    stops: [(0, rgb(0xFFE1C7)), (1, rgb(0xFFB1A8))],
                    blobs: [
                        Blob(center: [0.18, 0.2], radius: 0.42, color: rgb(0xFFF1B8), opacity: 0.6),
                        Blob(center: [0.86, 0.78], radius: 0.45, color: rgb(0xFF8FB3), opacity: 0.45),
                        Blob(center: [0.62, 0.08], radius: 0.35, color: rgb(0xFFC9A3), opacity: 0.4),
                    ],
                    grain: 0.012,
                    seed: 67
                )
            case .blueprint:
                Style(
                    stops: [(0, rgb(0x0D4AA8)), (1, rgb(0x072A66))],
                    blobs: [
                        Blob(center: [0.5, 0.35], radius: 0.6, color: rgb(0x1D63C9), opacity: 0.45),
                    ],
                    grain: 0.012,
                    grid: true,
                    seed: 71
                )
            case .carbon:
                Style(
                    stops: [(0, rgb(0x1C1C21)), (1, rgb(0x0C0C0F))],
                    blobs: [
                        Blob(center: [0.5, -0.05], radius: 0.7, color: rgb(0x40404C), opacity: 0.6),
                    ],
                    grain: 0.045,
                    seed: 83
                )
            }
        }
    }

    static func rgb(_ hex: UInt32) -> SIMD3<Float> {
        SIMD3(
            Float((hex >> 16) & 0xFF) / 255,
            Float((hex >> 8) & 0xFF) / 255,
            Float(hex & 0xFF) / 255
        )
    }

    // MARK: Painting

    private final class CachedImage {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    /// Slider drags that change only the corners or the shadow repaint the
    /// same size again; keep the last few.
    nonisolated(unsafe) private static let cache: NSCache<NSString, CachedImage> = {
        let cache = NSCache<NSString, CachedImage>()
        cache.countLimit = 6
        return cache
    }()

    private static func bitmap(
        _ artwork: BackgroundArtwork,
        style: Style,
        width: Int,
        height: Int
    ) -> CGImage? {
        let key = "\(artwork.rawValue)-\(width)x\(height)" as NSString
        if let cached = cache.object(forKey: key) { return cached.image }

        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let aspect = Float(width) / Float(height)
        let invWidth = 1 / Float(width), invHeight = 1 / Float(height)

        for y in 0 ..< height {
            let v = (Float(y) + 0.5) * invHeight
            for x in 0 ..< width {
                let u = (Float(x) + 0.5) * invWidth
                var color = base(style, u: u, v: v)
                for blob in style.blobs {
                    let dx = (u - blob.center.x) * aspect
                    let dy = v - blob.center.y
                    let weight = exp(-(dx * dx + dy * dy) / (blob.radius * blob.radius)) * blob.opacity
                    color += (blob.color - color) * weight
                }
                if let stipple = style.stipple {
                    let density = cloudDensity(u: u, v: v, aspect: aspect, seed: style.seed)
                    let roll = hash(Int32(x), Int32(y), style.seed &+ 1)
                    if roll < density * density * 0.95 || roll > 0.9975 {
                        color = stipple.ink
                    }
                }
                if style.grain > 0 {
                    color += (hash(Int32(x), Int32(y), style.seed) - 0.5) * 2 * style.grain
                }
                let offset = (y * width + x) * 4
                let clamped = simd_clamp(color, SIMD3(repeating: 0), SIMD3(repeating: 1)) * 255
                pixels[offset] = UInt8(clamped.x.rounded())
                pixels[offset + 1] = UInt8(clamped.y.rounded())
                pixels[offset + 2] = UInt8(clamped.z.rounded())
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else { return nil }
        cache.setObject(CachedImage(image), forKey: key)
        return image
    }

    private static func base(_ style: Style, u: Float, v: Float) -> SIMD3<Float> {
        let t = style.diagonal ? (u + v) / 2 : v
        var previous = style.stops[0]
        for stop in style.stops.dropFirst() {
            if t <= stop.0 {
                let span = max(stop.0 - previous.0, 0.0001)
                let local = min(max((t - previous.0) / span, 0), 1)
                return previous.1 + (stop.1 - previous.1) * local
            }
            previous = stop
        }
        return previous.1
    }

    /// Where the stippled clouds sit: banks rising from the bottom and up
    /// the sides with crisp, noise-broken edges, shaded inside so they read
    /// as clouds rather than static, plus a halo at the top centre.
    private static func cloudDensity(u: Float, v: Float, aspect: Float, seed: UInt32) -> Float {
        let shape = fbm(u * aspect * 2.4, v * 2.4, seed: seed)
        let bottom = smoothstep(0.66, 0.74, v + (shape - 0.5) * 0.6)
        let sides = smoothstep(0.4, 0.46, abs(u - 0.5) + (shape - 0.5) * 0.35)
            * smoothstep(0.35, 0.7, v)
        let shading = fbm(u * aspect * 7, v * 7, seed: seed &+ 7)
        let cloud = max(bottom, sides) * (0.3 + 0.7 * shading)
        let dx = (u - 0.5) * aspect, dy = v + 0.04
        let halo = exp(-(dx * dx + dy * dy) / 0.05) * 0.5 * shading
        return min(max(cloud + halo, 0), 1)
    }

    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func fbm(_ x: Float, _ y: Float, seed: UInt32) -> Float {
        var total: Float = 0, amplitude: Float = 0.5, frequency: Float = 1, norm: Float = 0
        for octave in 0 ..< 4 {
            total += valueNoise(x * frequency, y * frequency, seed: seed &+ UInt32(octave) &* 101) * amplitude
            norm += amplitude
            amplitude *= 0.5
            frequency *= 2
        }
        return total / norm
    }

    private static func valueNoise(_ x: Float, _ y: Float, seed: UInt32) -> Float {
        let x0 = floor(x), y0 = floor(y)
        let fx = x - x0, fy = y - y0
        let ix = Int32(x0), iy = Int32(y0)
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        let a = hash(ix, iy, seed), b = hash(ix + 1, iy, seed)
        let c = hash(ix, iy + 1, seed), d = hash(ix + 1, iy + 1, seed)
        return (a + (b - a) * sx) + ((c + (d - c) * sx) - (a + (b - a) * sx)) * sy
    }

    /// A stateless 0…1 hash, so any pixel's noise is the same however the
    /// canvas is painted.
    @inline(__always)
    static func hash(_ x: Int32, _ y: Int32, _ seed: UInt32) -> Float {
        var h = UInt32(bitPattern: x) &* 0x8DA6_B343
        h ^= UInt32(bitPattern: y) &* 0xD816_3841
        h ^= seed &* 0xCB1A_B31F
        h ^= h >> 13
        h &*= 0x85EB_CA6B
        h ^= h >> 16
        return Float(h & 0xFF_FFFF) / Float(0x100_0000)
    }

    // MARK: Vector overlays

    /// Four-point sparkles with long hairline rays, drawn at the canvas's
    /// own resolution so they stay sharp.
    private static func drawSparkles(count: Int, seed: UInt32, in context: CGContext, rect: CGRect, scale: CGFloat) {
        context.saveGState()
        context.clip(to: rect)
        for index in 0 ..< count {
            let i = Int32(index)
            // In the margin a framed capture leaves visible: along the top,
            // or high up either side.
            let along = CGFloat(hash(i, 1, seed)), across = CGFloat(hash(i, 2, seed))
            let u: CGFloat, v: CGFloat
            if index % 3 == 2 {
                u = index % 2 == 0 ? 0.015 + across * 0.04 : 0.945 + across * 0.04
                v = 0.12 + along * 0.4
            } else {
                // Spread across the top in even slots so they never bunch.
                let slot = CGFloat(index - index / 3)
                let slots = CGFloat(count - count / 3)
                u = 0.05 + (slot + 0.2 + along * 0.6) / slots * 0.9
                v = 0.015 + across * 0.05
            }
            let radius = (4 + CGFloat(hash(i, 3, seed)) * 7) * scale
            // y-up context: v is measured from the top.
            let center = CGPoint(x: rect.minX + u * rect.width, y: rect.maxY - v * rect.height)

            context.setStrokeColor(CGColor(gray: 1, alpha: 0.5))
            context.setLineWidth(max(0.5, 0.6 * scale))
            context.move(to: CGPoint(x: center.x - radius * 2.6, y: center.y))
            context.addLine(to: CGPoint(x: center.x + radius * 2.6, y: center.y))
            context.move(to: CGPoint(x: center.x, y: center.y - radius * 2.6))
            context.addLine(to: CGPoint(x: center.x, y: center.y + radius * 2.6))
            context.strokePath()

            let waist = radius * 0.2
            let star = CGMutablePath()
            star.move(to: CGPoint(x: center.x, y: center.y + radius))
            star.addQuadCurve(to: CGPoint(x: center.x + radius, y: center.y), control: CGPoint(x: center.x + waist, y: center.y + waist))
            star.addQuadCurve(to: CGPoint(x: center.x, y: center.y - radius), control: CGPoint(x: center.x + waist, y: center.y - waist))
            star.addQuadCurve(to: CGPoint(x: center.x - radius, y: center.y), control: CGPoint(x: center.x - waist, y: center.y - waist))
            star.addQuadCurve(to: CGPoint(x: center.x, y: center.y + radius), control: CGPoint(x: center.x - waist, y: center.y + waist))
            context.addPath(star)
            context.setFillColor(CGColor(gray: 1, alpha: 0.95))
            context.fillPath()
        }
        context.restoreGState()
    }

    private static func drawGrid(in context: CGContext, rect: CGRect, scale: CGFloat) {
        context.saveGState()
        context.clip(to: rect)
        let minor = 24 * scale
        let lineWidth = max(0.5, 0.75 * scale)
        var column = 0
        var x = rect.minX
        while x <= rect.maxX {
            context.setStrokeColor(CGColor(gray: 1, alpha: column % 5 == 0 ? 0.16 : 0.07))
            context.setLineWidth(lineWidth)
            context.move(to: CGPoint(x: x, y: rect.minY))
            context.addLine(to: CGPoint(x: x, y: rect.maxY))
            context.strokePath()
            x += minor
            column += 1
        }
        var row = 0
        var y = rect.maxY
        while y >= rect.minY {
            context.setStrokeColor(CGColor(gray: 1, alpha: row % 5 == 0 ? 0.16 : 0.07))
            context.setLineWidth(lineWidth)
            context.move(to: CGPoint(x: rect.minX, y: y))
            context.addLine(to: CGPoint(x: rect.maxX, y: y))
            context.strokePath()
            y -= minor
            row += 1
        }
        context.restoreGState()
    }
}
