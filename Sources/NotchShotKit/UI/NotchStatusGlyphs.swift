import SwiftUI

/// A mode NotchShot itself has switched on, shown as a small glyph beside the
/// camera while the notch is idle: the strip the privacy dots use, on the
/// other side of the camera.
enum NotchStatusGlyph: String, CaseIterable, Identifiable, Sendable {
    case keyboardLocked
    case instantReplay
    case keepAwake

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .keyboardLocked: "keyboard.badge.ellipsis"
        case .instantReplay: "record.circle"
        case .keepAwake: "cup.and.heat.waves.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .keyboardLocked: "Keyboard locked for cleaning"
        case .instantReplay: "Instant Replay is keeping the last moments of the screen"
        case .keepAwake: "Keeping the Mac awake"
        }
    }
}

@MainActor
enum NotchStatusGlyphPolicy {
    /// The strip holds two glyphs; a third mode waits for one to end.
    static let maximumVisible = 2

    /// Most urgent first: a locked keyboard explains why typing does nothing.
    static func glyphs(
        keyboardLocked: Bool,
        replayBuffering: Bool,
        keepingAwake: Bool
    ) -> [NotchStatusGlyph] {
        var result: [NotchStatusGlyph] = []
        if keyboardLocked { result.append(.keyboardLocked) }
        if replayBuffering { result.append(.instantReplay) }
        if keepingAwake { result.append(.keepAwake) }
        return Array(result.prefix(maximumVisible))
    }

    static var current: [NotchStatusGlyph] {
        let keepAwake = KeepAwakeController.shared
        return glyphs(
            keyboardLocked: KeyboardCleaningController.shared.isActive,
            replayBuffering: InstantReplayController.shared.isBuffering,
            // The agent mode is armed, not awake, until an agent works.
            keepingAwake: keepAwake.mode == .whileAgentsWork ? keepAwake.isHoldingAssertion : keepAwake.isOn
        )
    }

    /// Whether the idle notch widens for its indicator strips: the privacy
    /// dots on one side, these glyphs on the other. `NotchRootView` and the
    /// window controller must agree, or the strip draws where clicks fall
    /// through to the menu bar.
    static func showsIndicatorWings(hasPhysicalNotch: Bool) -> Bool {
        guard hasPhysicalNotch else { return false }
        let privacy = Preferences.shared.showsPrivacyIndicators && PrivacyIndicatorMonitor.shared.isActive
        return privacy || !current.isEmpty
    }
}

struct NotchStatusGlyphRow: View {
    var glyphs: [NotchStatusGlyph]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(glyphs) { glyph in
                Image(systemName: glyph.symbolName)
                    .font(.system(size: glyphs.count > 1 ? 8 : 10, weight: .semibold))
                    .foregroundStyle(glyph == .keyboardLocked
                        ? IslandSystemColor.orange
                        : Color.islandInk(NotchIsland.Ink.secondary))
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(glyphs.map(\.accessibilityLabel).joined(separator: ", "))
    }
}
