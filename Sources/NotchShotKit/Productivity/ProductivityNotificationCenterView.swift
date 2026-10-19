import AppKit
import SwiftUI

struct ProductivityNotificationCenterView: View {
    @Bindable var coordinator: AppCoordinator
    @Bindable private var store = ProductivityNotificationStore.shared
    @Bindable private var router = ProductivityCenterRouter.shared

    @State private var title = "NotchShot alert"
    @State private var bodyText = "A task needs your attention."
    @State private var priority: ProductivityNotificationPriority = .standard
    @State private var delayMinutes = 0
    @State private var message: String?
    @State private var isPosting = false
    @State private var notificationsDenied = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if geometry.size.width >= 760 {
                        HStack(alignment: .top, spacing: 18) {
                            preview
                            composer
                        }
                    } else {
                        preview
                        composer
                    }
                    inbox
                }
                .padding(22)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Notification Center")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Text("NotchShot alerts, visible notification banners, media, and live Focus state in one place.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Schedule") { router.selectedTool = .schedule }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Activity stack preview", systemImage: "rectangle.stack")
                .font(.headline)
            NotchActivityCardStack(
                coordinator: coordinator,
                store: store,
                isLocked: false,
                showsPlaceholders: true
            )
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(activityPreviewBackdrop)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.white.opacity(0.09))
            }
        }
        .frame(maxWidth: 430, alignment: .leading)
    }

    private var activityPreviewBackdrop: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color(red: 0.42, green: 0.36, blue: 0.20), location: 0),
                .init(color: Color(red: 0.24, green: 0.32, blue: 0.25), location: 0.42),
                .init(color: Color(red: 0.08, green: 0.25, blue: 0.32), location: 0.72),
                .init(color: Color(red: 0.04, green: 0.14, blue: 0.20), location: 1),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("New NotchShot alert", systemImage: "square.and.pencil")
                .font(.headline)

            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
            TextField("Message", text: $bodyText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2 ... 5)
            Picker("Priority", selection: $priority) {
                ForEach(ProductivityNotificationPriority.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            Stepper(
                delayMinutes == 0 ? "Deliver now" : "In \(delayMinutes) minutes",
                value: $delayMinutes,
                in: 0 ... 1_440
            )
            Button(isPosting ? "Posting…" : "Post Alert", action: post)
                .disabled(isPosting || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .notchShotPrimaryActionStyle()

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(message.hasPrefix("Could not") ? .orange : .secondary)
            }
            if notificationsDenied {
                Button("Open Notification Settings…") {
                    coordinator.openNotificationSettings()
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            Divider()
            Text("Reply in NotchShot stores text locally against this alert. It does not send a message to another application.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: 390, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.primary.opacity(0.08))
        }
    }

    private var inbox: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("NotchShot inbox", systemImage: "tray.full")
                    .font(.headline)
                Spacer()
                if store.items.contains(where: { $0.state == .completed || $0.state == .dismissed }) {
                    Button("Clear Finished") { store.clearFinished() }
                        .buttonStyle(.borderless)
                }
            }

            if store.items.isEmpty {
                ContentUnavailableView(
                    "No NotchShot Alerts",
                    systemImage: "bell.slash",
                    description: Text("Create an alert here or schedule one from Schedule.")
                )
                .frame(maxWidth: .infinity, minHeight: 170)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(store.items) { item in
                        inboxRow(item)
                    }
                }
            }

            if let error = store.lastError {
                InlineErrorMessage(message: error)
            }
        }
    }

    private func inboxRow(_ item: ProductivityNotificationItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.priority.symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(item.priority == .high ? .orange : .purple)
                .frame(width: 30, height: 30)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(item.state.title.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                if !item.body.isEmpty {
                    Text(item.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let reply = item.reply {
                    Label(reply, systemImage: "arrowshape.turn.up.left.fill")
                        .font(.caption)
                        .foregroundStyle(.purple)
                        .lineLimit(2)
                }
                Text(item.scheduledAt, style: item.scheduledAt > Date() ? .relative : .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 10)
            if item.state == .scheduled || item.state == .delivered {
                Button("Done") { ProductivityNotificationCenter.shared.complete(item) }
                    .buttonStyle(.borderless)
            }
            Button {
                ProductivityNotificationCenter.shared.remove(item)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete \(item.title)")
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.07))
        }
    }

    private func post() {
        let requestedTitle = title
        let requestedBody = bodyText
        let requestedPriority = priority
        let date = Date().addingTimeInterval(TimeInterval(max(1, delayMinutes * 60)))
        isPosting = true
        message = nil
        Task {
            defer { isPosting = false }
            do {
                guard try await ProductivityNotificationCenter.shared.requestAuthorization() else {
                    notificationsDenied = true
                    message = "Could not post because notifications are disabled."
                    return
                }
                try await ProductivityNotificationCenter.shared.schedule(
                    title: requestedTitle,
                    body: requestedBody,
                    priority: requestedPriority,
                    at: date
                )
                notificationsDenied = false
                message = delayMinutes == 0 ? "Alert posted." : "Alert scheduled."
            } catch {
                message = "Could not post: \(error.localizedDescription)"
            }
        }
    }
}

