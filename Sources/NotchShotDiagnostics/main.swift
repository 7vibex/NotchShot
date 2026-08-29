import AppKit
import CoreGraphics
import Foundation
import NotchShotKit

/// Headless smoke test for the capture and recording pipeline.
///
/// Exercises the same `CaptureService` / `RecordingService` code the app uses,
/// without the notch, the overlay, or any UI. When a capture "doesn't work",
/// this says whether the problem is the pipeline or the app's TCC grant.
///
///     swift run notchshot-diagnostics
///
/// Run from a terminal that already has Screen Recording permission, otherwise
/// it reports the permission state and stops.
@MainActor
func run() async {
    print("NotchShot diagnostics")
    print(String(repeating: "─", count: 46))

    // 1. Permission
    let preflight = CGPreflightScreenCaptureAccess()
    print("Screen Recording (this process): \(preflight ? "granted" : "NOT granted")")
    guard preflight else {
        print("""

        This process can't capture. Grant Screen Recording to whichever app is
        running it (Terminal, iTerm, Xcode), then run it again.

        Note this is separate from NotchShot.app's own grant.
        """)
        exit(1)
    }

    // 2. Shareable content
    do {
        let snapshot = try await ShareableContentProvider.shared.snapshot(forceRefresh: true)
        print("Displays: \(snapshot.displays.count), windows: \(snapshot.windows.count)")
        for display in snapshot.displays {
            print("  display \(display.id): \(Int(display.frame.width))×\(Int(display.frame.height)) @\(display.scale)x")
        }
        guard let display = snapshot.displays.first else {
            print("No displays reported — cannot continue.")
            exit(1)
        }

        // 3. Full-display capture
        let excluded = WindowExclusionRegistry.shared.excludedWindowNumbers
        let full = try await CaptureService.shared.captureDisplay(
            display.id,
            excludedWindows: excluded,
            showsCursor: false
        )
        print("Display capture: \(Int(full.pixelSize.width))×\(Int(full.pixelSize.height)) px @\(full.scale)x")

        let expectedWidth = Int(display.frame.width * display.scale)
        if abs(Int(full.pixelSize.width) - expectedWidth) > 2 {
            print("  ⚠︎ expected ~\(expectedWidth)px wide — scaling may be wrong")
        }

        // 4. Area capture, using a rect in the middle of that display
        let area = CGRect(
            x: display.frame.midX - 200,
            y: display.frame.midY - 150,
            width: 400,
            height: 300
        )
        let cropped = try await CaptureService.shared.captureArea(
            area,
            excludedWindows: excluded,
            showsCursor: false
        )
        print("Area capture:    \(Int(cropped.pixelSize.width))×\(Int(cropped.pixelSize.height)) px")
        let expectedArea = ScreenGeometry.pixelSize(forPointRect: area, scale: display.scale)
        if cropped.pixelSize != expectedArea {
            print("  ⚠︎ expected \(Int(expectedArea.width))×\(Int(expectedArea.height))")
        }

        // 5. Encode to every supported format
        for format in ImageFormat.allCases {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("notchshot-diagnostics-\(format.rawValue)")
                .appendingPathExtension(format.fileExtension)
            let written = try ImageExport.write(
                cropped.cgImage,
                to: url,
                format: format,
                quality: 0.9,
                dpiScale: cropped.scale
            )
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
            let label = format.title.padding(toLength: 5, withPad: " ", startingAt: 0)
            let fallback = written == format ? "" : "  (fell back to \(written.title))"
            print("Wrote \(label) \(size) bytes\(fallback)")
            try? FileManager.default.removeItem(at: url)
        }

        // 6. OCR
        let ocr = try await OCRService.shared.recognizeText(in: full)
        print("OCR: \(ocr.regions.count) text regions, \(ocr.detectedItems.count) detected items")

        // 7. A short recording
        print("Recording 3s of display \(display.id)…")
        let configuration = RecordingConfiguration(
            target: .display(display.id),
            audioSources: [.system],
            resolution: .p720,
            framesPerSecond: 30,
            showsCursor: true
        )
        try await RecordingService.shared.start(configuration)
        try await Task.sleep(for: .seconds(3))

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-diagnostics.mp4")
        let asset = try await RecordingService.shared.stop(destination: output)
        print("Recording: \(Int(asset.pixelSize.width))×\(Int(asset.pixelSize.height)), "
              + String(format: "%.1fs", asset.duration ?? 0)
              + ", \(asset.fileSizeDescription)")
        if (asset.duration ?? 0) < 1 {
            print("  ⚠︎ recording is suspiciously short")
        }
        try? FileManager.default.removeItem(at: output)

        print(String(repeating: "─", count: 46))
        print("All capture paths OK.")
        exit(0)
    } catch {
        print("\nFAILED: \(error.localizedDescription)")
        exit(1)
    }
}

Task { await run() }
RunLoop.main.run()
