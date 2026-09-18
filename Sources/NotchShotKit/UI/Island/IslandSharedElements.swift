import AppKit
import SwiftUI

/// Where each activity's shared element should currently be drawn.
///
/// Compact wings, expanded headers and satellites each place an invisible
/// anchor of the size they want. One glyph per activity is then drawn by
/// `IslandSharedElementLayer` at its anchor, above the clipped shell — so when
/// an anchor moves (compact → expanded, satellite → primary) the *same* view
/// travels and resizes instead of one copy fading out while another fades in.
struct IslandGlyphAnchorKey: PreferenceKey {
    static let defaultValue: [IslandActivityID: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [IslandActivityID: Anchor<CGRect>],
        nextValue: () -> [IslandActivityID: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { _, newest in newest }
    }
}

extension View {
    /// Reserves this view's frame for an activity's shared element.
    func islandGlyphAnchor(_ id: IslandActivityID) -> some View {
        anchorPreference(key: IslandGlyphAnchorKey.self, value: .bounds) { [id: $0] }
    }
}

/// An empty placeholder sized for a shared element.
struct IslandGlyphSlot: View {
    var id: IslandActivityID
    var size: CGFloat

    var body: some View {
        Color.clear
            .frame(width: size, height: size)
            .islandGlyphAnchor(id)
            .accessibilityHidden(true)
    }
}

/// Draws every visible activity's shared element at its current anchor.
struct IslandSharedElementLayer: View {
    var anchors: [IslandActivityID: Anchor<CGRect>]
    var activities: [IslandActivity]
    var isTracking: Bool
    @Bindable var coordinator: AppCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ForEach(activities.filter { anchors[$0.id] != nil }) { activity in
                if let anchor = anchors[activity.id] {
                    let rect = proxy[anchor]
                    IslandActivityGlyph(activity: activity, coordinator: coordinator)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        // Only presentation-shaping moves change `rect`; live
                        // values never do, so this cannot wobble on a tick.
                        .animation(
                            isTracking ? nil : IslandMotion.sharedElement(reduceMotion: reduceMotion),
                            value: rect
                        )
                        .transition(.opacity.animation(.easeOut(duration: 0.14)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The one visual that represents an activity at every level. It fills
/// whatever frame it is given, so the same view can be 16 pt in a satellite
/// and 56 pt in an expanded header.
struct IslandActivityGlyph: View {
    var activity: IslandActivity
    @Bindable var coordinator: AppCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accent: Color {
        Color(nsColor: NotchShotColorPolicy.readableAccentOnBlack(
            NSColor(hex: activity.accentHex) ?? .systemBlue
        ))
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            content(side: side)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    @ViewBuilder
    private func content(side: CGFloat) -> some View {
        switch activity.kind {
        case .media:
            IslandArtworkGlyph(coordinator: coordinator, side: side)
        case .recording:
            IslandRecordingGlyph(isPaused: activity.lifecycle == .paused, side: side)
        case .ai:
            IslandRingGlyph(
                progress: activity.progress,
                lifecycle: activity.lifecycle,
                accent: accent,
                side: side
            ) {
                if let agent = IslandActivityAdapters.headlineAgent(coordinator.context.islandAIActivities) {
                    AgentVibeIdentity(source: agent.source, size: side * 0.62)
                } else {
                    symbol(side: side)
                }
            }
        case .timer, .transfer, .external:
            IslandRingGlyph(
                progress: activity.progress,
                lifecycle: activity.lifecycle,
                accent: accent,
                side: side
            ) {
                symbol(side: side)
            }
        case .voiceNote, .calendar:
            symbol(side: side * 1.35)
        }
    }

    private func symbol(side: CGFloat) -> some View {
        Image(systemName: terminalSymbol ?? activity.symbolName)
            .resizable()
            .scaledToFit()
            .fontWeight(.semibold)
            .foregroundStyle(symbolColor)
            .frame(width: side * 0.46, height: side * 0.46)
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            .animation(IslandMotion.liveValue(reduceMotion: reduceMotion), value: terminalSymbol)
    }

    private var terminalSymbol: String? {
        switch activity.lifecycle {
        case .succeeded: "checkmark"
        case .failed: "exclamationmark"
        default: nil
        }
    }

    private var symbolColor: Color {
        switch activity.lifecycle {
        case .succeeded: .green
        case .failed: .red
        default: accent
        }
    }
}

/// A progress ring around a centre glyph. Determinate progress draws exactly
/// the reported fraction; an indeterminate source spins a short arc and never
/// implies a number.
struct IslandRingGlyph<Center: View>: View {
    var progress: IslandProgress
    var lifecycle: IslandLifecycle
    var accent: Color
    var side: CGFloat
    @ViewBuilder var center: () -> Center
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false

    private var lineWidth: CGFloat { max(1.5, side * 0.09) }

    private var tint: Color {
        switch lifecycle {
        case .succeeded: .green
        case .failed: .red
        case .waiting: .orange
        default: accent
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.islandInk(NotchIsland.Ink.hairline * 1.6), lineWidth: lineWidth)
            ring
            center()
        }
        .padding(lineWidth / 2)
        .frame(width: side, height: side)
    }

    @ViewBuilder
    private var ring: some View {
        switch progress {
        case .determinate(let fraction):
            Circle()
                .trim(from: 0, to: lifecycle == .succeeded ? 1 : fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                // The ring is the only thing a percentage animates.
                .animation(IslandMotion.liveValue(reduceMotion: reduceMotion), value: fraction)
                .animation(IslandMotion.liveValue(reduceMotion: reduceMotion), value: lifecycle)
        case .indeterminate where lifecycle == .active:
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(spin ? 270 : -90))
                .opacity(reduceMotion ? 0.6 : 1)
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { spin = true }
                }
                .onDisappear { spin = false }
        case .none, .indeterminate:
            if lifecycle.isTerminal {
                Circle().stroke(tint, lineWidth: lineWidth)
            }
        }
    }
}

struct IslandRecordingGlyph: View {
    var isPaused: Bool
    var side: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDimmed = false

    var body: some View {
        ZStack {
            if isPaused {
                Image(systemName: "pause.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.red)
                    .frame(width: side * 0.5, height: side * 0.5)
            } else {
                Circle()
                    .fill(.red)
                    .frame(width: side * 0.62, height: side * 0.62)
                    .opacity(isDimmed ? 0.4 : 1)
            }
        }
        .frame(width: side, height: side)
        .onAppear { startPulse() }
        .onChange(of: isPaused) { _, _ in startPulse() }
    }

    private func startPulse() {
        isDimmed = false
        guard !reduceMotion, !isPaused else { return }
        withAnimation(.easeInOut(duration: 0.9).repeatForever()) { isDimmed = true }
    }
}

struct IslandArtworkGlyph: View {
    @Bindable var coordinator: AppCoordinator
    var side: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: max(3, side / 5), style: .continuous)
        Group {
            if let image = coordinator.media.artwork {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.islandInk(NotchIsland.Ink.fill * 2)
                    Image(systemName: "music.note")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                        .padding(side * 0.26)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
    }
}
