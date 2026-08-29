import AppKit
import SwiftUI

/// Dictation island morphed from the physical notch.
///
/// Anchored top-centre, expanding symmetrically, with the hardware cutout kept
/// as a continuous black centre. The band beside the camera carries only
/// glanceable status; every control lives in the pill below it, where a full
/// 36pt target fits without being clipped by the notch band.
struct DictationIslandContent: View {
    var snapshot: DictationSnapshot
    var metrics: NotchMetrics
    @Bindable var coordinator: AppCoordinator

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var hasPhysicalNotch: Bool { metrics.hasPhysicalNotch }
    private var notchWidth: CGFloat { metrics.notchSize.width }
    private var increaseContrast: Bool { colorSchemeContrast == .increased }

    var body: some View {
        VStack(spacing: 0) {
            if hasPhysicalNotch {
                wingRow
                    .opacity(showsWingStatus ? 1 : 0)
                    .frame(height: metrics.notchSize.height)
                    .padding(.horizontal, NotchLayout.dictationHorizontalPadding)
            }
            controlRow
                .frame(height: NotchLayout.dictationControlRowHeight)
                .padding(.horizontal, NotchLayout.dictationHorizontalPadding)
            if showsTranscript {
                transcriptSurface
                    .padding(.horizontal, NotchLayout.dictationHorizontalPadding)
                    .padding(.top, 2)
            }
            if isFailed {
                recoveryRow
                    .padding(.horizontal, NotchLayout.dictationHorizontalPadding)
                    .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 8)
        .foregroundStyle(.white)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(accessibilityHint)
        .accessibilityAction(named: "Stop") { stop() }
        .accessibilityAction(named: "Cancel") { cancel() }
        .onHover { hovering in
            coordinator.dictation.setHoverExpanded(hovering)
        }
    }

    // MARK: Notch band

    /// Left and right of the camera cutout. Status and elapsed time only: this
    /// band is as tall as the hardware notch, so anything with a real hit target
    /// would overflow it.
    private var wingRow: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .accessibilityHidden(true)
                Text(statusText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(increaseContrast ? 0.95 : 0.72))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear
                .frame(width: notchWidth + NotchLayout.dictationCameraClearance)
                .accessibilityHidden(true)

            Group {
                if showsElapsed {
                    DictationTimerLabel(dictation: coordinator.dictation)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .accessibilityHidden(true)
    }

    // MARK: Pill

    /// The waveform is the one moving element, flanked by the two actions the
    /// user can take. On a notchless display it also carries the status glyph
    /// and timer, because there is no band above it to hold them.
    private var controlRow: some View {
        HStack(spacing: 8) {
            if !hasPhysicalNotch {
                Image(systemName: statusSymbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .accessibilityHidden(true)
            }

            centrePiece
                .frame(maxWidth: .infinity)

            if !hasPhysicalNotch, showsElapsed {
                DictationTimerLabel(dictation: coordinator.dictation)
            }

            if isStoppable {
                stopButton
            } else if isFailed {
                retryButton
            }

            if showsCancel {
                cancelButton
            }
        }
    }

    @ViewBuilder
    private var centrePiece: some View {
        switch snapshot.state {
        case .listening, .finalizing:
            LiveDictationWaveform(
                dictation: coordinator.dictation,
                isListening: snapshot.state == .listening,
                reduceMotion: reduceMotion,
                reduceTransparency: reduceTransparency,
                increaseContrast: increaseContrast
            )
            .frame(height: 22)
            .accessibilityHidden(true)
        case .preparingModel(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.white.opacity(0.85))
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.65))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Downloading on-device model")
            .accessibilityValue("\(Int((progress * 100).rounded())) percent")
        case .requestingMicrophone:
            inlineStatus("Waiting for permission…", symbol: nil, spinner: true)
        case .inserting:
            inlineStatus("Inserting…", symbol: nil, spinner: true, alignment: .center)
        case .completed:
            inlineStatus("Inserted", symbol: "checkmark.circle.fill", tint: .green, alignment: .center)
        case .copied:
            inlineStatus("Copied to clipboard", symbol: "doc.on.clipboard", alignment: .center)
        case .cancelled:
            inlineStatus("Cancelled", symbol: nil, alignment: .center)
        case .failed(let message):
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .idle:
            Color.clear
        }
    }

    private func inlineStatus(
        _ title: String,
        symbol: String?,
        tint: Color = .white,
        spinner: Bool = false,
        alignment: Alignment = .leading
    ) -> some View {
        HStack(spacing: 6) {
            if spinner {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
            }
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: alignment)
        .accessibilityElement(children: .combine)
    }

    // MARK: Controls

    private var stopButton: some View {
        Button(action: stop) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(.white)
                .frame(width: 10, height: 10)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .notchControlSurface(
            in: Circle(),
            reduceTransparency: reduceTransparency,
            tint: Color(nsColor: .systemRed),
            emphasized: true
        )
        .frame(
            width: NotchShotDesignSystem.minimumControlTarget,
            height: NotchShotDesignSystem.minimumControlTarget
        )
        .contentShape(Rectangle())
        .accessibilityLabel("Stop dictation")
        .help("Stop and insert (repeat the dictation shortcut)")
    }

    private var retryButton: some View {
        Button(action: retry) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .notchControlSurface(in: Circle(), reduceTransparency: reduceTransparency)
        .frame(
            width: NotchShotDesignSystem.minimumControlTarget,
            height: NotchShotDesignSystem.minimumControlTarget
        )
        .contentShape(Rectangle())
        .accessibilityLabel("Retry dictation")
    }

    private var cancelButton: some View {
        Button(action: cancel) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .notchControlSurface(in: Circle(), reduceTransparency: reduceTransparency)
        .frame(
            width: NotchShotDesignSystem.minimumControlTarget,
            height: NotchShotDesignSystem.minimumControlTarget
        )
        .contentShape(Rectangle())
        .help("Cancel (Esc)")
        .accessibilityLabel("Cancel dictation")
    }

    // MARK: Transcript

    /// A faint raised surface, not a black card. The shell behind it is already
    /// black, so the previous near-opaque black fill drew an invisible box that
    /// only added height.
    private var transcriptSurface: some View {
        transcriptText
            .frame(
                maxWidth: .infinity,
                minHeight: snapshot.isHoverExpanded ? 30 : 15,
                alignment: .topLeading
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(reduceTransparency ? Color(white: 0.16) : .white.opacity(0.07))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(.white.opacity(increaseContrast ? 0.32 : 0.08), lineWidth: 1)
                    }
            }
    }

