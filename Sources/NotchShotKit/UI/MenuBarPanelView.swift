import AppKit
import SwiftUI

/// The glass menu that drops from the menu-bar mascot.
///
/// It replaces both the plain popover and the twenty-item right-click menu
/// that sat behind the old camera icon. Capturing is the notch's job, so the
/// menu holds no capture buttons: only the Quick Toggles row, the places
/// captures end up, the three after-capture switches people actually flip,
/// and the app itself. The rarely used commands are one level down under
/// More, and everything else stays in Settings.
///
/// It is drawn like the island it controls: dark glass, white ink,
/// hairlines instead of boxes.
struct MenuBarPanelView: View {
    @Bindable var coordinator: AppCoordinator
    /// Nil when this build has no signed update feed.
    var onCheckForUpdates: (() -> Void)?
    var onSummarizeDocument: () -> Void
    /// Closes the panel immediately. Every action calls it *before* acting: a
    /// capture that starts under its own menu photographs the menu.
    var onDismiss: () -> Void

    @Bindable private var preferences = Preferences.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    static let width: CGFloat = 320
    /// Concentric with the rows' 10 pt highlight inside the 10 pt inset.
    static let cornerRadius: CGFloat = 20
    static let inset: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            MenuBarHairline()
            MenuBarQuickToggles(coordinator: coordinator, onDismiss: onDismiss)
            MenuBarHairline()
            librarySection
            MenuBarHairline()
            afterCaptureSection
            MenuBarHairline()
            appSection
        }
        .padding(Self.inset)
        .frame(width: Self.width)
        .background(MenuBarGlassBackground(cornerRadius: Self.cornerRadius))
        .environment(\.colorScheme, .dark)
        .tint(.accentColor)
        // Drops out of the menu bar the way the island opens from the notch.
        .scaleEffect(hasAppeared || reduceMotion ? 1 : 0.94, anchor: .top)
        .offset(y: hasAppeared || reduceMotion ? 0 : -6)
        .onAppear {
            withAnimation(NotchMotion.content(reduceMotion: reduceMotion)) { hasAppeared = true }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            NotchShotLogoShape()
                .fill(Color.white, style: FillStyle(eoFill: true))
                .frame(width: 22, height: 16)
                .accessibilityHidden(true)
            Text("NotchShot")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            if coordinator.isRecordingActive {
                MenuBarStatusLabel(title: "Recording", tint: IslandSystemColor.red)
            } else if coordinator.stack.isCollecting {
                MenuBarStatusLabel(title: "Collecting", tint: .islandInk(NotchIsland.Ink.secondary))
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 34)
    }

    // MARK: Library

    private var librarySection: some View {
        VStack(spacing: 0) {
            // The one capture control kept here: the menu bar is where people
            // look to stop a recording, and it is only shown while one runs.
            if coordinator.isRecordingActive {
                MenuBarRow(
                    title: "Stop Recording",
                    systemImage: "stop.circle.fill",
                    iconTint: IslandSystemColor.red
                ) {
                    onDismiss()
                    coordinator.stopRecording()
                }
            }
            MenuBarRow(
                title: "Shelf",
                systemImage: "tray.full",
                detail: coordinator.shelfItems.isEmpty ? "Empty" : "\(coordinator.shelfItems.count)"
            ) {
                onDismiss()
                coordinator.showShelf()
            }
            .disabled(!coordinator.canShowShelf)

            MenuBarRow(title: "History", systemImage: "clock.arrow.circlepath") {
                onDismiss()
                coordinator.onOpenHistory?()
            }
            MenuBarRow(title: "Clipboard", systemImage: "doc.on.clipboard") {
                onDismiss()
                coordinator.openClipboard()
            }
            MenuBarRow(title: "Productivity", systemImage: "square.grid.2x2") {
                onDismiss()
                coordinator.openProductivity()
            }
        }
    }

    // MARK: After capture

    private var afterCaptureSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuBarSectionTitle("After Capture")
            MenuBarSwitchRow(
                title: "Copy to Clipboard",
                systemImage: "doc.on.doc",
                isOn: $preferences.copyToClipboardAfterCapture
            )
            MenuBarSwitchRow(
                title: "Save to \(preferences.outputFolder.lastPathComponent)",
                systemImage: "folder",
                isOn: $preferences.saveToDiskAfterCapture
            )
            MenuBarSwitchRow(
                title: "Play Sound",
                systemImage: "speaker.wave.2",
                isOn: $preferences.playsCaptureSound
            )
        }
    }

    // MARK: App

    private var appSection: some View {
        VStack(spacing: 0) {
            Menu {
                moreMenuItems
            } label: {
                MenuBarRowLabel(title: "More", systemImage: "ellipsis.circle") {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                }
            }
            .menuStyle(.button)
            .buttonStyle(MenuBarRowButtonStyle())
            .menuIndicator(.hidden)

            MenuBarRow(title: "Settings…", systemImage: "gearshape", shortcut: "⌘,") {
                onDismiss()
                coordinator.onOpenSettings?()
            }
            .keyboardShortcut(",", modifiers: .command)

            MenuBarRow(title: "Quit NotchShot", systemImage: "power", shortcut: "⌘Q") {
                onDismiss()
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    /// Commands too occasional for the surface, kept so nothing the old
    /// right-click menu could do is lost.
    @ViewBuilder
    private var moreMenuItems: some View {
        Section("Capture") {
            Button {
                onDismiss()
                coordinator.capture(.previousArea, timer: .none)
            } label: {
                Label(CaptureIntent.previousArea.title, systemImage: CaptureIntent.previousArea.symbolName)
            }
            .disabled(!coordinator.hasPreviousArea)
            Button {
                onDismiss()
                coordinator.restoreLastDismissed()
            } label: {
                Label("Restore Last Capture", systemImage: "arrow.uturn.backward")
            }
            .disabled(!coordinator.canRestoreDismissed)
        }
        Section("Stack") {
            Toggle(isOn: Binding(
                get: { coordinator.stack.isCollecting },
                set: { _ in
                    onDismiss()
                    coordinator.toggleStackCollecting()
                }
            )) {
                Label("Collect Captures in Stack", systemImage: "square.stack")
            }
            Button("Add Latest Capture to Stack") {
                onDismiss()
                coordinator.addLatestToStack()
            }
            .disabled(!coordinator.canShowShelf)
            Button("Clear Stack") {
                onDismiss()
                coordinator.stack.clear()
            }
            .disabled(coordinator.stack.isEmpty)
        }
        Section("Pinned Captures") {
            Button("Unlock All") {
                onDismiss()
                FloatingCaptureManager.shared.unlockAll()
            }
            Button("Close All") {
                onDismiss()
                FloatingCaptureManager.shared.closeAll()
            }
        }
        Divider()
        Button {
            onDismiss()
            onSummarizeDocument()
        } label: {
            Label("Summarize Document…", systemImage: "doc.text.magnifyingglass")
        }
        if let onCheckForUpdates {
            Button {
                onDismiss()
                onCheckForUpdates()
            } label: {
                Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
            }
        }
    }
}

// MARK: - Surface

/// The island's black-into-glass, as a menu: native Liquid Glass darkened
/// most at the top, where the panel meets the menu bar, so white ink reads
/// over any window behind it. Reduce Transparency and Increase Contrast get a
/// solid surface of the same shape.
private struct MenuBarGlassBackground: View {
    var cornerRadius: CGFloat

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if NotchShotDesignSystem.usesLiquidGlass(
            reduceTransparency: reduceTransparency,
            increaseContrast: colorSchemeContrast == .increased
        ) {
            ZStack {
                Color.clear
                    .notchShotMenuGlass(in: shape)
                shape.fill(LinearGradient(
                    colors: [.black.opacity(0.62), .black.opacity(0.42)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.2), .white.opacity(0.06)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            }
        } else {
            shape.fill(Color(white: 0.08))
                .overlay(shape.strokeBorder(Color.islandInk(0.24), lineWidth: 1))
        }
    }
}

private struct MenuBarHairline: View {
    var body: some View {
        Rectangle()
            .fill(Color.islandInk(NotchIsland.Ink.hairline))
            .frame(height: 1)
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .accessibilityHidden(true)
    }
}

private struct MenuBarSectionTitle: View {
    var title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
            .padding(.horizontal, 10)
            .padding(.top, 2)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct MenuBarStatusLabel: View {
    var title: String
    var tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Rows

/// Icon, title, and an optional trailing detail or shortcut, the way a menu
/// item reads, on the island's ink ladder.
struct MenuBarRowLabel<Trailing: View>: View {
    var title: String
    var systemImage: String
    var iconTint: Color = .islandInk(NotchIsland.Ink.secondary)
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(iconTint)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 8)
            trailing()
        }
    }
}

struct MenuBarRow: View {
    var title: String
    var systemImage: String
    var iconTint: Color = .islandInk(NotchIsland.Ink.secondary)
    var detail: String?
    var shortcut: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            MenuBarRowLabel(title: title, systemImage: systemImage, iconTint: iconTint) {
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                } else if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(MenuBarRowButtonStyle())
        .accessibilityLabel(detail.map { "\(title), \($0)" } ?? title)
    }
}

/// The row's highlight follows the pointer like a system menu's selection,
/// as a rounded fill on the island's surface ladder.
struct MenuBarRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuBarRowHighlight(isPressed: configuration.isPressed) {
            configuration.label
        }
    }
}

