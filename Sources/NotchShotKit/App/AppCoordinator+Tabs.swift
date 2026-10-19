import Foundation

/// The tab pill under the open notch. Each tab drives a page the notch could
/// already reach — the capture menu, the shelf, the expanded player, the
/// agents page — so the pill adds a path, not a state.
extension AppCoordinator {
    static let nowPlayingActivityID = IslandActivityID(kind: .media, key: "now-playing")
    static let agentsActivityID = IslandActivityID(kind: .ai, key: "agents")

    public func isTabAvailable(_ tab: NotchTab) -> Bool {
        switch tab {
        // The clipboard panel explains itself when history is off, so the
        // tab never needs to be greyed out.
        case .capture, .clipboard: true
        case .shelf: canShowShelf
        case .nowPlaying:
            media.snapshot.hasContent && islandEngine.activities[Self.nowPlayingActivityID] != nil
        case .agents:
            islandEngine.activities[Self.agentsActivityID] != nil
        }
    }

    /// Why a tab is greyed out, for its tooltip.
    public func unavailableTabHint(_ tab: NotchTab) -> String {
        switch tab {
        case .shelf: "Shelf — nothing here yet"
        case .nowPlaying: "Now Playing — nothing is playing"
        case .agents: "AI Agents — no Claude Code, Codex or Cursor session is reporting"
        case .capture, .clipboard: tab.title
        }
    }

    public func showTab(_ tab: NotchTab) {
        guard isTabAvailable(tab) else { return }
        switch tab {
        case .capture:
            leaveCurrentTab()
            arbiter.userExpanded = true
            refreshActivity()
            windowController?.focusActivePanel()
        case .shelf:
            leaveCurrentTab()
            showShelf()
        case .nowPlaying:
            leaveCurrentTab()
            selectIslandActivity(Self.nowPlayingActivityID, expand: true)
        case .agents:
            leaveCurrentTab()
            selectIslandActivity(Self.agentsActivityID, expand: true)
        case .clipboard:
            openClipboard()
        }
        IslandHaptics.perform(.islandOpened)
    }

    /// Steps out of whichever page is showing without discarding anything:
    /// the shelf keeps its captures, the island keeps its activities.
    private func leaveCurrentTab() {
        arbiter.userExpanded = false
        if arbiter.hasResult {
            arbiter.hasResult = false
            shelfTimer?.invalidate()
        }
        islandCollapseTask?.cancel()
        islandEngine.collapse()
        setPeeking(false)
    }
}
