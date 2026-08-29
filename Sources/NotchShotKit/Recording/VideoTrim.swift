import AVFoundation
import AVKit
import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
public final class VideoTrimSession {
    public let asset: CaptureAsset
    public private(set) var duration: TimeInterval = 0
    public var startTime: TimeInterval = 0
    public var endTime: TimeInterval = 0
    public private(set) var isLoading = true
    public private(set) var isExporting = false
    public private(set) var errorMessage: String?
    public let player: AVPlayer
    public var onExport: ((CaptureAsset) -> Void)?

    public init(asset: CaptureAsset) {
        self.asset = asset
        player = AVPlayer()
    }

    public var isReady: Bool {
        !isLoading && duration.isFinite && duration > 0
    }

    public func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        guard SafeAssetFile.isCurrentAndSafe(asset) else {
            duration = 0
            endTime = 0
            errorMessage = "This recording changed after it was added. Add the current file again."
            return
        }
        let source = AVURLAsset(url: asset.url)
        player.replaceCurrentItem(with: AVPlayerItem(asset: source))
        do {
            let loadedDuration = try await source.load(.duration).seconds
            guard loadedDuration.isFinite, loadedDuration > 0 else {
                duration = 0
                endTime = 0
                errorMessage = "This recording does not have a valid duration."
                return
            }
            duration = loadedDuration
            endTime = loadedDuration
        } catch {
            duration = 0
            endTime = 0
            errorMessage = "The recording duration could not be read."
        }
    }

    public func restoreOriginalRange() {
        startTime = 0
        endTime = duration
    }

    public func previewFromStart() {
        player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600))
        player.play()
    }

    public func export() async {
        guard !isExporting, endTime > startTime else { return }
        guard SafeAssetFile.isCurrentAndSafe(asset) else {
            errorMessage = "This recording changed after it was added. Add the current file again."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = asset.url.deletingPathExtension().lastPathComponent + " Trimmed.mp4"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard SafeAssetFile.isCurrentAndSafe(asset) else {
            errorMessage = "This recording changed while the Save panel was open. Nothing was exported."
            return
        }

        isExporting = true
        errorMessage = nil
        defer { isExporting = false }
        do {
            let source = AVURLAsset(url: asset.url)
            guard let exporter = AVAssetExportSession(
                asset: source,
                presetName: AVAssetExportPresetPassthrough
            ) else {
                throw NotchShotError.exportFailed("Could not prepare the trimmed recording")
            }
            exporter.timeRange = CMTimeRange(
                start: CMTime(seconds: startTime, preferredTimescale: 600),
                duration: CMTime(seconds: endTime - startTime, preferredTimescale: 600)
            )
            try await exporter.export(to: destination, as: .mp4)
            let metadata = await VideoThumbnail.metadata(for: destination)
            let trimmed = CaptureAsset(
                url: destination,
                kind: .recording,
                pixelSize: metadata?.pixelSize ?? asset.pixelSize,
                scale: 1,
                duration: metadata?.duration ?? endTime - startTime,
                ownership: .userDocument
            )
            onExport?(trimmed)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

public struct VideoTrimView: View {
    @Bindable var session: VideoTrimSession

    public init(session: VideoTrimSession) {
        self.session = session
    }

    public var body: some View {
        Group {
            if session.isLoading {
                ProgressView("Loading recording…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !session.isReady {
                ContentUnavailableView(
                    "Couldn’t load recording",
                    systemImage: "film.stack.fill",
                    description: Text(session.errorMessage ?? "The recording is unavailable or unsupported.")
                )
            } else {
                editor
            }
        }
        .padding(18)
        .frame(minWidth: 620, minHeight: 440)
        .task { await session.load() }
    }

    private var editor: some View {
        VStack(spacing: 16) {
            VideoPlayer(player: session.player)
                .frame(minHeight: 260)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(spacing: 12) {
                LabeledContent {
                    Slider(
                        value: $session.startTime,
                        in: 0...max(0.01, session.endTime - 0.05)
                    )
                    .accessibilityLabel("Trim start")
                    .accessibilityValue(time(session.startTime))
                } label: {
                    Text("Start \(time(session.startTime))")
                        .monospacedDigit()
                }
                .font(.caption)

                LabeledContent {
                    Slider(
                        value: $session.endTime,
                        in: min(session.duration, session.startTime + 0.05)...max(session.duration, 0.06)
                    )
                    .accessibilityLabel("Trim end")
                    .accessibilityValue(time(session.endTime))
                } label: {
                    Text("End \(time(session.endTime))")
                        .monospacedDigit()
                }
                .font(.caption)

                HStack {
                    Button("Restore Original") { session.restoreOriginalRange() }
                    Button("Preview") { session.previewFromStart() }
                    Spacer()
                    if let errorMessage = session.errorMessage {
                        InlineErrorMessage(message: errorMessage)
                    }
                    Button(session.isExporting ? "Exporting…" : "Export Trimmed Copy…") {
                        Task { await session.export() }
                    }
                    .notchShotPrimaryActionStyle()
                    .disabled(session.isExporting || session.endTime <= session.startTime)
                }
            }
        }
    }

    private func time(_ value: TimeInterval) -> String {
        String(format: "%02d:%02d.%01d", Int(value) / 60, Int(value) % 60, Int(value * 10) % 10)
    }
}
