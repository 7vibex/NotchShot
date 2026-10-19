import AppKit
import CoreGraphics
import Foundation
import IOKit
import Observation

/// How NotchShot changes one display's brightness.
public enum DisplayBrightnessMethod: String, Sendable, Equatable {
    /// Apple's own displays, through the same DisplayServices call the
    /// built-in screen uses.
    case native
    /// The monitor's backlight, over DDC/CI.
    case hardware
    /// The picture is dimmed through the display's gamma table. Works on
    /// every monitor, but the backlight stays as bright as before.
    case software

    public var title: String {
        switch self {
        case .native: "Built-in control"
        case .hardware: "Monitor backlight (DDC)"
        case .software: "Dimmed picture"
        }
    }
}

public struct ControlledDisplay: Identifiable, Sendable, Equatable {
    public var id: CGDirectDisplayID
    public var name: String
    public var isBuiltIn: Bool
    public var method: DisplayBrightnessMethod
    /// 0…1.
    public var level: Double
}

/// Brightness for every connected display, external monitors included.
///
/// macOS can only dim Apple's own displays. Most other monitors accept the
/// VESA DDC/CI "set brightness" command over the video cable, which is what
/// this tries first; monitors that refuse it — DDC switched off in the
/// monitor's menu, or a dock or adapter that drops the signal — get the
/// picture dimmed instead. DDC talks to slow hardware, so every read and
/// write runs on a private queue and only the latest requested level is
/// sent.
@MainActor
@Observable
public final class DisplayBrightnessController {
    public static let shared = DisplayBrightnessController()

    public private(set) var displays: [ControlledDisplay] = []
    public private(set) var isRefreshing = false

    @ObservationIgnored private let ddc = DDCQueue()
    @ObservationIgnored private let dimmer = GammaDimmer()
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private let defaults = UserDefaults.standard
    private static let storedLevelsKey = "notchshot.extras.displayDimLevels"

    private init() {}

