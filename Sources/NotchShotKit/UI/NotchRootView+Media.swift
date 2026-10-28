import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A flat transport glyph. The reference player draws its controls straight on
/// the island rather than inside a capsule, so the surface only appears under
/// the pointer or while the control's own panel is open.
struct MediaControlButton: View {
    var systemName: String
    var label: String
    var diameter: CGFloat
    var symbolSize: CGFloat
    var opacity: Double = NotchIsland.Ink.primary
    var isSelected = false
    var accessibilityValue: String?
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private var backgroundOpacity: Double {
        if isSelected { return NotchIsland.Ink.hairline }
        return isHovered && isEnabled ? NotchIsland.Ink.fill : 0
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: symbolSize, weight: .semibold))
                .foregroundStyle(Color.islandInk(opacity))
                .contentTransition(.symbolEffect(.replace))
                .animation(NotchShotMotion.selection(reduceMotion: reduceMotion), value: systemName)
                .frame(width: diameter, height: diameter)
                .background {
                    Circle().fill(Color.islandInk(backgroundOpacity))
                }
                .frame(
                    width: max(diameter, NotchIsland.Hit.control),
                    height: max(diameter, NotchIsland.Hit.control)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressButtonStyle())
        // Plain buttons get no disabled appearance from AppKit, so an
        // unavailable command would look identical to an available one.
        .opacity(isEnabled ? 1 : NotchIconButton.disabledOpacity)
        .scaleEffect(NotchShotMotion.activeScale(
            isActive: isHovered && isEnabled,
            reduceMotion: reduceMotion,
            activeScale: 1.06
        ))
        .onHover { isHovered = $0 }
        .animation(NotchShotMotion.interaction(reduceMotion: reduceMotion), value: isHovered)
        .help(isEnabled ? label : "\(label) unavailable")
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue ?? "")
    }
}

/// The small capitalised marker Apple Music puts beside a track name.
struct MediaTitleBadge: View {
    var letter: String
    var label: String

    var body: some View {
        Text(letter)
            .font(.system(size: 8, weight: .heavy, design: .rounded))
            .foregroundStyle(.black)
            .frame(width: 13, height: 13)
            .background(Color.islandInk(NotchIsland.Ink.secondary), in: RoundedRectangle(
                cornerRadius: 3,
                style: .continuous
            ))
            .accessibilityLabel(label)
    }
}

/// One upcoming track. There is deliberately no artwork: fetching cover art per
/// queued track costs one Apple Event apiece for rows the user is only
/// glancing at, and the position number carries the ordering just as well.
struct MediaQueueRow: View {
    var entry: MediaQueueEntry
    var position: Int

