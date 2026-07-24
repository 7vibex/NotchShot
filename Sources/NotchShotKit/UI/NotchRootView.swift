import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The whole notch, for one display.
///
/// The panel behind this view is a fixed, generous rectangle; everything here
/// draws inside it, anchored to the top centre, so state changes animate the
/// island rather than resizing a window.
public struct NotchRootView: View {
    @Bindable var coordinator: AppCoordinator
    let context: NotchDisplayContext

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var peekTask: Task<Void, Never>?
    @State private var isTargetedForDrop = false

    public init(coordinator: AppCoordinator, context: NotchDisplayContext) {
        self.coordinator = coordinator
        self.context = context
    }

    private var isActiveDisplay: Bool {
        coordinator.windowController?.activeDisplayID == context.displayID
    }

    /// A non-active display shows media at most, never a capture UI.
    private var effectiveActivity: NotchActivity {
        guard !isActiveDisplay else { return coordinator.activity }
        return coordinator.activity == .media ? .media : .idle
    }

    private var layout: NotchLayout {
        NotchLayout.layout(
            for: effectiveActivity,
            metrics: context.metrics,
            isPeeking: coordinator.isPeeking && isActiveDisplay,
            resultCount: coordinator.shelfItems.count,
            hasStack: coordinator.stack.isCollecting || !coordinator.stack.isEmpty
        )
    }

    public var body: some View {
        VStack(spacing: 0) {
            island
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Hover is *not* handled here. SwiftUI's onHover fires for the whole
        // panel — which is far larger than the island — and fighting the window
        // controller's own hit test made the notch open on its own. The
        // controller is the single source of truth.
        .onDrop(of: [.fileURL], isTargeted: $isTargetedForDrop) { providers in
            handleDrop(providers)
        }
        .onChange(of: isTargetedForDrop) { _, targeted in
            coordinator.setDraggingFiles(targeted)
        }
    }

    private var shape: NotchShape {
        NotchShape(
            bottomRadius: layout.cornerRadius,
            // The fillets only make sense against a real cutout; on an external
            // display they would look like a floating tab with odd ears.
            topRadius: context.metrics.hasPhysicalNotch ? 10 : 0
        )
    }

    private var island: some View {
        ZStack(alignment: .top) {
            shape
                .fill(islandFill)
                .overlay {
                    if isTargetedForDrop {
                        shape.stroke(Color.accentColor, lineWidth: 2)
                    }
                }
                // The shadow only appears once the island is bigger than the
                // cutout, so a closed notch casts nothing onto the bezel.
                .shadow(
                    color: .black.opacity(effectiveActivity.isExpanded ? 0.45 : 0),
                    radius: 22,
                    y: 10
                )

            content
                .frame(width: layout.size.width, height: layout.size.height)
                .clipShape(shape)
                // Content fades in a beat after the shape has started growing,
                // so text never appears outside the island it belongs to.
                .transition(contentTransition)
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .animation(shapeAnimation, value: layout.size)
        .animation(contentAnimation, value: effectiveActivity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("NotchShot")
        .accessibilityValue(accessibilityDescription)
    }

    /// Pure, fully opaque black.
    ///
    /// The island has to read as the hardware cutout growing, and the cutout is
    /// literally black — even 4% transparency lets the desktop bleed through and
    /// breaks the illusion the moment a light window sits behind the menu bar.
    /// Liquid Glass belongs on the controls *inside* the island, never on the
    /// mask itself.
    private var islandFill: Color { .black }

    /// Size changes get a spring with a little overshoot; content gets a
    /// shorter, softer curve so the two don't visibly fight.
    private var shapeAnimation: Animation? {
        reduceMotion
            ? .easeInOut(duration: 0.18)
            : .spring(response: 0.38, dampingFraction: 0.72)
    }

    private var contentAnimation: Animation? {
        reduceMotion
            ? .easeInOut(duration: 0.18)
            : .spring(response: 0.30, dampingFraction: 0.86)
    }

    private var contentTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.90, anchor: .top))
                .combined(with: .offset(y: -8)),
            removal: .opacity
                .combined(with: .scale(scale: 0.96, anchor: .top))
        )
    }

    @ViewBuilder
    private var content: some View {
        switch effectiveActivity {
        case .idle:
            IdleContent(isPeeking: coordinator.isPeeking && isActiveDisplay, coordinator: coordinator)
        case .media:
            MediaContent(
                coordinator: coordinator,
                isPeeking: coordinator.isPeeking && isActiveDisplay
            )
        case .expanded:
            CaptureMenuContent(coordinator: coordinator)
        case .selecting(let intent):
            StatusContent(
                symbolName: intent.symbolName,
                title: intent.title,
                subtitle: "Esc to cancel"
            )
        case .countdown(let remaining, let intent):
            CountdownContent(remaining: remaining, intent: intent, coordinator: coordinator)
        case .recording:
            RecordingContent(coordinator: coordinator)
        case .processing(let message):
            ProcessingContent(message: message, coordinator: coordinator)
        case .result:
            ShelfContent(coordinator: coordinator)
        case .systemLevel(let level):
            SystemLevelContent(level: level)
        case .error(let message):
            ErrorContent(message: message, coordinator: coordinator)
        }
    }

    private var accessibilityDescription: String {
        switch effectiveActivity {
        case .idle: "Idle"
        case .media: coordinator.media.snapshot.title.map { "Playing \($0)" } ?? "Media"
        case .expanded: "Capture menu"
        case .selecting(let intent): intent.title
        case .countdown(let remaining, _): "Capturing in \(remaining) seconds"
        case .recording: "Recording, \(coordinator.recordingStatus.elapsedDescription)"
        case .processing(let message): message
        case .result: "\(coordinator.shelfItems.count) recent captures"
        case .systemLevel(let level): "\(level.kind.title) \(Int(level.value * 100)) percent"
        case .error(let message): "Error: \(message)"
        }
    }

    // MARK: Interaction

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        Task {
            var urls: [URL] = []
            for provider in providers {
                guard let item = try? await provider.loadItem(
                    forTypeIdentifier: UTType.fileURL.identifier
                ) else { continue }
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                } else if let url = item as? URL {
                    urls.append(url)
                }
            }
            await MainActor.run { coordinator.acceptDroppedFiles(urls) }
        }
        return true
    }
}

