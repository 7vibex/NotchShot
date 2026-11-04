import Foundation

/// Battery levels for a connected Bluetooth audio accessory.
///
/// Every value is optional and nothing is ever inferred: an accessory that
/// reports only a combined level shows one number, and one that reports nothing
/// shows none. Guessing "probably full" on a headset that never said so would
/// be worse than an empty card.
public struct AccessoryBattery: Sendable, Equatable, Codable {
    public var name: String
    public var left: Int?
    public var right: Int?
    public var enclosure: Int?
    public var single: Int?

    public init(
        name: String,
        left: Int? = nil,
        right: Int? = nil,
        enclosure: Int? = nil,
        single: Int? = nil
    ) {
        self.name = name
        self.left = left
        self.right = right
        self.enclosure = enclosure
        self.single = single
    }

    public var hasAnyLevel: Bool {
        left != nil || right != nil || enclosure != nil || single != nil
    }

    /// True when the accessory reports a charging case, which is what separates
    /// an in-ear pair from over-ear headphones for the artwork.
    public var hasCase: Bool { enclosure != nil }

    /// The lowest level it reports, for the compact strip where only one number
    /// fits — the one worth knowing is the one about to run out.
    public var lowestLevel: Int? {
        [left, right, enclosure, single].compactMap { $0 }.min()
    }

    /// SF Symbol for this accessory. Apple ships symbols for its own hardware,
    /// so the artwork is the system's rather than a drawing of someone else's
    /// product. Anything unrecognised falls back to plain headphones instead of
    /// claiming to be an Apple device.
    public var symbolName: String {
        let lowered = name.lowercased()
        if lowered.contains("airpods max") { return "airpodsmax" }
        if lowered.contains("airpods pro") { return "airpodspro.chargingcase.wireless.fill" }
        if lowered.contains("airpods") {
            if lowered.contains("4") { return "airpods.gen4" }
            if lowered.contains("3") { return "airpods.gen3.chargingcase.wireless.fill" }
            return "airpods.chargingcase.wireless.fill"
        }
        return hasCase ? "airpods.chargingcase.wireless.fill" : "headphones"
    }
}