    var body: some View {
        HStack(spacing: NotchIsland.Spacing.row) {
            Text("\(position)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                .frame(width: 22, height: 22)
                .background(Color.islandInk(NotchIsland.Ink.fill), in: RoundedRectangle(
                    cornerRadius: NotchIsland.Radius.control - 4,
                    style: .continuous
                ))

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if !entry.artist.isEmpty {
                    Text(entry.artist)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: NotchIsland.Spacing.element)
        }
        .padding(.horizontal, NotchIsland.Spacing.row)
        .frame(maxWidth: .infinity, minHeight: NotchLayout.mediaPanelRowHeight)
        .background {
            RoundedRectangle(cornerRadius: NotchIsland.Radius.control, style: .continuous)
                .fill(Color.islandInk(NotchIsland.Ink.fill))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(position). \(entry.title)\(entry.artist.isEmpty ? "" : ", \(entry.artist)")")
    }
}

struct MediaContent: View {
    @Bindable var coordinator: AppCoordinator
    var isPeeking: Bool
    /// True on a display with no hardware cutout, where the island is a drawn
    /// pill and its curved ends have to be cleared by hand.
    var isFloating = false
    /// Inside the multi-activity island the artwork is a shared element: the
    /// header reserves its frame and the island draws the one artwork view
    /// that travels between compact, expanded, and satellite positions.
    var sharedArtworkID: IslandActivityID?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var audioOutputs: [AudioRouteReading] = []
    @State private var upcoming: [MediaQueueEntry] = []
    @State private var isLoadingQueue = false
    @State private var queueUnavailable = false
    @State private var modes: MediaPlaybackModes?
    @State private var currentAudioOutputID: UInt32?
    @State private var lyrics: LyricsPanelState = .idle

    private var snapshot: MediaSnapshot { coordinator.media.snapshot }

    var body: some View {
        Group {
            if isPeeking {
                expanded
            } else {
                compact
            }
        }
        .task(id: isPeeking) {
            guard isPeeking else { return }
            refreshAudioOutputs()
        }
    }

    /// The artwork tile is square and full-height-ish, so it meets the pill's
    /// curve where the curve is widest. The meter is three thin bars centred on
    /// the same line, so it needs a little more than the artwork to look level
    /// with it.
    private var compactLeadingInset: CGFloat {
        isFloating ? NotchIsland.Geometry.floatingContentInset : 6
    }

    private var compactTrailingInset: CGFloat {
        isFloating ? NotchIsland.Geometry.floatingContentInset + 2 : 8
    }

    private var compact: some View {
        Button {
            coordinator.setPeeking(true)
            coordinator.windowController?.focusActivePanel()
        } label: {
            HStack(spacing: 0) {
                artwork(size: 20)
                    .padding(.leading, compactLeadingInset)
                Spacer(minLength: 0)
                PlaybackIndicator(
                    isPlaying: snapshot.isPlaying,
                    accentColor: Color(nsColor: coordinator.media.artworkAccentColor),
                    animates: coordinator.media.areScreensAwake
                )
                .padding(.trailing, compactTrailingInset)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show now playing controls")
    }

    /// Reference-style stacked player: cover and titles, then the position bar
    /// with a time either side, then a transport bar that spans the island.
    ///
    /// The previous single row had to share its width between the track name
    /// and five controls, so the name had almost none of it and the buttons sat
    /// at half their comfortable size.
    private var expanded: some View {
        VStack(spacing: 0) {
            bandHeader
                .padding(.horizontal, -NotchIsland.Spacing.gutter)

            header
                .padding(.top, NotchIsland.Spacing.tight)

            MediaScrubber(
                snapshot: snapshot,
                ticks: coordinator.media.areScreensAwake
            ) { position in
                coordinator.media.send(.seek(position))
            }

            controlBar

            openPanel
        }
        .padding(.horizontal, NotchIsland.Spacing.gutter)
        .padding(.bottom, NotchIsland.Spacing.group)
        .animation(NotchShotMotion.content(reduceMotion: reduceMotion), value: coordinator.mediaPanel)
        // A track change while Playing Next is open would otherwise leave the
        // previous track's queue on screen.
        .task(id: queueRefreshKey) {
            guard coordinator.mediaPanel == .playingNext else { return }
            await refreshQueue()
        }
        .task(id: lyricsRefreshKey) {
            guard coordinator.mediaPanel == .lyrics else { return }
            await refreshLyrics()
        }
        // Re-read on every track change as well as on open: shuffle and repeat
        // can be changed in the player itself while this card is closed.
        .task(id: playbackModeRefreshKey) {
            await refreshPlaybackModes()
        }
    }

    private var header: some View {
        HStack(spacing: NotchIsland.Spacing.group) {
            Group {
                if let sharedArtworkID {
                    IslandGlyphSlot(id: sharedArtworkID, size: 56)
                } else {
                    artwork(size: 56)
                }
            }
            // In the island the cover is drawn in the shared layer above,
            // which draws its own sheen; this one serves the plain player.
            .overlay { ArtworkGlareSheen(cornerRadius: 56 / 5) }
            .overlay { ArtworkGlareTracker() }

            VStack(alignment: .leading, spacing: NotchIsland.Spacing.hairline) {
                HStack(spacing: NotchIsland.Spacing.snug) {
                    // Scrolls itself when the title is longer than the space, so
                    // a long track name is fully readable rather than truncated.
                    MarqueeText(
                        snapshot.title ?? "Not Playing",
                        font: .system(size: 15, weight: .bold),
                        color: .islandInk(NotchIsland.Ink.primary)
                    )
                    .frame(height: 19)

                    if snapshot.isExplicit {
                        MediaTitleBadge(letter: "E", label: "Explicit")
                    }
                    if snapshot.isLossless {
                        MediaTitleBadge(letter: "L", label: "Lossless")
                    }
                }
                .frame(height: 19)

                MarqueeText(
                    snapshot.artist ?? snapshot.applicationName ?? "",
                    font: .system(size: 12, weight: .medium),
                    color: .islandInk(NotchIsland.Ink.secondary),
                    speed: 22
                )
                .frame(height: 15)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 56)
    }

    /// Where the audio is coming from, left of the camera, and the live
    /// meter right of it: the band the camera sits in, which used to be an
    /// empty black strip above the cover.
    ///
    /// The capture button that sat beside the meter is gone; the Capture page
    /// is one click away in the pill under the island.
    private var bandHeader: some View {
        IslandBandHeader(leadingInset: 16, trailingInset: 18) {
            HStack(spacing: 6) {
                if let icon = coordinator.media.sourceApplicationIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 15, height: 15)
                        .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                        .accessibilityHidden(true)
                }
                Text(snapshot.applicationName ?? "Now Playing")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                    .lineLimit(1)
            }
        } trailing: {
            PlaybackIndicator(
                isPlaying: snapshot.isPlaying,
                accentColor: Color(nsColor: coordinator.media.artworkAccentColor),
                animates: coordinator.media.areScreensAwake,
                scale: 1.3
            )
            .accessibilityLabel(snapshot.isPlaying ? "Playing" : "Paused")
        }
    }

    /// Transport centred on the card, between the modes and the panel
    /// openers.
    private var controlBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: NotchIsland.Spacing.snug) {
                if supportsQueue {
                    MediaControlButton(
                        systemName: "list.bullet",
                        label: "Playing next",
                        diameter: 30,
                        symbolSize: 14,
                        opacity: coordinator.mediaPanel == .playingNext
                            ? NotchIsland.Ink.primary
                            : NotchIsland.Ink.tertiary,
                        isSelected: coordinator.mediaPanel == .playingNext,
                        action: toggleQueueList
                    )
                }

                if ExtrasPreferences.shared.songRecognitionEnabled {
                    MediaControlButton(
                        systemName: "shazam.logo",
                        label: SongRecognizer.shared.isListening ? "Stop listening" : "What's this song?",
                        diameter: 30,
                        symbolSize: 14,
                        opacity: SongRecognizer.shared.isListening
                            ? NotchIsland.Ink.primary
                            : NotchIsland.Ink.tertiary,
                        isSelected: SongRecognizer.shared.isListening
                    ) {
                        SongRecognizer.shared.toggle()
                    }
                }

                if supportsPlaybackModes {
                    MediaControlButton(
                        systemName: "shuffle",
                        label: "Shuffle",
                        diameter: 30,
                        symbolSize: 14,
                        opacity: modes?.isShuffling == true
                            ? NotchIsland.Ink.primary
                            : NotchIsland.Ink.tertiary,
                        isSelected: modes?.isShuffling == true,
                        accessibilityValue: modes?.isShuffling == true ? "On" : "Off",
                        action: toggleShuffle
                    )
                }
            }
            // Both sides take equal flexible columns, so play sits on the
            // card's centre line whatever each side carries. Spacers either
            // side of the trio put it about 20 pt left of centre, because the
            // right side has one more control than the left.
            .frame(maxWidth: .infinity, alignment: .leading)

            transportControls
                .fixedSize()

            HStack(spacing: NotchIsland.Spacing.snug) {
                if Preferences.shared.lyricsEnabled {
                    MediaControlButton(
                        systemName: "quote.bubble",
                        label: "Lyrics",
                        diameter: 30,
                        symbolSize: 14,
                        opacity: coordinator.mediaPanel == .lyrics
                            ? NotchIsland.Ink.primary
                            : NotchIsland.Ink.tertiary,
                        isSelected: coordinator.mediaPanel == .lyrics,
                        action: toggleLyrics
                    )
                }

                if supportsPlaybackModes {
                    MediaControlButton(
                        systemName: repeatMode.symbolName,
                        label: "Repeat",
                        diameter: 30,
                        symbolSize: 14,
                        opacity: repeatMode.isOn
                            ? NotchIsland.Ink.primary
                            : NotchIsland.Ink.tertiary,
                        isSelected: repeatMode.isOn,
                        accessibilityValue: repeatMode.accessibilityDescription,
                        action: cycleRepeat
                    )
                }

                MediaControlButton(
                    systemName: currentAudioOutput?.selectorSymbolName ?? "airplayaudio",
                    label: "Audio output",
                    diameter: 30,
                    symbolSize: 14,
                    opacity: coordinator.mediaPanel == .audioRoutes
                        ? NotchIsland.Ink.primary
                        : NotchIsland.Ink.tertiary,
                    isSelected: coordinator.mediaPanel == .audioRoutes,
                    accessibilityValue: currentAudioOutputName,
                    action: toggleRouteList
                )
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: 40)
        .accessibilityElement(children: .contain)
    }

    private var transportControls: some View {
        HStack(spacing: NotchIsland.Spacing.snug) {
            MediaControlButton(
                systemName: "backward.fill",
                label: "Previous track",
                diameter: 34,
                symbolSize: 16
            ) {
                coordinator.media.send(.previousTrack)
            }
            .disabled(!coordinator.media.supports(.previousTrack))

            MediaControlButton(
                systemName: snapshot.isPlaying ? "pause.fill" : "play.fill",
                label: snapshot.isPlaying ? "Pause" : "Play",
                diameter: 40,
                symbolSize: 22
            ) {
                coordinator.media.send(.togglePlayPause)
            }
            .disabled(!coordinator.media.supports(.togglePlayPause))

            MediaControlButton(
                systemName: "forward.fill",
                label: "Next track",
                diameter: 34,
                symbolSize: 16
            ) {
                coordinator.media.send(.nextTrack)
            }
            .disabled(!coordinator.media.supports(.nextTrack))
        }
    }

    private var supportsPlaybackModes: Bool {
        MediaPlaybackModeService.supportsModes(bundleID: snapshot.applicationBundleID)
    }

    private var repeatMode: MediaRepeatMode { modes?.repeatMode ?? .off }

    /// Read from the player rather than remembered here: the user can hit
    /// shuffle in Spotify itself, and a shadow copy would then disagree with
    /// the button they are looking at.
    private func refreshPlaybackModes() async {
        guard supportsPlaybackModes else {
            modes = nil
            return
        }
        modes = await MediaPlaybackModeService.shared.modes(
            for: snapshot.applicationBundleID
        )
    }

    private func toggleShuffle() {
        let enabled = !(modes?.isShuffling ?? false)
        // Optimistic, then corrected by whatever the player confirms — the
        // Apple Event round trip is slow enough to feel like a dead button.
        modes = MediaPlaybackModes(isShuffling: enabled, repeatMode: repeatMode)
        Task {
            let confirmed = await MediaPlaybackModeService.shared.setShuffle(
                enabled,
                for: snapshot.applicationBundleID
            )
            if let confirmed { modes = confirmed }
        }
    }

    private func cycleRepeat() {
        let current = repeatMode
        let optimistic = MediaPlaybackModeService.next(
            after: current,
            supportsSingleTrack: snapshot.applicationBundleID == "com.apple.Music"
        )
        modes = MediaPlaybackModes(
            isShuffling: modes?.isShuffling ?? false,
            repeatMode: optimistic
        )
        Task {
            let confirmed = await MediaPlaybackModeService.shared.cycleRepeat(
                from: current,
                for: snapshot.applicationBundleID
            )
            if let confirmed { modes = confirmed }
        }
    }

    /// A list opens inside the island rather than in a popover: a popover is a
    /// second window with its own shadow and arrow, which reads as a menu
    /// escaping the notch instead of the player growing.
    @ViewBuilder
    private var openPanel: some View {
        switch coordinator.mediaPanel {
        case .none:
            EmptyView()
        case .audioRoutes:
            panel(title: "Audio Output", onRefresh: refreshAudioOutputs) {
                if audioOutputs.isEmpty && appVolumeSources.isEmpty {
                    emptyPanelRow("No audio outputs found")
                } else {
                    panelList(rowCount: audioOutputs.count + appVolumeSources.count) {
                        ForEach(audioOutputs) { output in
                            AudioOutputDeviceRow(
                                output: output,
                                isSelected: output.deviceID == currentAudioOutputID,
                                action: { selectAudioOutput(output) }
                            )
                        }
                        // Per-app levels under the speakers they play to,
                        // as one list: the output and the mix are one choice.
                        ForEach(appVolumeSources) { source in
                            AppVolumeRow(source: source)
                                .padding(.horizontal, 8)
                        }
                    }
                }
            }
        case .lyrics:
            panel(
                title: "Lyrics",
                isRefreshing: lyrics.isLoading,
                onRefresh: { Task { await refreshLyrics(forceRefresh: true) } }
            ) {
                LyricsPanel(
                    state: lyrics,
                    snapshot: snapshot,
                    ticks: coordinator.media.areScreensAwake,
                    height: Self.panelListHeight(rowCount: Self.lyricsRows)
                ) { position in
                    coordinator.media.send(.seek(position))
                }
            }
        case .playingNext:
            panel(title: "Playing Next", onRefresh: { Task { await refreshQueue() } }) {
                if upcoming.isEmpty {
                    emptyPanelRow(queueEmptyMessage)
                } else {
                    panelList(rowCount: upcoming.count) {
                        ForEach(Array(upcoming.enumerated()), id: \.element.id) { index, entry in
                            MediaQueueRow(entry: entry, position: index + 1)
                        }
                    }
                }
            }
        }
    }

    private func panel<Content: View>(
        title: String,
        isRefreshing: Bool = false,
        onRefresh: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: NotchIsland.Spacing.tight) {
            HStack(spacing: NotchIsland.Spacing.element) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))

