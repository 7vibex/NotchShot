import CoreGraphics

/// Responsive placement for the opted-in Now Playing card on loginwindow.
public enum LockedCardGeometry {
    /// Matches the compact player shown in the product reference while still
    /// fitting immediately above the avatar and password field.
    public static let preferredCardSize = CGSize(width: 360, height: 172)
    /// Slack around the card for its border and shadow.
    public static let padding: CGFloat = 30
    /// AppKit is bottom-origin. At 0.27 the visual bottom of this compact card
    /// sits just above loginwindow's avatar/password group, with no empty space
    /// reserved for activity cards that are not present.
    public static let verticalCenterFraction: CGFloat = 0.27

    public static func cardSize(in screenFrame: CGRect) -> CGSize {
        let availableWidth = max(0, screenFrame.width - padding * 2)
        let availableHeight = max(0, screenFrame.height - padding * 2)
        let scale = min(1, availableWidth / preferredCardSize.width, availableHeight / preferredCardSize.height)
        return CGSize(width: preferredCardSize.width * scale, height: preferredCardSize.height * scale)
    }

    /// The panel frame — card plus shadow slack — for a given display.
    public static func panelFrame(in screenFrame: CGRect) -> CGRect {
        let card = cardSize(in: screenFrame)
        let width = min(card.width + padding * 2, screenFrame.width)
        let height = min(card.height + padding * 2, screenFrame.height)
        let desiredCenterY = screenFrame.minY
            + screenFrame.height * verticalCenterFraction
        let unclampedY = desiredCenterY - height / 2
        let y = min(
            max(unclampedY, screenFrame.minY),
            screenFrame.maxY - height
        )
        return CGRect(
            x: screenFrame.midX - width / 2,
            y: y,
            width: width,
            height: height
        )
    }
}
