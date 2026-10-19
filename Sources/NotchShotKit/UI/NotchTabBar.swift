import SwiftUI

/// The small pill that hangs under the open notch: one glyph per page, the
/// current one lifted onto the island's near-black control surface.
struct NotchTabBar: View {
    var current: NotchTab
    @Bindable var coordinator: AppCoordinator

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection

    var body: some View {
        let tabs = Preferences.shared.notchTabs
        HStack(spacing: NotchTabBarGeometry.spacing) {
            ForEach(tabs, id: \.self) { tab in
                NotchTabButton(
                    tab: tab,
                    isSelected: tab == current,
                    isAvailable: coordinator.isTabAvailable(tab),
                    unavailableHint: coordinator.unavailableTabHint(tab),
                    selection: selection
                ) {
                    guard tab != current else { return }
                    coordinator.showTab(tab)
                }
            }
        }
        .padding(NotchTabBarGeometry.inset)
        .frame(
            width: NotchTabBarGeometry.size(tabCount: tabs.count).width,
            height: NotchTabBarGeometry.height
        )
        .background(Capsule().fill(.black))
        .overlay(Capsule().strokeBorder(Color.islandInk(NotchIsland.Surface.edge), lineWidth: NotchIsland.Stroke.hairline))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .animation(NotchMotion.selection(reduceMotion: reduceMotion), value: current)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notch pages")
    }
}

private struct NotchTabButton: View {
    var tab: NotchTab
    var isSelected: Bool
    var isAvailable: Bool
    var unavailableHint: String
    var selection: Namespace.ID
    var action: () -> Void

    @State private var isHovered = false

    /// Inactive pages sit at the secondary ink level, so every tab reads as a
    /// page at a glance; an unavailable one (the shelf with nothing on it)
    /// stays visible at the tertiary floor instead of fading to a smudge.
    private var inkOpacity: Double {
        if !isAvailable { return NotchIsland.Ink.tertiary - 0.08 }
        if isSelected { return NotchIsland.Ink.primary }
        return isHovered ? NotchIsland.Ink.primary : NotchIsland.Ink.secondary + 0.07
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: tab.symbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.islandInk(inkOpacity))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Color.islandInk(NotchIsland.Surface.selected))
                            .matchedGeometryEffect(id: "selected", in: selection)
                    } else if isHovered, isAvailable {
                        Capsule().fill(Color.islandInk(NotchIsland.Surface.control))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(NotchPressButtonStyle())
        .disabled(!isAvailable)
        .onHover { isHovered = $0 }
        .help(isAvailable ? tab.title : unavailableHint)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
