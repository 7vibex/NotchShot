import AppKit
import SwiftUI

/// One app's volume: its icon, its name, and a level bar that is also the
/// slider. Shared by the menu-bar panel and the player's output list.
struct AppVolumeRow: View {
    var source: AppVolumeSource
    var height: CGFloat = NotchLayout.mediaPanelRowHeight

    @State private var draft: Double?
    @State private var isHovered = false

    private var mixer: AppVolumeMixer { .shared }
    private var level: Double { draft ?? mixer.volume(for: source.bundleIdentifier) }

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 20, height: 20)
                .opacity(source.isPlaying ? 1 : 0.55)
                .accessibilityHidden(true)
            Text(source.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.islandInk(source.isPlaying ? NotchIsland.Ink.primary : NotchIsland.Ink.secondary))
                .lineLimit(1)
                .frame(width: 92, alignment: .leading)
            AppVolumeSlider(level: level, isHovered: isHovered) { value, isFinal in
                draft = isFinal ? nil : value
                mixer.setVolume(value, for: source.bundleIdentifier)
            }
            Text("\(Int((level * 100).rounded()))")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                .frame(width: 24, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .frame(height: height)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(source.name) volume")
        .accessibilityValue("\(Int((level * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.1 : -0.1
            mixer.setVolume(level + step, for: source.bundleIdentifier)
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let image = NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleIdentifier).first?.icon {
            Image(nsImage: image).resizable()
        } else {
            Image(systemName: "app.fill")
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
        }
    }
}

/// The volume HUD's bar, made draggable: click anywhere to jump, drag to
/// adjust. Thickens a little while the row is hovered.
private struct AppVolumeSlider: View {
    var level: Double
    var isHovered: Bool
    var onChange: (Double, _ isFinal: Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.islandInk(NotchIsland.Ink.track))
                Capsule()
                    .fill(level > 0 ? Color.white : Color.clear)
                    .frame(width: max(level > 0 ? 6 : 0, width * level))
            }
            .frame(height: isHovered ? 6 : 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { onChange(Self.fraction($0.location.x, width), false) }
                    .onEnded { onChange(Self.fraction($0.location.x, width), true) }
            )
            .animation(NotchMotion.fade(reduceMotion: reduceMotion), value: isHovered)
        }
        .frame(height: 20)
    }

    private static func fraction(_ x: CGFloat, _ width: CGFloat) -> Double {
        Double(min(max(x / width, 0), 1))
    }
}

/// The menu panel's list: the apps playing now, then the ones turned down.
/// Re-read while the panel is open, so an app that starts playing appears.
struct MenuBarAppVolumeList: View {
    private var mixer: AppVolumeMixer { .shared }
    static let visibleLimit = 4

    var body: some View {
        VStack(spacing: 0) {
            if mixer.sources.isEmpty {
                Text("Apps that play sound show up here")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                    .frame(maxWidth: .infinity, minHeight: 28)
            } else {
                ForEach(mixer.sources.prefix(Self.visibleLimit)) { source in
                    AppVolumeRow(source: source, height: 30)
                        .padding(.horizontal, 10)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                mixer.refreshSources()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
