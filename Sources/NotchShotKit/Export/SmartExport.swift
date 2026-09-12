import AppKit
import CoreGraphics
import Foundation
import Observation
import SwiftUI

public enum SmartExportPreset: String, CaseIterable, Identifiable, Sendable {
    case original
    case messages
    case email
    case issueTracker
    case documentation
    case smallFile
    case retina2x
    case standard1x
    case customWidth

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .original: "Original dimensions"
        case .messages: "Best for Messages"
        case .email: "Best for Email"
        case .issueTracker: "GitHub / Jira attachment"
        case .documentation: "Documentation"
        case .smallFile: "Small file"
        case .retina2x: "Retina 2×"
        case .standard1x: "Standard 1×"
        case .customWidth: "Maximum width…"
        }
    }
}

public struct SmartExportPlan: Sendable, Equatable {
    public var pixelSize: CGSize
    public var format: ImageFormat
    public var quality: Double
    public var estimatedBytes: Int64

    public var dimensionsDescription: String {
        "\(Int(pixelSize.width)) × \(Int(pixelSize.height))"
    }

    public var estimatedSizeDescription: String {
        ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .file)
    }
}

public enum SmartExportService {
    /// Downscales until an encode fits the requested byte ceiling. The source
    /// is never upscaled, and the real encoder output—not an estimate—drives
    /// every iteration.
    public static func renderToFit(
        _ image: CGImage,
        maximumBytes: Int,
        format: ImageFormat,
        quality: Double,
        dpiScale: CGFloat
    ) throws -> CGImage {
        guard maximumBytes > 0 else { return image }
        var candidate = image
        for _ in 0 ..< 8 {
            let encoded = try ImageExport.encode(
                candidate,
                format: format,
                quality: quality,
                dpiScale: dpiScale
            ).data
            guard encoded.count > maximumBytes else { return candidate }
            let ratio = sqrt(Double(maximumBytes) / Double(max(encoded.count, 1))) * 0.94
            let scale = min(max(ratio, 0.35), 0.92)
            let size = CGSize(
                width: max(1, (CGFloat(candidate.width) * scale).rounded(.down)),
                height: max(1, (CGFloat(candidate.height) * scale).rounded(.down))
            )
            candidate = try render(candidate, to: size)
        }
        let finalBytes = try ImageExport.encode(
            candidate,
            format: format,
            quality: quality,
            dpiScale: dpiScale
        ).data.count
        guard finalBytes <= maximumBytes else {
            throw NotchShotError.exportFailed(
                "Could not fit this image below \(ByteCountFormatter.string(fromByteCount: Int64(maximumBytes), countStyle: .file))"
            )
        }
        return candidate
    }

    public static func plan(
        for asset: CaptureAsset,
        image: CGImage,
        preset: SmartExportPreset,
        customWidth: Int = 1_920
    ) -> SmartExportPlan {
        let source = CGSize(width: image.width, height: image.height)
        let pointWidth = max(1, Int((CGFloat(image.width) / max(asset.scale, 1)).rounded()))

        let specification: (maximumWidth: Int, format: ImageFormat, quality: Double) = switch preset {
        case .original:
            (image.width, inferredFormat(from: asset.url), 0.9)
        case .messages:
            (2_048, .jpeg, 0.82)
        case .email:
            (1_600, .jpeg, 0.78)
        case .issueTracker:
            (2_560, .png, 1)
        case .documentation:
            (3_200, .png, 1)
        case .smallFile:
            (1_280, .jpeg, 0.70)
        case .retina2x:
            (pointWidth * 2, .png, 1)
        case .standard1x:
            (pointWidth, .png, 1)
        case .customWidth:
            (min(max(customWidth, 320), 16_384), .png, 1)
        }

        let width = min(image.width, specification.maximumWidth)
        let scale = CGFloat(width) / max(source.width, 1)
        let height = max(1, Int((source.height * scale).rounded()))
        let pixels = Int64(width) * Int64(height)
        let sourceBytes = max(asset.fileSize, 1)
        let sourcePixels = max(Int64(image.width) * Int64(image.height), 1)
        let pixelRatio = Double(pixels) / Double(sourcePixels)
        let estimated: Int64
        if preset == .original {
            estimated = sourceBytes
        } else if specification.format == .png {
            estimated = max(8_192, Int64(Double(sourceBytes) * pixelRatio * 1.05))
        } else {
            estimated = max(8_192, Int64(Double(pixels) * 0.42 * specification.quality))
        }

        return SmartExportPlan(
            pixelSize: CGSize(width: width, height: height),
            format: specification.format,
            quality: specification.quality,
            estimatedBytes: estimated
        )
    }