    private var transcriptText: some View {
        // Head truncation keeps the most recent words visible, which is the end
        // of the sentence the user is still speaking.
        Text(transcriptAttributed)
        .font(.system(size: 11.5))
        .lineLimit(snapshot.isHoverExpanded ? 2 : 1)
        .truncationMode(.head)
        .multilineTextAlignment(.leading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: snapshot.volatileText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Transcript")
        .accessibilityValue(snapshot.combinedText.isEmpty ? "Listening" : snapshot.combinedText)
    }

    /// One paragraph so it wraps and truncates as a unit, with the
    /// not-yet-final words dimmed to show they may still change.
    private var transcriptAttributed: AttributedString {
        var finalized = AttributedString(snapshot.finalizedText)
        finalized.foregroundColor = .white
        var pending = AttributedString(transcriptJoiner + snapshot.volatileText)
        pending.foregroundColor = .white.opacity(increaseContrast ? 0.8 : 0.55)
        return finalized + pending
    }

    private var transcriptJoiner: String {
        snapshot.finalizedText.isEmpty || snapshot.volatileText.isEmpty ? "" : " "
    }

    private var recoveryRow: some View {
        HStack(spacing: 8) {
            if !snapshot.combinedText.isEmpty {
                compactControl("Copy", action: copyTranscript)
            }
            if !isAccessibilityGranted {
                compactControl("Open Accessibility", action: openAccessibilitySettings)
            }
            compactControl("Settings", action: openSettings)
            Spacer(minLength: 0)
        }
    }

    private func compactControl(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 10)
            .frame(minHeight: 26)
            .notchControlSurface(in: Capsule(), reduceTransparency: reduceTransparency)
            .frame(minWidth: 44, minHeight: NotchShotDesignSystem.minimumControlTarget)
            .contentShape(Rectangle())
    }

