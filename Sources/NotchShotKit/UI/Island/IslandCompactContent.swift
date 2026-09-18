import AppKit
import SwiftUI

/// The compact primary: a shared element in the leading wing and one short,
/// live value in the trailing wing, with the camera cutout reserved between.
///
/// Every value is read from its source when drawn, so a tick re-renders a
/// single `Text` and never changes a frame the shell depends on.
struct IslandCompactContent: View {
    var activity: IslandActivity
    var physicalNotchWidth: CGFloat?
    @Bindable var coordinator: AppCoordinator

    private var isFloating: Bool { physicalNotchWidth == nil }

    private var accent: Color {
        Color(nsColor: NotchShotColorPolicy.readableAccentOnBlack(
            NSColor(hex: activity.accentHex) ?? .systemBlue
        ))
    }

    private var glyphSize: CGFloat {
        switch activity.kind {
        case .media: 20
        case .recording: 16
        default: 21
        }
    }

    var body: some View {
        Button {
            coordinator.expandIslandPrimary()
        } label: {
            HStack(spacing: 0) {
                HStack(spacing: NotchIsland.Spacing.snug) {
                    IslandGlyphSlot(id: activity.id, size: glyphSize)
                    leadingDetail
                }
                .padding(.leading, isFloating ? NotchIsland.Geometry.floatingContentInset : 7)
                .frame(maxWidth: .infinity, alignment: .leading)

                if let physicalNotchWidth {
                    Color.clear
                        .frame(width: physicalNotchWidth)
                        .accessibilityHidden(true)
                } else {
                    Spacer(minLength: NotchIsland.Spacing.element)
                }

                trailing
                    .padding(.trailing, isFloating ? NotchIsland.Geometry.floatingContentInset + 2 : 9)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            // Fill the shell's height so both wings sit on its vertical centre.
            // Without this the row hugged the top of the taller synthetic pill.
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(activity.kind.title)
        .accessibilityValue(IslandAccessibility.value(for: activity, coordinator: coordinator))
        .accessibilityHint("Shows details. Adjust to switch between activities.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: coordinator.selectIslandNeighbor(.trailing)
            case .decrement: coordinator.selectIslandNeighbor(.leading)
            @unknown default: break
            }
        }
    }

    /// A physical notch has room beside the glyph only for a recording's
    /// elapsed time; everything else keeps the wing to the glyph.
    @ViewBuilder
    private var leadingDetail: some View {
        if activity.kind == .recording, !isFloating {
            IslandNumericText(
                text: coordinator.recordingStatus.elapsedDescription,
                font: .system(size: 11, weight: .semibold, design: .rounded),
                color: .red
            )
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch activity.kind {
        case .media:
            PlaybackIndicator(
                isPlaying: coordinator.media.snapshot.isPlaying,
                accentColor: Color(nsColor: coordinator.media.artworkAccentColor),
                animates: coordinator.media.areScreensAwake
            )
        case .recording:
            if isFloating {
                IslandNumericText(
                    text: coordinator.recordingStatus.elapsedDescription,
                    font: .system(size: 12, weight: .semibold, design: .rounded),
                    color: .red
                )
            } else {
                IslandMiniWaveform(samples: coordinator.recordingStatus.systemWaveform, tint: .red)
                    .frame(width: 30, height: 14)
            }
        case .timer:
            IslandNumericText(
                text: coordinator.context.timer.current.map { FocusTimerPolicy.formatted($0.remaining) }
                    ?? activity.metric ?? "",
                countsDown: true,
                font: .system(size: 12, weight: .semibold, design: .rounded),
                color: accent
            )
        case .voiceNote:
            IslandNumericText(
                text: coordinator.context.voiceNotes.snapshot.map { FocusTimerPolicy.formatted($0.elapsed) }
                    ?? activity.metric ?? "",
                font: .system(size: 12, weight: .semibold, design: .rounded),
                color: .red
            )
        case .ai, .transfer, .external:
            if activity.lifecycle.isTerminal || activity.progress.fraction == nil {
                IslandStateText(
                    text: activity.stateLabel ?? "",
                    font: .system(size: 11, weight: .semibold),
                    color: IslandAccessibility.lifecycleColor(activity.lifecycle, accent: accent)
                )
                .minimumScaleFactor(0.8)
            } else {
                IslandNumericText(
                    text: activity.metric ?? "",
                    font: .system(size: 12, weight: .semibold, design: .rounded),
                    color: accent
                )
            }
        case .calendar:
            Text(activity.metric ?? "")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

/// A tiny real meter from recorded samples; flat when the tap is silent.
struct IslandMiniWaveform: View {
    var samples: [Float]
    var tint: Color

    var body: some View {
        let recent = Array(samples.suffix(8))
        HStack(alignment: .center, spacing: 1.5) {
            ForEach(recent.indices, id: \.self) { index in
                Capsule()
                    .fill(tint.opacity(0.85))
                    .frame(width: 2, height: max(2, CGFloat(recent[index]) * 14))
            }
        }
        .animation(.linear(duration: 0.1), value: recent)
        .accessibilityHidden(true)
    }
}

/// Shared phrasing so compact, satellite and expanded forms read the same
/// to VoiceOver.
@MainActor
enum IslandAccessibility {
    static func value(for activity: IslandActivity, coordinator: AppCoordinator) -> String {
        var parts: [String] = [activity.title]
        switch activity.kind {
        case .recording:
            parts = [coordinator.isRecordingPaused ? "Paused" : "Recording", coordinator.recordingStatus.elapsedDescription]
        case .timer:
            if let timer = coordinator.context.timer.current {
                parts.append(FocusTimerPolicy.formatted(timer.remaining) + " remaining")
            }
        case .media:
            if let artist = coordinator.media.snapshot.artist { parts.append(artist) }
            parts.append(coordinator.media.snapshot.isPlaying ? "Playing" : "Paused")
        default:
            if let state = activity.stateLabel { parts.append(state) }
            if let fraction = activity.progress.fraction {
                parts.append("\(Int((fraction * 100).rounded(.down))) percent")
            }
        }
        return parts.joined(separator: ", ")
    }

    static func lifecycleColor(_ lifecycle: IslandLifecycle, accent: Color) -> Color {
        switch lifecycle {
        case .succeeded: .green
        case .failed: .red
        case .waiting: .orange
        case .paused: Color.islandInk(NotchIsland.Ink.secondary)
        case .active: accent
        }
    }
}
