import SwiftUI

/// What the lyrics panel is showing.
enum LyricsPanelState: Equatable {
    case idle
    case loading(LyricsQuery)
    case loaded(LyricsQuery, Lyrics)
    case unavailable(String, LyricsQuery? = nil)

    static let noTrackMessage = "Lyrics need a track title and artist"
    static let notFoundMessage = "No lyrics found for this track"
    static let offlineMessage = "Couldn't reach LRCLIB — check your connection"

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
                message("Finding lyrics…")
            case .unavailable(let text, _):
                message(text)
            case .loaded(_, let lyrics) where lyrics.isInstrumental:
                message("Instrumental")
            case .loaded(_, let lyrics):
                lines(lyrics)
            }
        }
        .frame(height: height)
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

    @ViewBuilder
    private func row(_ line: LyricLine, lyrics: Lyrics) -> some View {
        let isCurrent = lyrics.isSynced && line.id == currentIndex
        let isPast = lyrics.isSynced && currentIndex.map { line.id < $0 } == true
        let text = line.text.isEmpty ? "♪" : line.text
        // One font size for every line, with the current one scaled up: a
        // transform animates on the GPU, where changing the point size would
        // re-lay out the text and shove the lines below it each time.
        let label = Text(text)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Color.islandInk(
                isCurrent ? NotchIsland.Ink.primary
                    : (isPast ? NotchIsland.Ink.recessed : NotchIsland.Ink.tertiary)
            ))
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scaleEffect(isCurrent || !lyrics.isSynced ? 1 : 0.93, anchor: .leading)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: isCurrent)

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
