import AppKit
import SwiftUI

// MARK: - Live Activities

/// Behaviour of the multi-activity island, grouped by what the user is
/// deciding: whether to use it, what may appear, how it responds, what may
/// interrupt it, and whether other tools may publish to it.
struct ActivityIslandSettings: View {
    @Bindable var coordinator: AppCoordinator
    @Bindable var preferences: Preferences
    @Bindable private var external = ExternalActivityStore.shared
    @Bindable private var focus = FocusStatusMonitor.shared

    var body: some View {
        Form {
            Section {
                Toggle("Show multiple activities", isOn: binding(\.multipleActivitiesEnabled))
                Picker("Visible at once", selection: binding(\.maximumVisibleActivities)) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                    Text("3").tag(3)
                }
                .pickerStyle(.segmented)
                .disabled(!preferences.multipleActivitiesEnabled)
            } header: {
                Text("Activity Island")
            } footer: {
                Text("One activity leads the notch; others wait beside it as small satellites. Short events like volume changes appear over the island and hand it back. Turning this off restores the single-activity notch.")
            }

            // These shape the whole notch, island or not.
            Section {
                Picker("Animation style", selection: binding(\.islandAnimationStyle)) {
                    ForEach(IslandAnimationStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                LabeledContent("Shadow") {
                    Slider(value: binding(\.islandShadowStrength), in: 0...1) {
                        Text("Shadow")
                    } minimumValueLabel: {
                        Image(systemName: "circle").imageScale(.small)
                    } maximumValueLabel: {
                        Image(systemName: "circle.fill").imageScale(.small)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
                Toggle("Glass notch", isOn: binding(\.islandGlassEnabled))
                LabeledContent("Glass level") {
                    Slider(value: binding(\.islandGlassLevel), in: 0...1) {
                        Text("Glass level")
                    } minimumValueLabel: {
                        Image(systemName: "square.fill").imageScale(.small)
                    } maximumValueLabel: {
                        Image(systemName: "square.dashed").imageScale(.small)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    .accessibilityValue("\(Int((preferences.islandGlassLevel * 100).rounded())) percent")
                }
                .disabled(!preferences.islandGlassEnabled)
                Toggle("Press and hold to open the capture menu", isOn: binding(\.longPressExpandsIsland))
            } header: {
                Text("Motion and Feel")
            } footer: {
                Text("Subtle never overshoots; Bouncy settles with a visible spring. Reduce Motion in System Settings replaces all of them with short fades. Shadow sets how strongly the open notch lifts off the screen. Glass notch keeps the camera and main controls dark while the lower edge reveals the desktop through clear Liquid Glass. The page switcher uses matching glass. Glass level controls how far the transparency reaches. The closed notch stays black, and Reduce Transparency or Increase Contrast keeps it all black.")
            }

            Group {
                Section("Show in the Island") {
                    Toggle("Now Playing", isOn: binding(\.showsMediaActivity))
                    Toggle("AI agent activity", isOn: binding(\.showsAIIslandActivity))
                        .disabled(!preferences.aiActivityEnabled)
                    Toggle("Timers", isOn: binding(\.showsTimerActivity))
                    Toggle("Calls", isOn: binding(\.showsCallActivity))
                        .help("FaceTime, Zoom, Teams, Discord, Slack huddles and other calling apps, while they use the microphone.")
                    Toggle("File transfers", isOn: binding(\.showsTransferActivity))
                    Toggle("Upcoming calendar events", isOn: binding(\.showsPassiveActivities))
                        .disabled(!preferences.calendarGlanceEnabled)
                    Text("Screen recordings and voice notes always appear while the microphone or screen is being captured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Interaction") {
                    Toggle("Expand on hover", isOn: binding(\.hoverPeekEnabled))
                    Toggle("Show tabs below the open notch", isOn: binding(\.showsNotchTabBar))
                        .help("Capture, Shelf and Now Playing, one click apart.")
                    Picker("Fourth tab", selection: binding(\.notchTabLastSlot)) {
                        ForEach(NotchTabLastSlot.allCases) { slot in
                            Text(slot.title).tag(slot)
                        }
                    }
                    .disabled(!preferences.showsNotchTabBar)
                    .help("AI Agents opens your Claude Code, Codex and Cursor sessions in the notch. The Productivity Center stays in the capture page's More menu.")
                    Toggle("Swipe between activities on the trackpad", isOn: binding(\.swipesBetweenActivities))
                    Toggle("Haptic feedback", isOn: binding(\.islandHapticsEnabled))
                    Text("Click a satellite to bring it forward. Haptics follow your own gestures only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            }
            .disabled(!preferences.multipleActivitiesEnabled)

            // The system cards apply with or without the island, so these
            // switches stay available when it is off.
            Section("Interruptions") {
                Toggle("Low battery and charging", isOn: contextBinding(\.powerStatusEnabled))
                Toggle("Connectivity changes", isOn: contextBinding(\.networkStatusEnabled))
                Toggle("Audio accessories", isOn: contextBinding(\.audioRouteStatusEnabled))
                Toggle("Microphone and camera in use", isOn: contextBinding(\.showsPrivacyIndicators))
                Group {
                    Toggle("Show these alerts over activities", isOn: binding(\.allowsAlertsOverActivities))
                    Toggle("Transfer completion", isOn: binding(\.showsTransferCompletionAlerts))
                    focusRow
                }
                .disabled(!preferences.multipleActivitiesEnabled)
            }

            Group {
                Section("Live Activity API") {
                    Toggle("Allow local tools to publish activities", isOn: binding(\.externalActivitiesEnabled))
                    LabeledContent("Status", value: external.isListening ? "Listening on a private local socket" : "Off")
                    HStack {
                        Button("Copy CLI Path") { copyCLIPath() }
                        if !external.history.isEmpty {
                            Button("Clear Recent") { external.clearHistory() }
                        }
                    }
                    if !external.history.isEmpty {
                        DisclosureGroup("Recent (\(external.history.count))") {
                            ForEach(external.history.prefix(10)) { activity in
                                LabeledContent(activity.title) {
                                    Text(activity.lifecycle == .failed ? "Failed" : "Finished")
                                        .foregroundStyle(activity.lifecycle == .failed ? .red : .secondary)
                                }
                            }
                        }
                    }
                    Text("Scripts can run `notchshot-cli activity start|update|finish`. Only your account can connect; messages are plain text.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!preferences.multipleActivitiesEnabled)
        }
        .notchShotFormStyle()
    }

    @ViewBuilder
    private var focusRow: some View {
        Toggle("Focus on and off", isOn: Binding(
            get: { preferences.showsFocusEvents },
            set: { enabled in
                preferences.showsFocusEvents = enabled
                if enabled, focus.availability == .notDetermined {
                    focus.requestAuthorization { _ in coordinator.refreshIslandServices() }
                } else {
                    coordinator.refreshIslandServices()
                }
            }
        ))
        .disabled(focus.availability == .unavailable)
        switch focus.availability {
        case .unavailable:
            Text("This build lacks the Focus Status entitlement, so Focus changes can't be read.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .denied:
            Text("Focus Status access was declined. macOS reports only on or off — never which Focus is active.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .notDetermined, .authorized:
            Text("macOS reports only whether a Focus is on, never its name.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func binding<Value>(_ keyPath: ReferenceWritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(
            get: { preferences[keyPath: keyPath] },
            set: { value in
                preferences[keyPath: keyPath] = value
                coordinator.refreshIslandServices()
            }
        )
    }

    /// Context monitors start and stop with their preference.
    private func contextBinding(_ keyPath: ReferenceWritableKeyPath<Preferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { preferences[keyPath: keyPath] },
            set: { value in
                preferences[keyPath: keyPath] = value
                coordinator.refreshContextPreferences()
            }
        )
    }

    private func copyCLIPath() {
        guard let executable = Bundle.main.executableURL else { return }
        let path = executable.deletingLastPathComponent()
            .appendingPathComponent("notchshot-cli", isDirectory: false).path
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}
