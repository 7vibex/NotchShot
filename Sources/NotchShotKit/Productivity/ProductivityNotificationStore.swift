import Foundation
import Observation

public enum ProductivityNotificationPriority: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard
    case high

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standard: "Standard"
        case .high: "High priority"
        }
    }

    public var symbolName: String {
        switch self {
        case .standard: "bell"
        case .high: "exclamationmark.bubble"
        }
    }
}

public enum ProductivityNotificationState: String, Codable, Sendable {
    case scheduled
    case delivered
    case completed
    case dismissed

    public var title: String {
        switch self {
        case .scheduled: "Scheduled"
        case .delivered: "Active"
        case .completed: "Done"
        case .dismissed: "Dismissed"
        }
    }
}

public struct ProductivityNotificationItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var body: String
    public var priority: ProductivityNotificationPriority
    public var state: ProductivityNotificationState
    public var createdAt: Date
    public var scheduledAt: Date
    public var deliveredAt: Date?
    public var completedAt: Date?
    public var reply: String?

    public init(
        id: UUID = UUID(),
        title: String,
        body: String,
        priority: ProductivityNotificationPriority = .standard,
        state: ProductivityNotificationState = .scheduled,
        createdAt: Date = Date(),
        scheduledAt: Date = Date(),
        deliveredAt: Date? = nil,
        completedAt: Date? = nil,
        reply: String? = nil
    ) {
        self.id = id
        self.title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        self.body = String(body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        self.priority = priority
        self.state = state
        self.createdAt = createdAt
        self.scheduledAt = scheduledAt
        self.deliveredAt = deliveredAt
        self.completedAt = completedAt
        self.reply = reply.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000)) }
        if self.title.isEmpty { self.title = "NotchShot alert" }
    }

    public func isVisibleOnLockScreen(at date: Date = Date()) -> Bool {
        switch state {
        case .delivered:
            true
        case .scheduled:
            scheduledAt <= date
        case .completed, .dismissed:
            false
        }
    }
}

public enum ProductivityNotificationAction: Equatable, Sendable {
    case delivered(Date)
    case completed(Date)
    case dismissed(Date)
    case replied(String, Date)
}

public enum ProductivityNotificationReducer {
    public static func applying(
        _ action: ProductivityNotificationAction,
        to item: ProductivityNotificationItem
    ) -> ProductivityNotificationItem {
        var updated = item
        switch action {
        case .delivered(let date):
            guard item.state == .scheduled else { return item }
            updated.state = .delivered
            updated.deliveredAt = date
        case .completed(let date):
            updated.state = .completed
            updated.completedAt = date
        case .dismissed(let date):
            updated.state = .dismissed
            updated.completedAt = date
        case .replied(let reply, let date):
            let bounded = String(reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000))
            updated.reply = bounded.isEmpty ? nil : bounded
            updated.state = .completed
            updated.completedAt = date
        }
        return updated
    }
}

@MainActor
@Observable
public final class ProductivityNotificationStore {
    public static let shared = ProductivityNotificationStore()
    public static let maximumItemCount = 100
    public static let maximumStoreBytes = 2_000_000

    public private(set) var items: [ProductivityNotificationItem] = []
    public private(set) var lastError: String?
    public var onChange: (() -> Void)?

    private let storeURL: URL

    public init(storeURL: URL = AppPaths.support.appendingPathComponent("productivity-notifications.json")) {
        self.storeURL = storeURL
        load()
    }

    public var activeItems: [ProductivityNotificationItem] {
        items.filter { $0.state == .scheduled || $0.state == .delivered }
    }

    public func lockScreenItem(at date: Date = Date()) -> ProductivityNotificationItem? {
        items
            .filter { $0.isVisibleOnLockScreen(at: date) }
            .sorted {
                if $0.priority != $1.priority { return $0.priority == .high }
                return ($0.deliveredAt ?? $0.scheduledAt) > ($1.deliveredAt ?? $1.scheduledAt)
            }
            .first
    }

    @discardableResult
    public func recordScheduled(
        id: UUID,
        title: String,
        body: String,
        priority: ProductivityNotificationPriority,
        scheduledAt: Date,
        createdAt: Date = Date()
    ) -> ProductivityNotificationItem {
        let item = ProductivityNotificationItem(
            id: id,
            title: title,
            body: body,
            priority: priority,
            createdAt: createdAt,
            scheduledAt: scheduledAt
        )
        items.removeAll { $0.id == id }
        items.insert(item, at: 0)
        finishMutation()
        return item
    }

    public func apply(_ action: ProductivityNotificationAction, to id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index] = ProductivityNotificationReducer.applying(action, to: items[index])
        finishMutation()
    }

    public func remove(id: UUID) {
        items.removeAll { $0.id == id }
        finishMutation()
    }

    public func clearFinished() {
        items.removeAll { $0.state == .completed || $0.state == .dismissed }
        finishMutation()
    }

    public func reconcile(deliveredIDs: Set<UUID>, pendingIDs: Set<UUID>, now: Date = Date()) {
        var changed = false
        for index in items.indices where items[index].state == .scheduled {
            if deliveredIDs.contains(items[index].id) {
                items[index] = ProductivityNotificationReducer.applying(
                    .delivered(now),
                    to: items[index]
                )
                changed = true
            } else if items[index].scheduledAt <= now, !pendingIDs.contains(items[index].id) {
                // A due request that is no longer pending or delivered was
                // cleared in Notification Center or removed by the system.
                items[index] = ProductivityNotificationReducer.applying(
                    .dismissed(now),
                    to: items[index]
                )
                changed = true
            }
        }
        if changed { finishMutation() }
    }

    private func finishMutation() {
        items.sort { $0.createdAt > $1.createdAt }
        items = Array(items.prefix(Self.maximumItemCount))
        persist()
        onChange?()
    }

    private func load() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: storeURL.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size <= Self.maximumStoreBytes,
              let data = try? Data(contentsOf: storeURL) else { return }
        do {
            items = Array(
                try JSONDecoder().decode([ProductivityNotificationItem].self, from: data)
                    .sorted { $0.createdAt > $1.createdAt }
                    .prefix(Self.maximumItemCount)
            )
        } catch {
            lastError = "Notifications could not be loaded: \(error.localizedDescription)"
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(items)
            guard data.count <= Self.maximumStoreBytes else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try data.write(to: storeURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: storeURL.path
            )
            lastError = nil
        } catch {
            lastError = "Notifications could not be saved: \(error.localizedDescription)"
        }
    }
}
