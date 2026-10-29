import SwiftUI

/// What the lyrics panel is showing.
enum LyricsPanelState: Equatable {
    case idle
    case loading(LyricsQuery)
    case loaded(LyricsQuery, Lyrics)
    case unavailable(String, LyricsQuery? = nil)

    static let noTrackMessage = "Lyrics need a track title and artist"
    static let notFoundMessage = "No lyrics found for this track"
    static let offlineMessage = "Lyrics are temporarily unavailable — try refreshing"

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var query: LyricsQuery? {
        switch self {
        case .idle: nil
        case .loading(let query): query
        case .loaded(let query, _): query
        case .unavailable(_, let query): query
        }
    }
}

/// Lyrics inside the expanded player. Synced lyrics follow the track: the
/// line being sung is bright and held near the top third, lines already sung
/// dim, and tapping a line seeks to it.
struct LyricsPanel: View {
    var state: LyricsPanelState
    var snapshot: MediaSnapshot
    /// False while the screens sleep, which stops following the track.
    var ticks: Bool
    var height: CGFloat
    var onSeek: (TimeInterval) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Only changes when the sung line does, so following the track redraws
    /// the list a few times a minute rather than on every position check.
    @State private var currentIndex: Int?

    var body: some View {
        Group {
            switch state {
            case .idle, .loading:
                HStack(spacing: 8) {
                    IslandSpinner(size: 12)
                    Text("Finding lyrics…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            case .unavailable(let text, _):
                message(text)
                    .transition(.opacity)
            case .loaded(_, let lyrics) where lyrics.isInstrumental:
                message("Instrumental")
                    .transition(.opacity)
            case .loaded(_, let lyrics):
                lines(lyrics)
                    .transition(.opacity)
            }
        }
        .frame(height: height)
        // The lines arrive as a crossfade from "Finding lyrics", not a cut.
        .animation(NotchMotion.fade(reduceMotion: reduceMotion), value: Self.phase(of: state))
    }

    enum Phase: Equatable { case finding, message, lines }

    static func phase(of state: LyricsPanelState) -> Phase {
        switch state {
        case .idle, .loading: .finding
        case .unavailable: .message
        case .loaded(_, let lyrics): lyrics.isInstrumental ? .message : .lines
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func lines(_ lyrics: Lyrics) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(lyrics.lines) { line in
                        row(line, lyrics: lyrics)
                            .id(line.id)
                    }
                }
                // Room to scroll the first and last lines to the reading line.
                .padding(.vertical, height * 0.3)
            }
            .scrollIndicators(.hidden)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.16),
                        .init(color: .black, location: 0.84),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .onAppear {
                currentIndex = lyrics.currentLineIndex(at: position(at: Date()))
                if let currentIndex { proxy.scrollTo(currentIndex, anchor: Self.readingLine) }
            }
            .onChange(of: currentIndex) { _, index in
                guard let index else { return }
                withAnimation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.9)) {
                    proxy.scrollTo(index, anchor: Self.readingLine)
                }
            }
            .task(id: followKey(lyrics)) {
                await follow(lyrics)
            }
        }
    }

    /// Where the current line sits in the panel.
    private static let readingLine = UnitPoint(x: 0.5, y: 0.35)

    /// Sharp for the sung line, a little softer for each line away, and no
    /// further after three. Unsynced lyrics have no sung line and stay sharp.
    static func blurRadius(linesAway: Int?) -> CGFloat {
        guard let linesAway else { return 0 }
        return CGFloat(min(linesAway, 3)) * 0.8
    }

    @ViewBuilder
    private func row(_ line: LyricLine, lyrics: Lyrics) -> some View {
        let isCurrent = lyrics.isSynced && line.id == currentIndex
        let linesAway = lyrics.isSynced ? currentIndex.map { abs(line.id - $0) } : nil
        let isPast = lyrics.isSynced && currentIndex.map { line.id < $0 } == true
        let text = line.text.isEmpty ? "♪" : line.text
        let sweep = isCurrent && !line.text.isEmpty
            ? LiveLyricLinePolicy.sweep(
                in: lyrics,
                index: line.id,
                position: position(at: Date()),
                trackDuration: snapshot.duration
            )
            : nil
        // One font size for every line, with the current one scaled up: a
        // transform animates on the GPU, where changing the point size would
        // re-lay out the text and shove the lines below it each time.
        let label = Group {
            if let sweep, !reduceMotion {
                LyricSweepLabel(
                    text: text,
                    startFraction: sweep.fraction,
                    duration: sweep.duration,
                    isRunning: snapshot.isPlaying && ticks
                )
                .id(line.id)
            } else {
                Text(text)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.islandInk(
                        isCurrent ? NotchIsland.Ink.primary
                            : (isPast ? NotchIsland.Ink.recessed : NotchIsland.Ink.tertiary)
                    ))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scaleEffect(isCurrent || !lyrics.isSynced ? 1 : 0.93, anchor: .leading)
        // Lines soften the further they are from the sung one, as Apple
        // Music's do, so the eye lands on the right line first.
        .blur(radius: Self.blurRadius(linesAway: linesAway))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: linesAway)

        if lyrics.isSynced, let time = line.time, snapshot.supportedCommands.contains(.seek) {
            Button { onSeek(time) } label: { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityHint("Plays from this line")
        } else {
            label
        }
    }

    private func followKey(_ lyrics: Lyrics) -> String {
        "\(lyrics.isSynced)—\(snapshot.isPlaying && ticks)—\(snapshot.position ?? -1)—\(lyrics.lines.count)"
    }

    /// Checks the position a few times a second while playing and publishes
    /// only line changes. Paused, it settles once and stops.
    private func follow(_ lyrics: Lyrics) async {
        guard lyrics.isSynced else {
            currentIndex = nil
            return
        }
        repeat {
            let index = lyrics.currentLineIndex(at: position(at: Date()))
            if index != currentIndex { currentIndex = index }
            guard snapshot.isPlaying, ticks else { return }
            try? await Task.sleep(for: .milliseconds(200))
        } while !Task.isCancelled
    }

    private func position(at date: Date) -> TimeInterval {
        snapshot.interpolatedPosition(at: date) ?? 0
    }
}

/// The sung line filling from left to right as it is sung, like karaoke:
/// the dim line underneath, the bright copy revealed over it. One linear
/// glide per line on the render server, started when the line starts and
/// frozen on pause; a SwiftUI animation this long re-rendered the notch on
/// every frame of every line.
struct LyricSweepLabel: View {
    var text: String
    var startFraction: Double
    var duration: TimeInterval
    var isRunning: Bool

    var body: some View {
        label(NotchIsland.Ink.secondary)
            .overlay(alignment: .leading) {
                LayerSweepReveal(
                    progress: startFraction,
                    remaining: isRunning ? max(0.05, duration * (1 - startFraction)) : nil,
                    key: text
                ) {
                    label(NotchIsland.Ink.primary)
                }
            }
    }

    private func label(_ ink: Double) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Color.islandInk(ink))
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