// MARK: - Idle

private struct IdleContent: View {
    var isPeeking: Bool
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        if isPeeking {
            HStack(spacing: 10) {
                Button {
                    coordinator.toggleExpanded()
                } label: {
                    Label("Capture", systemImage: "camera.viewfinder")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)

                Divider().frame(height: 14).overlay(.white.opacity(0.2))

                NotchIconButton(systemName: "square.dashed", label: "Capture area") {
                    coordinator.capture(.area)
                }
                .scaleEffect(0.8)

                NotchIconButton(systemName: "record.circle", label: "Record") {
                    coordinator.startRecording()
                }
                .scaleEffect(0.8)
            }
            .padding(.horizontal, 14)
        } else {
            // Closed state draws nothing: the island is exactly the hardware
            // notch, so anything here would look like a rendering artefact.
            Color.clear
        }
    }
}

// MARK: - Media

private struct MediaContent: View {
    @Bindable var coordinator: AppCoordinator
    var isPeeking: Bool

    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var snapshot: MediaSnapshot { coordinator.media.snapshot }

    var body: some View {
        Group {
            if isPeeking {
                expanded
            } else {
                compact
            }
        }
        .onReceive(ticker) { date in
            // Only tick while something is actually playing — an idle notch
            // must not wake the CPU once a second.
            if snapshot.isPlaying { now = date }
        }
    }

