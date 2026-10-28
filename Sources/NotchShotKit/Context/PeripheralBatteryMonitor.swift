import Foundation
import IOKit

/// One battery-powered input device as the HID driver reports it.
struct PeripheralBatteryReading: Sendable, Equatable {
    var registryID: UInt64
    var name: String
    var percent: Int

    var kind: PeripheralKind { PeripheralKind(productName: name) }
}

enum PeripheralKind: Equatable {
    case mouse
    case trackpad
    case keyboard
    case other

    /// Apple's own product names say what they are ("Magic Mouse",
    /// "Magic Trackpad", "Magic Keyboard with Touch ID"), and most others
    /// follow the same pattern.
    init(productName: String) {
        let name = productName.lowercased()
        if name.contains("trackpad") { self = .trackpad }
        else if name.contains("mouse") { self = .mouse }
        else if name.contains("keyboard") { self = .keyboard }
        else { self = .other }
    }

    var symbolName: String {
        switch self {
        case .mouse: "magicmouse.fill"
        case .trackpad: "rectangle.and.hand.point.up.left.fill"
        case .keyboard: "keyboard.fill"
        case .other: "gamecontroller.fill"
        }
    }
}

/// When a peripheral is worth a burst: on connecting, and on crossing each
/// low threshold once on the way down.
enum PeripheralBatteryPolicy {
    /// macOS warns at 10%; the second step catches the last few minutes.
    static let lowThresholds = [10, 5]

    static func connectedEvent(_ reading: PeripheralBatteryReading) -> IslandTransientEvent {
        IslandTransientEvent(
            kind: .accessory,
            severity: reading.percent <= lowThresholds[0] ? .warning : .informational,
            coalescingKey: "accessory-\(reading.registryID)",
            symbolName: reading.kind.symbolName,
            title: "Connected",
            detail: reading.name,
            level: Double(reading.percent) / 100,
            holdDuration: 2.4
        )
    }

    /// The lowest threshold `current` has newly fallen to or below, if any.
    static func crossedThreshold(previous: Int, current: Int) -> Int? {
        lowThresholds.filter { current <= $0 && previous > $0 }.min()
    }

    static func lowEvent(_ reading: PeripheralBatteryReading) -> IslandTransientEvent {
        IslandTransientEvent(
            kind: .accessory,
            severity: .warning,
            coalescingKey: "accessory-\(reading.registryID)",
            symbolName: reading.kind.symbolName,
            title: "\(reading.percent)% Left",
            detail: reading.name,
            level: Double(reading.percent) / 100,
            holdDuration: 4
        )
    }
}

/// Watches Bluetooth mice, keyboards and trackpads for connections and low
/// charge, through the battery level their HID driver publishes in the I/O
/// Registry. Nothing is paired, opened or polled faster than every few
/// minutes, and the built-in keyboard and trackpad, which report no battery,
/// are never shown.
@MainActor
final class PeripheralBatteryMonitor {
    var onEvent: ((IslandTransientEvent) -> Void)?

    static let serviceClass = "AppleDeviceManagementHIDEventService"
    /// A charge level changes by a percent every several minutes at most.
    static let pollInterval: Duration = .seconds(300)
    /// The battery property is published a moment after the device appears.
    static let connectSettle: Duration = .seconds(2)

    private var port: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var lastPercent: [UInt64: Int] = [:]
    private var pollTask: Task<Void, Never>?
    private var isPrimed = false

    func start() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let monitor = Unmanaged<PeripheralBatteryMonitor>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.devicesAppeared(iterator) }
        }
        IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            IOServiceMatching(Self.serviceClass),
            callback,
            context,
            &addedIterator
        )
        // Draining the iterator arms the notification. Devices already
        // connected at launch are recorded, not announced.
        devicesAppeared(addedIterator)
        isPrimed = true
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { return }
                self?.poll()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        if addedIterator != 0 {
            IOObjectRelease(addedIterator)
            addedIterator = 0
        }
        if let port {
            IONotificationPortDestroy(port)
        }
        port = nil
        lastPercent = [:]
        isPrimed = false
    }

    private func devicesAppeared(_ iterator: io_iterator_t) {
        var ids: [UInt64] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &id)
            ids.append(id)
            if let reading = Self.reading(service) {
                lastPercent[reading.registryID] = reading.percent
                if isPrimed { onEvent?(PeripheralBatteryPolicy.connectedEvent(reading)) }
            }
            IOObjectRelease(service)
        }
        guard isPrimed else { return }
        // Devices whose battery wasn't published yet get one more look.
        let pending = ids.filter { lastPercent[$0] == nil }
        guard !pending.isEmpty else { return }
        Task { [weak self] in
            try? await Task.sleep(for: Self.connectSettle)
            guard let self, self.port != nil else { return }
            for reading in Self.readAll() where pending.contains(reading.registryID) {
                guard self.lastPercent[reading.registryID] == nil else { continue }
                self.lastPercent[reading.registryID] = reading.percent
                self.onEvent?(PeripheralBatteryPolicy.connectedEvent(reading))
            }
        }
    }

    private func poll() {
        let readings = Self.readAll()
        var seen: [UInt64: Int] = [:]
        for reading in readings {
            seen[reading.registryID] = reading.percent
            if let previous = lastPercent[reading.registryID],
               PeripheralBatteryPolicy.crossedThreshold(previous: previous, current: reading.percent) != nil {
                onEvent?(PeripheralBatteryPolicy.lowEvent(reading))
            }
        }
        // Disconnected devices drop out, so reconnecting announces again.
        lastPercent = seen
    }

    static func readAll() -> [PeripheralBatteryReading] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(serviceClass), &iterator)
            == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var readings: [PeripheralBatteryReading] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            if let reading = reading(service) { readings.append(reading) }
            IOObjectRelease(service)
        }
        return readings
    }

    private static func reading(_ service: io_object_t) -> PeripheralBatteryReading? {
        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue()
        }
        guard let percent = property("BatteryPercent") as? Int, (0...100).contains(percent) else { return nil }
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &id)
        let name = (property("Product") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Accessory"
        return PeripheralBatteryReading(registryID: id, name: name, percent: percent)
    }
}