    // MARK: Helpers

    private var showsTranscript: Bool {
        switch snapshot.state {
        case .listening, .finalizing: !snapshot.combinedText.isEmpty
        default: false
        }
    }

    /// Terminal and hand-off states say everything they need to in the pill.
    /// Repeating it beside the camera printed the same word twice.
    private var showsWingStatus: Bool {
        switch snapshot.state {
        case .inserting, .completed, .copied, .cancelled, .idle: false
        default: true
        }
    }

    private var showsElapsed: Bool {
        switch snapshot.state {
        case .listening, .finalizing: true
        default: false
        }
    }

    private var showsCancel: Bool {
        switch snapshot.state {
        case .completed, .copied, .cancelled, .idle, .inserting: false
        default: true
        }
    }

    private var statusSymbol: String {
        switch snapshot.state {
        case .listening: "mic.fill"
        case .finalizing: "waveform"
        case .failed: "exclamationmark.triangle.fill"
        case .completed: "checkmark.circle.fill"
        case .copied: "doc.on.clipboard"
        default: "mic"
        }
    }

    private var statusColor: Color {
        switch snapshot.state {
        case .listening: Color(nsColor: .systemPink)
        case .failed: .orange
        case .completed: .green
        default: .white.opacity(0.9)
        }
    }

    /// Short label for the notch band. It never repeats what the pill below is
    /// already saying — the old island printed the same status twice.
    private var statusText: String {
        switch snapshot.state {
        case .requestingMicrophone: "Microphone"
        case .preparingModel: "Preparing"
        case .listening: "Listening"
        case .finalizing: "Finalizing"
        case .inserting: "Inserting"
        case .completed: "Done"
        case .copied: "Copied"
        case .cancelled: "Cancelled"
        case .failed: "Dictation failed"
        case .idle: ""
        }
    }

    private var isStoppable: Bool { snapshot.state.isStoppable }

    private var isFailed: Bool {
        if case .failed = snapshot.state { return true }
        return false
    }

    private var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    private var accessibilityLabel: String {
        switch snapshot.state {
        case .listening: "Dictation listening"
        case .finalizing: "Finalizing dictation"
        case .completed: "Dictation inserted"
        case .copied: "Dictation copied"
        case .failed(let msg): "Dictation failed: \(msg)"
        default: "Dictation"
        }
    }

    private var accessibilityValue: String {
        snapshot.combinedText
    }

    private var accessibilityHint: String {
        "Repeat the dictation shortcut to stop and insert, or choose Cancel"
    }

    private func stop() {
        switch snapshot.state {
        case .requestingMicrophone, .preparingModel:
            coordinator.dictation.cancel()
        default:
            Task { await coordinator.dictation.stop() }
        }
    }
    private func cancel() { coordinator.dictation.cancel() }
    private func retry() { Task { await coordinator.dictation.start() } }
    private func copyTranscript() {
        let text = snapshot.combinedText
        guard !text.isEmpty else { return }
        ImageExport.copyToPasteboard(text: text)
    }
    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    private func openSettings() {
        coordinator.onOpenSettings?()
    }
}

func dictationAccessibilityDescription(_ snap: DictationSnapshot) -> String {
    switch snap.state {
    case .idle: "Idle"
    case .requestingMicrophone: "Requesting microphone"
    case .preparingModel: "Preparing model"
    case .listening: "Listening, \(snap.combinedText)"
    case .finalizing: "Finalizing"
    case .inserting: "Inserting"
    case .completed: "Inserted: \(snap.finalizedText)"
    case .copied: "Copied"
    case .cancelled: "Cancelled"
    case .failed(let m): "Failed: \(m)"
    }
}

/// Elapsed time, isolated in its own view so the seconds tick invalidates one
/// label instead of the island around it.
struct DictationTimerLabel: View {
    let dictation: DictationCoordinator