                Spacer(minLength: NotchIsland.Spacing.group)

                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NotchPressButtonStyle())
                .disabled(isRefreshing)
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                .help("Refresh \(title.lowercased())")
                .accessibilityLabel("Refresh \(title.lowercased())")
            }
            .frame(height: 18)

            content()
        }
        .padding(.top, NotchIsland.Spacing.element)
        .transition(.opacity)
        .accessibilityElement(children: .contain)
    }

    private func emptyPanelRow(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: NotchLayout.mediaPanelRowHeight)
    }

    private func panelList<Content: View>(
        rowCount: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: NotchLayout.mediaPanelRowSpacing) {
                content()
            }
        }
        .scrollIndicators(
            rowCount > NotchLayout.mediaPanelVisibleRowLimit ? .visible : .hidden
        )
        .frame(height: Self.panelListHeight(rowCount: rowCount))
    }

    private static func panelListHeight(rowCount: Int) -> CGFloat {
        let rows = min(max(rowCount, 1), NotchLayout.mediaPanelVisibleRowLimit)
        return CGFloat(rows) * NotchLayout.mediaPanelRowHeight
            + CGFloat(rows - 1) * NotchLayout.mediaPanelRowSpacing
    }

    private struct QueueRefreshKey: Equatable {
        var isPresented: Bool
        var player: String
        var title: String
        var artist: String
    }

    /// Separate fields avoid collisions when a track name contains a separator.
    private var queueRefreshKey: QueueRefreshKey {
        QueueRefreshKey(
            isPresented: coordinator.mediaPanel == .playingNext,
            player: snapshot.applicationBundleID ?? "",
            title: snapshot.title ?? "",
            artist: snapshot.artist ?? ""
        )
    }

    /// Lyrics fill the tallest panel the island allows, so a few lines of
    /// context show either side of the one being sung.
    private static let lyricsRows = NotchLayout.mediaPanelVisibleRowLimit

    private struct LyricsRefreshKey: Equatable {
        var isPresented: Bool
        var isEnabled: Bool
        var query: LyricsQuery?
    }

    private var lyricsRefreshKey: LyricsRefreshKey {
        LyricsRefreshKey(
            isPresented: coordinator.mediaPanel == .lyrics,
            isEnabled: Preferences.shared.lyricsEnabled,
            query: LyricsQuery(snapshot: snapshot)
        )
    }

    private func toggleLyrics() {
        guard coordinator.mediaPanel != .lyrics else {
            coordinator.setMediaPanel(.none)
            return
        }
        coordinator.setMediaPanel(.lyrics, rowCount: Self.lyricsRows)
        coordinator.windowController?.focusActivePanel()
        // The keyed task fetches once the panel is open.
    }

    private func refreshLyrics(forceRefresh: Bool = false) async {
        guard Preferences.shared.lyricsEnabled, let query = LyricsQuery(snapshot: snapshot) else {
            lyrics = .unavailable(LyricsPanelState.noTrackMessage)
            return
        }
        lyrics = .loading(query)
        let result = await LyricsService.shared.lyrics(for: query, forceRefresh: forceRefresh)
        // A shared lookup can finish after this panel task was cancelled.
        // Apply the same live-query gate to failures and successes.
        guard !Task.isCancelled,
              Preferences.shared.lyricsEnabled,
              coordinator.mediaPanel == .lyrics,
              LyricsQuery(snapshot: snapshot) == query else { return }
        switch result {
        case .success(let found):
            lyrics = .loaded(query, found)
        case .failure(.notFound):
            lyrics = .unavailable(LyricsPanelState.notFoundMessage, query)
        case .failure(.unavailable):
            lyrics = .unavailable(LyricsPanelState.offlineMessage, query)
        }
    }

    private var playbackModeRefreshKey: String {
        "\(isPeeking)—\(snapshot.applicationBundleID ?? "")—\(snapshot.title ?? "")"
    }

    private var supportsQueue: Bool {
        MediaQueueService.supportsQueue(bundleID: snapshot.applicationBundleID)
    }

    private func toggleRouteList() {
        guard coordinator.mediaPanel != .audioRoutes else {
            coordinator.setMediaPanel(.none)
            return
        }
        refreshAudioOutputs()
        coordinator.setMediaPanel(.audioRoutes, rowCount: max(1, audioOutputs.count + appVolumeSources.count))
        coordinator.windowController?.focusActivePanel()
    }

    private func toggleQueueList() {
        guard coordinator.mediaPanel != .playingNext else {
            coordinator.setMediaPanel(.none)
            return
        }
        // Opened at one row so the island has somewhere to put the progress
        // line while Apple Events answers, then resized once the rows arrive.
        coordinator.setMediaPanel(.playingNext, rowCount: max(1, upcoming.count))
        coordinator.windowController?.focusActivePanel()
        // The refresh itself is left to the keyed task below, which already
        // reacts to the panel opening — asking here as well would send two
        // Apple Events for one click.
    }

    /// Apple Events are synchronous on the player's side and can take most of
    /// their two-second timeout, so this only runs when the panel is open —
    /// never on the playback tick.
    private func refreshQueue() async {
        let key = queueRefreshKey
        guard supportsQueue else {
            upcoming = []
            queueUnavailable = true
            isLoadingQueue = false
            return
        }
        isLoadingQueue = upcoming.isEmpty
        let entries = await MediaQueueService.shared.upcoming(
            for: snapshot.applicationBundleID
        )
        guard !Task.isCancelled, coordinator.mediaPanel == .playingNext, queueRefreshKey == key else { return }
        isLoadingQueue = false
        queueUnavailable = entries == nil
        upcoming = entries ?? []
        if coordinator.mediaPanel == .playingNext {
            coordinator.setMediaPanel(.playingNext, rowCount: max(1, upcoming.count))
        }
    }

    /// "Nothing queued" would be a lie when the real answer is that Music never
    /// replied — most often because Automation is still denied.
    private var queueEmptyMessage: String {
        if isLoadingQueue { return "Reading the queue…" }
        if queueUnavailable { return "Music didn't answer — check Automation access" }
        return "Nothing queued after this track"
    }

    private var currentAudioOutput: AudioRouteReading? {
        audioOutputs.first(where: { $0.deviceID == currentAudioOutputID })
    }

    private var currentAudioOutputName: String {
        currentAudioOutput?.name ?? "Audio Output"
    }

    private func refreshAudioOutputs() {
        audioOutputs = AudioOutputDeviceService.availableOutputs()
        currentAudioOutputID = AudioOutputDeviceService.currentOutput()?.deviceID
        AppVolumeMixer.shared.refreshSources()
        if coordinator.mediaPanel == .audioRoutes {
            coordinator.setMediaPanel(.audioRoutes, rowCount: max(1, audioOutputs.count + appVolumeSources.count))
        }
    }

    /// Empty unless per-app volume is on.
    private var appVolumeSources: [AppVolumeSource] {
        ExtrasPreferences.shared.appVolumesEnabled ? AppVolumeMixer.shared.sources : []
    }

    private func selectAudioOutput(_ output: AudioRouteReading) {
        guard output.deviceID != currentAudioOutputID else {
            coordinator.setMediaPanel(.none)
            return
        }
        do {
            try AudioOutputDeviceService.select(output.deviceID)
            refreshAudioOutputs()
            coordinator.setMediaPanel(.none)
        } catch {
            coordinator.present(error: error)
        }
    }

    /// Cover art, with the owning app's own icon badged into the corner so the
    /// player says where the audio is coming from without a second text line.
    /// The icon is read from the copy installed on this Mac; none is bundled.
    @ViewBuilder
    private func artwork(size: CGFloat) -> some View {
        Group {
            if let image = coordinator.media.artwork {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: size / 5)
                    .fill(Color.islandInk(NotchIsland.Ink.fill))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: size / 2.4))
                            .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 5, style: .continuous))
        .artworkPresence(
            isPlaying: snapshot.isPlaying,
            accent: Color(nsColor: coordinator.media.artworkAccentColor),
            cornerRadius: size / 5,
            glows: size >= 40
        )
        .overlay(alignment: .bottomTrailing) {
            if size >= 40, let icon = coordinator.media.sourceApplicationIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: size / 3, height: size / 3)
                    .clipShape(RoundedRectangle(cornerRadius: size / 12, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                    .offset(x: size / 12, y: size / 12)
            }
        }
        // The cover used to breathe, tilt and pulse an accent glow on a
        // 2.8 s loop. Rotating a small raster by a fraction of a degree
        // resamples it every frame, which is what made the cover look soft
        // and shimmer; the animated shadow radius re-blurred it every frame
        // on top. The cover now holds still, as the system player's does.
        .accessibilityHidden(true)
    }
}

