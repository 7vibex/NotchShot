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
    @State private var now = Date()
    @State private var audioOutputs: [AudioRouteReading] = []
    @State private var upcoming: [MediaQueueEntry] = []
    @State private var isLoadingQueue = false
    @State private var queueUnavailable = false
    @State private var modes: MediaPlaybackModes?
    @State private var currentAudioOutputID: UInt32?
    @State private var artworkMotion = false

    private var snapshot: MediaSnapshot { coordinator.media.snapshot }

    var body: some View {
        Group {
            if isPeeking {
                expanded
            } else {
                compact
            }
        }
        // The timer exists only while something is playing, so a paused notch
        // stops waking the CPU once a second. An autoconnected publisher held in
        // a property could not do that: it fires for as long as the view lives,
        // whatever the playback state.
        .task(id: snapshot.isPlaying && coordinator.media.areScreensAwake) {
            guard snapshot.isPlaying, coordinator.media.areScreensAwake else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                now = Date()
            }
        }
        .task(id: isPeeking) {
            guard isPeeking else { return }
            refreshAudioOutputs()
        }
        .task(id: snapshot.isPlaying && !reduceMotion && coordinator.media.areScreensAwake) {
            artworkMotion = false
            guard snapshot.isPlaying, !reduceMotion, coordinator.media.areScreensAwake else { return }
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            artworkMotion = true
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
            header

            MediaScrubber(snapshot: snapshot, now: now) { position in
                coordinator.media.send(.seek(position))
            }

            controlBar

            openPanel
        }
        .padding(.horizontal, NotchIsland.Spacing.gutter)
        .padding(.top, NotchIsland.Spacing.row)
        .padding(.bottom, NotchIsland.Spacing.group)
        .animation(NotchShotMotion.content(reduceMotion: reduceMotion), value: coordinator.mediaPanel)
        // A track change while Playing Next is open would otherwise leave the
        // previous track's queue on screen.
        .task(id: queueRefreshKey) {
            guard coordinator.mediaPanel == .playingNext else { return }
            await refreshQueue()
        }
        // Re-read on every track change as well as on open: shuffle and repeat
        // can be changed in the player itself while this card is closed.
        .task(id: playbackModeRefreshKey) {
            await refreshPlaybackModes()
        }
        // `now` is read so the progress bar re-evaluates on each tick. It must
        // not become a view identity — keying the view on it rebuilt the whole
        // subtree every second and restarted the marquee mid-scroll.
        .opacity(now == .distantPast ? 0 : 1)
    }

    private var header: some View {
        HStack(spacing: NotchIsland.Spacing.group) {
            if let sharedArtworkID {
                IslandGlyphSlot(id: sharedArtworkID, size: 56)
            } else {
                artwork(size: 56)
            }

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

            headerChrome
        }
        .frame(height: 56)
    }

    /// The meter and the capture button. Playback controls all live in the row
    /// below; this side of the header is chrome only.
    private var headerChrome: some View {
        HStack(spacing: 0) {
            PlaybackIndicator(
                isPlaying: snapshot.isPlaying,
                accentColor: Color(nsColor: coordinator.media.artworkAccentColor),
                animates: coordinator.media.areScreensAwake,
                scale: 1.4
            )
            .padding(.trailing, NotchIsland.Spacing.snug)

            MediaControlButton(
                systemName: "camera.viewfinder",
                label: "Open capture tools",
                diameter: 26,
                symbolSize: 13,
                opacity: NotchIsland.Ink.secondary
            ) {
                coordinator.toggleExpanded()
            }
        }
    }

    /// Transport between the modes and the panel openers, with the two gaps
    /// equal.
    ///
    /// Two spacers rather than a centred layer: centring the trio on the card
    /// made the gap to shuffle wider than the gap to repeat, because the
    /// trailing side carries one more control. Equal spacers put the same
    /// distance on both sides of the transport, which is the spacing the eye
    /// actually reads — the trio then sits slightly left of the card's centre.
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

            Spacer(minLength: 0)

            transportControls

            Spacer(minLength: 0)

            HStack(spacing: NotchIsland.Spacing.snug) {
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
                if audioOutputs.isEmpty {
                    emptyPanelRow("No audio outputs found")
                } else {
                    panelList(rowCount: audioOutputs.count) {
                        ForEach(audioOutputs) { output in
                            AudioOutputDeviceRow(
                                output: output,
                                isSelected: output.deviceID == currentAudioOutputID,
                                action: { selectAudioOutput(output) }
                            )
                        }
                    }
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

    /// Identity for the queue refresh: the track and which panel is open.
    private var queueRefreshKey: String {
        "\(coordinator.mediaPanel == .playingNext)—\(snapshot.title ?? "")—\(snapshot.artist ?? "")"
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
        coordinator.setMediaPanel(.audioRoutes, rowCount: max(1, audioOutputs.count))
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
        guard supportsQueue else {
            upcoming = []
            queueUnavailable = true
            return
        }
        isLoadingQueue = upcoming.isEmpty
        let entries = await MediaQueueService.shared.upcoming(
            for: snapshot.applicationBundleID
        )
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
        if coordinator.mediaPanel == .audioRoutes {
            coordinator.setMediaPanel(.audioRoutes, rowCount: max(1, audioOutputs.count))
        }
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
        .scaleEffect(artworkMotion ? 1.035 : 0.99)
        .rotationEffect(.degrees(artworkMotion ? 0.65 : -0.35))
        .shadow(
            color: Color(nsColor: coordinator.media.artworkAccentColor).opacity(artworkMotion ? 0.46 : 0.18),
            radius: artworkMotion ? 12 : 4
        )
        .animation(
            reduceMotion || !snapshot.isPlaying
                ? .easeOut(duration: 0.16)
                : .easeInOut(duration: 2.8).repeatForever(autoreverses: true),
            value: artworkMotion
        )
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
    /// Ticks once a second so the elapsed time advances between source polls.
    var now: Date
    var onSeek: (TimeInterval) -> Void

    /// Where the user just dragged to, and when. Held briefly after release —
    /// see `displayedFraction`.
    @State private var pending: (fraction: Double, at: Date)?

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
                        .frame(height: 5)
                    Capsule()
                        .fill(.white.opacity(canSeek ? 0.95 : 0.6))
                        .frame(width: max(5, geometry.size.width * displayedFraction), height: 5)
                    if canSeek {
                        Circle()
                            .fill(.white)
                            .frame(width: 9, height: 9)
                            .offset(x: max(0, geometry.size.width * displayedFraction - 4.5))
                    }
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
                pending = (Self.clamped(value.location.x / width), Date())
            }
            .onEnded { value in
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
        guard let pending, let duration else { return snapshot.progress }
        let target = pending.fraction * duration
        if let position = snapshot.interpolatedPosition(at: now), abs(position - target) < 1.5 {
            return snapshot.progress
        }
        // Give up waiting rather than showing a stale position forever if the
        // player ignored the seek.
        if Date().timeIntervalSince(pending.at) > 3 { return snapshot.progress }
        return pending.fraction
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
        guard let time, time.isFinite, time >= 0 else { return "--:--" }
        let total = Int(time.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

/// Three bars that bounce while audio is playing.
///
/// Each bar animates its own height between a short and a tall value, on its own
/// duration, so they drift out of step and read as a level meter rather than
/// three things moving together. Driving a shared phase through `sin` does not
/// work here: SwiftUI interpolates the resulting height, not the phase, so a
/// phase running 0 → 2π starts and ends at the same height and nothing appears
/// to move at all.
