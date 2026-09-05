import AppKit
import CoreAudio
import Observation
import SwiftUI

enum LockedNowPlayingLayout {
    static let cornerRadius: CGFloat = 24
    static let artworkSize: CGFloat = 72
    static let artworkCornerRadius: CGFloat = 16
    static let titleSize: CGFloat = 15.5
    static let artistSize: CGFloat = 12.5
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

    @State private var now = Date()
    @State private var output = LockedNowPlayingAudioOutput()

    private var snapshot: MediaSnapshot { coordinator.media.snapshot }

    var body: some View {
        LockedNowPlayingPresentation(
            snapshot: snapshot,
            artwork: coordinator.media.artwork,
            cardSize: cardSize,
            now: now,
            audioRoute: output.route
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { output.start() }
        .onDisappear { output.stop() }
        // Advance locally; paused playback does not need a progress timer.
        .task(id: snapshot.isPlaying && coordinator.media.areScreensAwake) {
            now = Date()
            guard snapshot.isPlaying, coordinator.media.areScreensAwake else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                now = Date()
            }
        }
    }
}

/// A side-effect-free presentation seam for previews and pixel validation.
/// It never starts media sources, opens the clipboard, or accesses a coordinator.
struct LockedNowPlayingPresentation: View {
    var snapshot: MediaSnapshot
    var artwork: NSImage?
    var cardSize: CGSize = LockedCardGeometry.preferredCardSize
    var now: Date = Date()
    var audioRoute: AudioRouteReading? = nil
    /// Previews can exercise the accessibility fallback without changing
    /// system preferences; production follows the environment by default.
    var reduceTransparencyOverride: Bool? = nil

    @Environment(\.accessibilityReduceTransparency) private var environmentReduceTransparency

    private var reduceTransparency: Bool {
        reduceTransparencyOverride ?? environmentReduceTransparency
    }

    var body: some View {
        card
            .scaleEffect(scale)
            .frame(width: cardSize.width, height: cardSize.height)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Now playing")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint("Playback controls are unavailable while the Mac is locked.")
    }

    private var scale: CGFloat {
        min(cardSize.width / LockedCardGeometry.preferredCardSize.width,
            cardSize.height / LockedCardGeometry.preferredCardSize.height)
    }

    private var card: some View {
        VStack(spacing: 0) {
            header

            progress
                .padding(.top, 11)

            transport
                .padding(.top, 10)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: LockedCardGeometry.preferredCardSize.width, height: LockedCardGeometry.preferredCardSize.height)
        .notchShotLockedNowPlayingSurface(
            cornerRadius: LockedNowPlayingLayout.cornerRadius,
            reduceTransparency: reduceTransparency
        )
        .shadow(color: .black.opacity(reduceTransparency ? 0.24 : 0.08), radius: 12, y: 5)
    }

    private var header: some View {
        HStack(spacing: 15) {
            albumArtwork

            VStack(alignment: .leading, spacing: 3) {
                Text(LockedNowPlayingPresentationPolicy.title(snapshot))
                    .font(.system(size: LockedNowPlayingLayout.titleSize, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                Text(LockedNowPlayingPresentationPolicy.subtitle(snapshot))
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
    private var albumArtwork: some View {
        Group {
            if let image = artwork {
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
                        .frame(width: geometry.size.width * fraction, height: 3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 14)

            timeLabel(remaining, countdown: true)
        }
    }

    private var transport: some View {
        HStack(spacing: 0) {
            transportSymbol("shuffle", size: 16, opacity: 0.78)
            Spacer()
            transportSymbol("backward.fill", size: 24)
            Spacer()
            transportSymbol(snapshot.isPlaying ? "pause.fill" : "play.fill", size: 29)
                .frame(width: 34)
            Spacer()
            transportSymbol("forward.fill", size: 24)
            Spacer()
            transportSymbol(LockedNowPlayingPresentationPolicy.routeSymbol(audioRoute), size: 18)
        }
        .frame(height: 35)
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
            .font(.system(size: 11, weight: .semibold, design: .rounded))
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
        LockedNowPlayingPresentationPolicy.accessibilityValue(snapshot, audioRoute: audioRoute)
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

/// Fallback text and route identity are independent of the live coordinator.
enum LockedNowPlayingPresentationPolicy {
    static func title(_ snapshot: MediaSnapshot) -> String {
        nonempty(snapshot.title) ?? "Not Playing"
    }

    static func subtitle(_ snapshot: MediaSnapshot) -> String {
        nonempty(snapshot.artist) ?? nonempty(snapshot.applicationName) ?? "Unknown artist"
    }

    static func routeSymbol(_ route: AudioRouteReading?) -> String {
        route?.selectorSymbolName ?? "speaker.wave.2"
    }

    static func accessibilityValue(_ snapshot: MediaSnapshot, audioRoute: AudioRouteReading?) -> String {
        [title(snapshot), subtitle(snapshot), snapshot.isPlaying ? "Playing" : "Paused",
         nonempty(audioRoute?.name).map { "Audio output: \($0)" }]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

/// Listen only for output changes while this card is mounted. This keeps the
/// route truthful even while paused, without polling or selecting a device.
@MainActor
@Observable
private final class LockedNowPlayingAudioOutput {
    private(set) var route: AudioRouteReading?
    @ObservationIgnored private var registration: LockedNowPlayingOutputRegistration?

    func start() {
        guard registration == nil else { return }
        route = AudioOutputDeviceService.currentOutput()
        registration = LockedNowPlayingOutputRegistration { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.registration != nil else { return }
                self.route = AudioOutputDeviceService.currentOutput()
            }
        }
    }

    func stop() {
        registration = nil
    }
}

/// Ownership of the Core Audio registration is independent of SwiftUI's
/// disappearance callbacks. Dropping the view state also releases the token,
/// removing the listener even if no explicit `stop` callback was delivered.
private final class LockedNowPlayingOutputRegistration {
    private let listener: AudioObjectPropertyListenerBlock

    private static var address: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    init?(_ listener: @escaping AudioObjectPropertyListenerBlock) {
        self.listener = listener
        var address = Self.address
        guard AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, listener
        ) == noErr else { return nil }
    }

    deinit {
        var address = Self.address
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, listener
        )
    }
}
