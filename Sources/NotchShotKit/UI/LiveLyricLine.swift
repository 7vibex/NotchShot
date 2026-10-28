import SwiftUI

/// Follows the line being sung for surfaces that show only one: the line
/// pinned under the closed notch and the Lock Screen player.
///
/// Lyrics come from the same in-memory `LyricsService` cache the lyrics panel
/// uses, so opening the panel afterwards costs no second lookup. Nothing is
/// fetched unless lyrics are turned on in Settings, and the follower checks
/// the position a few times a second only while the track plays and the
/// screens are awake; it publishes only when the line changes.
struct LiveLyricLine<Content: View>: View {
    var snapshot: MediaSnapshot
    var ticks: Bool
    @ViewBuilder var content: (String?) -> Content

    @State private var lyrics: Lyrics?
    @State private var line: String?

    private var query: LyricsQuery? {
        Preferences.shared.lyricsEnabled ? LyricsQuery(snapshot: snapshot) : nil
    }

    var body: some View {
        content(line)
            .task(id: query) {
                lyrics = nil
                line = nil
                guard let query else { return }
                guard case .success(let found) = await LyricsService.shared.lyrics(for: query),
                      !Task.isCancelled, found.isSynced, LyricsQuery(snapshot: snapshot) == query
                else { return }
                lyrics = found
            }
            .task(id: followKey) {
                guard let lyrics else { return }
                repeat {
                    let next = LiveLyricLinePolicy.line(in: lyrics, at: snapshot.interpolatedPosition(at: Date()) ?? 0)
                    if next != line { line = next }
                    guard ticks else { return }
                    try? await Task.sleep(for: .milliseconds(250))
                } while !Task.isCancelled
            }
    }

    private var followKey: String {
        "\(lyrics?.lines.count ?? -1)—\(ticks)—\(snapshot.position ?? -1)—\(query?.title ?? "")"
    }
}

enum LiveLyricLinePolicy {
    /// The sung line's text; nil before the first line, in instrumental
    /// gaps (empty lines), and for unsynced lyrics.
    static func line(in lyrics: Lyrics, at position: TimeInterval) -> String? {
        guard let index = lyrics.currentLineIndex(at: position) else { return nil }
        let text = lyrics.lines[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// How far through its line the track is, 0...1, and how long the line
    /// lasts, for the sweep that fills the current line as it is sung. The
    /// last line runs to the end of the track, capped so an outro does not
    /// stretch it over a minute.
    static func sweep(
        in lyrics: Lyrics,
        index: Int,
        position: TimeInterval,
        trackDuration: TimeInterval?
    ) -> (fraction: Double, duration: TimeInterval)? {
        guard lyrics.lines.indices.contains(index), let start = lyrics.lines[index].time else { return nil }
        let nextStart = lyrics.lines.indices.contains(index + 1) ? lyrics.lines[index + 1].time : nil
        let end = nextStart ?? min(trackDuration ?? (start + 6), start + 8)
        let length = end - start
        guard length > 0.05 else { return nil }
        let fraction = min(max((position - start) / length, 0), 1)
        return (fraction, length)
    }
}

/// The pinned lyric under the closed notch: one short line on a black pill,
/// which crossfades with a slight rise as each new line starts.
struct PinnedLyricPill: View {
    var text: String
    var maxWidth: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.92))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 12)
            .frame(height: 22)
            .background(.black, in: Capsule())
            .frame(maxWidth: maxWidth)
            .id(text)
            .transition(reduceMotion
                ? .opacity
                : .opacity.combined(with: .offset(y: -5)).combined(with: IslandMotion.blur(3)))
            .allowsHitTesting(false)
            .accessibilityLabel("Lyric: \(text)")
    }
}
