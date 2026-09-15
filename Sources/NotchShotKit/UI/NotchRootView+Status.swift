import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Status / countdown / processing / error

struct StatusContent: View {
    var symbolName: String
    var title: String
    var subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbolName)
                .font(.system(size: 15))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.68))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }
}

struct CountdownContent: View {
    var remaining: Int
    var intent: CaptureIntent
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        Button {
            coordinator.cancelCurrentOperation()
        } label: {
            VStack(spacing: 4) {
                Text("\(remaining)")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
                Text(intent.shortTitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("Cancel capture. Capturing in \(remaining) seconds.")
    }
}

struct ProcessingContent: View {
    var message: String
    @Bindable var coordinator: AppCoordinator

    private var isScrolling: Bool {
        coordinator.isScrollingCaptureActive
    }

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 0)

            if isScrolling {
                NotchIconButton(
                    systemName: "camera.fill",
                    label: "Capture frame now",
                    visualScale: 0.8
                ) {
                    coordinator.captureScrollingFrame()
                }

                NotchIconButton(
                    systemName: "checkmark",
                    label: "Finish scrolling capture",
                    visualScale: 0.8
                ) {
                    coordinator.finishScrollingCapture()
                }
                .keyboardShortcut(.return, modifiers: [])

                NotchIconButton(systemName: "xmark", label: "Cancel", visualScale: 0.8) {
                    coordinator.cancelCurrentOperation()
                }
            }
        }
        .padding(.horizontal, 14)
    }
}

struct ErrorContent: View {
    var message: String
    @Bindable var coordinator: AppCoordinator

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
            Spacer(minLength: 0)

            if coordinator.permissions.pendingRemediation != nil {
                Button(coordinator.permissions.requiresScreenRecordingRelaunch
                       ? "Quit & Reopen" : "Open Settings") {
                    if coordinator.permissions.requiresScreenRecordingRelaunch {
                        coordinator.permissions.relaunchApplication()
                    } else if let kind = coordinator.permissions.pendingRemediation {
                        coordinator.permissions.openSettings(for: kind)
                    }
                }
                .font(.system(size: 10, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(minHeight: NotchShotDesignSystem.minimumControlTarget)
                .contentShape(Rectangle())
                .notchControlSurface(
                    in: Capsule(),
                    reduceTransparency: reduceTransparency,
                    emphasized: true,
                    allowsLiquidGlass: false
                )
            }

            NotchIconButton(systemName: "xmark", label: "Dismiss", visualScale: 0.75) {
                coordinator.dismissError()
            }
        }
        .padding(.horizontal, 14)
    }
}

// MARK: - Recording HUD

struct RecordingContent: View {
    @Bindable var coordinator: AppCoordinator

    private var status: RecordingStatus { coordinator.recordingStatus }

    var body: some View {
        HStack(spacing: 14) {
            RecordingDot()

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(status.elapsedDescription)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                    if status.fileSizeBytes > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: status.fileSizeBytes, countStyle: .file))
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.58))
                    }
                }

                AudioLevelBar(
                    level: status.systemLevel,
                    samples: status.systemWaveform,
                    isEnabled: status.isSystemAudioEnabled,
                    isAvailable: status.isSystemMeterAvailable,
                    symbolName: "speaker.wave.2.fill",
                    label: "System audio level"
                )
                AudioLevelBar(
                    level: status.microphoneLevel,
                    samples: status.microphoneWaveform,
                    isEnabled: status.isMicrophoneEnabled,
                    isAvailable: status.isMicrophoneMeterAvailable,
                    symbolName: "mic.fill",
                    label: "Microphone level"
                )
            }
            .frame(width: 150)

            Spacer(minLength: 0)

            NotchIconButton(
                systemName: coordinator.isRecordingPaused ? "play.fill" : "pause.fill",
                label: coordinator.isRecordingPaused ? "Resume recording" : "Pause recording"
            ) {
                if coordinator.isRecordingPaused {
                    coordinator.resumeRecording()
                } else {
                    coordinator.pauseRecording()
                }
            }

            NotchIconButton(systemName: "stop.fill", label: "Stop recording", tint: .red, isProminent: true) {
                coordinator.stopRecording()
            }

            NotchIconButton(systemName: "trash", label: "Discard recording") {
                coordinator.cancelRecording()
            }
        }
        .padding(.horizontal, 14)
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
            if let physicalNotchWidth {
                compactNotchContent(physicalNotchWidth: physicalNotchWidth)
            } else {
                pillContent
            }
        }
        .animation(
            reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.24, dampingFraction: 0.9),
            value: level.value
        )
        .animation(.easeOut(duration: 0.15), value: level.isMuted)
    }

    private var pillContent: some View {
        HStack(spacing: 12) {
            Image(systemName: level.symbolName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 22)
                // The symbol swaps as the level crosses each threshold; a plain
                // swap would pop, so cross-fade it.
                .contentTransition(.symbolEffect(.replace))

            Text(level.kind.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                // Matches the compact variant. A fixed 96pt box with no scaling
                // truncates a longer localized title to an ellipsis, which in a
                // two-word HUD label leaves nothing readable.
                .minimumScaleFactor(0.75)
                .frame(width: 96, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.18))
                    Capsule()
                        .fill(.white)
                        .frame(width: max(3, geometry.size.width * fillFraction))
                }
            }
            .frame(height: 6)

            Text("\(Int((level.isMuted ? 0 : level.value) * 100))")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .monospacedDigit()
                .frame(width: 26, alignment: .trailing)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 16)
    }

    /// Uses the visible areas beside the camera so system feedback reads as
    /// part of the hardware notch and never creates a second bubble below it.
    private func compactNotchContent(physicalNotchWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: level.symbolName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                Text(level.kind.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.leading, 10)
            .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear
                .frame(width: physicalNotchWidth)
                .accessibilityHidden(true)

            HStack(spacing: 7) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.18))
                        Capsule()
                            .fill(.white)
                            .frame(width: max(3, geometry.size.width * fillFraction))
                    }
                }
                .frame(height: 5)

                Text("\(Int((level.isMuted ? 0 : level.value) * 100))")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                    .monospacedDigit()
                    .frame(width: 24, alignment: .trailing)
                    .contentTransition(.numericText())
            }
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity)
        }
    }

    private var fillFraction: Double {
        level.isMuted ? 0 : min(max(level.value, 0), 1)
    }
}

private struct RecordingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDimmed = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 10, height: 10)
            .opacity(isDimmed ? 0.35 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever()) {
                    isDimmed = true
                }
            }
            .accessibilityHidden(true)
    }
}
