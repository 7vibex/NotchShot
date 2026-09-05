import Foundation
import Observation
import UserNotifications

struct LockedMediaNotificationPayload: Equatable, Sendable {
    var title: String
    var subtitle: String
    var body: String
}

struct LockedMediaNotificationSettings: Sendable {
    var authorization: UNAuthorizationStatus
    var lockScreen: UNNotificationSetting
}

/// An isolated boundary for deterministic delivery tests. Creating a test
/// client never accesses the system notification center or asks for permission.
@MainActor
struct LockedMediaNotificationClient {
    var settings: @MainActor () async -> LockedMediaNotificationSettings
    var requestAuthorization: @MainActor () async throws -> Void
    var add: @MainActor (UNNotificationRequest) async throws -> Void
    var remove: @MainActor ([String]) -> Void

    static var live: Self {
        let center = UNUserNotificationCenter.current()
        return Self(
            settings: {
                let settings = await center.notificationSettings()
                return LockedMediaNotificationSettings(
                    authorization: settings.authorizationStatus,
                    lockScreen: settings.lockScreenSetting
                )
            },
            requestAuthorization: { _ = try await center.requestAuthorization(options: [.alert]) },
            add: { try await center.add($0) },
            remove: {
                center.removePendingNotificationRequests(withIdentifiers: $0)
                center.removeDeliveredNotifications(withIdentifiers: $0)
            }
        )
    }
}

/// Why the current song is, or is not, reaching the Lock Screen.
///
/// This exists because every failure here is invisible by design: macOS
/// silently drops a notification an app is not allowed to post, so without a
/// reported state the feature reads as broken code when it is usually one
/// switch in System Settings.
public enum LockedMediaNotificationReadiness: Sendable, Equatable {
    case unknown
    case ready
    case notRequested
    case denied
    case lockScreenDisabled

    public var title: String {
        switch self {
        case .unknown: "Checking…"
        case .ready: "Allowed"
        case .notRequested: "Not requested yet"
        case .denied: "Notifications denied"
        case .lockScreenDisabled: "Lock Screen notifications are off"
        }
    }

    public var needsAttention: Bool { self != .ready && self != .unknown }

    /// What the user has to do, in the place they have to do it.
    public var remedy: String? {
        switch self {
        case .unknown, .ready:
            nil
        case .notRequested:
            "Turn the setting off and on again to ask macOS for permission."
        case .denied:
            "Allow notifications for NotchShot in System Settings › Notifications."
        case .lockScreenDisabled:
            "Turn on “Show notifications on lock screen” for NotchShot, and allow previews when locked, in System Settings › Notifications."
        }
    }
}

enum LockedMediaNotificationPolicy {
    static let maximumFieldLength = 160

    static func payload(
        snapshot: MediaSnapshot,
        screenIsLocked: Bool,
        enabled: Bool,
        customPresentationIsAvailable: Bool = false
    ) -> LockedMediaNotificationPayload? {
        guard enabled,
              screenIsLocked,
              !customPresentationIsAvailable,
              snapshot.hasContent,
              snapshot.isPlaying else {
            return nil
        }

        let title = bounded(snapshot.title) ?? "Now Playing"
        let subtitle = bounded(snapshot.artist) ?? ""
        let source = bounded(snapshot.applicationName)
        return LockedMediaNotificationPayload(
            title: title,
            subtitle: subtitle,
            body: source.map { "Playing in \($0)" } ?? "Playing now"
        )
    }

    /// `notSupported` is not a refusal. macOS reports it for settings it does
    /// not model per app, and treating it as "disabled" silently suppressed
    /// every post — the app would look broken while System Settings showed
    /// nothing wrong. Only an explicit `disabled` stops delivery.
    static func readiness(
        authorization: UNAuthorizationStatus,
        lockScreen: UNNotificationSetting
    ) -> LockedMediaNotificationReadiness {
        switch authorization {
        case .notDetermined:
            return .notRequested
        case .denied:
            return .denied
        default:
            break
        }
        return lockScreen == .disabled ? .lockScreenDisabled : .ready
    }

    private static func bounded(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(maximumFieldLength))
    }
}

/// Routes opted-in Now Playing metadata through the only system-owned surface
/// macOS permits on its secure Lock Screen: a user notification.
@MainActor
@Observable
final class LockedMediaNotificationController {
    static let shared = LockedMediaNotificationController()

    private static let requestIdentifier = "notchshot.locked-media.now-playing"
    private static let metadataKey = "notchshot.locked-media"

    /// Last known answer from macOS, for the settings screen to show. Nothing
    /// else depends on it: delivery re-reads the live settings every time.
    private(set) var readiness: LockedMediaNotificationReadiness = .unknown

    @ObservationIgnored private let client: LockedMediaNotificationClient
    @ObservationIgnored private var generation: UInt = 0
    // Cache only bounded, opted-in metadata, never the artwork or full snapshot.
    @ObservationIgnored private var eligiblePayload: LockedMediaNotificationPayload?
    @ObservationIgnored private var lastPayload: LockedMediaNotificationPayload?
    @ObservationIgnored private var customPresentationIsAvailable = false
    @ObservationIgnored private(set) var deliveryTask: Task<Void, Never>?

