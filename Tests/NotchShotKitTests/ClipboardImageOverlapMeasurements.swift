import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import NotchShotKit

/// Measurement for the clipboard image path. `ClipboardMonitor` decodes and
/// persists accepted image clippings off the main actor; if decode takes longer
/// than the 0.6 s poll interval, a burst of accepted copies can overlap. This
/// test records the peak number of in-flight chains rather than asserting a
/// bound, so the decision to add one is based on a measurement.
@Suite("Clipboard image processing overlap")
@MainActor
struct ClipboardImageOverlapMeasurements {
    private func largeImageData(width: Int, height: Int) throws -> Data {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ), let image = context.makeImage() else {
            throw NotchShotError.exportFailed("could not build the clipboard measurement fixture")
        }
        return try ImageExport.encode(image, format: .png, quality: 1, dpiScale: 1).data
    }

    @Test("Measurement: rapid accepted image copies at the maximum decode size")
    func measurePeakOverlap() async throws {
        let wasEnabled = Preferences.shared.clipboardEnabled
        Preferences.shared.clipboardEnabled = true
        defer { Preferences.shared.clipboardEnabled = wasEnabled }

        // 50 MP is exactly the monitor's decode ceiling.
        let data = try largeImageData(width: 8_000, height: 6_250)
        #expect(data.count <= ClipboardStore.maximumImageBytes)

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NotchShotClipboardOverlap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("NotchShotClipboardOverlap-\(UUID().uuidString)"))
        let store = ClipboardStore(
            storeURL: scratch.appendingPathComponent("clipboard.json"),
            imageDirectory: scratch.appendingPathComponent("images", isDirectory: true)
        )
        let monitor = ClipboardMonitor(pasteboard: pasteboard, store: store)
        var captured = 0
        monitor.onCapture = { _ in captured += 1 }

        // Four accepted copies at the production 0.6 s cadence.
        for _ in 0 ..< 4 {
            pasteboard.clearContents()
            pasteboard.setData(data, forType: .png)
            monitor.poll()
            try await Task.sleep(for: .milliseconds(600))
        }

        for _ in 0 ..< 400 where captured < 4 {
            try await Task.sleep(for: .milliseconds(50))
        }
        print(
            "clipboard image overlap: peak in-flight=\(monitor.peakPendingImageProcessing)"
                + " remaining=\(monitor.pendingImageProcessing)"
        )
        #expect(captured == 4, "every accepted copy must still be recorded")
        #expect(monitor.pendingImageProcessing == 0)
    }
}