/// Shared presentation for the interactive center and the display-only locked
/// session. It deliberately consumes only NotchShot-owned state.
struct NotchActivityCardStack: View {
    @Bindable var coordinator: AppCoordinator
    @Bindable var store: ProductivityNotificationStore
    var isLocked: Bool
    var showsPlaceholders: Bool
    var showsMedia = true

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            VStack(spacing: 12) {
                if showsMedia,
                   coordinator.media.snapshot.hasContent || showsPlaceholders {
                    mediaCard(now: timeline.date)
                }
                if let item = notification(at: timeline.date) {
                    notificationCard(item)
                } else if showsPlaceholders {
                    emptyCard(
                        symbol: "bell.slash",
                        title: "No active alerts",
                        subtitle: "NotchShot notifications appear here"
                    )
                }
                if isLocked, let power = LockedChargingPolicy.reading() {
                    chargingCard(power)
                }
                if let timer = coordinator.context.timer.current {
                    focusCard(timer)
                } else if showsPlaceholders {
                    emptyCard(
                        symbol: "timer",
                        title: "Focus is ready",
                        subtitle: "Start a timer from Schedule"
                    )
                }
            }
            .frame(maxWidth: 344)
            .notchShotActivityGlassGroup(spacing: 12)
        }
        .allowsHitTesting(!isLocked)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isLocked ? "NotchShot locked activity stack" : "NotchShot activity stack")
    }

    private func notification(at date: Date) -> ProductivityNotificationItem? {
        if isLocked { return store.lockScreenItem(at: date) }
        return store.activeItems.first
    }

    private func mediaCard(now: Date) -> some View {
        let snapshot = coordinator.media.snapshot
        let accent = Color(nsColor: coordinator.media.artworkAccentColor)
        return VStack(spacing: 10) {
            HStack(spacing: 12) {
                artwork(size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.title ?? "Nothing playing")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                        .lineLimit(2)
                    Text(snapshot.artist ?? snapshot.applicationName ?? "Start Music or Spotify")
                        .font(NotchAlertStyle.body)
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                MiniPlaybackWave(isPlaying: snapshot.isPlaying, tint: accent)
            }

            HStack(spacing: 8) {
                Text(formatTime(snapshot.interpolatedPosition(at: now)))
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.islandInk(0.18))
                        Capsule()
                            .fill(.white)
                            .frame(width: geometry.size.width * progress(snapshot, now: now))
                    }
                }
                .frame(height: 4)
                Text(formatTime(snapshot.duration))
            }
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))

            HStack(spacing: 18) {
                mediaControl("backward.fill", label: "Previous") { coordinator.media.send(.previousTrack) }
                mediaControl(snapshot.isPlaying ? "pause.fill" : "play.fill", label: "Play or pause") {
                    coordinator.media.send(.togglePlayPause)
                }
                mediaControl("forward.fill", label: "Next") { coordinator.media.send(.nextTrack) }
                Spacer()
                Image(systemName: "airplayaudio")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .accessibilityLabel("Audio output")
            }
        }
        .padding(14)
        .notchShotActivityGlassSurface(cornerRadius: 22, reduceTransparency: reduceTransparency)
    }

    // The three small cards use the notch alerts' row: a bare mark, a
    // 13 pt title with its metadata on the baseline, one grey line, and
    // controls at the trailing edge. They used to set their own type in the
    // rounded face, repeat "ACTIVE" in purple capitals on every alert, and put
    // each icon in a glass chip that read as a button even on the Lock Screen,
    // where nothing is clickable.
    private func notificationCard(_ item: ProductivityNotificationItem) -> some View {
        let isHigh = item.priority == .high
        return NotchAlertRow(
            title: item.title,
            meta: isHigh ? "High priority" : nil,
            metaColor: .orange,
            subtitle: item.body.isEmpty ? "NotchShot alert" : item.body
        ) {
            NotchAlertStyle.symbol(
                isHigh ? "exclamationmark.circle.fill" : "bell.fill",
                color: isHigh ? .orange : .accentColor
            )
        } trailing: {
            if !isLocked {
                NotchAlertIconButton(systemName: "checkmark", label: "Mark \(item.title) done") {
                    ProductivityNotificationCenter.shared.complete(item)
                }
                .padding(.trailing, -8)
            }
        }
        .cardPadding()
        .notchShotActivityGlassSurface(cornerRadius: 20, reduceTransparency: reduceTransparency)
    }

    /// Plugged in at the Lock Screen: the level as the phone's charging
    /// card draws it, a green battery and the percentage.
    private func chargingCard(_ power: PowerSourceReading) -> some View {
        let full = power.percentage >= 100 || !power.isCharging
        return NotchAlertRow(
            title: full ? "Charged" : "Charging",
            subtitle: full ? "Connected to power" : "Plugged in"
        ) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(IslandSystemColor.green)
                .frame(width: 26)
                .accessibilityHidden(true)
        } trailing: {
            HStack(spacing: 8) {
                Text("\(power.percentage)%")
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                IslandBatteryGlyph(level: Double(power.percentage) / 100, tint: IslandSystemColor.green, width: 30)
            }
        }
        .cardPadding()
        .notchShotActivityGlassSurface(cornerRadius: 20, reduceTransparency: reduceTransparency)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(full ? "Charged" : "Charging"), \(power.percentage) percent")
    }

    private func focusCard(_ timer: FocusTimerSnapshot) -> some View {
        let isRunning = timer.state == .running
        let status = switch timer.state {
        case .running: "Focusing"
        case .paused: "Paused"
        case .completed: "Done"
        }
        return NotchAlertRow(title: timer.label, subtitle: status) {
            FocusProgressMark(
                fraction: timer.duration > 0 ? min(max(timer.elapsed / timer.duration, 0), 1) : 0,
                isRunning: isRunning
            )
        } trailing: {
            HStack(spacing: 0) {
                Text(FocusTimerPolicy.formatted(timer.remaining))
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.islandInk(isRunning ? NotchIsland.Ink.primary : NotchIsland.Ink.secondary))
                    .contentTransition(.numericText(countsDown: true))
                    .padding(.trailing, isLocked ? 0 : 4)
                if !isLocked {
                    NotchAlertIconButton(
                        systemName: isRunning ? "pause.fill" : "play.fill",
                        label: isRunning ? "Pause focus timer" : "Resume focus timer",
                        emphasized: true
                    ) {
                        isRunning ? coordinator.pauseFocusTimer() : coordinator.resumeFocusTimer()
                    }
                    NotchAlertIconButton(systemName: "xmark", label: "Cancel focus timer") {
                        coordinator.cancelFocusTimer()
                    }
                    .padding(.trailing, -8)
                }
            }
        }
        .cardPadding()
        .notchShotActivityGlassSurface(cornerRadius: 20, reduceTransparency: reduceTransparency)
    }

    private func emptyCard(symbol: String, title: String, subtitle: String) -> some View {
        NotchAlertRow(title: title, subtitle: subtitle) {
            NotchAlertStyle.symbol(symbol, color: Color.islandInk(NotchIsland.Ink.tertiary), size: 20)
        }
        .cardPadding()
        .opacity(0.72)
        .notchShotActivityGlassSurface(cornerRadius: 20, reduceTransparency: reduceTransparency)
    }

    @ViewBuilder
    private func mediaControl(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        if isLocked {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .accessibilityLabel(label)
        } else {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
        }
    }

    private func artwork(size: CGFloat) -> some View {
        Group {
            if let image = coordinator.media.artwork {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(.white.opacity(0.1))
                    .overlay { Image(systemName: "music.note").font(.title2) }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .accessibilityHidden(true)
    }

    private func progress(_ snapshot: MediaSnapshot, now: Date) -> Double {
        guard let duration = snapshot.duration, duration > 0,
              let position = snapshot.interpolatedPosition(at: now) else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    private func formatTime(_ value: TimeInterval?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "--:--" }
        let seconds = Int(value)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct MiniPlaybackWave: View {
    var isPlaying: Bool
    var tint: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: isPlaying ? 0.16 : 1, paused: !isPlaying)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0 ..< 5, id: \.self) { index in
                    Capsule()
                        .fill(tint)
                        .frame(
                            width: 2.5,
                            height: isPlaying ? 7 + abs(sin(phase * 4 + Double(index))) * 13 : 7
                        )
                }
            }
            .frame(width: 28, height: 24)
        }
        .accessibilityLabel(isPlaying ? "Playing" : "Paused")
    }
}

private extension View {
    func cardPadding() -> some View {
        padding(.leading, 14)
            .padding(.trailing, 12)
            .padding(.vertical, 12)
    }
}

/// The focus card's mark: a ring that fills as the session runs.
private struct FocusProgressMark: View {
    var fraction: Double
    var isRunning: Bool

    var body: some View {
        ZStack {
            Circle().stroke(Color.orange.opacity(0.22), lineWidth: 3)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Color.orange, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: isRunning ? "timer" : "pause.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
        }
        .padding(2)
    }
}
