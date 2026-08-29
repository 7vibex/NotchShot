import AppKit
import SwiftUI

/// Resolves the real application icon for an AI source from the user's own Mac.
///
/// NotchShot ships no third-party artwork. The icon for Claude, Codex, or
/// Cursor is whatever LaunchServices reports for that app on this machine, so
/// it is always the current icon, it is legally the vendor's own copy, and an
/// agent that is not installed simply falls back to a drawn mark.
///
/// Every lookup is cached. `urlForApplication(withBundleIdentifier:)` is a
/// LaunchServices round trip — an order of magnitude past the `FileManager`
/// walk that already had to be cached out of the history load path — and the
/// island re-evaluates its body on every progress tick.
@MainActor
enum AgentIconCatalog {
    /// Bundle identifiers to try, in order. The first that resolves wins, so
    /// the dedicated app is listed before the general-purpose host that can
    /// also run that agent.
    static func bundleIdentifiers(for source: AISource) -> [String] {
        switch source {
        case .claude:
            [
                "com.anthropic.claudefordesktop",
                "com.anthropic.claude",
            ]
        case .codex:
            [
                // ChatGPT's desktop app ships under the Codex identifier.
                "com.openai.codex",
                "com.openai.chat",
            ]
        case .cursor:
            [
                // Cursor is packaged by ToDesktop and keeps their identifier.
                "com.todesktop.230313mzl4w4u92",
                "com.cursor.Cursor",
            ]
        case .terminal:
            [
                "com.mitchellh.ghostty",
                "dev.warp.Warp-Stable",
                "com.googlecode.iterm2",
                "net.kovidgoyal.kitty",
                "com.github.wez.wezterm",
                "com.apple.Terminal",
            ]
        }
    }

    private static var resolvedURLs: [AISource: URL] = [:]
    private static var resolvedIcons: [AISource: NSImage] = [:]
    private static var misses: [AISource: Date] = [:]

    /// How long a failed lookup is trusted. A miss is cached so an uninstalled
    /// agent does not pay LaunchServices on every frame, but not permanently —
    /// installing Cursor mid-session should light its icon up before a relaunch.
    private static let missLifetime: TimeInterval = 5 * 60

    /// The installed application for this source, or `nil` when none of its
    /// candidates are present.
    ///
    /// Every caller goes through here rather than calling LaunchServices
    /// directly, because a SwiftUI body re-runs on each progress tick and
    /// `urlForApplication(withBundleIdentifier:)` is not cheap enough to sit in
    /// one uncached.
    static func applicationURL(for source: AISource) -> URL? {
        if let cached = resolvedURLs[source] { return cached }
        if let missedAt = misses[source], Date().timeIntervalSince(missedAt) < missLifetime {
            return nil
        }

        let workspace = NSWorkspace.shared
        for identifier in bundleIdentifiers(for: source) {
            guard let url = workspace.urlForApplication(withBundleIdentifier: identifier) else {
                continue
            }
            resolvedURLs[source] = url
            misses[source] = nil
            return url
        }

        misses[source] = Date()
        return nil
    }

    /// The installed icon for this source, or `nil` when no candidate app is
    /// present. Safe to call from a SwiftUI body.
    static func icon(for source: AISource) -> NSImage? {
        if let cached = resolvedIcons[source] { return cached }
        guard let url = applicationURL(for: source) else { return nil }

        let image = NSWorkspace.shared.icon(forFile: url.path)
        // An app icon is drawn at 16–28pt here. Pinning the size lets AppKit
        // pick the right representation once instead of resampling the 1024pt
        // master on every draw.
        image.size = NSSize(width: 64, height: 64)
        resolvedIcons[source] = image
        return image
    }

    /// Brings the source's application forward, if it is installed.
    static func activate(_ source: AISource) {
        guard let url = applicationURL(for: source) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// The visual identity for one agent: its real app icon when installed, and a
/// drawn accent tile when it is not.
///
/// The two cases are deliberately the same silhouette and size, so a row does
/// not reflow when an agent is installed partway through a session.
struct AgentGlyph: View {
    var source: AISource
    var size: CGFloat
    /// Rings the drawn fallback so it reads as a mark rather than as a loose
    /// symbol. A real app icon never gets one: it already carries its own edge
    /// and corner radius, and a second outline around it reads as a rendering
    /// bug rather than as emphasis.
    var showsAccentRing = true

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var accent: Color {
        Color(nsColor: NotchShotColorPolicy.readableAccentOnBlack(
            NSColor(hex: source.accentHex) ?? .systemGreen
        ))
    }

    private var cornerRadius: CGFloat { size * 0.26 }

    var body: some View {
        content
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        if let icon = AgentIconCatalog.icon(for: source) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(fallbackFill)
                .overlay {
                    Image(systemName: source.symbolName)
                        .font(.system(size: size * 0.5, weight: .semibold))
                        .foregroundStyle(accent)
                }
                .overlay {
                    if showsAccentRing {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(accent.opacity(0.34), lineWidth: NotchIsland.Stroke.hairline)
                    }
                }
        }
    }

    /// A vertical wash rather than a flat fill: on the island's black shell a
    /// flat tint reads as a missing image, while a gradient reads as a mark.
    private var fallbackFill: LinearGradient {
        LinearGradient(
            colors: reduceTransparency
                ? [accent.opacity(0.30), accent.opacity(0.30)]
                : [accent.opacity(0.34), accent.opacity(0.16)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
