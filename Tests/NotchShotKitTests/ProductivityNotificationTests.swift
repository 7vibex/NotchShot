import Foundation
import Testing
@testable import NotchShotKit

@Suite("Productivity notifications")
struct ProductivityNotificationTests {
    @Test("Notification actions preserve a bounded local reply")
    func notificationReducer() {
        let item = ProductivityNotificationItem(
            title: "Build finished",
            body: "Review the result",
            priority: .high
        )
        let delivered = ProductivityNotificationReducer.applying(
            .delivered(Date(timeIntervalSince1970: 10)),
            to: item
        )
        #expect(delivered.state == .delivered)
        #expect(delivered.deliveredAt == Date(timeIntervalSince1970: 10))

        let replied = ProductivityNotificationReducer.applying(
            .replied(String(repeating: "a", count: 3_000), Date(timeIntervalSince1970: 20)),
            to: delivered
        )
        #expect(replied.state == .completed)
        #expect(replied.reply?.count == 2_000)
        #expect(replied.completedAt == Date(timeIntervalSince1970: 20))
    }

    @Test("Only due active alerts are eligible for the locked activity stack")
    @MainActor
    func lockedAlertSelection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-notifications-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("items.json")
        let store = ProductivityNotificationStore(storeURL: url)
        let now = Date(timeIntervalSince1970: 1_000)

        let future = UUID()
        store.recordScheduled(
            id: future,
            title: "Later",
            body: "Not due",
            priority: .high,
            scheduledAt: now.addingTimeInterval(60),
            createdAt: now
        )
        #expect(store.lockScreenItem(at: now) == nil)

        let due = UUID()
        store.recordScheduled(
            id: due,
            title: "Due",
            body: "Visible",
            priority: .standard,
            scheduledAt: now.addingTimeInterval(-1),
            createdAt: now.addingTimeInterval(1)
        )
        #expect(store.lockScreenItem(at: now)?.id == due)

        store.apply(.completed(now), to: due)
        #expect(store.lockScreenItem(at: now) == nil)
    }

    @Test("Notification inbox persists state with private file permissions")
    @MainActor
    func persistenceAndPermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-notifications-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("items.json")
        let id = UUID()

        let first = ProductivityNotificationStore(storeURL: url)
        first.recordScheduled(
            id: id,
            title: "Local alert",
            body: "Owned by NotchShot",
            priority: .high,
            scheduledAt: Date(timeIntervalSince1970: 100)
        )
        first.apply(.replied("Handled", Date(timeIntervalSince1970: 110)), to: id)

        let reloaded = ProductivityNotificationStore(storeURL: url)
        #expect(reloaded.items.count == 1)
        #expect(reloaded.items[0].id == id)
        #expect(reloaded.items[0].reply == "Handled")
        #expect(reloaded.items[0].state == .completed)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("Reconciliation distinguishes delivered, pending, and cleared requests")
    @MainActor
    func reconciliation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-notifications-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProductivityNotificationStore(storeURL: root.appendingPathComponent("items.json"))
        let now = Date(timeIntervalSince1970: 1_000)
        let delivered = UUID()
        let pending = UUID()
        let cleared = UUID()

        for id in [delivered, pending, cleared] {
            store.recordScheduled(
                id: id,
                title: id.uuidString,
                body: "",
                priority: .standard,
                scheduledAt: now.addingTimeInterval(-10),
                createdAt: now
            )
        }
        store.reconcile(deliveredIDs: [delivered], pendingIDs: [pending], now: now)

        #expect(store.items.first(where: { $0.id == delivered })?.state == .delivered)
        #expect(store.items.first(where: { $0.id == pending })?.state == .scheduled)
        #expect(store.items.first(where: { $0.id == cleared })?.state == .dismissed)
    }
}
