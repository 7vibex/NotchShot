import AppKit
import SwiftUI

/// A small, testable presentation model for the app named by Notification
/// Center's visible banner. It deliberately recognizes only sources whose
/// installed application can be resolved by a stable bundle identifier.
enum SystemNotificationSourceKind: String, Sendable, Equatable {
    case messages
    case whatsApp
    case mail
    case slack
    case generic

    static func resolve(_ sourceName: String) -> Self {
        let folded = sourceName.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        if folded.contains("whatsapp") { return .whatsApp }
        if folded == "messages" || folded.contains("imessage") { return .messages }
        if folded == "mail" || folded.contains("apple mail") { return .mail }
        if folded.contains("slack") { return .slack }
        return .generic
    }

    var symbolName: String {
        switch self {
        case .messages: "message.fill"
        case .whatsApp: "bubble.left.and.bubble.right.fill"
        case .mail: "envelope.fill"
        case .slack: "number"
        case .generic: "app.badge.fill"
        }
    }

    var accentHex: String {
        switch self {
        case .messages: "#0A84FF"
        case .whatsApp: "#25D366"
        case .mail: "#64D2FF"
        case .slack: "#C084FC"
        case .generic: "#A78BFA"
        }
    }

    var bundleIdentifiers: [String] {
        switch self {
        case .messages:
            ["com.apple.MobileSMS"]
        case .whatsApp:
            ["net.whatsapp.WhatsApp", "desktop.WhatsApp"]
        case .mail:
            ["com.apple.mail"]
        case .slack:
            ["com.tinyspeck.slackmacgap"]
        case .generic:
            []
        }
    }

    /// Messages and WhatsApp are the sources for which the card describes the
    /// launch as a reply handoff. NotchShot still does not send the message.
    var supportsReplyHandoff: Bool {
        self == .messages || self == .whatsApp
    }
}

struct SystemNotificationSourcePresentation: Sendable, Equatable {
    let sourceName: String
    let kind: SystemNotificationSourceKind

    init(sourceName: String) {
        self.sourceName = sourceName
        kind = SystemNotificationSourceKind.resolve(sourceName)
    }

    var symbolName: String { kind.symbolName }
    var accentHex: String { kind.accentHex }
    var supportsReplyHandoff: Bool { kind.supportsReplyHandoff }

    var openAccessibilityLabel: String {
        supportsReplyHandoff
            ? "Open \(sourceName) to reply"
            : "Open \(sourceName)"
    }
}

enum SystemNotificationTimePolicy {
    static func compactElapsed(receivedAt: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(receivedAt)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }
}

/// Resolves app URLs and icons once. The banner carries a source name, not a
/// bundle identifier, so unknown or localized names keep the generic mark and
/// do not receive a control that could open the wrong application.
@MainActor
enum SystemNotificationSourceCatalog {
    private static var resolvedURLs: [SystemNotificationSourceKind: URL] = [:]
    private static var resolvedIcons: [SystemNotificationSourceKind: NSImage] = [:]
    private static var misses: [SystemNotificationSourceKind: Date] = [:]
    private static let missLifetime: TimeInterval = 5 * 60

    static func applicationURL(for source: SystemNotificationSourcePresentation) -> URL? {
        guard source.kind != .generic else { return nil }
        if let cached = resolvedURLs[source.kind] { return cached }
        if let missedAt = misses[source.kind], Date().timeIntervalSince(missedAt) < missLifetime {
            return nil
        }

        for identifier in source.kind.bundleIdentifiers {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
                continue
            }
            resolvedURLs[source.kind] = url
            misses[source.kind] = nil
            return url
        }
        misses[source.kind] = Date()
        return nil
    }

    static func icon(for source: SystemNotificationSourcePresentation) -> NSImage? {
        if let cached = resolvedIcons[source.kind] { return cached }
        guard let url = applicationURL(for: source) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 64, height: 64)
        resolvedIcons[source.kind] = icon
        return icon
    }

    @discardableResult
    static func activate(_ source: SystemNotificationSourcePresentation) -> Bool {
        guard let url = applicationURL(for: source) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return true
    }
}

struct SystemNotificationSourceGlyph: View {
    var source: SystemNotificationSourcePresentation
    var size: CGFloat

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var accent: Color {
        Color(nsColor: NotchShotColorPolicy.readableAccentOnBlack(
            NSColor(hex: source.accentHex) ?? .systemPurple
        ))
    }

    var body: some View {
        Group {
            if let icon = SystemNotificationSourceCatalog.icon(for: source) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: reduceTransparency
                                ? [accent.opacity(0.30), accent.opacity(0.30)]
                                : [accent.opacity(0.34), accent.opacity(0.15)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay {
                        Image(systemName: source.symbolName)
                            .font(.system(size: size * 0.46, weight: .semibold))
                            .foregroundStyle(accent)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                            .stroke(accent.opacity(0.34), lineWidth: NotchIsland.Stroke.hairline)
                    }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
