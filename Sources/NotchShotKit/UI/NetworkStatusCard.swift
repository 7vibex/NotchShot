import AppKit
import SwiftUI

/// The connectivity card: a statement of fact plus the one handoff that can
/// act on it.
///
/// Losing the connection gets a headline, what to do about it, and a neutral
/// dismiss beside the one call to action. Regaining it gets a single quiet
/// row, because there is nothing left for the user to decide.
struct NetworkStatusCard: View {
    let snapshot: ContextSnapshot
    var onDismiss: () -> Void
    var onOpenNetworkSettings: () -> Void

    static let buttonHeight: CGFloat = 32

    private var isOffline: Bool { NetworkContextPolicy.isOfflineAlert(snapshot) }

    private var accent: Color {
        Color(nsColor: NotchShotColorPolicy.readableAccentOnBlack(
            NSColor(hex: snapshot.accentHex) ?? .systemGreen
        ))
    }

    var body: some View {
        Group {
            if isOffline { offlineAlert } else { restoredRow }
        }
        .padding(.horizontal, NotchAlertStyle.horizontalInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(snapshot.title)
        .accessibilityValue(snapshot.subtitle ?? "")
    }

    private var offlineAlert: some View {
        VStack(alignment: .leading, spacing: NotchIsland.Spacing.group) {
            NotchAlertRow(title: snapshot.title, subtitle: snapshot.subtitle, subtitleLines: 2) {
                NotchAlertStyle.symbol("wifi.slash", color: accent, size: 24)
            }
            HStack(spacing: NotchIsland.Spacing.element) {
                NotchAlertTextButton(
                    title: "OK",
                    height: Self.buttonHeight,
                    expands: true,
                    help: "Dismiss this alert",
                    action: onDismiss
                )
                NotchAlertTextButton(
                    title: "Network Settings",
                    prominent: true,
                    height: Self.buttonHeight,
                    expands: true,
                    help: "Open Network Settings",
                    action: onOpenNetworkSettings
                )
            }
        }
        .padding(.vertical, NotchIsland.Spacing.group)
    }

    private var restoredRow: some View {
        NotchAlertRow(title: snapshot.title, subtitle: snapshot.subtitle) {
            // Back on Wi-Fi gets the joining sweep; other links just say so.
            if snapshot.metric == NetworkLinkKind.wifi.displayName {
                WiFiJoinGlyph(size: 22, tint: accent)
                    .frame(width: 26)
            } else {
                NotchAlertStyle.symbol(snapshot.metric == NetworkLinkKind.wired.displayName ? "cable.connector" : "wifi", color: accent, size: 24)
            }
        }
    }
}