private struct AudioOutputDeviceRow: View {
    var output: AudioRouteReading
    var isSelected: Bool
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            // Control Center's own sound list: a glyph, the device name, and a
            // radio dot at the trailing edge. Rows carry no card of their own —
            // only the selected or hovered row is tinted — so four devices read
            // as one list instead of four stacked tiles.
            HStack(spacing: NotchIsland.Spacing.row) {
                Image(systemName: output.selectorSymbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.islandInk(
                        isSelected ? NotchIsland.Ink.primary : NotchIsland.Ink.secondary
                    ))
                    .frame(width: 22, height: 22)

                Text(output.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.islandInk(
                        isSelected ? NotchIsland.Ink.primary : NotchIsland.Ink.secondary
                    ))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: NotchIsland.Spacing.element)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle.fill")
                    .font(.system(size: isSelected ? 13 : 11, weight: .semibold))
                    .foregroundStyle(Color.islandInk(
                        isSelected ? NotchIsland.Ink.primary : NotchIsland.Ink.recessed
                    ))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, NotchIsland.Spacing.element)
            .frame(maxWidth: .infinity, minHeight: NotchLayout.mediaPanelRowHeight)
            .background {
                RoundedRectangle(cornerRadius: NotchIsland.Radius.control, style: .continuous)
                    .fill(Color.islandInk(
                        isSelected
                            ? NotchIsland.Ink.hairline
                            : (isHovered ? NotchIsland.Ink.fill : 0)
                    ))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressButtonStyle())
        .scaleEffect(NotchShotMotion.activeScale(
            isActive: isHovered,
            reduceMotion: reduceMotion,
            activeScale: 1.012
        ))
        .onHover { isHovered = $0 }
        .animation(NotchShotMotion.interaction(reduceMotion: reduceMotion), value: isHovered)
        .accessibilityLabel(output.name)
        .accessibilityValue(isSelected ? "Selected" : "Available")
    }
}