    public static func render(_ image: CGImage, to size: CGSize) throws -> CGImage {
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0, height > 0,
              width <= 16_384, height <= 16_384,
              width <= 100_000_000 / height,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw NotchShotError.exportFailed("That export size is too large")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let output = context.makeImage() else {
            throw NotchShotError.exportFailed("Could not render the optimized image")
        }
        return output
    }

    private static func inferredFormat(from url: URL) -> ImageFormat {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": .jpeg
        case "heic", "heif": .heic
        default: .png
        }
    }
}

@MainActor
@Observable
public final class SmartExportSession {
    public let asset: CaptureAsset
    public let source: CGImage
    public var preset: SmartExportPreset = .messages
    public var customWidth = 1_920
    public var errorMessage: String?
    public var exportedAsset: CaptureAsset?
    public private(set) var isExporting = false
    public var onExported: ((CaptureAsset) -> Void)?

    public init(asset: CaptureAsset) throws {
        guard asset.kind.isImage, let source = SafeImageFile.cgImage(for: asset) else {
            throw NotchShotError.exportFailed("That image could not be read safely")
        }
        self.asset = asset
        self.source = source
    }

    public var plan: SmartExportPlan {
        SmartExportService.plan(
            for: asset,
            image: source,
            preset: preset,
            customWidth: customWidth
        )
    }

