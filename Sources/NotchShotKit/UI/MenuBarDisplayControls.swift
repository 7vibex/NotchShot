import SwiftUI

/// The menu's Display section: a brightness bar for every screen, external
/// monitors included, then Night Shift and Dark Mode. Control Center only
/// dims Apple's own displays and hides Night Shift a level down, so this is
/// the one place both are a single drag or click away.
struct MenuBarDisplayControls: View {
    @Bindable var brightness: DisplayBrightnessController

    @Bindable private var nightShift = NightShiftController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuBarSectionTitle("Display")
            ForEach(brightness.displays) { display in
                MenuBarLevelRow(
                    // "Built-in Retina Display" doesn't fit beside a slider.
                    title: display.isBuiltIn ? "Built-in" : display.name,
                    systemImage: display.isBuiltIn ? "laptopcomputer" : "display",
                    level: display.level,
                    accessibilityTitle: "\(display.name) brightness"
                ) { value, _ in
                    brightness.setLevel(value, for: display.id)
                } trailing: {
                    Text("\(Int((display.level * 100).rounded()))")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                        .frame(width: 30, alignment: .trailing)
                        .accessibilityHidden(true)
                }
            }
            if nightShift.isAvailable {
                MenuBarLevelRow(
                    title: "Night Shift",
                    systemImage: nightShift.isOn ? "moon.fill" : "moon",
                    level: nightShift.strength,
                    isDimmed: !nightShift.isOn,
                    accessibilityTitle: "Night Shift warmth"
                ) { value, isFinal in
                    nightShift.setStrength(value, isFinal: isFinal)
                } trailing: {
                    // Its own button: the row's slider takes the rest of the
                    // clicks.
                    Button { nightShift.setOn(!nightShift.isOn) } label: {
                        MenuBarSwitch(isOn: nightShift.isOn)
                            .frame(width: 30, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Night Shift")
                    .accessibilityValue(nightShift.isOn ? "On" : "Off")
                    .accessibilityAddTraits(.isToggle)
                }
            }
            if nightShift.isDarkModeAvailable {
                MenuBarSwitchRow(
                    title: "Dark Mode",
                    systemImage: "circle.lefthalf.filled",
                    isOn: Binding(get: { nightShift.isDarkMode }, set: { nightShift.setDarkMode($0) })
                )
            }
        }
        .onAppear {
            brightness.refreshNativeLevels()
            nightShift.refresh()
        }
    }

    /// Whether the section has anything to show, so the menu can leave out
    /// its title and hairline on a Mac where none of it works.
    static func hasContent(brightness: DisplayBrightnessController) -> Bool {
        !brightness.displays.isEmpty || NightShiftController.shared.isAvailable
            || NightShiftController.shared.isDarkModeAvailable
    }
}

/// Icon, name and a draggable level bar, laid out like the app volume rows
/// so the two lists read as one family.
private struct MenuBarLevelRow<Trailing: View>: View {
    var title: String
    var systemImage: String
    var level: Double
    var isDimmed = false
    var accessibilityTitle: String
    var onChange: (Double, _ isFinal: Bool) -> Void
    @ViewBuilder var trailing: () -> Trailing

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 92, alignment: .leading)
                LevelBarSlider(level: level, isHovered: isHovered, onChange: onChange)
                    .opacity(isDimmed ? 0.45 : 1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityTitle)
            .accessibilityValue("\(Int((level * 100).rounded())) percent")
            .accessibilityAdjustableAction { direction in
                onChange(level + (direction == .increment ? 0.1 : -0.1), true)
            }
            trailing()
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}
