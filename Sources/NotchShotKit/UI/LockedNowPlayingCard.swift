import AppKit
import SwiftUI

enum LockedNowPlayingLayout {
    static let cornerRadius: CGFloat = 20
    static let artworkSize: CGFloat = 64
    static let artworkCornerRadius: CGFloat = 14
    static let titleSize: CGFloat = 15
    static let artistSize: CGFloat = 11.5
}

/// The compact, display-only Now Playing surface drawn over loginwindow.
///
/// The secure Lock Screen is intentionally never made interactive: the panel
/// ignores all events so it cannot intercept a password, an unlock click, or a
/// keyboard shortcut. The transport glyphs mirror the familiar player layout
/// while playback remains owned by the source application.
struct LockedNowPlayingCard: View {
    @Bindable var coordinator: AppCoordinator
    var cardSize: CGSize

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var now = Date()

    private var snapshot: MediaSnapshot { coordinator.media.snapshot }

    var body: some View {
        card
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Advance the position locally without polling the media source.
            // A paused card performs no once-per-second work.
            .task(id: snapshot.isPlaying && coordinator.media.areScreensAwake) {
                guard snapshot.isPlaying, coordinator.media.areScreensAwake else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    now = Date()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Now playing")
            .accessibilityValue(accessibilityValue)
    }

    private var card: some View {
        VStack(spacing: 0) {
            header

            progress
                .padding(.top, 9)

            transport
                .padding(.top, 5)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: cardSize.width, height: cardSize.height)
        .notchShotLockedNowPlayingSurface(
            cornerRadius: LockedNowPlayingLayout.cornerRadius,
            reduceTransparency: reduceTransparency
        )
        .shadow(color: .black.opacity(reduceTransparency ? 0.24 : 0.08), radius: 12, y: 5)
        // Read `now` so the progress view refreshes without rebuilding the
        // artwork/title subtree every second.
        .opacity(now == .distantPast ? 0 : 1)
    }

    private var header: some View {
        HStack(spacing: 14) {
            artwork

            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.title ?? "Not Playing")
                    .font(.system(size: LockedNowPlayingLayout.titleSize, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                Text(snapshot.artist ?? snapshot.applicationName ?? "")
                    .font(.system(size: LockedNowPlayingLayout.artistSize, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "waveform")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(.white.opacity(snapshot.isPlaying ? 0.94 : 0.58))
                .frame(width: 30)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var artwork: some View {
        Group {
            if let image = coordinator.media.artwork {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: LockedNowPlayingLayout.artworkCornerRadius, style: .continuous)
                    .fill(.white.opacity(0.10))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 21, weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                    }
            }
        }
        .frame(
            width: LockedNowPlayingLayout.artworkSize,
            height: LockedNowPlayingLayout.artworkSize
        )
        .clipShape(RoundedRectangle(
            cornerRadius: LockedNowPlayingLayout.artworkCornerRadius,
            style: .continuous
        ))
        .overlay {
            RoundedRectangle(
                cornerRadius: LockedNowPlayingLayout.artworkCornerRadius,
                style: .continuous
            )
                .strokeBorder(.white.opacity(0.16), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.18), radius: 7, y: 3)
        .accessibilityHidden(true)
    }

    private var progress: some View {
        HStack(spacing: 8) {
            timeLabel(elapsed)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.22))
                        .frame(height: 3)
                    Capsule()
                        .fill(.white.opacity(0.94))
                        .frame(width: max(3, geometry.size.width * fraction), height: 3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 14)

            timeLabel(remaining, countdown: true)
        }
    }

    private var transport: some View {
        HStack(spacing: 0) {
            transportSymbol("heart.fill", size: 15)
            Spacer()
            transportSymbol("backward.fill", size: 21)
            Spacer()
            transportSymbol(snapshot.isPlaying ? "pause.fill" : "play.fill", size: 26)
                .frame(width: 34)
            Spacer()
            transportSymbol("forward.fill", size: 21)
            Spacer()
            transportSymbol("display", size: 17)
        }
        .frame(height: 32)
        .accessibilityHidden(true)
    }

    private func transportSymbol(
        _ name: String,
        size: CGFloat,
        opacity: Double = 0.94
    ) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.white.opacity(opacity))
            .frame(minWidth: 28, minHeight: 28)
    }

    private func timeLabel(_ value: TimeInterval?, countdown: Bool = false) -> some View {
        Text((countdown && value != nil ? "-" : "") + Self.formatted(value))
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.72))
            .monospacedDigit()
            .frame(minWidth: 30)
    }

    private var elapsed: TimeInterval? {
        snapshot.interpolatedPosition(at: now)
    }

    private var remaining: TimeInterval? {
        guard let duration = snapshot.duration, duration.isFinite, duration > 0,
              let elapsed else { return nil }
        return max(0, duration - elapsed)
    }

    private var fraction: Double {
        guard let duration = snapshot.duration, duration.isFinite, duration > 0,
              let elapsed else { return 0 }
        return min(max(elapsed / duration, 0), 1)
    }

    private var accessibilityValue: String {
        [snapshot.title, snapshot.artist]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private static func formatted(_ value: TimeInterval?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "--:--" }
        let total = Int(value.rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