    public func export() {
        guard !isExporting else { return }
        let plan = plan
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ImageExport.utType(for: plan.format)]
        panel.directoryURL = Preferences.shared.outputFolder
        panel.nameFieldStringValue = asset.url.deletingPathExtension().lastPathComponent
            + "-optimized.\(plan.format.fileExtension)"
        panel.message = "Exports a flattened image and removes the original file metadata. Only redactions already applied to this image are included."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let quality = Preferences.shared.jpegQuality
        let source = UncheckedImage(image: self.source)
        let preset = self.preset
        // When nothing was resampled the original scale (and therefore its DPI)
        // must survive; a 1× capture was being relabelled as a 2× Retina file.
        let matchesSource = plan.pixelSize == CGSize(
            width: CGFloat(self.source.width),
            height: CGFloat(self.source.height)
        )
        let outputScale: CGFloat = matchesSource ? max(1, asset.scale) : 2
        let dpiScale: CGFloat = preset == .standard1x ? 1 : outputScale
        isExporting = true
        errorMessage = nil
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                Self.renderAndWrite(
                    source: source,
                    plan: plan,
                    quality: quality,
                    dpiScale: dpiScale,
                    to: url
                )
            }.value
            guard let self else { return }
            self.isExporting = false
            switch outcome {
            case .success(let finalURL, let pixelSize):
                let result = CaptureAsset(
                    url: finalURL,
                    kind: .screenshot,
                    pixelSize: pixelSize,
                    scale: outputScale,
                    sourceApplication: self.asset.sourceApplication,
                    sourceApplicationName: self.asset.sourceApplicationName
                )
                self.exportedAsset = result
                self.onExported?(result)
            case .failure(let message):
                self.errorMessage = message
            }
        }
    }

    /// AppKit panels stay on the main actor; the render, encode, and possible
    /// extension fix-up run here so a large image cannot stall the UI.
    private nonisolated static func renderAndWrite(
        source: UncheckedImage,
        plan: SmartExportPlan,
        quality: Double,
        dpiScale: CGFloat,
        to url: URL
    ) -> ExportOutcome {
        do {
            let rendered = try SmartExportService.render(source.image, to: plan.pixelSize)
            let usedFormat = try ImageExport.write(
                rendered,
                to: url,
                format: plan.format,
                quality: quality,
                dpiScale: dpiScale
            )
            var finalURL = url
            if usedFormat != plan.format {
                // The encoder fell back to another format, so the bytes on disk
                // do not match the extension the user chose. Correcting that is
                // not optional: if the corrective move failed — the commonest
                // reason being that the correctly-named file already exists —
                // the old code left a mislabelled orphan behind and reported
                // success. Pick a free name instead of colliding.
                var replacement = url.deletingPathExtension()
                    .appendingPathExtension(usedFormat.fileExtension)
                if FileManager.default.fileExists(atPath: replacement.path) {
                    replacement = AppPaths.uniqueURL(
                        in: url.deletingLastPathComponent(),
                        name: url.deletingPathExtension().lastPathComponent,
                        extension: usedFormat.fileExtension
                    )
                }
                do {
                    try FileManager.default.moveItem(at: url, to: replacement)
                } catch {
                    // Never leave a file claiming to be something it is not.
                    try? FileManager.default.removeItem(at: url)
                    throw error
                }
                finalURL = replacement
            }
            return .success(url: finalURL, pixelSize: plan.pixelSize)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private enum ExportOutcome: Sendable {
        case success(url: URL, pixelSize: CGSize)
        case failure(String)
    }

    private struct UncheckedImage: @unchecked Sendable {
        let image: CGImage
    }

    public func shareExported() {
        guard let exportedAsset, SafeAssetFile.isCurrentAndSafe(exportedAsset) else {
            errorMessage = "Export the optimized image before sharing it."
            return
        }
        do {
            try MacSharePresenter.shared.present(items: [exportedAsset.url])
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

public struct SmartExportView: View {
    @Bindable var session: SmartExportSession

    public init(session: SmartExportSession) {
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                Image(nsImage: NSImage(
                    cgImage: session.source,
                    size: NSSize(width: session.source.width, height: session.source.height)
                ))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .accessibilityLabel("Source image for optimized export")
                .frame(width: 260, height: 190)
                .background(.quaternary.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Form {
                    Picker("Preset", selection: $session.preset) {
                        ForEach(SmartExportPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    if session.preset == .customWidth {
                        Stepper(
                            "Maximum width: \(session.customWidth) px",
                            value: $session.customWidth,
                            in: 320 ... 16_384,
                            step: 160
                        )
                    }
                    LabeledContent("Dimensions", value: session.plan.dimensionsDescription)
                    LabeledContent("Format", value: session.plan.format.title)
                    LabeledContent("Estimated size", value: session.plan.estimatedSizeDescription)
                    LabeledContent("Metadata", value: "Removed")
                    LabeledContent("Layers", value: "Flattened")
                }
                .notchShotFormStyle()
                .frame(maxWidth: .infinity)
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "Editable project changes are included only after they have been exported to this image.",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack {
                    if let error = session.errorMessage {
                        InlineErrorMessage(message: error)
                    }
                    Spacer()
                    if session.exportedAsset != nil {
                        Button("Share…") { session.shareExported() }
                            .disabled(session.isExporting)
                    }
                    Button(session.isExporting ? "Exporting…" : "Export…") { session.export() }
                        .notchShotPrimaryActionStyle()
                        .disabled(session.isExporting)
                }
            }
            .padding(14)
        }
        .frame(minWidth: 720, minHeight: 360)
    }
}