    /// Starts following display changes and restores saved dimming.
    public func start() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // macOS resets gamma tables on wake, which would silently undo dimming.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reapplyDimming() }
        }
        refresh()
    }

    /// Stops following changes and gives every dimmed display its picture back.
    public func stop() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        screenObserver = nil
        wakeObserver = nil
        dimmer.restoreAll()
        displays = []
    }

    public var isRunning: Bool { screenObserver != nil }

    /// Re-lists displays and asks each external one whether it speaks DDC.
    public func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        let online = Self.onlineDisplays()
        let stored = storedLevels()
        var listed: [ControlledDisplay] = []
        var probe: [CGDirectDisplayID] = []
        for id in online {
            let isBuiltIn = CGDisplayIsBuiltin(id) != 0
            if let level = BrightnessReader.shared.level(displayID: id) {
                listed.append(ControlledDisplay(id: id, name: Self.name(of: id), isBuiltIn: isBuiltIn, method: .native, level: level))
            } else if !isBuiltIn {
                let level = stored[Self.storageKey(for: id)] ?? 1
                listed.append(ControlledDisplay(id: id, name: Self.name(of: id), isBuiltIn: false, method: .software, level: level))
                probe.append(id)
            }
        }
        dimmer.forget(except: Set(online))
        // The built-in screen first, then externals by name, so the order
        // stays put as monitors come and go.
        displays = listed.sorted {
            $0.isBuiltIn != $1.isBuiltIn ? $0.isBuiltIn : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        reapplyDimming()
        guard !probe.isEmpty else { return }
        isRefreshing = true
        let identities = probe.map { DDCDisplayIdentity(displayID: $0) }
        ddc.probe(identities) { [weak self] results in
            Task { @MainActor in
                guard let self, generation == self.refreshGeneration else { return }
                self.isRefreshing = false
                for (id, level) in results {
                    guard let index = self.displays.firstIndex(where: { $0.id == id }) else { continue }
                    self.dimmer.restore(id)
                    self.displays[index].method = .hardware
                    self.displays[index].level = level
                }
            }
        }
    }

    public func display(_ id: CGDirectDisplayID) -> ControlledDisplay? {
        displays.first { $0.id == id }
    }

    /// Sets a level from a slider or a key press. Returns the level applied.
    @discardableResult
    public func setLevel(_ level: Double, for id: CGDirectDisplayID) -> Double? {
        guard let index = displays.firstIndex(where: { $0.id == id }) else { return nil }
        let clamped = min(max(level, 0), 1)
        switch displays[index].method {
        case .native:
            guard BrightnessReader.shared.setBrightness(clamped, displayID: id) else { return nil }
        case .hardware:
            ddc.write(level: clamped, to: id)
        case .software:
            guard dimmer.apply(level: clamped, to: id) else { return nil }
            var stored = storedLevels()
            stored[Self.storageKey(for: id)] = clamped < 1 ? clamped : nil
            defaults.set(stored, forKey: Self.storedLevelsKey)
        }
        displays[index].level = clamped
        return clamped
    }

    /// One brightness-key step on an external display. `nil` when NotchShot
    /// does not control that display, so the key can go to macOS untouched.
    public func step(_ id: CGDirectDisplayID, increasing: Bool, fine: Bool) -> Double? {
        guard let display = display(id), !display.isBuiltIn else { return nil }
        let target = SystemMediaKeyAction.adjustedLevel(current: display.level, increasing: increasing, fine: fine)
        return setLevel(target, for: id)
    }

    /// The display under the pointer: the one a brightness key is meant for.
    public static func displayUnderPointer() -> CGDirectDisplayID? {
        let location = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
        return (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    // MARK: Internals

    private func reapplyDimming() {
        for display in displays where display.method == .software && display.level < 1 {
            _ = dimmer.apply(level: display.level, to: display.id)
        }
    }

    private func storedLevels() -> [String: Double] {
        defaults.dictionary(forKey: Self.storedLevelsKey) as? [String: Double] ?? [:]
    }

    /// Display IDs change between boots; vendor, model and serial do not.
    static func storageKey(for id: CGDirectDisplayID) -> String {
        "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
    }

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        // Mirrored secondaries share the primary's picture; listing both
        // would show two sliders fighting over one screen.
        return ids.prefix(Int(count)).filter { CGDisplayIsActive($0) != 0 && CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
    }

    private static func name(of id: CGDirectDisplayID) -> String {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
        return screen?.localizedName ?? (CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display")
    }
}

// MARK: - Software dimming

/// Dims a display by scaling its gamma table. The original table is captured
/// the first time a display is dimmed and written back on restore, so a
/// calibrated profile survives.
@MainActor
final class GammaDimmer {
    /// The darkest the picture goes. Lower than this and the screen reads as
    /// off, which is a frightening way to discover a brightness key.
    static let minimumScale: Float = 0.12

    private struct Table {
        var red: [CGGammaValue]
        var green: [CGGammaValue]
        var blue: [CGGammaValue]
    }

    private var originals: [CGDirectDisplayID: Table] = [:]

    static func scale(for level: Double) -> Float {
        let clamped = Float(min(max(level, 0), 1))
        return minimumScale + (1 - minimumScale) * clamped
    }

    func apply(level: Double, to id: CGDirectDisplayID) -> Bool {
        if level >= 1 {
            restore(id)
            return true
        }
        guard let original = originals[id] ?? capture(id) else { return false }
        originals[id] = original
        let scale = Self.scale(for: level)
        var red = original.red.map { $0 * scale }
        var green = original.green.map { $0 * scale }
        var blue = original.blue.map { $0 * scale }
        return CGSetDisplayTransferByTable(id, UInt32(red.count), &red, &green, &blue) == .success
    }

    func restore(_ id: CGDirectDisplayID) {
        guard var original = originals.removeValue(forKey: id) else { return }
        _ = CGSetDisplayTransferByTable(id, UInt32(original.red.count), &original.red, &original.green, &original.blue)
    }

    func restoreAll() {
        for id in Array(originals.keys) { restore(id) }
    }

    /// Drops tables for displays that went away; their gamma went with them.
    func forget(except online: Set<CGDirectDisplayID>) {
        originals = originals.filter { online.contains($0.key) }
    }

    private func capture(_ id: CGDirectDisplayID) -> Table? {
        let capacity = CGDisplayGammaTableCapacity(id)
        guard capacity > 0 else { return nil }
        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = red
        var blue = red
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, capacity, &red, &green, &blue, &count) == .success, count > 0 else {
            return nil
        }
        let n = Int(count)
        return Table(red: Array(red.prefix(n)), green: Array(green.prefix(n)), blue: Array(blue.prefix(n)))
    }
}

// MARK: - DDC/CI

/// What a display reports about itself, used to pair a `CGDirectDisplayID`
/// with its video link in the I/O Registry.
struct DDCDisplayIdentity: Sendable, Equatable {
    var displayID: CGDirectDisplayID
    var vendor: UInt32
    var model: UInt32
    var serial: UInt32

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        vendor = CGDisplayVendorNumber(displayID)
        model = CGDisplayModelNumber(displayID)
        serial = CGDisplaySerialNumber(displayID)
    }

    init(displayID: CGDirectDisplayID, vendor: UInt32, model: UInt32, serial: UInt32) {
        self.displayID = displayID
        self.vendor = vendor
        self.model = model
        self.serial = serial
    }
}

