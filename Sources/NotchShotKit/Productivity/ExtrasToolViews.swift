import AppKit
import SwiftUI

// MARK: - Today

/// The working day at a glance: how much of it is left, the next eye break,
/// and where the screen time went — the last two only when turned on.
struct TodayToolView: View {
    @Bindable var coordinator: AppCoordinator
    @Bindable private var extras = ExtrasPreferences.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Form {
                if extras.showsDayProgress {
                    Section("Workday") {
                        dayProgress(at: context.date)
                    }
                }
                Section("Eye Breaks") {
                    Toggle("Remind me to rest my eyes", isOn: $extras.eyeBreaksEnabled)
                    Stepper(
                        "Every \(extras.eyeBreakIntervalMinutes) minutes of use",
                        value: $extras.eyeBreakIntervalMinutes,
                        in: 5 ... 120,
                        step: 5
                    )
                    .disabled(!extras.eyeBreaksEnabled)
                }
                Section {
                    Toggle("Track time per app on this Mac", isOn: $extras.screenTimeEnabled)
                    if extras.screenTimeEnabled {
                        screenTime(on: context.date)
                    }
                } header: {
                    Text("Screen Time")
                } footer: {
                    Text("Samples the frontmost app every 30 seconds while you're active. Kept for two weeks, never leaves this Mac.")
                }
            }
            .notchShotFormStyle()
        }
        .onChange(of: extras.eyeBreaksEnabled) { _, _ in coordinator.wellbeing.refresh() }
        .onChange(of: extras.screenTimeEnabled) { _, _ in coordinator.wellbeing.refresh() }
    }

    @ViewBuilder
    private func dayProgress(at date: Date) -> some View {
        let progress = DayProgress.at(date, startHour: extras.dayStartHour, endHour: extras.dayEndHour)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(progress.fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Spacer()
                Text(remainingText(progress))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progress.fraction)
                .tint(progress.fraction > 0.85 ? .orange : .accentColor)
            Text("\(hourLabel(extras.dayStartHour)) – \(hourLabel(extras.dayEndHour))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func remainingText(_ progress: DayProgress) -> String {
        if progress.isBeforeStart { return "Not started" }
        if progress.isAfterEnd { return "Done for today" }
        let formatted = Duration.seconds(progress.remaining)
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return "\(formatted) left"
    }

    private func hourLabel(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour % 24, minute: 0, second: 0, of: Date()) ?? Date()
        return hour == 24 ? "Midnight" : date.formatted(date: .omitted, time: .shortened)
    }

    @ViewBuilder
    private func screenTime(on date: Date) -> some View {
        let usage = coordinator.wellbeing.ledger.usage(on: date)
        if usage.isEmpty {
            Text("Nothing recorded yet today.")
                .foregroundStyle(.secondary)
        } else {
            let total = usage.reduce(0) { $0 + $1.seconds }
            let longest = usage.first?.seconds ?? 1
            LabeledContent("Total", value: duration(total))
            ForEach(usage.prefix(8), id: \.bundleIdentifier) { entry in
                HStack(spacing: 10) {
                    appIcon(entry.bundleIdentifier)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(entry.name).lineLimit(1)
                            Spacer()
                            Text(duration(entry.seconds))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        GeometryReader { proxy in
                            Capsule()
                                .fill(Color.accentColor.opacity(0.7))
                                .frame(width: max(4, proxy.size.width * entry.seconds / longest))
                        }
                        .frame(height: 4)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Button("Clear Screen Time", role: .destructive) {
                coordinator.wellbeing.clearScreenTime()
            }
        }
    }

    private func appIcon(_ bundleIdentifier: String) -> some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        return Image(nsImage: icon)
            .resizable()
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
    }

    private func duration(_ seconds: TimeInterval) -> String {
        seconds < 60
            ? "<1m"
            : Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}

// MARK: - Shortcuts

/// Every shortcut, with the pinned ones first. Pinned shortcuts also appear
/// in the capture menu's More list, so they're one click from the notch.
struct ShortcutsToolView: View {
    @Bindable private var extras = ExtrasPreferences.shared
    @State private var names: [String] = []
    @State private var query = ""
    @State private var isLoading = true
    @State private var running: String?
    @State private var message: String?
    @State private var loadError: String?

    private var filtered: [String] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = query.isEmpty ? names : names.filter { $0.localizedCaseInsensitiveContains(query) }
        let pinned = extras.pinnedShortcuts.filter(matching.contains)
        return pinned + matching.filter { !extras.pinnedShortcuts.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search shortcuts", text: $query)
                    .textFieldStyle(.roundedBorder)
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
                    .labelStyle(.iconOnly)
                    .help("Refresh the list")
            }
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
            if isLoading {
                ProgressView("Reading your shortcuts…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                ContentUnavailableView("Shortcuts unavailable", systemImage: "square.stack.3d.up.slash", description: Text(loadError))
            } else if names.isEmpty {
                ContentUnavailableView("No shortcuts", systemImage: "square.stack.3d.up", description: Text("Shortcuts you make in the Shortcuts app appear here."))
            } else {
                List(filtered, id: \.self) { name in
                    row(name)
                }
            }
        }
        .padding()
        .task { await load() }
    }

    private func row(_ name: String) -> some View {
        let isPinned = extras.pinnedShortcuts.contains(name)
        return HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.fill")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(name).lineLimit(1)
            Spacer()
            Button(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.fill" : "pin") {
                togglePin(name)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(isPinned ? "Remove from the notch's More menu" : "Show in the notch's More menu")
            Button(running == name ? "Running…" : "Run") { run(name) }
                .disabled(running != nil)
        }
        .padding(.vertical, 2)
    }

    private func togglePin(_ name: String) {
        if let index = extras.pinnedShortcuts.firstIndex(of: name) {
            extras.pinnedShortcuts.remove(at: index)
        } else if extras.pinnedShortcuts.count < ExtrasPreferences.maximumPinnedShortcuts {
            extras.pinnedShortcuts.append(name)
        } else {
            message = "Up to \(ExtrasPreferences.maximumPinnedShortcuts) shortcuts can be pinned."
        }
    }

    private func load() async {
        isLoading = names.isEmpty
        do {
            names = try await ShortcutsService.list()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func run(_ name: String) {
        running = name
        message = nil
        Task {
            defer { running = nil }
            do {
                let output = try await ShortcutsService.run(name)
                message = output.map { "\(name): \($0)" } ?? "\(name) finished."
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

// MARK: - Running apps

struct RunningAppsToolView: View {
    @State private var apps: [RunningAppEntry] = []

    var body: some View {
        Group {
            if apps.isEmpty {
                ContentUnavailableView("No other apps running", systemImage: "app.dashed")
            } else {
                List(apps) { app in
                    HStack(spacing: 10) {
                        Image(nsImage: app.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage())
                            .resizable()
                            .frame(width: 28, height: 28)
                            .opacity(app.isHidden ? 0.5 : 1)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name)
                            if app.isActive || app.isHidden {
                                Text(app.isActive ? "Frontmost" : "Hidden")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Hide") { AppSwitcher.hide(app); reload() }
                            .buttonStyle(.borderless)
                            .disabled(app.isHidden)
                        Button("Quit") { AppSwitcher.quit(app); reloadSoon() }
                            .buttonStyle(.borderless)
                        Button("Switch") { AppSwitcher.activate(app) }
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(app.name)
                }
            }
        }
        .padding()
        .onAppear(perform: reload)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in reload() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in reload() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) { _ in reload() }
    }

    private func reload() { apps = AppSwitcher.runningApps() }

    private func reloadSoon() {
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            reload()
        }
    }
}

// MARK: - Review queue

struct ReviewQueueToolView: View {
    @Bindable private var extras = ExtrasPreferences.shared
    @State private var requests: [ReviewRequest] = []
    @State private var error: String?
    @State private var isLoading = false
    @State private var lastRefresh: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Check GitHub for review requests", isOn: $extras.reviewQueueEnabled)
                Spacer()
                if let lastRefresh {
                    Text(lastRefresh, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
                    .labelStyle(.iconOnly)
                    .disabled(!extras.reviewQueueEnabled || isLoading)
            }
            if !extras.reviewQueueEnabled {
                ContentUnavailableView(
                    "Review queue is off",
                    systemImage: "arrow.triangle.pull",
                    description: Text("Turn it on to list pull requests waiting for your review. It uses the GitHub CLI you're signed in to; NotchShot never stores a token.")
                )
            } else if isLoading && requests.isEmpty {
                ProgressView("Asking GitHub…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView("Couldn't load reviews", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if requests.isEmpty {
                ContentUnavailableView("Nothing to review", systemImage: "checkmark.circle", description: Text("No open pull requests are waiting for you."))
            } else {
                List(requests) { request in
                    Button { NSWorkspace.shared.open(request.url) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(request.title).lineLimit(2)
                                if request.isDraft == true {
                                    Text("Draft")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 5)
                                        .background(.quaternary, in: Capsule())
                                }
                            }
                            Text("\(request.repository.nameWithOwner) #\(request.number)\(request.author.map { " · \($0.login)" } ?? "") · \(request.updatedAt.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the pull request in your browser")
                }
            }
        }
        .padding()
        .task(id: extras.reviewQueueEnabled) {
            if extras.reviewQueueEnabled { await load() }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            requests = try await ReviewQueueService.fetch()
            error = nil
            lastRefresh = Date()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
