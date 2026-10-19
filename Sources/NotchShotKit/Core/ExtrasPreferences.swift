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

    // MARK: Developer

    /// Pull requests waiting for the user's review, read through the GitHub
    /// CLI they are already signed in to.
    public var reviewQueueEnabled = false { didSet { write(reviewQueueEnabled, "reviewQueue") } }

    // MARK: Lock Screen

    /// A charging card in the locked activity stack while plugged in.
    public var showsChargingWhileLocked = true { didSet { write(showsChargingWhileLocked, "lockedCharging") } }

    // MARK: Keyboard

    /// A burst in the island when Caps Lock turns on or off.
    public var showsCapsLock = true { didSet { write(showsCapsLock, "capsLock") } }
    /// A burst with the new language when the keyboard input source changes.
    /// Only shown when more than one layout is enabled.
    public var showsInputSource = true { didSet { write(showsInputSource, "inputSource") } }

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
        reviewQueueEnabled = bool("reviewQueue", false)
        showsChargingWhileLocked = bool("lockedCharging", true)
        idleAnimationFileName = defaults.string(forKey: key("idleAnimation"))
        showsCapsLock = bool("capsLock", true)
        showsInputSource = bool("inputSource", true)
        showsDownloads = bool("downloads", true)
        controlsExternalDisplays = bool("externalDisplays", true)
    }

    private func key(_ name: String) -> String { "notchshot.extras.\(name)" }

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
