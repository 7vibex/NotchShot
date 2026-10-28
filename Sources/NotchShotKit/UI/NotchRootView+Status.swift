import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Status / countdown / processing / error

struct StatusContent: View {
    var symbolName: String
    var title: String
    var subtitle: String

    var body: some View {
        IslandBandHeader {
            IslandBandTitle(systemImage: symbolName, title: title, tint: .white)
        } trailing: {
            Text(subtitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .combine)
    }
}

/// The delay before a capture, wrapped round the camera: what is about to be
/// captured on the left, the seconds on the right. Clicking cancels.
struct CountdownContent: View {
    var remaining: Int
    var intent: CaptureIntent
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        Button {
            coordinator.cancelCurrentOperation()
        } label: {
            IslandBandHeader(trailingInset: 16) {
                IslandBandTitle(systemImage: intent.symbolName, title: intent.shortTitle, tint: .white)
            } trailing: {
                Text("\(remaining)")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .keyboardShortcut(.cancelAction)
        .help("Click or press Esc to cancel")
        .accessibilityLabel("Cancel capture. Capturing in \(remaining) seconds.")
    }
}

/// A white arc that turns, readable on the island's black. The system's small
/// spinner ignores `.tint` on macOS and draws in a grey that all but vanishes
/// there. Reduce Motion holds a static arc.
///
/// The turn is a layer animation. As a `TimelineView(.animation)` it rebuilt
/// and laid out the notch on the main thread every frame it was on screen.
struct IslandSpinner: View {
    var size: CGFloat = 15
    var tint: Color = .white

    var body: some View {
        LayerSpinner(
            diameter: size,
            lineWidth: max(1.5, size * 0.14),
            tint: tint,
            trackOpacity: 0.18,
            arcLength: 0.28,
            period: 0.9
        )
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("In progress")
    }
}

struct ProcessingContent: View {
    var message: String
    @Bindable var coordinator: AppCoordinator

    private var isScrolling: Bool {
        coordinator.isScrollingCaptureActive
    }

    var body: some View {
        VStack(spacing: 0) {
            IslandBandHeader(trailingInset: 16) {
                IslandSpinner(size: 15)
            } trailing: {
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            if isScrolling {
                HStack(spacing: NotchIsland.Spacing.element) {
                    IslandTextButton(title: "Capture Frame", systemImage: "camera.fill") {
                        coordinator.captureScrollingFrame()
                    }
                    IslandTextButton(title: "Finish", systemImage: "checkmark") {
                        coordinator.finishScrollingCapture()
                    }
                    .keyboardShortcut(.return, modifiers: [])
                    Spacer(minLength: 0)
                    IslandBandButton(systemName: "xmark", label: "Cancel") {
                        coordinator.cancelCurrentOperation()
                    }
                }
                .padding(.horizontal, NotchIsland.Spacing.gutter)
                .padding(.top, NotchIsland.Spacing.tight)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message)
    }
}

struct ErrorContent: View {
    var message: String
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            IslandBandHeader {
                IslandBandTitle(
                    systemImage: "exclamationmark.triangle.fill",
                    title: "Couldn’t finish",
                    tint: IslandSystemColor.orange
                )
            } trailing: {
                IslandBandButton(systemName: "xmark", label: "Dismiss") {
                    coordinator.dismissError()
                }
            }

            HStack(alignment: .center, spacing: NotchIsland.Spacing.row) {
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.islandInk(0.86))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if coordinator.permissions.pendingRemediation != nil {
                    IslandTextButton(
                        title: coordinator.permissions.requiresScreenRecordingRelaunch
                            ? "Quit & Reopen" : "Open Settings",
                        systemImage: coordinator.permissions.requiresScreenRecordingRelaunch
                            ? "arrow.clockwise" : "gearshape"
                    ) {
                        if coordinator.permissions.requiresScreenRecordingRelaunch {
                            coordinator.permissions.relaunchApplication()
                        } else if let kind = coordinator.permissions.pendingRemediation {
                            coordinator.permissions.openSettings(for: kind)
                        }
                    }
                }
            }
            .padding(.horizontal, NotchIsland.Spacing.gutter + 2)
            .padding(.top, NotchIsland.Spacing.tight)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Error: \(message)")
    }
}

// MARK: - Recording HUD

struct RecordingContent: View {
    @Bindable var coordinator: AppCoordinator
    /// Inside the island the indicator is a shared element that travels from
    /// the compact wing; this reserves its place instead of drawing a second dot.
    var sharedIndicatorID: IslandActivityID?

    private var status: RecordingStatus { coordinator.recordingStatus }

    /// The phone marks a recording with a red dot and a red clock, never with
    /// an outline round the island; the shell's red keyline is gone for that
    /// reason, and the time carries the colour instead.
    private var timeColor: Color {
        coordinator.isRecordingPaused ? Color.islandInk(NotchIsland.Ink.secondary) : IslandSystemColor.red
    }