    private var compact: some View {
        HStack(spacing: 0) {
            artwork(size: 20)
                .padding(.leading, 6)
            Spacer(minLength: 0)
            PlaybackIndicator(isPlaying: snapshot.isPlaying)
                .padding(.trailing, 8)
        }
    }

    private var expanded: some View {
        HStack(spacing: 12) {
            artwork(size: 52)

            VStack(alignment: .leading, spacing: 3) {
                // Scrolls itself when the title is longer than the space, so a
                // long track name is fully readable rather than truncated.
                MarqueeText(
                    snapshot.title ?? "Not Playing",
                    font: .system(size: 12, weight: .semibold),
                    color: .white
                )
                .frame(height: 15)

                MarqueeText(
                    snapshot.artist ?? snapshot.applicationName ?? "",
                    font: .system(size: 10),
                    color: .white.opacity(0.65),
                    speed: 22
                )
                .frame(height: 13)

                if snapshot.duration != nil {
                    ProgressView(value: snapshot.progress)
                        .progressViewStyle(.linear)
                        .tint(.white.opacity(0.85))
                        .frame(height: 2)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                NotchIconButton(systemName: "backward.fill", label: "Previous track") {
                    coordinator.media.send(.previousTrack)
                }
                .disabled(!coordinator.media.supports(.previousTrack))

                NotchIconButton(
                    systemName: snapshot.isPlaying ? "pause.fill" : "play.fill",
                    label: snapshot.isPlaying ? "Pause" : "Play"
                ) {
                    coordinator.media.send(.togglePlayPause)
                }

                NotchIconButton(systemName: "forward.fill", label: "Next track") {
                    coordinator.media.send(.nextTrack)
                }
                .disabled(!coordinator.media.supports(.nextTrack))

                Divider().frame(height: 18).overlay(.white.opacity(0.2))

                NotchIconButton(systemName: "camera.viewfinder", label: "Capture") {
                    coordinator.toggleExpanded()
                }
            }
        }
        .padding(.horizontal, 12)
        // `now` is read so the progress bar re-evaluates on each tick. It must
        // not become a view identity — keying the view on it rebuilt the whole
        // subtree every second and restarted the marquee mid-scroll.
        .opacity(now == .distantPast ? 0 : 1)
    }

    @ViewBuilder
    private func artwork(size: CGFloat) -> some View {
        Group {
            if let image = coordinator.media.artwork {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: size / 5)
                    .fill(.white.opacity(0.12))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: size / 2.4))
                            .foregroundStyle(.white.opacity(0.6))
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 5))
        .accessibilityHidden(true)
    }
}

/// Three bars that bounce while audio is playing.
private struct PlaybackIndicator: View {
    var isPlaying: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0 ..< 3, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(isPlaying ? 0.9 : 0.35))
                    .frame(width: 2, height: height(for: index))
            }
        }
        .frame(height: 12, alignment: .center)
        .onAppear { startAnimating() }
        .onChange(of: isPlaying) { _, _ in startAnimating() }
        .accessibilityHidden(true)
    }

    private func height(for index: Int) -> CGFloat {
        guard isPlaying, !reduceMotion else { return 5 }
        let offsets: [CGFloat] = [0, 0.66, 1.33]
        return 4 + 6 * abs(sin(phase + offsets[index]))
    }

    private func startAnimating() {
        guard isPlaying, !reduceMotion else { return }
        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
            phase = .pi * 2
        }
    }
}

// MARK: - Capture menu

private struct CaptureMenuContent: View {
    @Bindable var coordinator: AppCoordinator
    @State private var timer: CaptureTimer = .none

