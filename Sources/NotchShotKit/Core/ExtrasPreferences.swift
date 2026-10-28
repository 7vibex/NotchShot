import Foundation
import Observation

/// Settings for the newer notch features — share links, notification
/// replies, Shortcuts, the app switcher, meeting controls, wellbeing, the
/// review queue, the Lock Screen charging card, the idle animation, keyboard
/// bursts, downloads and external displays —
/// kept out of `Preferences` so each feature's storage stays next to it.
///
/// Everything that reads the user's activity or talks to a network is off by
/// default, matching the rest of NotchShot.
@MainActor
@Observable
public final class ExtrasPreferences {
    public static let shared = ExtrasPreferences()

    @ObservationIgnored private let defaults: UserDefaults

    // MARK: Share links

    public var shareLink = ShareLinkConfiguration() {
        didSet { writeJSON(shareLink, "shareLink") }
    }
    /// Copy the link as soon as an upload finishes. Off would only upload.
    public var copiesShareLinkAfterUpload = true { didSet { write(copiesShareLinkAfterUpload, "shareLinkCopies") } }

    // MARK: Notifications

    /// A Reply button on mirrored banners that offer one. It opens the
    /// banner's own reply field through Accessibility, so the posting app
    /// still routes the message.
    public var notificationRepliesEnabled = true { didSet { write(notificationRepliesEnabled, "notificationReplies") } }
    /// A Copy button on mirrored banners that carry a one-time code. The code
    /// is read from the banner already on screen and is never stored.
    public var offersOneTimeCodes = true { didSet { write(offersOneTimeCodes, "oneTimeCodes") } }

    // MARK: Shortcuts and apps

    public static let maximumPinnedShortcuts = 6
    /// Names of the user's Shortcuts pinned to the More page, in order.
    public var pinnedShortcuts: [String] = [] { didSet { write(pinnedShortcuts, "pinnedShortcuts") } }
    public var showsAppSwitcher = true { didSet { write(showsAppSwitcher, "appSwitcher") } }

    // MARK: Meetings

    /// Mute and camera buttons on the call activity.
    public var meetingControlsEnabled = true { didSet { write(meetingControlsEnabled, "meetingControls") } }

    // MARK: Wellbeing

    public var showsDayProgress = true { didSet { write(showsDayProgress, "dayProgress") } }
    /// The working day the Today page measures, in whole hours.
    public var dayStartHour = 9 { didSet { write(dayStartHour, "dayStart") } }
    public var dayEndHour = 18 { didSet { write(dayEndHour, "dayEnd") } }
    /// The 20-20-20 reminder: every `eyeBreakIntervalMinutes` of continuous
    /// use, look 20 feet away for 20 seconds.
    public var eyeBreaksEnabled = false { didSet { write(eyeBreaksEnabled, "eyeBreaks") } }
    public var eyeBreakIntervalMinutes = 20 { didSet { write(eyeBreakIntervalMinutes, "eyeBreakInterval") } }
    /// Counts time per frontmost app, on this Mac only.
    public var screenTimeEnabled = false { didSet { write(screenTimeEnabled, "screenTime") } }
    /// Short nudges to blink, drink water and stand up, each after its own
    /// stretch of continuous use. The menu bar's Breaks switch.
    public var breakNudgesEnabled = false { didSet { write(breakNudgesEnabled, "breakNudges") } }
    public var blinkNudgeMinutes = 10 { didSet { write(blinkNudgeMinutes, "blinkNudge") } }
    public var waterNudgeMinutes = 45 { didSet { write(waterNudgeMinutes, "waterNudge") } }
    public var standNudgeMinutes = 60 { didSet { write(standNudgeMinutes, "standNudge") } }

    // MARK: Developer

    /// Pull requests waiting for the user's review, read through the GitHub
    /// CLI they are already signed in to.
    public var reviewQueueEnabled = false { didSet { write(reviewQueueEnabled, "reviewQueue") } }

    // MARK: Lock Screen

    /// A charging card in the locked activity stack while plugged in.
    public var showsChargingWhileLocked = true { didSet { write(showsChargingWhileLocked, "lockedCharging") } }
    /// A padlock that opens in the notch as the Mac unlocks.
    public var showsUnlockAnimation = true { didSet { write(showsUnlockAnimation, "unlockAnimation") } }