    var body: some View {
        VStack(spacing: 0) {
            IslandBandHeader(leadingInset: 16, trailingInset: 16) {
                HStack(spacing: 7) {
                    if let sharedIndicatorID {
                        IslandGlyphSlot(id: sharedIndicatorID, size: 12)
                    } else {
                        RecordingDot()
                    }
                    IslandClockText(
                        text: status.elapsedDescription,
                        font: .system(size: 17, weight: .semibold, design: .rounded),
                        color: timeColor
                    )
                    .fixedSize()
                }
            } trailing: {
                Text(trailingCaption)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }

            HStack(spacing: NotchIsland.Spacing.group) {
                VStack(alignment: .leading, spacing: 9) {
                    RecordingLevelMeter(
                        level: status.systemLevel,
                        isEnabled: status.isSystemAudioEnabled,
                        isAvailable: status.isSystemMeterAvailable,
                        symbolName: "speaker.wave.2.fill",
                        label: "System audio level"
                    )
                    RecordingLevelMeter(
                        level: status.microphoneLevel,
                        isEnabled: status.isMicrophoneEnabled,
                        isAvailable: status.isMicrophoneMeterAvailable,
                        symbolName: "mic.fill",
                        label: "Microphone level"
                    )
                }
                .frame(maxWidth: .infinity)

                // The same round controls as the timer and call cards, so every
                // live activity on the island is driven the same way.
                HStack(spacing: 8) {
                    IslandRoundButton(
                        systemName: coordinator.isRecordingPaused ? "play.fill" : "pause.fill",
                        label: coordinator.isRecordingPaused ? "Resume recording" : "Pause recording",
                        tint: .white,
                        filled: false
                    ) {
                        if coordinator.isRecordingPaused {
                            coordinator.resumeRecording()
                        } else {
                            coordinator.pauseRecording()
                        }
                    }
                    IslandRoundButton(systemName: "stop.fill", label: "Stop recording", tint: .red, filled: true, solid: true) {
                        coordinator.stopRecording()
                    }
                    IslandRoundButton(systemName: "trash", label: "Discard recording", tint: .white, filled: false) {
                        coordinator.cancelRecording()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, NotchIsland.Spacing.tight)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var trailingCaption: String {
        if coordinator.isRecordingPaused { return "Paused" }
        guard status.fileSizeBytes > 0 else { return "Recording" }
        return ByteCountFormatter.string(fromByteCount: status.fileSizeBytes, countStyle: .file)
    }
}

/// A level meter that reads as one: a track the width of the column with a
/// green-to-red fill, instead of a row of 2 pt dots that looked like a dotted
/// line whenever the input was quiet.
struct RecordingLevelMeter: View {
    var level: Float
    var isEnabled: Bool
    var isAvailable: Bool
    var symbolName: String
    var label: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: CGFloat {
        guard isEnabled, isAvailable else { return 0 }
        return max(0, min(CGFloat(level), 1))
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: isEnabled ? symbolName : (symbolName.hasPrefix("mic") ? "mic.slash.fill" : "speaker.slash.fill"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 14)

            if isEnabled, !isAvailable {
                Text("Meter unavailable")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(IslandSystemColor.orange)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !isEnabled {
                Text("Off")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.islandInk(0.14))
                        LinearGradient(
                            stops: [
                                .init(color: IslandSystemColor.green, location: 0),
                                .init(color: IslandSystemColor.green, location: 0.62),
                                .init(color: .yellow, location: 0.8),
                                .init(color: IslandSystemColor.red, location: 1),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .mask(alignment: .leading) {
                            Capsule().frame(width: max(fraction > 0.01 ? 6 : 0, proxy.size.width * fraction))
                        }
                    }
                }
                .frame(height: 6)
                .animation(reduceMotion ? nil : .linear(duration: 0.08), value: fraction)
            }
        }
        .frame(height: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue)
    }

    private var iconColor: Color {
        if !isEnabled { return Color.islandInk(0.32) }
        if !isAvailable { return IslandSystemColor.orange }
        return Color.islandInk(NotchIsland.Ink.secondary)
    }

    private var accessibilityValue: String {
        if !isEnabled { return "off" }
        if !isAvailable { return "meter unavailable" }
        switch level {
        case ..<0.02: return "silent"
        case ..<0.35: return "low"
        case ..<0.75: return "moderate"
        case ..<0.92: return "high"
        default: return "near clipping"
        }
    }
}

// MARK: - System level HUD

/// Mirrors a volume or brightness change, in the shape of the system HUD but
/// living in the notch.
struct SystemLevelContent: View {
    var level: SystemLevel
    var physicalNotchWidth: CGFloat?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if level.kind == .volume, level.isMuted {
                // Muting is a state, not a level: the phone answers its switch
                // with the Silent pill rather than an empty slider.
                IslandSilentContent(physicalNotchWidth: physicalNotchWidth)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            } else if let physicalNotchWidth {
                compactNotchContent(physicalNotchWidth: physicalNotchWidth)
            } else {
                pillContent
            }
        }
        .animation(
            NotchMotion.liveValue(reduceMotion: reduceMotion),
            value: level.value
        )
        .animation(NotchMotion.fade(reduceMotion: false), value: level.isMuted)
    }

    // Icon and bar only. The "Volume" / "Brightness" word repeated what the
    // symbol already says and pushed the bar down to a 5 pt hairline.
    private var pillContent: some View {
        HStack(spacing: 12) {
            levelSymbol(size: 16)
                .frame(width: 24)
            LevelBar(fraction: fillFraction, isMuted: level.isMuted, height: 8, bump: level.bump)
            percentage(size: 12)
        }
        .padding(.horizontal, 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(level.kind.title)
        .accessibilityValue(accessibilityValue)
    }

    /// Uses the visible areas beside the camera so system feedback reads as
    /// part of the hardware notch and never creates a second bubble below it.
    private func compactNotchContent(physicalNotchWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            levelSymbol(size: 14)
                .padding(.leading, 14)
                .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear
                .frame(width: physicalNotchWidth)
                .accessibilityHidden(true)

            LevelBar(fraction: fillFraction, isMuted: level.isMuted, height: 6, bump: level.bump)
                .padding(.leading, 10)
                .padding(.trailing, 14)
                .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(level.kind.title)
        .accessibilityValue(accessibilityValue)
    }

    @ViewBuilder
    private func levelSymbol(size: CGFloat) -> some View {
        if level.kind == .volume {
            // One speaker whose waves fill with the level, as the system's own
            // volume indicator draws it, instead of three symbols swapped at
            // thresholds.
            Image(systemName: "speaker.wave.3.fill", variableValue: fillFraction)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
        } else {
            Image(systemName: level.symbolName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                // The symbol swaps as the level crosses each threshold; a plain
                // swap would pop, so cross-fade it.
                .contentTransition(.symbolEffect(.replace))
        }
    }

    private func percentage(size: CGFloat) -> some View {
        Text("\(Int((level.isMuted ? 0 : level.value) * 100))")
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
            .monospacedDigit()
            .frame(width: 28, alignment: .trailing)
            .contentTransition(.numericText())
    }

    private var accessibilityValue: String {
        level.isMuted ? "Muted" : "\(Int(level.value * 100)) percent"
    }

    private var fillFraction: Double {
        level.isMuted ? 0 : min(max(level.value, 0), 1)
    }
}

/// A thick track with an accent fill, so the level reads at a glance from the
/// corner of the eye. Muted keeps the track and drops the fill.
private struct LevelBar: View {
    var fraction: Double
    var isMuted: Bool
    var height: CGFloat
    /// A press past the end: the bar stretches toward it and springs back,
    /// as iOS's sliders do, so a key at 100% answers instead of doing nothing.
    var bump: SystemLevelBump? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Counted here rather than read from `bump`, so the press that moves
    /// the level off the end (bump gone) doesn't play the stretch again.
    @State private var stretches = 0
    @State private var stretchEdge: SystemLevelBump.Edge = .top

    var body: some View {
        let stretchAnchor: UnitPoint = stretchEdge == .bottom ? .trailing : .leading
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.islandInk(0.2))
                // White on grey, as the phone's level indicators are. The
                // accent colour made the bar read as a selected control.
                Capsule()
                    .fill(Color.white)
                    .frame(width: max(fraction > 0 ? height : 0, geometry.size.width * fraction))
                    .opacity(isMuted ? 0 : 1)
            }
        }
        .frame(height: height)
        .keyframeAnimator(initialValue: LevelBarStretch(), trigger: stretches) { content, stretch in
            // Pinned at the far end, so the stretch reaches past the edge
            // the key pushed against.
            content.scaleEffect(
                x: stretch.width,
                y: stretch.height,
                anchor: stretchAnchor
            )
        } keyframes: { _ in
            KeyframeTrack(\.width) {
                SpringKeyframe(1.08, duration: 0.11, spring: .snappy)
                SpringKeyframe(1, duration: 0.5, spring: .bouncy(duration: 0.5, extraBounce: 0.1))
            }
            KeyframeTrack(\.height) {
                SpringKeyframe(0.72, duration: 0.11, spring: .snappy)
                SpringKeyframe(1, duration: 0.5, spring: .bouncy(duration: 0.5, extraBounce: 0.1))
            }
        }
        // The HUD often appears on the very press that hits the end.
        .onAppear { stretch(for: bump) }
        .onChange(of: bump) { _, bump in stretch(for: bump) }
    }

    private func stretch(for bump: SystemLevelBump?) {
        guard let bump, !reduceMotion else { return }
        stretchEdge = bump.edge
        stretches += 1
    }
}

private struct LevelBarStretch {
    var width: CGFloat = 1
    var height: CGFloat = 1
}

/// Breathes on the render server; see `LayerPulsingDot`.
private struct RecordingDot: View {
    var body: some View {
        LayerPulsingDot(diameter: 10, color: .red, pulseOpacity: 0.35, halfPeriod: 0.9)
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)
    }
}
