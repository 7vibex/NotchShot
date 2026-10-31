import AppKit
import CoreAudio
import Observation
import SwiftUI

/// The Lock Screen player: a clear Liquid Glass slab the wallpaper shows
/// through, with the cover large on the left, the names and live meter
/// beside it, a thick progress line, and the transport centred beneath.
/// Charging and the sung lyric line ride along when there is something to
/// say.
enum LockedNowPlayingLayout {
    static let cornerRadius: CGFloat = 30
    static let artworkSize: CGFloat = 72
    static let artworkCornerRadius: CGFloat = 16
    static let titleSize: CGFloat = 17
    static let artistSize: CGFloat = 13
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
    @State private var power: PowerSourceReading?

    private var snapshot: MediaSnapshot { coordinator.media.snapshot }
    private var ticks: Bool { snapshot.isPlaying && coordinator.media.areScreensAwake }

    var body: some View {
        LiveLyricLine(snapshot: snapshot, ticks: ticks) { lyric in
            LockedNowPlayingPresentation(
                snapshot: snapshot,
                artwork: coordinator.media.artwork,
                accent: Color(nsColor: coordinator.media.artworkAccentColor),
                cardSize: cardSize,
                now: now,
                audioRoute: output.route,
                power: power,
                lyricLine: lyric,
                metersAnimate: ticks
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { output.start() }
        .onDisappear { output.stop() }
        // Advance locally; paused playback does not need a progress timer.
        .task(id: ticks) {
            now = Date()
            guard ticks else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                now = Date()
            }
        }
        // The charge moves a percent every few minutes; no need to ask often.
        .task {
            while !Task.isCancelled {
                power = LockedChargingPolicy.reading()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }
}

/// A side-effect-free presentation seam for previews and pixel validation.
/// It never starts media sources, opens the clipboard, or accesses a coordinator.
struct LockedNowPlayingPresentation: View {
    var snapshot: MediaSnapshot
    var artwork: NSImage?
    var accent: Color = .white
    var cardSize: CGSize = LockedCardGeometry.preferredCardSize
    var now: Date = Date()
    var audioRoute: AudioRouteReading? = nil
    var power: PowerSourceReading? = nil
    var lyricLine: String? = nil
    var metersAnimate = false
    /// Previews can exercise the accessibility fallback without changing
    /// system preferences; production follows the environment by default.
    var reduceTransparencyOverride: Bool? = nil

    @Environment(\.accessibilityReduceTransparency) private var environmentReduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                .padding(.top, 14)

            transport
                .padding(.top, 6)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .frame(width: LockedCardGeometry.preferredCardSize.width, height: LockedCardGeometry.preferredCardSize.height)
        // Nothing goes under the glass but its dimming layer: a cover tint
        // or a drop shadow there is seen through it and darkens the card.
        .notchShotLockedNowPlayingSurface(
            cornerRadius: LockedNowPlayingLayout.cornerRadius,
            reduceTransparency: reduceTransparency
        )
        // The opaque fallback still needs lifting off the wallpaper.
        .shadow(
            color: .black.opacity(reduceTransparency ? 0.24 : 0),
            radius: reduceTransparency ? 12 : 0,
            y: reduceTransparency ? 5 : 0
        )
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            albumArtwork

            VStack(alignment: .leading, spacing: 3) {
                statusLine

                Text(LockedNowPlayingPresentationPolicy.title(snapshot))
                    .font(.system(size: LockedNowPlayingLayout.titleSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(LockedNowPlayingPresentationPolicy.subtitle(snapshot))
                    .font(.system(size: LockedNowPlayingLayout.artistSize, weight: .regular))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                if let lyricLine, !lyricLine.isEmpty {
                    Text(lyricLine)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .id(lyricLine)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
                        .padding(.top, 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.9), value: lyricLine)
        }
        .frame(maxWidth: .infinity)
    }

    /// Where the sound goes and the live meter on one side, the battery on
    /// the other while the Mac charges.
    private var statusLine: some View {
        HStack(spacing: 6) {
            Image(systemName: LockedNowPlayingPresentationPolicy.routeSymbol(audioRoute))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(snapshot.isPlaying ? 0.8 : 0.5))
            PlaybackIndicator(isPlaying: snapshot.isPlaying, accentColor: accent, animates: metersAnimate)
                .fixedSize()
            Spacer(minLength: 4)
            if let power {
                LockedChargeChip(power: power)
            }
        }
        .frame(height: 13)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var albumArtwork: some View {
        let shape = RoundedRectangle(cornerRadius: LockedNowPlayingLayout.artworkCornerRadius, style: .continuous)
        Group {
            if let image = artwork {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                shape
                    .fill(.white.opacity(0.12))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                    }
            }
        }
        .frame(width: LockedNowPlayingLayout.artworkSize, height: LockedNowPlayingLayout.artworkSize)
        .clipShape(shape)
        .overlay { shape.strokeBorder(.white.opacity(0.16), lineWidth: 0.5) }
        // Paused, the cover steps back the way the phone's does.
        .scaleEffect(snapshot.isPlaying ? 1 : 0.9)
        .opacity(snapshot.isPlaying ? 1 : 0.78)
        .shadow(color: accent.opacity(0.45), radius: 14, y: 4)
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.78), value: snapshot.isPlaying)
        .accessibilityHidden(true)
    }

    private var progress: some View {
        VStack(spacing: 5) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.3))
                    Capsule()
                        .fill(.white.opacity(0.92))
                        .frame(width: max(6, geometry.size.width * fraction))
                }
            }
            .frame(height: 6)

            HStack {
                timeLabel(elapsed)
                Spacer()
                timeLabel(remaining, countdown: true)
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 44) {
            transportSymbol("backward.fill", size: 20)
            transportSymbol(snapshot.isPlaying ? "pause.fill" : "play.fill", size: 28)
                .contentTransition(NotchSymbolMotion.swap(reduceMotion: reduceMotion))
                .frame(width: 34)
            transportSymbol("forward.fill", size: 20)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .accessibilityHidden(true)
    }

    private func transportSymbol(
        _ name: String,
        size: CGFloat,
        opacity: Double = 0.96
    ) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.white.opacity(opacity))
            .frame(minWidth: 30, minHeight: 30)
    }

    private func timeLabel(_ value: TimeInterval?, countdown: Bool = false) -> some View {
        Text((countdown && value != nil ? "-" : "") + Self.formatted(value))
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.75))
            .monospacedDigit()
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
        MediaTimePolicy.formatted(value)
    }
}