struct MenuBarRowHighlight<Content: View>: View {
    var isPressed: Bool
    @ViewBuilder var content: () -> Content

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private var fill: Double {
        guard isEnabled else { return 0 }
        if isPressed { return NotchIsland.Surface.selected }
        return isHovered ? NotchIsland.Surface.hover : 0
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: NotchIsland.Radius.control, style: .continuous)
        content()
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background(shape.fill(Color.islandInk(fill)))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovered = $0 }
    }
}

/// A setting that applies the moment it is flipped; the whole row is the
/// hit target, not only the switch.
private struct MenuBarSwitchRow: View {
    var title: String
    var systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        MenuBarRowHighlight(isPressed: false) {
            MenuBarRowLabel(title: title, systemImage: systemImage) {
                MenuBarSwitch(isOn: isOn)
            }
        }
        .onTapGesture { isOn.toggle() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
        .accessibilityAction { isOn.toggle() }
    }
}

/// Drawn rather than a system switch: an `NSSwitch` in a panel whose app is
/// not active draws its inactive grey, and on and off then look alike. It
/// takes no clicks of its own; the row toggles.
private struct MenuBarSwitch: View {
    var isOn: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Capsule()
            .fill(isOn ? Color.accentColor : Color.islandInk(NotchIsland.Ink.recessed))
            .frame(width: 30, height: 18)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .padding(2)
            }
            .animation(NotchShotMotion.selection(reduceMotion: reduceMotion), value: isOn)
            .accessibilityHidden(true)
    }
}
