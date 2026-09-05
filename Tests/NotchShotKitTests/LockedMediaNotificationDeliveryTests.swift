import Foundation
import Testing
import UserNotifications
@testable import NotchShotKit

@Suite("Lock Screen media notification delivery")
@MainActor
struct LockedMediaNotificationDeliveryTests {
    private func song(_ title: String = "Synthetic song") -> MediaSnapshot {
        MediaSnapshot(source: .mediaRemote, applicationName: "Synthetic player",
                      title: title, artist: "Synthetic artist", isPlaying: true)
    }

    @Test("An identical observation preserves the pending settings lookup")
    func duplicateWhileSettingsPending() async {
        let center = NotificationClientFixture()
        center.holdSettings = true
        let controller = LockedMediaNotificationController(client: center.client)
        controller.update(snapshot: song(), screenIsLocked: true, enabled: true)
        await center.settingsCalls.wait(until: 1)
        controller.update(snapshot: song(), screenIsLocked: true, enabled: true)
        center.holdSettings = false
        center.finishSettings()
        await controller.deliveryTask?.value

        #expect(center.addedTitles == ["Synthetic song"])
        #expect(center.settingsCalls.count == 1)
        controller.update(snapshot: song(), screenIsLocked: true, enabled: true)
        #expect(controller.deliveryTask == nil)
        #expect(center.authorizationRequests == 0)
    }

    @Test("Custom presentation loss replays the latest eligible song without a media change")
    func customPresentationLoss() async {
        let center = NotificationClientFixture()
        let controller = LockedMediaNotificationController(client: center.client)
        controller.setCustomPresentationAvailable(true)
        controller.update(snapshot: song("First"), screenIsLocked: true, enabled: true)
        controller.update(snapshot: song("Latest"), screenIsLocked: true, enabled: true)
        #expect(center.addedTitles.isEmpty)

        controller.setCustomPresentationAvailable(false)
        await controller.deliveryTask?.value
        #expect(center.addedTitles == ["Latest"])
        controller.setCustomPresentationAvailable(false)
        #expect(controller.deliveryTask == nil)
        controller.setCustomPresentationAvailable(true)
        #expect(center.deliveredTitles.isEmpty)
        #expect(center.authorizationRequests == 0)
    }

    @Test("Clear discards cached metadata so custom-panel teardown cannot replay it")
    func clearPreventsReplay() async {
        let center = NotificationClientFixture()
        let controller = LockedMediaNotificationController(client: center.client)
        controller.setCustomPresentationAvailable(true)
        controller.update(snapshot: song(), screenIsLocked: true, enabled: true)
        controller.clear()
        controller.setCustomPresentationAvailable(false)
        #expect(controller.deliveryTask == nil)
        #expect(center.settingsCalls.count == 0)
        #expect(center.addedTitles.isEmpty)
    }

    @Test("Clear invalidates a pending settings lookup before it can submit metadata")
    func clearWhileSettingsPending() async {
        let center = NotificationClientFixture()
        center.holdSettings = true
        let controller = LockedMediaNotificationController(client: center.client)
        controller.update(snapshot: song(), screenIsLocked: true, enabled: true)
        await center.settingsCalls.wait(until: 1)
        let pending = controller.deliveryTask
        controller.clear()
        #expect(pending?.isCancelled == true)
        center.finishSettings()
        await pending?.value
        #expect(center.addedTitles.isEmpty)
        #expect(center.deliveredTitles.isEmpty)
    }

    @Test("Changed metadata supersedes the payload waiting for settings")
    func changedPayloadSupersedesPending() async {
        let center = NotificationClientFixture()
        center.holdSettings = true
        let controller = LockedMediaNotificationController(client: center.client)
        controller.update(snapshot: song("Old"), screenIsLocked: true, enabled: true)
        await center.settingsCalls.wait(until: 1)
        controller.update(snapshot: song("New"), screenIsLocked: true, enabled: true)
        center.holdSettings = false
        center.finishSettings()
        await controller.deliveryTask?.value
        #expect(center.addedTitles == ["New"])
        #expect(center.deliveredTitles == ["New"])
        #expect(center.settingsCalls.count == 2)
    }

    @Test("An identical observation does not invalidate a submission already in progress")
    func duplicateWhileAdding() async {
        let center = NotificationClientFixture()
        center.holdAdds = true
        let controller = LockedMediaNotificationController(client: center.client)
        controller.update(snapshot: song(), screenIsLocked: true, enabled: true)
        await center.addCalls.wait(until: 1)
        controller.update(snapshot: song(), screenIsLocked: true, enabled: true)
        center.finishAdd()
        await controller.deliveryTask?.value
        #expect(center.addedTitles == ["Synthetic song"])
        #expect(center.deliveredTitles == ["Synthetic song"])
    }

