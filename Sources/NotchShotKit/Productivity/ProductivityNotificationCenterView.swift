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
                    message = "Could not post because notifications are disabled."
                    return
                }
                try await ProductivityNotificationCenter.shared.schedule(
                    title: requestedTitle,
                    body: requestedBody,
                    priority: requestedPriority,
                    at: date
                )
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

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            VStack(spacing: 12) {
                if coordinator.media.snapshot.hasContent || showsPlaceholders {
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
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .lineLimit(2)
                    Text(snapshot.artist ?? snapshot.applicationName ?? "Start Music or Spotify")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                MiniPlaybackWave(isPlaying: snapshot.isPlaying, tint: accent)
            }

            HStack(spacing: 8) {
                Text(formatTime(snapshot.interpolatedPosition(at: now)))
                ProgressView(value: progress(snapshot, now: now)).tint(.white)
                Text(formatTime(snapshot.duration))
            }
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.58))

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

    private func notificationCard(_ item: ProductivityNotificationItem) -> some View {
        HStack(spacing: 12) {
            activityIcon(
                item.priority == .high ? "exclamationmark" : "bell.fill",
                tint: item.priority == .high ? .orange : .purple
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(item.body.isEmpty ? "NotchShot alert" : item.body)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(item.priority == .high ? "HIGH" : "ACTIVE")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(item.priority == .high ? .orange : .purple)
            if !isLocked {
                Button {
                    ProductivityNotificationCenter.shared.complete(item)
                } label: {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Mark \(item.title) done")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .notchShotActivityGlassSurface(cornerRadius: 18, reduceTransparency: reduceTransparency)
    }

    private func focusCard(_ timer: FocusTimerSnapshot) -> some View {
        HStack(spacing: 12) {
            if isLocked {
                activityIcon(timer.state == .running ? "pause.fill" : "play.fill", tint: .orange)
            } else {
                Button {
                    timer.state == .running ? coordinator.pauseFocusTimer() : coordinator.resumeFocusTimer()
                } label: {
                    activityIcon(timer.state == .running ? "pause.fill" : "play.fill", tint: .orange)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(timer.state == .running ? "Pause focus timer" : "Resume focus timer")
            }
            if !isLocked {
                Button {
                    coordinator.cancelFocusTimer()
                } label: {
                    activityIcon("xmark", tint: .white.opacity(0.72))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel focus timer")
            }
            Spacer()
            Text(timer.label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.orange)
            Text(FocusTimerPolicy.formatted(timer.remaining))
                .font(.system(size: 25, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.orange)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .notchShotActivityGlassSurface(cornerRadius: 18, reduceTransparency: reduceTransparency)
    }

    private func emptyCard(symbol: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            activityIcon(symbol, tint: .white.opacity(0.55))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.48))
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .opacity(0.72)
        .notchShotActivityGlassSurface(cornerRadius: 18, reduceTransparency: reduceTransparency)
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

    private func activityIcon(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .notchControlSurface(
                in: Circle(),
                reduceTransparency: reduceTransparency,
                tint: tint,
                interactive: !isLocked
            )
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