/// The VESA DDC/CI byte layout for the two commands NotchShot sends.
enum DDCPacket {
    static let brightnessCode: UInt8 = 0x10
    /// The monitor's I²C address, and the host's source address.
    static let destination: UInt8 = 0x6E
    static let source: UInt8 = 0x51

    /// "Set VCP feature": length, opcode 0x03, code, value, checksum. The
    /// source byte travels as the I²C sub-address, so it is not in the buffer
    /// but is in the checksum.
    static func set(code: UInt8, value: UInt16) -> [UInt8] {
        sealed([0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    /// "Get VCP feature": length, opcode 0x01, code, checksum.
    static func get(code: UInt8) -> [UInt8] {
        sealed([0x82, 0x01, code])
    }

    private static func sealed(_ body: [UInt8]) -> [UInt8] {
        body + [body.reduce(destination ^ source, ^)]
    }

    /// Parses a "Get VCP feature" reply: `(current, maximum)`, or nil if the
    /// monitor answered with something else or an error.
    static func parseReply(_ reply: [UInt8], code: UInt8) -> (current: UInt16, maximum: UInt16)? {
        guard reply.count >= 10,
              reply[1] == 0x88, reply[2] == 0x02,
              reply[3] == 0x00, reply[4] == code else { return nil }
        let maximum = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        guard maximum > 0 else { return nil }
        return (min(current, maximum), maximum)
    }

    /// Pairs displays with registry links. An exact serial match wins; a
    /// serial-less monitor matches on vendor and model alone, once.
    static func pair(
        displays: [DDCDisplayIdentity],
        links: [(vendor: UInt32, model: UInt32, serial: UInt32)]
    ) -> [CGDirectDisplayID: Int] {
        var result: [CGDirectDisplayID: Int] = [:]
        var used = Set<Int>()
        for display in displays {
            if let index = links.indices.first(where: {
                !used.contains($0) && links[$0].vendor == display.vendor
                    && links[$0].model == display.model && links[$0].serial == display.serial
            }) {
                result[display.displayID] = index
                used.insert(index)
            }
        }
        for display in displays where result[display.displayID] == nil {
            if let index = links.indices.first(where: {
                !used.contains($0) && links[$0].vendor == display.vendor && links[$0].model == display.model
            }) {
                result[display.displayID] = index
                used.insert(index)
            }
        }
        return result
    }
}

/// Owns the Apple silicon `IOAVService` handles and serializes I²C traffic.
///
/// The `IOAVService` calls are not public API; they are resolved with
/// `dlsym`, and if a future macOS removes them every external monitor simply
/// falls back to software dimming.
final class DDCQueue: @unchecked Sendable {
    private typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias Transfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private let queue = DispatchQueue(label: "com.notchshot.ddc", qos: .userInitiated)
    private let create: Create?
    private let readI2C: Transfer?
    private let writeI2C: Transfer?

    // Touched only on `queue`.
    private var services: [CGDirectDisplayID: CFTypeRef] = [:]
    private var maximums: [CGDirectDisplayID: UInt16] = [:]
    private var pendingWrites: [CGDirectDisplayID: Double] = [:]
    private var writeScheduled: Set<CGDirectDisplayID> = []

    init() {
        let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        create = handle.flatMap { dlsym($0, "IOAVServiceCreateWithService") }.map { unsafeBitCast($0, to: Create.self) }
        readI2C = handle.flatMap { dlsym($0, "IOAVServiceReadI2C") }.map { unsafeBitCast($0, to: Transfer.self) }
        writeI2C = handle.flatMap { dlsym($0, "IOAVServiceWriteI2C") }.map { unsafeBitCast($0, to: Transfer.self) }
    }

    /// Finds each display's link and reads its brightness. Displays that
    /// answer come back with their level; the rest are left out.
    func probe(_ displays: [DDCDisplayIdentity], completion: @escaping @Sendable ([CGDirectDisplayID: Double]) -> Void) {
        queue.async { [self] in
            services.removeAll()
            maximums.removeAll()
            guard let create else { return completion([:]) }
            let links = Self.externalLinks()
            let pairs = DDCPacket.pair(displays: displays, links: links.map { ($0.vendor, $0.model, $0.serial) })
            var results: [CGDirectDisplayID: Double] = [:]
            for (displayID, index) in pairs {
                guard let service = create(kCFAllocatorDefault, links[index].service)?.takeRetainedValue() else { continue }
                services[displayID] = service
                if let reading = read(DDCPacket.brightnessCode, from: service) {
                    maximums[displayID] = reading.maximum
                    results[displayID] = Double(reading.current) / Double(reading.maximum)
                } else {
                    services.removeValue(forKey: displayID)
                }
            }
            for link in links { IOObjectRelease(link.service) }
            completion(results)
        }
    }

    /// Queues a write; rapid key repeats collapse into the latest level.
    func write(level: Double, to displayID: CGDirectDisplayID) {
        queue.async { [self] in
            pendingWrites[displayID] = level
            guard !writeScheduled.contains(displayID) else { return }
            writeScheduled.insert(displayID)
            flush(displayID)
        }
    }

    private func flush(_ displayID: CGDirectDisplayID) {
        guard let level = pendingWrites.removeValue(forKey: displayID),
              let service = services[displayID], let writeI2C else {
            writeScheduled.remove(displayID)
            return
        }
        let maximum = maximums[displayID] ?? 100
        var packet = DDCPacket.set(code: DDCPacket.brightnessCode, value: UInt16((level * Double(maximum)).rounded()))
        _ = writeI2C(service, UInt32(DDCPacket.destination >> 1), UInt32(DDCPacket.source), &packet, UInt32(packet.count))
        // Monitors need a breather between commands; anything sent sooner
        // is dropped by most of them.
        queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [self] in flush(displayID) }
    }

    private func read(_ code: UInt8, from service: CFTypeRef) -> (current: UInt16, maximum: UInt16)? {
        guard let readI2C, let writeI2C else { return nil }
        for _ in 0 ..< 3 {
            var request = DDCPacket.get(code: code)
            guard writeI2C(service, UInt32(DDCPacket.destination >> 1), UInt32(DDCPacket.source), &request, UInt32(request.count)) == KERN_SUCCESS else {
                usleep(20_000)
                continue
            }
            usleep(45_000)
            var reply = [UInt8](repeating: 0, count: 11)
            guard readI2C(service, UInt32(DDCPacket.destination >> 1), UInt32(DDCPacket.source), &reply, UInt32(reply.count)) == KERN_SUCCESS else {
                continue
            }
            if let parsed = DDCPacket.parseReply(reply, code: code) { return parsed }
        }
        return nil
    }

    private struct Link {
        var service: io_service_t
        var vendor: UInt32
        var model: UInt32
        var serial: UInt32
    }

    /// Walks the registry in order. Each external framebuffer carries the
    /// monitor's identity, and the `DCPAVServiceProxy` that follows it is
    /// that monitor's video link.
    private static func externalLinks() -> [Link] {
        var iterator = io_iterator_t()
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var links: [Link] = []
        var identity: (UInt32, UInt32, UInt32)?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            var nameBuffer = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &nameBuffer)
            let name = String(cString: nameBuffer)
            var keep = false
            if name == "AppleCLCD2" || name == "IOMobileFramebufferShim" {
                identity = attributes(of: entry)
            } else if name == "DCPAVServiceProxy",
                      let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                          .takeRetainedValue() as? String,
                      location == "External",
                      let (vendor, model, serial) = identity {
                links.append(Link(service: entry, vendor: vendor, model: model, serial: serial))
                identity = nil
                keep = true
            }
            if !keep { IOObjectRelease(entry) }
        }
        return links
    }

    private static func attributes(of entry: io_registry_entry_t) -> (UInt32, UInt32, UInt32)? {
        guard let attributes = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any],
              let product = attributes["ProductAttributes"] as? [String: Any],
              let vendor = (product["LegacyManufacturerID"] as? NSNumber)?.uint32Value,
              let model = (product["ProductID"] as? NSNumber)?.uint32Value else { return nil }
        let serial = (product["SerialNumber"] as? NSNumber)?.uint32Value ?? 0
        return (vendor, model, serial)
    }
}
