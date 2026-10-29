import CoreGraphics

/// The pages of the open notch, as a small tab pill hanging below it — the
/// way the phone's island offers its own surfaces. A tab only names a page
/// the notch can already show; switching never invents a new state.
public enum NotchTab: String, CaseIterable, Sendable {
    case capture
    case shelf
    case nowPlaying
    case agents
    case clipboard

    public var title: String {
        switch self {
        case .capture: "Capture"
        case .shelf: "Shelf"
        case .nowPlaying: "Now Playing"
        case .agents: "AI Agents"
        case .clipboard: "Clipboard"
        }
    }

    public var symbolName: String {
        switch self {
        case .capture: "camera.viewfinder"
        case .shelf: "tray.full"
        case .nowPlaying: "music.note"
        case .agents: "sparkles"
        case .clipboard: "doc.on.clipboard"
        }
    }

    /// Capture, Shelf and Now Playing always lead; the last slot is the
    /// user's choice, or absent.
    public static func visible(lastSlot: NotchTabLastSlot) -> [NotchTab] {
        [.capture, .shelf, .nowPlaying] + (lastSlot.tab.map { [$0] } ?? [])
    }

    /// The page an activity *is*, or nil when the pill should not show: a
    /// closed or compact notch, a modal capture step, a banner, a burst, or a
    /// page whose tab the user left out of the pill.
    public static func current(for activity: NotchActivity, in tabs: [NotchTab] = NotchTab.allCases) -> NotchTab? {
        let tab: NotchTab? = switch activity {
        case .expanded: .capture
        case .result: .shelf
        case .island(let descriptor) where descriptor.isExpanded && descriptor.primaryKind == .media:
            .nowPlaying
        case .island(let descriptor) where descriptor.isExpanded && descriptor.primaryKind == .ai:
            .agents
        default: nil
        }
        return tab.flatMap { tabs.contains($0) ? $0 : nil }
    }

    /// Whether `activity` is one of the pill's pages, the only presentations
    /// a page switch's held height applies to.
    public static func holdsHeight(of activity: NotchActivity, in tabs: [NotchTab]) -> Bool {
        current(for: activity, in: tabs) != nil
    }
}

/// What the pill's last slot holds. It used to be a fixed "More" that opened
/// the Productivity Center — the same window the capture page's own More menu
/// already opens — so the slot now goes to something the notch can't reach in
/// one click otherwise.
public enum NotchTabLastSlot: String, CaseIterable, Identifiable, Sendable {
    /// The expanded agents page: every Claude Code, Codex or Cursor session
    /// reporting in, with Approve and Deny when one is waiting.
    case agents
    /// The clipboard history panel.
    case clipboard
    /// Three tabs, no fourth.
    case none

    public var id: String { rawValue }

    public var tab: NotchTab? {
        switch self {
        case .agents: .agents
        case .clipboard: .clipboard
        case .none: nil
        }
    }

    public var title: String {
        switch self {
        case .agents: "AI Agents"
        case .clipboard: "Clipboard"
        case .none: "None"
        }
    }
}

/// Where the pill sits: centred under the island with a small gap, and only
/// when the fixed panel has room for it below the island.
public enum NotchTabBarGeometry {
    public static let height: CGFloat = 34
    public static let gap: CGFloat = 7
    static let buttonWidth: CGFloat = 43
    static let spacing: CGFloat = 2
    static let inset: CGFloat = 3

    /// Every button keeps the same width, so a three-tab pill is narrower
    /// rather than stretched; four tabs come to the original 184 pt.
    public static func size(tabCount: Int) -> CGSize {
        let count = CGFloat(max(1, tabCount))
        return CGSize(width: inset * 2 + count * buttonWidth + (count - 1) * spacing, height: height)
    }

    /// Offset of the pill's top edge from the top of the panel's island
    /// stack, or nil when it would not fit inside the panel.
    public static func topOffset(below layout: NotchLayout) -> CGFloat? {
        let top = layout.topInset + layout.size.height + gap
        let panelHeight = NotchLayout.maximumSize.height + NotchLayout.shadowPadding
        return top + height <= panelHeight ? top : nil
    }

    /// The pill in screen coordinates (AppKit, bottom-origin).
    public static func rect(below layout: NotchLayout, in metrics: NotchMetrics, tabCount: Int) -> CGRect? {
        guard let top = topOffset(below: layout) else { return nil }
        let size = size(tabCount: tabCount)
        return CGRect(
            x: metrics.notchCenterX - size.width / 2,
            y: metrics.screenFrame.maxY - top - size.height,
            width: size.width,
            height: size.height
        )
    }
}
