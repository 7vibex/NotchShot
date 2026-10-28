// Renders NotchShot's app icon from the mascot in NotchShotLogo.swift.
//
// Run through Scripts/make_app_icon.sh, which compiles this file together with
// Sources/NotchShotKit/UI/NotchShotLogo.swift. Usage: render_icon <iconset-dir>

import AppKit

let canvas: CGFloat = 1024
/// Apple's macOS icon grid: an 824 pt squircle centred on the 1024 canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: stops.map { color($0.0, $0.1) } as CFArray,
        locations: stops.map(\.2)
    )!
}

/// A superellipse close to the system's continuous-corner icon shape, so
/// macOS treats the icon as already conforming instead of framing it.
func squircle(in rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * copysign(pow(abs(c), 2 / exponent), c)
        let y = rect.midY + b * copysign(pow(abs(s), 2 / exponent), s)
        step == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func sparkle(center: CGPoint, radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let waist = radius * 0.22
    path.move(to: CGPoint(x: center.x, y: center.y - radius))
    path.addQuadCurve(to: CGPoint(x: center.x + radius, y: center.y), control: CGPoint(x: center.x + waist, y: center.y - waist))
    path.addQuadCurve(to: CGPoint(x: center.x, y: center.y + radius), control: CGPoint(x: center.x + waist, y: center.y + waist))
    path.addQuadCurve(to: CGPoint(x: center.x - radius, y: center.y), control: CGPoint(x: center.x - waist, y: center.y + waist))
    path.addQuadCurve(to: CGPoint(x: center.x, y: center.y - radius), control: CGPoint(x: center.x - waist, y: center.y - waist))
    path.closeSubpath()
    return path
}

func drawIcon(in context: CGContext) {
    // Work top-down like the logo's own grid.
    context.translateBy(x: 0, y: canvas)
    context.scaleBy(x: 1, y: -1)

    let shape = squircle(in: tile)
    context.addPath(shape)
    context.clip()

    // Wallpaper: a soft dawn, so the black notch has something to hang over.
    context.drawLinearGradient(
        gradient([(0x8CC6FF, 1, 0), (0xB4A9FF, 1, 0.55), (0xFFB8D6, 1, 1)]),
        start: CGPoint(x: 0, y: tile.minY),
        end: CGPoint(x: 0, y: tile.maxY),
        options: []
    )
    context.drawRadialGradient(
        gradient([(0xFFFFFF, 0.45, 0), (0xFFFFFF, 0, 1)]),
        startCenter: CGPoint(x: 512, y: 700), startRadius: 0,
        endCenter: CGPoint(x: 512, y: 700), endRadius: 420,
        options: []
    )

    // The menu bar the notch lives in.
    let bar = CGRect(x: tile.minX, y: tile.minY, width: tile.width, height: 66)
    context.setFillColor(color(0xFFFFFF, 0.42))
    context.fill(bar)
    context.setFillColor(color(0xFFFFFF, 0.7))
    for (index, width) in [CGFloat(30), 22, 34].enumerated() {
        let x = 662 + CGFloat(index) * 46
        let pill = CGPath(roundedRect: CGRect(x: x, y: 124, width: width, height: 16), cornerWidth: 8, cornerHeight: 8, transform: nil)
        context.addPath(pill)
        context.fillPath()
    }

    // The screenshot it just took, dropping out underneath.
    context.saveGState()
    context.translateBy(x: 520, y: 712)
    context.rotate(by: -7 * .pi / 180)
    let card = CGRect(x: -168, y: -122, width: 336, height: 244)
    context.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: color(0x3A2470, 0.28))
    context.addPath(CGPath(roundedRect: card, cornerWidth: 30, cornerHeight: 30, transform: nil))
    context.setFillColor(color(0xFFFFFF))
    context.fillPath()
    context.setShadow(offset: .zero, blur: 0, color: nil)
    let photo = card.insetBy(dx: 16, dy: 16)
    context.saveGState()
    context.addPath(CGPath(roundedRect: photo, cornerWidth: 18, cornerHeight: 18, transform: nil))
    context.clip()
    context.drawLinearGradient(
        gradient([(0x7CC8FF, 1, 0), (0xD6F0FF, 1, 1)]),
        start: CGPoint(x: 0, y: photo.minY), end: CGPoint(x: 0, y: photo.maxY), options: []
    )
    context.setFillColor(color(0xFFD25E))
    context.fillEllipse(in: CGRect(x: photo.maxX - 92, y: photo.minY + 26, width: 52, height: 52))
    let backHill = CGMutablePath()
    backHill.move(to: CGPoint(x: photo.minX, y: photo.maxY))
    backHill.addLine(to: CGPoint(x: photo.minX, y: photo.maxY - 70))
    backHill.addQuadCurve(to: CGPoint(x: photo.maxX, y: photo.maxY - 50), control: CGPoint(x: photo.midX - 10, y: photo.maxY - 170))
    backHill.addLine(to: CGPoint(x: photo.maxX, y: photo.maxY))
    context.addPath(backHill)
    context.setFillColor(color(0x7ED9A4))
    context.fillPath()
    let frontHill = CGMutablePath()
    frontHill.move(to: CGPoint(x: photo.minX, y: photo.maxY))
    frontHill.addLine(to: CGPoint(x: photo.minX, y: photo.maxY - 34))
    frontHill.addQuadCurve(to: CGPoint(x: photo.maxX, y: photo.maxY - 86), control: CGPoint(x: photo.midX + 60, y: photo.maxY - 10))
    frontHill.addLine(to: CGPoint(x: photo.maxX, y: photo.maxY))
    context.addPath(frontHill)
    context.setFillColor(color(0x4DBA82))
    context.fillPath()
    context.restoreGState()
    context.restoreGState()

    // The mascot, hanging from the top edge.
    let scale: CGFloat = 30
    let origin = CGPoint(x: 512 - NotchShotLogo.designSize.width * scale / 2, y: tile.minY)
    var toIcon = CGAffineTransform(translationX: origin.x, y: origin.y).scaledBy(x: scale, y: scale)
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y).applying(toIcon) }

    let body = NotchShotLogo.bodyPath().copy(using: &toIcon)!
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 18), blur: 36, color: color(0x241446, 0.35))
    context.addPath(body)
    context.setFillColor(color(0x0B0B10))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(body)
    context.clip()
    context.drawLinearGradient(
        gradient([(0x000000, 1, 0), (0x15151D, 1, 0.75), (0x24242E, 1, 1)]),
        start: point(0, 0), end: point(0, 14.5), options: []
    )
    // A glassy rim along the lower edge, where the island meets the desktop.
    context.addPath(body)
    context.setLineWidth(10)
    context.setStrokeColor(color(0xFFFFFF, 0.14))
    context.strokePath()
    context.restoreGState()

    // Cheeks.
    for x in [CGFloat(5.0), 15.0] {
        let center = point(x, 10.2)
        context.drawRadialGradient(
            gradient([(0xFF8DBB, 0.95, 0), (0xFF8DBB, 0.55, 0.45), (0xFF8DBB, 0, 1)]),
            startCenter: center, startRadius: 0, endCenter: center, endRadius: 40,
            options: []
        )
    }

    // The camera eye.
    let eye = point(NotchShotLogo.eyeCenter.x, NotchShotLogo.eyeCenter.y)
    let lens = NotchShotLogo.eyeRadius * scale
    context.setFillColor(color(0x1A2030))
    context.fillEllipse(in: NotchShotLogo.circle(eye, lens))
    context.setStrokeColor(color(0x3B4762))
    context.setLineWidth(7)
    context.strokeEllipse(in: NotchShotLogo.circle(eye, lens - 3.5))
    context.saveGState()
    context.addEllipse(in: NotchShotLogo.circle(eye, 2.55 * scale))
    context.clip()
    context.drawRadialGradient(
        gradient([(0x8FE0FF, 1, 0), (0x3D7BFF, 1, 0.55), (0x1F2C8F, 1, 1)]),
        startCenter: CGPoint(x: eye.x - 18, y: eye.y - 22), startRadius: 0,
        endCenter: eye, endRadius: 2.55 * scale,
        options: [.drawsAfterEndLocation]
    )
    context.restoreGState()
    context.setFillColor(color(0x05060B))
    context.fillEllipse(in: NotchShotLogo.circle(eye, 1.15 * scale))
    context.setFillColor(color(0xFFFFFF))
    context.fillEllipse(in: NotchShotLogo.circle(CGPoint(x: eye.x + 24, y: eye.y - 24), 15))
    context.setFillColor(color(0xFFFFFF, 0.8))
    context.fillEllipse(in: NotchShotLogo.circle(CGPoint(x: eye.x - 22, y: eye.y + 22), 7))

    // Smile.
    var smileTransform = toIcon
    let smile = NotchShotLogo.smilePath(lineWidth: 0.62).copy(using: &smileTransform)!
    context.addPath(smile)
    context.setFillColor(color(0xFFFFFF, 0.95))
    context.fillPath()

    // Shutter sparkles.
    context.setFillColor(color(0xFFFFFF, 0.95))
    context.addPath(sparkle(center: CGPoint(x: 806, y: 262), radius: 34))
    context.fillPath()
    context.setFillColor(color(0xFFFFFF, 0.75))
    context.addPath(sparkle(center: CGPoint(x: 226, y: 560), radius: 22))
    context.fillPath()
}

func render(pixels: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    let factor = CGFloat(pixels) / canvas
    context.scaleBy(x: factor, y: factor)
    drawIcon(in: context)
    return context.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode \(url.lastPathComponent)")
    }
    try! data.write(to: url)
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: render_icon <iconset-dir>\n".utf8))
    exit(64)
}
let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    write(render(pixels: points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    write(render(pixels: points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