/// Position bar with elapsed and total time, draggable to seek.
///
/// This replaced a plain `ProgressView`, which showed no times and could not be
/// dragged — the bar moved and that was all it did.
private struct MediaScrubber: View {
    var snapshot: MediaSnapshot
    /// False while the screens sleep, which stops the tick.
    var ticks: Bool
    var onSeek: (TimeInterval) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Advances once a second so the elapsed time moves between source polls.
    /// Owned here rather than by the player: held one level up, every tick
    /// re-evaluated the whole expanded card — header, marquees, controls —
    /// to move one bar.
    @State private var now = Date()
    /// Where the user just dragged to, and when. Held briefly after release —
    /// see `displayedFraction`.
    @State private var pending: (fraction: Double, at: Date)?
    @State private var isDragging = false

    /// While playing, the bar glides continuously instead of stepping once a
    /// second. The glide is a layer animation (see `MediaPlaybackFill`); the
    /// view itself still updates only once a second, for the time labels.
    private var glides: Bool {
        snapshot.isPlaying && ticks && !reduceMotion && !isDragging && pending == nil && duration != nil
    }

    private static let tick: TimeInterval = 1

    private var duration: TimeInterval? {
        guard let duration = snapshot.duration, duration > 0, duration.isFinite else { return nil }
        return duration
    }