/// Reads accessory battery levels from the system's own Bluetooth report.
///
/// `system_profiler` is the only public source for this on macOS — Core Audio
/// describes routes, not batteries, and `IOBluetoothDevice` exposes no battery
/// API. It costs a second or two, so it runs off the main actor and only when
/// something actually changed: a route switch, or the card being shown.
public actor BluetoothAccessoryBatteryService {
    public static let shared = BluetoothAccessoryBatteryService()

    private var cached: [String: AccessoryBattery] = [:]
    private var lastRead: Date?
    /// Long enough that opening the card repeatedly costs one read, short
    /// enough that a draining battery is not stale on screen.
    private let cacheLifetime: TimeInterval = 60
    private var lastFailedRead: Date?
    /// The read under way. A second caller waits for it rather than starting
    /// another report.
    private var inFlight: Task<Void, Never>?
    /// A failed or hung report is retried at most this often, so a wedged
    /// Bluetooth stack costs one bounded attempt per interval rather than a
    /// fresh process on every card open.
    private let failureRetryDelay: TimeInterval = 15

    public init() {}

    /// Levels for the accessory whose name best matches the audio route.
    public func battery(forRouteNamed routeName: String) async -> AccessoryBattery? {
        await refreshIfNeeded()
        return Self.match(routeName: routeName, in: cached)
    }

    private func refreshIfNeeded() async {
        if let lastRead, Date().timeIntervalSince(lastRead) < cacheLifetime { return }
        if let lastFailedRead, Date().timeIntervalSince(lastFailedRead) < failureRetryDelay {
            return
        }
        if let inFlight {
            await inFlight.value
            return
        }
        let read = Task { await self.read() }
        inFlight = read
        await read.value
    }

    private func read() async {
        defer { inFlight = nil }
        guard let data = await Self.runReport() else {
            lastFailedRead = Date()
            return
        }
        cached = Self.parse(data)
        lastRead = Date()
        lastFailedRead = nil
    }

    /// Names rarely match exactly — Core Audio says "Marius's AirPods" while
    /// Bluetooth may say "Marius’s AirPods" with a typographic apostrophe, or
    /// append a suffix. Compare on letters and digits only. Among containment
    /// matches the longest accessory name wins, so "AirPods" pairs with the
    /// most specific report rather than whichever one the dictionary emitted
    /// first.
    static func match(
        routeName: String,
        in accessories: [String: AccessoryBattery]
    ) -> AccessoryBattery? {
        let route = normalized(routeName)
        guard !route.isEmpty else { return nil }
        if let exact = accessories[route] { return exact }
        return accessories
            .filter { key, _ in key.contains(route) || route.contains(key) }
            .max { $0.key.count < $1.key.count }?
            .value
    }

    static func normalized(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// `system_profiler` normally answers in a second or two, but a wedged
    /// Bluetooth stack can hang it. The read races a hard timeout that
    /// terminates the process, then kills it if that didn't work, and the caller
    /// is released either way: a hung report costs five seconds once instead of
    /// forever. The read waits on its own thread, because one that never
    /// returned would otherwise hold a Swift concurrency thread with it.
    private static func runReport() async -> Data? {
        let report = ReportProcess()
        do {
            try report.process.run()
        } catch {
            Log.app.notice("Bluetooth battery report could not start")
            return nil
        }
        return await withCheckedContinuation { continuation in
            let result = ReportResult(continuation)
            let queue = DispatchQueue.global(qos: .utility)
            queue.async { result.resume(returning: report.read()) }
            queue.asyncAfter(deadline: .now() + Self.reportTimeout) {
                report.terminateIfRunning()
                result.resume(returning: nil)
                queue.asyncAfter(deadline: .now() + Self.killDelay) { report.killIfRunning() }
            }
        }
    }

    static let reportTimeout: TimeInterval = 5
    private static let killDelay: TimeInterval = 1

    /// Hands the first answer to the waiting caller and drops the other.
    private final class ReportResult: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data?, Never>?

        init(_ continuation: CheckedContinuation<Data?, Never>) {
            self.continuation = continuation
        }

        func resume(returning data: Data?) {
            lock.lock()
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(returning: data)
        }
    }

    /// `Process` is not `Sendable`, but this box only ever has one thread reading
    /// it to completion, and the timeout's conditional `terminate` and `kill`.
    private final class ReportProcess: @unchecked Sendable {
        let process = Process()
        let pipe = Pipe()

        init() {
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            process.arguments = ["SPBluetoothDataType", "-json"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
        }

        func read() -> Data? {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            // A wait that never returned would also hold up the timeout task:
            // the group still waits for this child.
            process.blockUntilExit()
            return data.isEmpty ? nil : data
        }

        func terminateIfRunning() {
            guard process.isRunning else { return }
            process.terminate()
        }

        func killIfRunning() {
            guard process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
    }

    /// The report nests connected devices several levels deep and has changed
    /// shape between macOS releases, so this walks the whole tree looking for
    /// dictionaries that carry battery keys rather than following a fixed path.
    static func parse(_ data: Data) -> [String: AccessoryBattery] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        var found: [String: AccessoryBattery] = [:]
        walk(root, into: &found)
        return found
    }

    private static func walk(_ node: Any, into found: inout [String: AccessoryBattery]) {
        if let dictionary = node as? [String: Any] {
            for (key, value) in dictionary {
                if let child = value as? [String: Any], let battery = battery(named: key, from: child) {
                    found[normalized(key)] = battery
                }
                walk(value, into: &found)
            }
        } else if let array = node as? [Any] {
            for element in array { walk(element, into: &found) }
        }
    }

    private static func battery(named name: String, from device: [String: Any]) -> AccessoryBattery? {
        let battery = AccessoryBattery(
            name: name,
            left: percent(device["device_batteryLevelLeft"]),
            right: percent(device["device_batteryLevelRight"]),
            enclosure: percent(device["device_batteryLevelCase"]),
            single: percent(device["device_batteryLevelMain"])
                ?? percent(device["device_batteryLevel"])
        )
        return battery.hasAnyLevel ? battery : nil
    }

    /// Values arrive as strings with a percent sign ("15%").
    static func percent(_ value: Any?) -> Int? {
        guard let text = value as? String else { return value as? Int }
        let digits = text.filter(\.isNumber)
        guard let parsed = Int(digits), (0 ... 100).contains(parsed) else { return nil }
        return parsed
    }
}
