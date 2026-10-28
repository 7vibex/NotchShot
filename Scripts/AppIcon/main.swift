// Packages the source artwork as a native macOS icon. Run through
// Scripts/make_app_icon.sh; the source PNG stays independent of the icon mask.

import AppKit
import ImageIO

let canvas: CGFloat = 1024
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)

func squircle(in rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    for step in 0...720 {
        let t = CGFloat(step) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let point = CGPoint(
            x: rect.midX + a * copysign(pow(abs(c), 2 / exponent), c),
            y: rect.midY + b * copysign(pow(abs(s), 2 / exponent), s)
        )
        step == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    path.closeSubpath()
    return path
}

func render(_ artwork: CGImage, pixels: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    let factor = CGFloat(pixels) / canvas
    context.scaleBy(x: factor, y: factor)

    let shape = squircle(in: tile)
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -10), blur: 18,
        color: CGColor(srgbRed: 0.22, green: 0.12, blue: 0.08, alpha: 0.18)
    )
    context.setFillColor(CGColor(srgbRed: 0.98, green: 0.96, blue: 0.92, alpha: 1))
    context.addPath(shape)
    context.fillPath()
    context.restoreGState()

    context.addPath(shape)
    context.clip()
    context.draw(artwork, in: tile)
    return context.makeImage()!
}

func write(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url, options: .atomic)
}

guard CommandLine.arguments.count == 4 else {
    FileHandle.standardError.write(Data("usage: render_icon <artwork.png> <iconset-dir> <preview.png>\n".utf8))
    exit(64)
}
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil),
      artwork.width == artwork.height, artwork.width >= 1024 else {
    FileHandle.standardError.write(Data("Icon artwork must be a square image at least 1024 pixels wide.\n".utf8))
    exit(65)
}
let iconset = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try write(render(artwork, pixels: points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try write(render(artwork, pixels: points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
try write(render(artwork, pixels: 1024), to: URL(fileURLWithPath: CommandLine.arguments[3]))