    private var canSeek: Bool {
        duration != nil && snapshot.supportedCommands.contains(.seek)
    }

    var body: some View {
        HStack(spacing: NotchIsland.Spacing.row) {
            timeLabel(elapsed, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.islandInk(NotchIsland.Ink.recessed))
                        .frame(height: isDragging ? 7 : 5)
                        .animation(NotchMotion.hover(reduceMotion: reduceMotion), value: isDragging)
                    MediaPlaybackFill(
                        fraction: displayedFraction,
                        anchor: now,
                        velocity: glides ? 1 / (duration ?? 1) : 0,
                        barHeight: isDragging ? 7 : 5,
                        knobDiameter: canSeek ? (isDragging ? 12 : 9) : 0,
                        fillOpacity: canSeek ? 0.95 : 0.6
                    )
                }
                // The bar is 3pt tall but the whole row is grabbable, or seeking
                // would demand pixel-accurate aim at a hairline.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(seekGesture(width: geometry.size.width))
            }
            .frame(height: 22)

            // The reference player counts down rather than showing the track
            // length, which is the number you actually want mid-listen: how
            // much of this track is left.
            timeLabel(remaining, alignment: .trailing, isCountdown: duration != nil)
        }
        // Only while something is playing, so a paused notch stops waking
        // the CPU once a second.
        .task(id: snapshot.isPlaying && ticks) {
            now = Date()
            guard snapshot.isPlaying, ticks else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.tick))
                guard !Task.isCancelled else { return }
                now = Date()
                // Hand the bar back to the player once it has caught up with
                // the seek (or given up on it), so gliding resumes.
                if !isDragging, pending != nil, displayedFraction != pending?.fraction {
                    pending = nil
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(canSeek ? "Adjust up or down to seek" : "Seeking is unavailable")
        .accessibilityRespondsToUserInteraction(canSeek)
        .accessibilityAdjustableAction { direction in
            guard canSeek, let duration else { return }
            let step = max(5, duration * 0.05)
            let target = min(max((elapsed ?? 0) + (direction == .increment ? step : -step), 0), duration)
            pending = (target / duration, Date())
            onSeek(target)
        }
    }

    @ViewBuilder
    private func timeLabel(
        _ time: TimeInterval?,
        alignment: Alignment,
        isCountdown: Bool = false
    ) -> some View {
        Text(isCountdown ? "-\(Self.formatted(time))" : Self.formatted(time))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
            .monospacedDigit()
            // Hour-long media needs more than the old fixed 32pt slot. A
            // minimum preserves alignment for short tracks without clipping.
            .frame(minWidth: 32, alignment: alignment)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func seekGesture(width: CGFloat) -> some Gesture {
        // `minimumDistance: 0` so a plain tap jumps to that point, as it does in
        // every other player.
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard canSeek, width > 0 else { return }
                isDragging = true
                pending = (Self.clamped(value.location.x / width), Date())
            }
            .onEnded { value in
                isDragging = false
                guard canSeek, width > 0, let duration else { return }
                let fraction = Self.clamped(value.location.x / width)
                pending = (fraction, Date())
                onSeek(fraction * duration)
            }
    }

    /// The fraction to draw: the dragged one until the player confirms it.
    ///
    /// The Apple Events source only polls every couple of seconds, so clearing
    /// the dragged value on release makes the bar snap back to where the track
    /// was and then jump forward — it reads as the seek having failed.
    private var displayedFraction: Double {
        guard let pending, let duration else { return fraction(at: now) }
        let target = pending.fraction * duration
        if let position = snapshot.interpolatedPosition(at: now), abs(position - target) < 1.5 {
            return fraction(at: now)
        }
        // Give up waiting rather than showing a stale position forever if the
        // player ignored the seek.
        if Date().timeIntervalSince(pending.at) > 3 { return fraction(at: now) }
        return pending.fraction
    }

    private func fraction(at date: Date) -> Double {
        guard let duration, let position = snapshot.interpolatedPosition(at: date) else { return 0 }
        return Self.clamped(position / duration)
    }

    private var elapsed: TimeInterval? {
        if let duration { return displayedFraction * duration }
        // No duration — a live stream, or a player that does not report one.
        // The elapsed time is still worth showing.
        return snapshot.interpolatedPosition(at: now)
    }

    /// Time left in the track, or nil when the source reports no duration.
    private var remaining: TimeInterval? {
        guard let duration, let elapsed else { return nil }
        return max(0, duration - elapsed)
    }

    private var accessibilityValue: String {
        guard let duration else { return Self.formatted(elapsed) }
        return "\(Self.formatted(elapsed)) of \(Self.formatted(duration)), \(Self.formatted(remaining)) remaining"
    }

    private static func clamped(_ fraction: Double) -> Double {
        min(max(fraction, 0), 1)
    }

    static func formatted(_ time: TimeInterval?) -> String {
        MediaTimePolicy.formatted(time)
    }
}

