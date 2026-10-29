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

    private var valueTint: Color { IslandAccessibility.valueTint(for: activity, accent: accent) }

    private var glyphSize: CGFloat {
        switch activity.kind {
        case .media: 20
        case .recording: 16
        case .call: 16
        default: 21
        }
    }

    var body: some View {
        Button {
            coordinator.expandIslandPrimary()
            coordinator.noteIslandOpenedByPointer()
        } label: {
            HStack(spacing: 0) {
                HStack(spacing: NotchIsland.Spacing.snug) {
                    IslandGlyphSlot(id: activity.id, level: .compact, size: glyphSize)
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
        .buttonStyle(IslandSquishButtonStyle())
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
            IslandClockText(
                text: coordinator.recordingStatus.elapsedDescription,
                font: .system(size: 11, weight: .semibold, design: .rounded),
                color: .red
            )
        } else if activity.kind == .call {
            IslandCallElapsed(
                startedAt: activity.startedAt,
                font: .system(size: isFloating ? 12 : 11, weight: .semibold, design: .rounded)
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
                IslandClockText(
                    text: coordinator.recordingStatus.elapsedDescription,
                    font: .system(size: 12, weight: .semibold, design: .rounded),
                    color: .red
                )
            } else {
                IslandMiniWaveform(samples: coordinator.recordingStatus.systemWaveform, tint: .red)
                    .frame(width: 30, height: 14)
            }
        case .timer:
            IslandClockText(
                text: coordinator.context.timer.current.map { IslandClock.formatted($0.remaining, roundingUp: true) }
                    ?? activity.metric ?? "",
                font: .system(size: 12, weight: .semibold, design: .rounded),
                color: accent
            )
        case .voiceNote:
            IslandClockText(
                text: coordinator.context.voiceNotes.snapshot.map { IslandClock.formatted($0.elapsed) }
                    ?? activity.metric ?? "",
                font: .system(size: 12, weight: .semibold, design: .rounded),
                color: .red
            )
        case .transfer where !activity.lifecycle.isTerminal && activity.progress.fraction != nil:
            IslandRingGlyph(
                progress: activity.progress,
                lifecycle: activity.lifecycle,
                accent: accent,
                side: 19
            ) { EmptyView() }
        case .ai, .transfer, .external:
            if activity.lifecycle.isTerminal || activity.progress.fraction == nil {
                IslandStateText(
                    text: activity.stateLabel ?? "",
                    font: .system(size: 12, weight: .semibold),
                    color: IslandAccessibility.lifecycleColor(activity.lifecycle, accent: valueTint)
                )
                .minimumScaleFactor(0.8)
            } else {
                IslandNumericText(
                    text: activity.metric ?? "",
                    font: .system(size: 12, weight: .semibold, design: .rounded),
                    color: valueTint
                )
            }
        case .calendar:
            Text(activity.metric ?? "")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        case .call:
            IslandCallWaveform(animates: coordinator.media.areScreensAwake)
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
        case .call:
            parts.append("On a call")
            parts.append(FocusTimerPolicy.formatted(max(0, Date().timeIntervalSince(activity.startedAt))))
        default:
            if let state = activity.stateLabel { parts.append(state) }
            if let fraction = activity.progress.fraction {
                parts.append("\(Int((fraction * 100).rounded(.down))) percent")
            }
        }
        return parts.joined(separator: ", ")
    }

    /// The colour of a live value. Agents stay neutral while they work:
    /// Claude's coral would read as the orange that means "needs you".
    static func valueTint(for activity: IslandActivity, accent: Color) -> Color {
        activity.kind == .ai ? Color.islandInk(NotchIsland.Ink.body) : accent
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

/// The short value a lone satellite shows beside its glyph: the same numbers
/// the compact primary shows, at a size that fits a 40 pt slot.
struct IslandSatelliteValue: View {
    var activity: IslandActivity
    @Bindable var coordinator: AppCoordinator

    private var accent: Color {
        Color(nsColor: NotchShotColorPolicy.readableAccentOnBlack(
            NSColor(hex: activity.accentHex) ?? .systemBlue
        ))
    }
    private let font = Font.system(size: 11, weight: .semibold, design: .rounded)

    var body: some View {
        Group {
            switch activity.kind {
            case .recording:
                IslandClockText(text: coordinator.recordingStatus.elapsedDescription, font: font, color: .red)
            case .timer:
                IslandClockText(
                    text: coordinator.context.timer.current.map { IslandClock.formatted($0.remaining, roundingUp: true) }
                        ?? activity.metric ?? "",
                    font: font,
                    color: accent
                )
            case .voiceNote:
                IslandClockText(
                    text: coordinator.context.voiceNotes.snapshot.map { IslandClock.formatted($0.elapsed) }
                        ?? activity.metric ?? "",
                    font: font,
                    color: .red
                )
            case .ai, .transfer, .external:
                if activity.lifecycle.isTerminal || activity.progress.fraction == nil {
                    IslandStateText(
                        text: activity.stateLabel ?? "",
                        font: .system(size: 10, weight: .semibold),
                        color: IslandAccessibility.lifecycleColor(
                            activity.lifecycle,
                            accent: IslandAccessibility.valueTint(for: activity, accent: accent)
                        )
                    )
                } else {
                    IslandNumericText(
                        text: activity.metric ?? "",
                        font: font,
                        color: IslandAccessibility.valueTint(for: activity, accent: accent)
                    )
                }
            case .calendar:
                Text(activity.metric ?? "")
                    .font(font)
                    .foregroundStyle(accent)
                    .lineLimit(1)
            case .call:
                IslandCallElapsed(startedAt: activity.startedAt, font: font)
            case .media:
                EmptyView()
            }
        }
        .minimumScaleFactor(0.7)
        .lineLimit(1)
    }
}