    // MARK: Keyboard

    /// A burst in the island when Caps Lock turns on or off.
    public var showsCapsLock = true { didSet { write(showsCapsLock, "capsLock") } }
    /// A burst with the new language when the keyboard input source changes.
    /// Only shown when more than one layout is enabled.
    public var showsInputSource = true { didSet { write(showsInputSource, "inputSource") } }

    // MARK: Network and accessories

    /// A burst when a VPN connects or disconnects. Only whether one is up is
    /// read, never which.
    public var showsVPNStatus = true { didSet { write(showsVPNStatus, "vpnStatus") } }
    /// The Wi-Fi bars sweeping, then filling, when the Mac joins Wi-Fi.
    public var showsWiFiJoin = true { didSet { write(showsWiFiJoin, "wifiJoin") } }
    /// A battery ring when a mouse, keyboard or trackpad connects, and a
    /// warning when one runs low.
    public var showsAccessoryBattery = true { didSet { write(showsAccessoryBattery, "accessoryBattery") } }

    // MARK: Music

    /// The cover's colour glowing softly behind it in the open player.
    public var showsArtworkGlow = true { didSet { write(showsArtworkGlow, "artworkGlow") } }
    /// The cover steps back and dims while paused, as the phone's player does.
    public var dimsArtworkWhenPaused = true { didSet { write(dimsArtworkWhenPaused, "dimPausedArtwork") } }
    /// The line being sung, in a small pill under the closed notch. Needs
    /// lyrics turned on.
    public var pinsLyricLine = false { didSet { write(pinsLyricLine, "pinnedLyric") } }
    /// The meter follows the music itself through a Core Audio tap on the
    /// player. Asks for "System Audio Recording" the first time.
    public var usesLiveAudioMeter = false { didSet { write(usesLiveAudioMeter, "liveAudioMeter") } }
    /// A "What's this song?" button in the open player that listens to the
    /// Mac's own sound and asks Shazam. Asks for "System Audio Recording".
    public var songRecognitionEnabled = true { didSet { write(songRecognitionEnabled, "songRecognition") } }
    /// A two-finger swipe across the closed player skips to the next or
    /// previous track when there is no other activity to swipe to.
    public var swipesBetweenTracks = true { didSet { write(swipesBetweenTracks, "swipeTracks") } }
    /// A soft sheen that follows the pointer across the open player's cover.
    public var showsArtworkGlare = true { didSet { write(showsArtworkGlare, "artworkGlare") } }

    // MARK: App volume

    /// Per-app volume sliders in the player's sound panel. Each app turned
    /// down is played through a Core Audio tap, which asks for "System Audio
    /// Recording" the first time; an app left at full volume is never tapped.
    public var appVolumesEnabled = false { didSet { write(appVolumesEnabled, "appVolumes") } }
    /// Bundle identifier → volume below 1, for apps the user turned down.
    public var appVolumes: [String: Double] = [:] { didSet { writeJSON(appVolumes, "appVolumeLevels") } }

    // MARK: Instant Replay

    /// Keeps the last `replaySeconds` of the screen in memory, so a shortcut
    /// can save what just happened. Nothing reaches the disk until it does.
    public var instantReplayEnabled = false { didSet { write(instantReplayEnabled, "instantReplay") } }
    public var replaySeconds = 30 { didSet { write(replaySeconds, "replaySeconds") } }
    public var replayIncludesSystemAudio = true { didSet { write(replayIncludesSystemAudio, "replayAudio") } }

    // MARK: Motion

    /// The closed notch stretches a few points toward the pointer over it.
    public var leansTowardPointer = true { didSet { write(leansTowardPointer, "pointerLean") } }

    // MARK: Downloads

    /// Browser downloads in the island. Safari, Chrome and other browsers
    /// publish each download's progress to the system; NotchShot only
    /// listens, and only to the Downloads folder.
    public var showsDownloads = true { didSet { write(showsDownloads, "downloads") } }

    // MARK: Displays

    /// The brightness keys and the Displays page control external monitors:
    /// through DDC when the monitor accepts it, by dimming the picture
    /// otherwise.
    public var controlsExternalDisplays = true { didSet { write(controlsExternalDisplays, "externalDisplays") } }

    // MARK: Idle notch

