// Thumbnail decode bench for the 2026-10-29 report. Decodes every file in a
// folder (the stored History thumbnails) four ways, interleaved over four
// rounds, and prints instructions and time per file and the decoded total.
// Reads only. Build with swiftc -O; pass the folder as the only argument.

import CoreGraphics
import Darwin
import Foundation
import ImageIO

@_silgen_name("thread_selfcounts")
func thread_selfcounts(_ type: Int32, _ buffer: UnsafeMutableRawPointer, _ size: Int) -> Int32
func instructions() -> UInt64 { var c: (UInt64, UInt64) = (0, 0); _ = withUnsafeMutableBytes(of: &c) { thread_selfcounts(1, $0.baseAddress!, $0.count) }; return c.0 }

let target = CGSize(width: 104, height: 72)
func source(_ data: Data) -> CGImageSource { CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)! }
func fullDecode(_ data: Data) -> CGImage {
    CGImageSourceCreateImageAtIndex(source(data), 0, [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary)!
}
func fillSize(_ w: Int, _ h: Int) -> (Int, Int) {
    let scale = min(1, max(target.width / CGFloat(w), target.height / CGFloat(h)))
    return (max(1, Int((CGFloat(w) * scale).rounded(.up))), max(1, Int((CGFloat(h) * scale).rounded(.up))))
}
func imageIOThumbnail(_ data: Data) -> CGImage {
    let src = source(data)
    let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
    let w = p[kCGImagePropertyPixelWidth] as! Int, h = p[kCGImagePropertyPixelHeight] as! Int
    let scale = max(target.width / CGFloat(w), target.height / CGFloat(h))
    let pixels = min(max(w, h), Int((CGFloat(max(w, h)) * scale).rounded(.up)) + 1)
    return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: pixels] as CFDictionary)!
}
func decodeAndDraw(_ data: Data, quality: CGInterpolationQuality) -> CGImage {
    let full = fullDecode(data)
    let (w, h) = fillSize(full.width, full.height)
    let space = full.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = quality
    context.draw(full, in: CGRect(x: 0, y: 0, width: w, height: h))
    return context.makeImage()!
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).map { try Data(contentsOf: $0) }
let variants: [(String, (Data) -> CGImage)] = [
    ("full decode (before)", fullDecode),
    ("ImageIO thumbnail (first fix)", imageIOThumbnail),
    ("decode + draw, medium", { decodeAndDraw($0, quality: .medium) }),
    ("decode + draw, high", { decodeAndDraw($0, quality: .high) }),
]
var totals = [String: [Double]](), bytes = [String: Int](), ms = [String: [Double]]()
for _ in 0 ..< 4 {
    for (name, body) in variants {
        var b = 0
        let t = Date(); let i = instructions()
        for data in files { let image = body(data); b += image.bytesPerRow * image.height }
        totals[name, default: []].append(Double(instructions() - i) / Double(files.count) / 1e6)
        ms[name, default: []].append(Date().timeIntervalSince(t) * 1000 / Double(files.count))
        bytes[name] = b
    }
}
for (name, _) in variants {
    let v = totals[name]!.sorted(), m = ms[name]!.sorted()
    print(String(format: "%-30@ %6.2f-%6.2f M instr/thumb  %5.2f-%5.2f ms/thumb  decoded total %6.2f MB", name as NSString, v.first!, v.last!, m.first!, m.last!, Double(bytes[name]!) / 1048576))
}