/// The battery while charging, as a small green bolt and number inside the
/// player, so the Lock Screen has one surface instead of two.
struct LockedChargeChip: View {
    var power: PowerSourceReading
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: power.isChargingOnHold ? "pause.fill" : "bolt.fill")
                .font(.system(size: 9, weight: .bold))
                .contentTransition(NotchSymbolMotion.swap(reduceMotion: reduceMotion))
            Text("\(power.percentage)%")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(power.isChargingOnHold ? IslandSystemColor.orange : IslandSystemColor.green)
        .padding(.horizontal, 6)
        .frame(height: 16)
        .background(.black.opacity(0.28), in: Capsule())
    }
}

/// The Lock Screen card's charging face, shown in the player's place when
/// nothing is playing: a large battery filling green, the percentage, and
/// what macOS knows about the charge.
struct LockedChargingCard: View {
    var cardSize: CGSize

    @State private var power: PowerSourceReading?

    var body: some View {
        Group {
            if let power {
                LockedChargingPresentation(power: power, cardSize: cardSize)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            while !Task.isCancelled {
                power = LockedChargingPolicy.reading()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }
}

struct LockedChargingPresentation: View {
    var power: PowerSourceReading
    var cardSize: CGSize = LockedCardGeometry.preferredCardSize
    var reduceTransparencyOverride: Bool? = nil

    @Environment(\.accessibilityReduceTransparency) private var environmentReduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var reduceTransparency: Bool { reduceTransparencyOverride ?? environmentReduceTransparency }
    private var tint: Color { power.isChargingOnHold ? IslandSystemColor.orange : IslandSystemColor.green }
    private var scale: CGFloat {
        min(cardSize.width / LockedCardGeometry.preferredCardSize.width,
            cardSize.height / LockedCardGeometry.preferredCardSize.height)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LockedNowPlayingLayout.cornerRadius, style: .continuous)
        HStack(spacing: 22) {
            ZStack {
                IslandBatteryGlyph(
                    level: Double(power.percentage) / 100,
                    tint: tint,
                    width: 112,
                    animatesIn: true
                )
                Image(systemName: power.isChargingOnHold ? "pause.fill" : "bolt.fill")
                    .font(.system(size: 24, weight: .bold))
                    .contentTransition(NotchSymbolMotion.swap(reduceMotion: reduceMotion))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(x: -4)
                    .symbolEffect(.bounce, value: power.isCharging)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("\(power.percentage)%")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text(PowerChargeDescription.title(power))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                Text(PowerChargeDescription.detail(power))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.66))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 26)
        .frame(width: LockedCardGeometry.preferredCardSize.width, height: LockedCardGeometry.preferredCardSize.height)
        .background {
            if !reduceTransparency {
                // A wash of the charge colour pooled behind the battery.
                RadialGradient(
                    colors: [tint.opacity(0.42), tint.opacity(0.08), .clear],
                    center: UnitPoint(x: 0.28, y: 0.5),
                    startRadius: 4,
                    endRadius: 210
                )
                .clipShape(shape)
            }
        }
        .notchShotLockedNowPlayingSurface(
            cornerRadius: LockedNowPlayingLayout.cornerRadius,
            reduceTransparency: reduceTransparency
        )
        .shadow(color: tint.opacity(reduceTransparency ? 0 : 0.28), radius: 24, y: 8)
        .scaleEffect(scale)
        .frame(width: cardSize.width, height: cardSize.height)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PowerChargeDescription.title(power))
        .accessibilityValue("\(power.percentage) percent, \(PowerChargeDescription.detail(power))")
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