    /// A GIF or image shown beside the camera while the notch is idle and
    /// hovered. Stored as a copy in Application Support, so moving or
    /// deleting the original doesn't break it.
    public var idleAnimationFileName: String? { didSet { write(idleAnimationFileName, "idleAnimation") } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        shareLink = readJSON("shareLink") ?? ShareLinkConfiguration()
        copiesShareLinkAfterUpload = bool("shareLinkCopies", true)
        notificationRepliesEnabled = bool("notificationReplies", true)
        pinnedShortcuts = defaults.stringArray(forKey: key("pinnedShortcuts")) ?? []
        showsAppSwitcher = bool("appSwitcher", true)
        meetingControlsEnabled = bool("meetingControls", true)
        showsDayProgress = bool("dayProgress", true)
        dayStartHour = (defaults.object(forKey: key("dayStart")) as? Int).map { min(max($0, 0), 22) } ?? 9
        dayEndHour = (defaults.object(forKey: key("dayEnd")) as? Int).map { min(max($0, dayStartHour + 1), 24) } ?? 18
        eyeBreaksEnabled = bool("eyeBreaks", false)
        let interval = defaults.integer(forKey: key("eyeBreakInterval"))
        eyeBreakIntervalMinutes = interval > 0 ? min(max(interval, 5), 120) : 20
        screenTimeEnabled = bool("screenTime", false)
        breakNudgesEnabled = bool("breakNudges", false)
        blinkNudgeMinutes = minutes("blinkNudge", fallback: 10, in: 5 ... 60)
        waterNudgeMinutes = minutes("waterNudge", fallback: 45, in: 15 ... 180)
        standNudgeMinutes = minutes("standNudge", fallback: 60, in: 15 ... 180)
        offersOneTimeCodes = bool("oneTimeCodes", true)
        showsUnlockAnimation = bool("unlockAnimation", true)
        swipesBetweenTracks = bool("swipeTracks", true)
        showsArtworkGlare = bool("artworkGlare", true)
        appVolumesEnabled = bool("appVolumes", false)
        appVolumes = (readJSON("appVolumeLevels") as [String: Double]?)?
            .compactMapValues { $0.isFinite && $0 >= 0 && $0 < 1 ? $0 : nil } ?? [:]
        instantReplayEnabled = bool("instantReplay", false)
        let replay = defaults.integer(forKey: key("replaySeconds"))
        replaySeconds = Self.replayDurations.contains(replay) ? replay : 30
        replayIncludesSystemAudio = bool("replayAudio", true)
        leansTowardPointer = bool("pointerLean", true)
        reviewQueueEnabled = bool("reviewQueue", false)
        showsChargingWhileLocked = bool("lockedCharging", true)
        idleAnimationFileName = defaults.string(forKey: key("idleAnimation"))
        showsCapsLock = bool("capsLock", true)
        showsInputSource = bool("inputSource", true)
        showsDownloads = bool("downloads", true)
        showsArtworkGlow = bool("artworkGlow", true)
        dimsArtworkWhenPaused = bool("dimPausedArtwork", true)
        pinsLyricLine = bool("pinnedLyric", false)
        usesLiveAudioMeter = bool("liveAudioMeter", false)
        songRecognitionEnabled = bool("songRecognition", true)
        showsVPNStatus = bool("vpnStatus", true)
        showsWiFiJoin = bool("wifiJoin", true)
        showsAccessoryBattery = bool("accessoryBattery", true)
        controlsExternalDisplays = bool("externalDisplays", true)
    }

    /// The lengths Instant Replay offers, in seconds.
    public static let replayDurations = [15, 30, 60, 120]

    private func key(_ name: String) -> String { "notchshot.extras.\(name)" }

    private func minutes(_ name: String, fallback: Int, in range: ClosedRange<Int>) -> Int {
        let stored = defaults.integer(forKey: key(name))
        return stored > 0 ? min(max(stored, range.lowerBound), range.upperBound) : fallback
    }

    private func bool(_ name: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key(name)) as? Bool ?? fallback
    }

    private func write(_ value: Any?, _ name: String) {
        if let value { defaults.set(value, forKey: key(name)) } else { defaults.removeObject(forKey: key(name)) }
    }

    private func writeJSON<T: Encodable>(_ value: T, _ name: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key(name))
    }

    private func readJSON<T: Decodable>(_ name: String) -> T? {
        defaults.data(forKey: key(name)).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
