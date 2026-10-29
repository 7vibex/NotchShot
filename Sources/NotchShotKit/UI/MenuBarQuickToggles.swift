import SwiftUI

/// The menu's row of round switches, the way Control Center lays out its
/// modules: Keep Awake, Instant Replay, Clean Keyboard, break nudges and the
/// per-app volume mixer. Each circle fills with the accent while its mode
/// runs, and the caption under it says how long is left.
struct MenuBarQuickToggles: View {
    @Bindable var coordinator: AppCoordinator
    var onDismiss: () -> Void

    @Bindable private var extras = ExtrasPreferences.shared
    private var keepAwake: KeepAwakeController { .shared }
    private var keyboard: KeyboardCleaningController { .shared }
    private var replay: InstantReplayController { .shared }

    /// Only a countdown needs the captions to tick.
    private var isCountingDown: Bool {
        keyboard.isActive || keepAwake.remaining() != nil
    }

    var body: some View {
        VStack(spacing: 2) {
            TimelineView(.animation(minimumInterval: 1, paused: !isCountingDown)) { context in
                HStack(spacing: 0) {
                    keepAwakeTile(now: context.date)
                    replayTile
                    keyboardTile(now: context.date)
                    MenuBarQuickTile(
                        title: "Breaks",
                        caption: "Breaks",
                        systemImage: "figure.stand",
                        isOn: extras.breakNudgesEnabled
                    ) {
                        extras.breakNudgesEnabled.toggle()
                        coordinator.wellbeing.refresh()
                    }
                    MenuBarQuickTile(
                        title: "App Volume",
                        caption: "App Volume",
                        systemImage: "slider.vertical.3",
                        isOn: extras.appVolumesEnabled
                    ) {
                        coordinator.setAppVolumesEnabled(!extras.appVolumesEnabled)
                    }
                }
            }
            .padding(.vertical, 4)

            if extras.appVolumesEnabled {
                MenuBarAppVolumeList()
            }

            if replay.isBuffering {
                MenuBarRow(
                    title: "Save Last \(extras.replaySeconds) Seconds",
                    systemImage: "square.and.arrow.down",
                    shortcut: HotKeyController.shared.bindings[.saveInstantReplay]?.displayString
                ) {
                    onDismiss()
                    coordinator.saveInstantReplay()
                }
                .disabled(replay.isSaving)
            }
        }
    }

    // MARK: Tiles

    @ViewBuilder
    private func keepAwakeTile(now: Date) -> some View {
        let caption: String = switch keepAwake.mode {
        case .off: "Keep Awake"
        case .until: Self.minutesLeft(keepAwake.remaining(now: now) ?? 0)
        case .indefinitely: "Awake"
        case .whileAgentsWork: keepAwake.isHoldingAssertion ? "Agents Busy" : "With Agents"
        }
        if keepAwake.isOn {
            MenuBarQuickTile(
                title: "Keep Awake",
                caption: caption,
                systemImage: "cup.and.heat.waves.fill",
                isOn: true
            ) {
                coordinator.turnOffKeepAwake()
            }
        } else {
            // Off, the circle asks for how long; on, it only switches off.
            Menu {
                ForEach(KeepAwakeChoice.allCases) { choice in
                    Button(choice.title) { coordinator.turnOnKeepAwake(choice) }
                }
            } label: {
                MenuBarQuickTileFace(caption: caption, systemImage: "cup.and.heat.waves", isOn: false)
            }
            .menuStyle(.button)
            .buttonStyle(MenuBarQuickTileButtonStyle())
            .menuIndicator(.hidden)
            .accessibilityLabel("Keep Awake")
            .accessibilityValue("Off")
        }
    }

    private var replayTile: some View {
        let caption: String = switch replay.state {
        case .off: "Replay"
        case .starting: "Starting"
        case .buffering: "Last \(extras.replaySeconds)s"
        case .paused: "Paused"
        case .failed: "Stopped"
        }
        return MenuBarQuickTile(
            title: "Instant Replay",
            caption: caption,
            systemImage: "record.circle",
            isOn: extras.instantReplayEnabled
        ) {
            coordinator.setInstantReplayEnabled(!extras.instantReplayEnabled)
        }
    }

    private func keyboardTile(now: Date) -> some View {
        let remaining = keyboard.remaining(now: now)
        return MenuBarQuickTile(
            title: "Clean Keyboard",
            caption: remaining.map(Self.clock) ?? "Clean Keys",
            systemImage: "keyboard",
            isOn: keyboard.isActive
        ) {
            if keyboard.isActive {
                coordinator.stopKeyboardCleaning()
            } else {
                // Closed first, so the notch's burst explains the dead keys.
                onDismiss()
                coordinator.startKeyboardCleaning()
            }
        }
    }

    private static func minutesLeft(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        return minutes >= 60 ? "\(minutes / 60) h left" : "\(max(1, minutes)) min left"
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// One round switch. The whole column is the hit target.
private struct MenuBarQuickTile: View {
    var title: String
    var caption: String
    var systemImage: String
    var isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            MenuBarQuickTileFace(caption: caption, systemImage: systemImage, isOn: isOn)
        }
        .buttonStyle(MenuBarQuickTileButtonStyle())
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? (caption == title ? "On" : "On, \(caption)") : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

private struct MenuBarQuickTileFace: View {
    var caption: String
    var systemImage: String
    var isOn: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.menuBarQuickTileHighlight) private var highlight

    var body: some View {
        VStack(spacing: 5) {
            Circle()
                .fill(isOn ? Color.accentColor : Color.islandInk(NotchIsland.Surface.selected + highlight))
                .frame(width: 38, height: 38)
                .overlay {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(NotchSymbolMotion.swap(reduceMotion: reduceMotion))
                }
                .brightness(isOn ? highlight : 0)
            Text(caption)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.islandInk(isOn ? NotchIsland.Ink.primary : NotchIsland.Ink.secondary))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .contentTransition(.numericText(countsDown: true))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .animation(NotchShotMotion.selection(reduceMotion: reduceMotion), value: isOn)
        .accessibilityHidden(true)
    }
}

/// Hover lifts the circle a step, a press another, like the rows' ladder.
private struct MenuBarQuickTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuBarQuickTileHover(isPressed: configuration.isPressed) {
            configuration.label
        }
    }
}

private struct MenuBarQuickTileHover<Content: View>: View {
    var isPressed: Bool
    @ViewBuilder var content: () -> Content

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        content()
            .environment(\.menuBarQuickTileHighlight, isPressed ? 0.1 : (isHovered ? 0.05 : 0))
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovered = $0 }
    }
}

private extension EnvironmentValues {
    @Entry var menuBarQuickTileHighlight: Double = 0
}