/// The played part of the scrubber and its knob, as layers.
///
/// While playing, the fill glides to the end of the track in one linear layer
/// animation, which the render server runs. It used to be a SwiftUI
/// `.linear(1s)` animation restarted every second, so SwiftUI was mid-
/// animation on every frame the expanded player was open and redrew the notch
/// at the display's full rate to move one bar. The animation restarts only
/// when the position stops matching it: a seek, a pause, a correction from
/// the player, or a resize.
private struct MediaPlaybackFill: NSViewRepresentable {
    /// The fraction played at `anchor`.
    var fraction: Double
    var anchor: Date
    /// Fraction per second; zero holds the bar still.
    var velocity: Double
    var barHeight: CGFloat
    /// Zero draws no knob.
    var knobDiameter: CGFloat
    var fillOpacity: Double

    func makeNSView(context: Context) -> MediaPlaybackFillView {
        MediaPlaybackFillView()
    }

    func updateNSView(_ view: MediaPlaybackFillView, context: Context) {
        let elapsed = max(0, Date().timeIntervalSince(anchor))
        view.configure(
            fraction: min(max(fraction + velocity * elapsed, 0), 1),
            velocity: velocity,
            barHeight: barHeight,
            knobDiameter: knobDiameter,
            fillOpacity: fillOpacity
        )
    }
}

