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

            Group {
                Section("Show in the Island") {
                    Toggle("Now Playing", isOn: binding(\.showsMediaActivity))
                    Toggle("AI agent activity", isOn: binding(\.showsAIIslandActivity))
                        .disabled(!preferences.aiActivityEnabled)
                    Toggle("Timers", isOn: binding(\.showsTimerActivity))
                    Toggle("File transfers", isOn: binding(\.showsTransferActivity))
                    Toggle("Upcoming calendar events", isOn: binding(\.showsPassiveActivities))
                        .disabled(!preferences.calendarGlanceEnabled)
                    Text("Screen recordings and voice notes always appear while the microphone or screen is being captured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Interaction") {
                    Toggle("Expand on hover", isOn: binding(\.hoverPeekEnabled))
                    Toggle("Swipe between activities on the trackpad", isOn: binding(\.swipesBetweenActivities))
                    Toggle("Haptic feedback", isOn: binding(\.islandHapticsEnabled))
                    Text("Click a satellite to bring it forward. Haptics play only for your own gestures, never for background events, and follow the system's Reduce Motion setting for animation.")
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
                    Text("Scripts and build tools can run `notchshot-cli activity start|update|finish|fail|dismiss`. Only your user account can connect. Messages carry bounded plain text, a progress value, and an icon from a fixed list — never commands, paths, links, or markup. Recent history stays in memory only.")
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
            Text("This build is not signed with the Focus Status capability macOS requires, so Focus changes cannot be read. Nothing is inferred instead.")
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