    var body: some View {
        Text(Self.format(dictation.elapsedSeconds))
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.85))
            .accessibilityLabel("Elapsed time \(Self.format(dictation.elapsedSeconds))")
    }

    static func format(_ seconds: Int) -> String {
        let total = max(0, seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Observation boundary for the waveform.
///
/// The meter updates 25 times a second. Reading it here — and nowhere else —
/// keeps that invalidation inside a single `Canvas`, instead of redrawing the
/// notch shell, its Liquid Glass, and every control on each tick.
struct LiveDictationWaveform: View {
    let dictation: DictationCoordinator
    var isListening: Bool
    var reduceMotion: Bool
    var reduceTransparency: Bool
    var increaseContrast: Bool

    var body: some View {
        let meter = dictation.meter
        DictationWaveformView(
            columns: meter.columns,
            level: meter.level,
            isCapturing: isListening && meter.isCapturing,
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast
        )
    }
}

/// A scrolling microphone trace: mirrored bars around the centre line, newest
/// at the trailing edge, older columns fading out behind it.
///
/// Drawn in one `Canvas` pass rather than as ~34 animated views. The motion is
/// the data itself — one new column per tick at a constant rate — so there is
/// no per-bar animation to schedule.
struct DictationWaveformView: View {
    var columns: [Float]
    var level: Float
    var isCapturing: Bool
    var reduceMotion: Bool
    var reduceTransparency: Bool = false
    var increaseContrast: Bool = false

    var body: some View {
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) { context, size in
            let values = renderedColumns
            guard !values.isEmpty, size.width > 1, size.height > 1 else { return }

            let slot = size.width / CGFloat(values.count)
            let barWidth = max(1.5, min(3, slot * 0.58))
            let radius = barWidth / 2
            let midY = size.height / 2
            let maxHalf = max(radius, size.height / 2)

            var path = Path()
            for (index, value) in values.enumerated() {
                let half = radius + (maxHalf - radius) * CGFloat(max(0, min(1, value)))
                let rect = CGRect(
                    x: slot * (CGFloat(index) + 0.5) - radius,
                    y: midY - half,
                    width: barWidth,
                    height: half * 2
                )
                path.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius))
            }

            let shading = GraphicsContext.Shading.linearGradient(
                gradient,
                startPoint: .zero,
                endPoint: CGPoint(x: size.width, y: 0)
            )

            // A soft bloom under the trace, which is what gives the pill its
            // depth. Accessibility appearances get the flat version.
            if isCapturing, !reduceTransparency, !increaseContrast {
                var glow = context
                glow.addFilter(.blur(radius: 3.5))
                glow.opacity = 0.45
                glow.fill(path, with: shading)
            }

            context.fill(path, with: shading)
        }
        .accessibilityHidden(true)
    }

    /// Reduce Motion keeps the level meter but drops the scroll: every column
    /// shows the current level instead of a moving history.
    var renderedColumns: [Float] {
        guard !columns.isEmpty else {
            return Array(repeating: DictationMeter.floorValue, count: DictationMeter.columnCount)
        }
        guard isCapturing else {
            return Array(repeating: DictationMeter.floorValue, count: columns.count)
        }
        if reduceMotion {
            return Array(repeating: max(DictationMeter.floorValue, level), count: columns.count)
        }
        return columns
    }

    private var gradient: Gradient {
        guard isCapturing else {
            return Gradient(colors: [.white.opacity(increaseContrast ? 0.5 : 0.22)])
        }
        if increaseContrast {
            return Gradient(stops: [
                .init(color: .white.opacity(0.55), location: 0),
                .init(color: .white, location: 1),
            ])
        }
        let accent = Color(nsColor: .systemPink)
        return Gradient(stops: [
            .init(color: .white.opacity(0.12), location: 0),
            .init(color: accent.opacity(0.55), location: 0.42),
            .init(color: accent.opacity(0.95), location: 0.82),
            .init(color: .white.opacity(0.96), location: 1),
        ])
    }
}