    init(client: LockedMediaNotificationClient = .live) {
        self.client = client
    }

    func prepareIfNeeded(enabled: Bool) {
        guard enabled else {
            clear()
            readiness = .unknown
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let settings = await client.settings()
            guard settings.authorization == .notDetermined else {
                refresh(with: settings)
                return
            }
            do {
                try await client.requestAuthorization()
            } catch {
                Log.media.error("Lock Screen notification authorization failed: \(error.localizedDescription)")
            }
            await refreshReadiness()
        }
    }

    /// Re-reads what macOS currently allows. Cheap, and called whenever the
    /// user is in a position to look at the answer.
    func refreshReadiness() async {
        refresh(with: await client.settings())
    }

    private func refresh(with settings: LockedMediaNotificationSettings) {
        let updated = LockedMediaNotificationPolicy.readiness(
            authorization: settings.authorization,
            lockScreen: settings.lockScreen
        )
        // The raw pair matters when diagnosing: `notSupported` and `enabled`
        // both allow delivery, but only one of them means System Settings has
        // a switch the user can actually see.
        Log.media.debug(
            "Notification settings: authorization=\(settings.authorization.rawValue, privacy: .public), lockScreen=\(settings.lockScreen.rawValue, privacy: .public)"
        )
        guard updated != readiness else { return }
        readiness = updated
        // Logged as well as shown: this is the first thing to look at in a bug
        // report that says the song never appears on the Lock Screen.
        Log.media.notice("Lock Screen song delivery: \(updated.title, privacy: .public)")
    }

    func update(snapshot: MediaSnapshot, screenIsLocked: Bool, enabled: Bool) {
        eligiblePayload = LockedMediaNotificationPolicy.payload(
            snapshot: snapshot,
            screenIsLocked: screenIsLocked,
            enabled: enabled
        )
        if eligiblePayload == nil {
            // Withdrawal is as important to trace as delivery: a track that
            // stops reporting itself as playing pulls its own notification,
            // which from the Lock Screen is indistinguishable from never
            // having posted one.
            if screenIsLocked, enabled, lastPayload != nil {
                Log.media.notice(
                    "Withdrew the Lock Screen song: playing=\(snapshot.isPlaying, privacy: .public), hasContent=\(snapshot.hasContent, privacy: .public)"
                )
            }
        }
        reconcileDelivery()
    }

    private func reconcileDelivery() {
        let payload = customPresentationIsAvailable ? nil : eligiblePayload
        guard let payload else {
            if lastPayload != nil { generation &+= 1 }
            // Also remove requests left by a previous process, even when this
            // controller has not submitted anything in its own lifetime.
            removeNotification()
            return
        }
        // An identical observation must preserve an in-flight settings lookup
        // or submission, as well as deduplicating an already-delivered song.
        guard payload != lastPayload else { return }
        generation &+= 1
        lastPayload = payload
        startDeliveryIfNeeded()
    }

    private func startDeliveryIfNeeded() {
        guard deliveryTask == nil else { return }
        deliveryTask = Task { [weak self] in
            guard let self else { return }
            // Serialize submissions of the shared request identifier. If a
            // stale add completes after withdrawal, remove it before starting
            // the replacement, rather than accidentally removing a newer song.
            while !Task.isCancelled, let payload = lastPayload {
                let currentGeneration = generation
                await deliver(payload, generation: currentGeneration)
                if generation == currentGeneration { break }
            }
            deliveryTask = nil
            if Task.isCancelled, lastPayload != nil { startDeliveryIfNeeded() }
        }
    }

    /// The system notification is a fallback, not a second Now Playing card.
    /// Once the custom panel is confirmed in the Lock Screen Space, withdraw
    /// any already-submitted banner and suppress later observation ticks.
    func setCustomPresentationAvailable(_ available: Bool) {
        guard available != customPresentationIsAvailable else { return }
        customPresentationIsAvailable = available
        reconcileDelivery()
    }

    func clear() {
        eligiblePayload = nil
        generation &+= 1
        deliveryTask?.cancel()
        removeNotification()
    }

    private func removeNotification() {
        lastPayload = nil
        client.remove([Self.requestIdentifier])
    }

    private func deliver(_ payload: LockedMediaNotificationPayload, generation: UInt) async {
        let settings = await client.settings()
        guard self.generation == generation, !Task.isCancelled else { return }
        refresh(with: settings)
        guard readiness == .ready else {
            Log.media.notice("Lock Screen song not submitted: \(self.readiness.title)")
            lastPayload = nil
            return
        }

        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.subtitle = payload.subtitle
        content.body = payload.body
        content.threadIdentifier = Self.requestIdentifier
        content.userInfo = [Self.metadataKey: true]

        client.remove([Self.requestIdentifier])
        guard self.generation == generation else { return }
        do {
            try await client.add(UNNotificationRequest(
                identifier: Self.requestIdentifier,
                content: content,
                trigger: nil
            ))
            guard self.generation == generation, !Task.isCancelled else {
                client.remove([Self.requestIdentifier])
                return
            }
            Log.media.notice("Submitted current song to the system Lock Screen notification center")
        } catch {
            if self.generation == generation { lastPayload = nil }
            Log.media.error("Lock Screen song notification failed: \(error.localizedDescription)")
        }
    }
}