    private let intents: [CaptureIntent] = [
        .area, .window, .display, .scrolling, .ocr, .previousArea,
    ]

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Capture")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Picker("Timer", selection: $timer) {
                    ForEach(CaptureTimer.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
                .labelsHidden()

                NotchIconButton(systemName: "xmark", label: "Close") {
                    coordinator.collapse()
                }
                .scaleEffect(0.8)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(intents) { intent in
                    Button {
                        coordinator.capture(intent, timer: timer)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: intent.symbolName)
                                .font(.system(size: 17))
                            Text(intent.shortTitle)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(.white)
                        .glassEffect(.regular, in: .rect(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(intent.title)
                }
            }

            HStack(spacing: 8) {
                Button {
                    coordinator.startRecording()
                } label: {
                    Label("Record", systemImage: "record.circle")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundStyle(.white)
                        .glassEffect(.regular.tint(.red.opacity(0.6)), in: .rect(cornerRadius: 9))
                }
                .buttonStyle(.plain)

                Button {
                    coordinator.onOpenHistory?()
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundStyle(.white)
                        .glassEffect(.regular, in: .rect(cornerRadius: 9))
                }
                .buttonStyle(.plain)

                NotchIconButton(systemName: "gearshape", label: "Settings") {
                    coordinator.onOpenSettings?()
                }
            }
        }
        .padding(14)
    }
}

// MARK: - Status / countdown / processing / error

private struct StatusContent: View {
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
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }
}

private struct CountdownContent: View {
    var remaining: Int
    var intent: CaptureIntent
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        VStack(spacing: 4) {
            Text("\(remaining)")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: true))
            Text(intent.shortTitle)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.6))
        }
        .onTapGesture { coordinator.cancelCurrentOperation() }
        .accessibilityLabel("Capturing in \(remaining) seconds. Tap to cancel.")
    }
}

private struct ProcessingContent: View {
    var message: String
    @Bindable var coordinator: AppCoordinator

    private var isScrolling: Bool {
        message.contains("frame") || message.contains("Scroll")
    }

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 0)

            if isScrolling {
                NotchIconButton(systemName: "checkmark", label: "Finish scrolling capture") {
                    coordinator.finishScrollingCapture()
                }
                .scaleEffect(0.8)
                .keyboardShortcut(.return, modifiers: [])

                NotchIconButton(systemName: "xmark", label: "Cancel") {
                    coordinator.cancelCurrentOperation()
                }
                .scaleEffect(0.8)
            }
        }
        .padding(.horizontal, 14)
    }
}

private struct ErrorContent: View {
    var message: String
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
            Spacer(minLength: 0)

            if coordinator.permissions.pendingRemediation != nil {
                Button("Open Settings") {
                    if let kind = coordinator.permissions.pendingRemediation {
                        coordinator.permissions.openSettings(for: kind)
                    }
                }
                .font(.system(size: 10, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule)
            }

            NotchIconButton(systemName: "xmark", label: "Dismiss") {
                coordinator.dismissError()
            }
            .scaleEffect(0.75)
        }
        .padding(.horizontal, 14)
    }
}

// MARK: - Recording HUD

private struct RecordingContent: View {
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
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }

                AudioLevelBar(
                    level: status.systemLevel,
                    isEnabled: status.isSystemAudioEnabled,
                    symbolName: "speaker.wave.2.fill",
                    label: "System audio level"
                )
                AudioLevelBar(
                    level: status.microphoneLevel,
                    isEnabled: status.isMicrophoneEnabled,
                    symbolName: "mic.fill",
                    label: "Microphone level"
                )
            }
            .frame(width: 150)

            Spacer(minLength: 0)

            NotchIconButton(
                systemName: status.isMicrophoneEnabled ? "mic.fill" : "mic.slash.fill",
                label: status.isMicrophoneEnabled ? "Mute microphone" : "Unmute microphone"
            ) {
                coordinator.toggleRecordingMicrophone()
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
private struct SystemLevelContent: View {
    var level: SystemLevel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: level.symbolName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 22)
                // The symbol swaps as the level crosses each threshold; a plain
                // swap would pop, so cross-fade it.
                .contentTransition(.symbolEffect(.replace))

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
        .animation(
            reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.24, dampingFraction: 0.9),
            value: level.value
        )
        .animation(.easeOut(duration: 0.15), value: level.isMuted)
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