    @Test("A late submission is removed after clear")
    func clearWhileAdding() async {
        let center = NotificationClientFixture()
        center.holdAdds = true
        let controller = LockedMediaNotificationController(client: center.client)
        controller.update(snapshot: song(), screenIsLocked: true, enabled: true)
        await center.addCalls.wait(until: 1)
        let pending = controller.deliveryTask
        controller.clear()
        center.finishAdd()
        await pending?.value
        #expect(center.deliveredTitles.isEmpty)
        controller.setCustomPresentationAvailable(true)
        controller.setCustomPresentationAvailable(false)
        #expect(controller.deliveryTask == nil)
    }

    @Test("A stale completed submission cannot remove its newer replacement")
    func serializedReplacement() async {
        let center = NotificationClientFixture()
        center.holdAdds = true
        let controller = LockedMediaNotificationController(client: center.client)
        controller.update(snapshot: song("Old"), screenIsLocked: true, enabled: true)
        await center.addCalls.wait(until: 1)
        controller.update(snapshot: song("New"), screenIsLocked: true, enabled: true)
        center.holdAdds = false
        center.finishAdd()
        await controller.deliveryTask?.value
        #expect(center.addedTitles == ["Old", "New"])
        #expect(center.deliveredTitles == ["New"])
    }

    @Test("Denied settings and failed submissions do not permanently poison deduplication")
    func retriesAfterFailure() async {
        let center = NotificationClientFixture()
        center.settingsValue.authorization = .denied
        let controller = LockedMediaNotificationController(client: center.client)
        controller.update(snapshot: song(), screenIsLocked: true, enabled: true)
        await controller.deliveryTask?.value
        #expect(center.addedTitles.isEmpty)

        center.settingsValue.authorization = .authorized
        center.failNextAdd = true
        controller.update(snapshot: song(), screenIsLocked: true, enabled: true)
        await controller.deliveryTask?.value
        #expect(center.deliveredTitles.isEmpty)

        controller.update(snapshot: song(), screenIsLocked: true, enabled: true)
        await controller.deliveryTask?.value
        #expect(center.deliveredTitles == ["Synthetic song"])
        #expect(center.authorizationRequests == 0)
    }

    @Test("Unlocked, disabled, and paused updates discard cached fallback eligibility")
    func privacyFiltersRemainEffective() async {
        let center = NotificationClientFixture()
        let controller = LockedMediaNotificationController(client: center.client)
        for state in 0..<3 {
            controller.setCustomPresentationAvailable(true)
            controller.update(snapshot: song(), screenIsLocked: true, enabled: true)
            var snapshot = song()
            if state == 2 { snapshot.isPlaying = false }
            controller.update(snapshot: snapshot, screenIsLocked: state != 0, enabled: state != 1)
            controller.setCustomPresentationAvailable(false)
            #expect(controller.deliveryTask == nil)
        }
        #expect(center.addedTitles.isEmpty)
        #expect(center.authorizationRequests == 0)
    }
}

@MainActor
private final class NotificationClientFixture {
    var settingsValue = LockedMediaNotificationSettings(authorization: .authorized, lockScreen: .enabled)
    var holdSettings = false
    var holdAdds = false
    var failNextAdd = false
    var authorizationRequests = 0
    var addedTitles: [String] = []
    var deliveredTitles: [String] = []
    let settingsCalls = CallGate()
    let addCalls = CallGate()
    private var pendingSettings: [CheckedContinuation<LockedMediaNotificationSettings, Never>] = []
    private var pendingAdds: [CheckedContinuation<Void, Never>] = []

    var client: LockedMediaNotificationClient {
        LockedMediaNotificationClient(
            settings: { await self.readSettings() },
            requestAuthorization: { self.authorizationRequests += 1 },
            add: { try await self.add($0) },
            remove: { _ in self.deliveredTitles.removeAll() }
        )
    }

    private func readSettings() async -> LockedMediaNotificationSettings {
        if holdSettings {
            return await withCheckedContinuation { continuation in
                pendingSettings.append(continuation)
                settingsCalls.signal()
            }
        }
        settingsCalls.signal()
        return settingsValue
    }

    func finishSettings() {
        pendingSettings.removeFirst().resume(returning: settingsValue)
    }

    private func add(_ request: UNNotificationRequest) async throws {
        addedTitles.append(request.content.title)
        if holdAdds {
            await withCheckedContinuation { continuation in
                pendingAdds.append(continuation)
                addCalls.signal()
            }
        } else {
            addCalls.signal()
        }
        if failNextAdd {
            failNextAdd = false
            throw CocoaError(.fileWriteUnknown)
        }
        deliveredTitles = [request.content.title]
    }

    func finishAdd() {
        pendingAdds.removeFirst().resume()
    }
}

@MainActor
private final class CallGate {
    private(set) var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func signal() {
        count += 1
        let ready = waiters.filter { $0.0 <= count }
        waiters.removeAll { $0.0 <= count }
        for (_, continuation) in ready { continuation.resume() }
    }

    func wait(until target: Int) async {
        guard count < target else { return }
        await withCheckedContinuation { waiters.append((target, $0)) }
    }
}