private final class MediaPlaybackFillView: NSView {
    private let fill = CALayer()
    private let knob = CALayer()
    /// The fraction at `origin`, in media time, and how fast it grows.
    private var origin: CFTimeInterval = 0
    private var originFraction: Double = 0
    private var velocity: Double = 0
    private var barHeight: CGFloat = 5
    private var knobDiameter: CGFloat = 0
    private var laidOutWidth: CGFloat = -1

    init() {
        super.init(frame: .zero)
        let host = CALayer()
        layer = host
        wantsLayer = true
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        host.addSublayer(fill)
        host.addSublayer(knob)
        knob.backgroundColor = NSColor.white.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Clicks belong to the scrubber's drag gesture underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func currentFraction(at time: CFTimeInterval = CACurrentMediaTime()) -> Double {
        min(max(originFraction + velocity * (time - origin), 0), 1)
    }

    func configure(fraction: Double, velocity: Double, barHeight: CGFloat, knobDiameter: CGFloat, fillOpacity: Double) {
        let reshapes = barHeight != self.barHeight || knobDiameter != self.knobDiameter
        fill.backgroundColor = NSColor.white.withAlphaComponent(fillOpacity).cgColor
        let width = max(bounds.width, 1)
        // Within half a point of where the running glide already is, and at
        // the same speed: leave it running.
        let drifted = abs(currentFraction() - fraction) * width > 0.5
        guard drifted || velocity != self.velocity || reshapes || laidOutWidth < 0 else { return }
        origin = CACurrentMediaTime()
        originFraction = fraction
        self.velocity = velocity
        self.barHeight = barHeight
        self.knobDiameter = knobDiameter
        // A drag grows the bar and knob with the track's own spring-free ease.
        restart(animatingShape: reshapes && laidOutWidth >= 0)
    }

    override func layout() {
        super.layout()
        guard abs(bounds.width - laidOutWidth) > 0.25 else { return }
        // Keep the position, re-aim the glide at the new width.
        originFraction = currentFraction()
        origin = CACurrentMediaTime()
        restart(animatingShape: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            originFraction = currentFraction()
            origin = CACurrentMediaTime()
            restart(animatingShape: false)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        [layer, fill, knob].forEach { $0?.contentsScale = scale }
    }

    private func fillWidth(_ fraction: Double) -> CGFloat {
        max(5, bounds.width * fraction)
    }

    private func knobX(_ fraction: Double) -> CGFloat {
        max(knobDiameter / 2, bounds.width * fraction)
    }

    private func restart(animatingShape: Bool) {
        laidOutWidth = bounds.width
        fill.removeAnimation(forKey: "glide")
        knob.removeAnimation(forKey: "glide")
        let fraction = currentFraction()

        CATransaction.begin()
        CATransaction.setDisableActions(!animatingShape)
        CATransaction.setAnimationDuration(0.18)
        fill.bounds = CGRect(x: 0, y: 0, width: fillWidth(fraction), height: barHeight)
        fill.position = CGPoint(x: 0, y: bounds.midY)
        fill.cornerRadius = barHeight / 2
        knob.isHidden = knobDiameter <= 0
        knob.bounds = CGRect(x: 0, y: 0, width: knobDiameter, height: knobDiameter)
        knob.cornerRadius = knobDiameter / 2
        knob.position = CGPoint(x: knobX(fraction), y: bounds.midY)
        CATransaction.commit()

        guard velocity > 0, fraction < 1, window != nil, bounds.width > 0 else { return }
        let remaining = (1 - fraction) / velocity
        let fillGlide = CABasicAnimation(keyPath: "bounds.size.width")
        fillGlide.fromValue = fillWidth(fraction)
        fillGlide.toValue = fillWidth(1)
        let knobGlide = CABasicAnimation(keyPath: "position.x")
        knobGlide.fromValue = knobX(fraction)
        knobGlide.toValue = knobX(1)
        for (layer, glide) in [(fill, fillGlide), (knob, knobGlide)] {
            glide.duration = remaining
            glide.timingFunction = CAMediaTimingFunction(name: .linear)
            glide.fillMode = .forwards
            glide.isRemovedOnCompletion = false
            layer.add(glide, forKey: "glide")
        }
    }
}
