import AppKit
import CoreAudio
import Foundation
import IOKit.ps

public struct PowerSourceReading: Sendable, Equatable {
    public var percentage: Int
    public var isConnectedToPower: Bool
    public var isCharging: Bool
    public var isInternalBattery: Bool
    public var isUPS: Bool

    public init(
        percentage: Int,
        isConnectedToPower: Bool,
        isCharging: Bool,
        isInternalBattery: Bool = true,
        isUPS: Bool = false
    ) {
        self.percentage = percentage
        self.isConnectedToPower = isConnectedToPower
        self.isCharging = isCharging
        self.isInternalBattery = isInternalBattery
        self.isUPS = isUPS
    }
}

enum PowerContextPolicy {
    static func snapshot(
        previous: PowerSourceReading?,
        current: PowerSourceReading,
        now: Date = Date()
    ) -> ContextSnapshot? {
        guard current.isInternalBattery, !current.isUPS else { return nil }
        let percentage = min(max(current.percentage, 0), 100)
        let title: String
        let symbol: String
        let expires: TimeInterval

        if !current.isConnectedToPower, percentage <= 20 {
            guard previous == nil
                || previous?.isConnectedToPower == true
                || (previous?.percentage ?? 101) > 20 else { return nil }
            title = "Low Battery"
            symbol = "#FFD60A"
            expires = 10
        } else if current.isConnectedToPower, percentage >= 100, !current.isCharging {
            guard previous?.percentage != percentage || previous?.isCharging != current.isCharging else { return nil }
            title = "Charged"
            symbol = "#30D158"
            expires = 4
        } else if previous?.isConnectedToPower != current.isConnectedToPower {
            title = current.isConnectedToPower ? "Charging" : "On Battery"
            symbol = current.isConnectedToPower ? "#30D158" : "#FFD60A"
            expires = 4
        } else if previous == nil {
            return nil
        } else {
            return nil
        }

        return ContextSnapshot(
            kind: .power,
            title: title,
            subtitle: current.isConnectedToPower ? "Power adapter connected" : "Using internal battery",
            metric: String(percentage) + "%",
            accentHex: symbol,
            createdAt: now,
            expiresAt: now.addingTimeInterval(expires),
            mayInterruptMedia: true
        )
    }
}

@MainActor
final class PowerSourceMonitor {
    var onTransition: ((ContextSnapshot) -> Void)?
    private var source: CFRunLoopSource?
    private var previous: PowerSourceReading?
    private var coalescingTask: Task<Void, Never>?

    func start() {
        guard source == nil else { return }
        previous = Self.currentReading()
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let unmanaged = IOPSNotificationCreateRunLoopSource({ rawContext in
            guard let rawContext else { return }
            let monitor = Unmanaged<PowerSourceMonitor>.fromOpaque(rawContext).takeUnretainedValue()
            Task { @MainActor in monitor.scheduleRefresh() }
        }, context) else { return }
        let runLoopSource = unmanaged.takeRetainedValue()
        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
    }

    func stop() {
        coalescingTask?.cancel()
        coalescingTask = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        source = nil
        previous = nil
    }

    private func scheduleRefresh() {
        coalescingTask?.cancel()
        coalescingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self, let current = Self.currentReading() else { return }
            let old = self.previous
            self.previous = current
            if let snapshot = PowerContextPolicy.snapshot(previous: old, current: current) {
                self.onTransition?(snapshot)
            }
        }
    }

    private static func currentReading() -> PowerSourceReading? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as Array
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                as? [String: Any] else { continue }
            let type = description[kIOPSTypeKey as String] as? String
            let isInternal = type == (kIOPSInternalBatteryType as String)
            let isUPS = type == (kIOPSUPSType as String)
            guard isInternal, !isUPS else { continue }
            guard let current = description[kIOPSCurrentCapacityKey as String] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey as String] as? Int,
                  maximum > 0 else { continue }
            let state = description[kIOPSPowerSourceStateKey as String] as? String
            let connected = state == (kIOPSACPowerValue as String)
            let charging = description[kIOPSIsChargingKey as String] as? Bool ?? false
            return PowerSourceReading(
                percentage: Int((Double(current) / Double(maximum) * 100).rounded()),
                isConnectedToPower: connected,
                isCharging: charging,
                isInternalBattery: true,
                isUPS: false
            )
        }
        return nil
    }
}

public struct AudioRouteReading: Sendable, Equatable, Identifiable {
    public var deviceID: UInt32
    public var name: String
    public var transport: UInt32

    public init(deviceID: UInt32, name: String, transport: UInt32) {
        self.deviceID = deviceID
        self.name = name
        self.transport = transport
    }

    public var id: UInt32 { deviceID }

    /// A transport-aware symbol for the output selector. Core Audio exposes
    /// the connection type, not a trustworthy product image, so the UI stays
    /// honest about generic Bluetooth and wired devices instead of pretending
    /// every headset is an AirPods model.
    var selectorSymbolName: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            "headphones"
        case kAudioDeviceTransportTypeAirPlay:
            "airplayaudio"
        case kAudioDeviceTransportTypeUSB:
            "cable.connector"
        case kAudioDeviceTransportTypeHDMI,
             kAudioDeviceTransportTypeDisplayPort,
             kAudioDeviceTransportTypeThunderbolt:
            "display"
        default:
            "speaker.wave.2.fill"
        }
    }
}

enum AudioOutputDeviceError: LocalizedError {
    case unavailable
    case couldNotSwitch(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "That audio output is no longer available."
        case .couldNotSwitch(let status):
            "macOS could not switch audio output (Core Audio error \(status))."
        }
    }
}

/// Public Core Audio device discovery and selection for the media card.
///
/// macOS has no public SwiftUI equivalent of iOS's route picker. Core Audio's
/// default-output property is the supported system-level surface, so the menu
/// can offer real local devices without impersonating Control Centre or using
/// MediaRemote/private notification APIs.
enum AudioOutputDeviceService {
    static func availableOutputs() -> [AudioRouteReading] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &byteCount
        ) == noErr, byteCount >= UInt32(MemoryLayout<AudioDeviceID>.size) else { return [] }

        var devices = Array(
            repeating: AudioDeviceID(0),
            count: Int(byteCount) / MemoryLayout<AudioDeviceID>.size
        )
        let status = devices.withUnsafeMutableBytes { storage in
            guard let baseAddress = storage.baseAddress else {
                return kAudioHardwareUnspecifiedError
            }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &byteCount,
                baseAddress
            )
        }
        guard status == noErr else { return [] }

        return normalized(
            devices.compactMap { device in
                guard hasOutputStreams(device) else { return nil }
                return reading(for: device)
            },
            currentID: currentOutput()?.deviceID
        )
    }

    static func currentOutput() -> AudioRouteReading? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &device
        ) == noErr, device != 0 else { return nil }
        return reading(for: device)
    }

    static func select(_ deviceID: AudioDeviceID) throws {
        guard availableOutputs().contains(where: { $0.deviceID == deviceID }) else {
            throw AudioOutputDeviceError.unavailable
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var selected = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &selected
        )
        guard status == noErr else { throw AudioOutputDeviceError.couldNotSwitch(status) }
    }

    static func normalized(
        _ devices: [AudioRouteReading],
        currentID: AudioDeviceID?
    ) -> [AudioRouteReading] {
        var seen = Set<AudioDeviceID>()
        return devices
            .filter { seen.insert($0.deviceID).inserted }
            .sorted { lhs, rhs in
                if lhs.deviceID == currentID { return true }
                if rhs.deviceID == currentID { return false }
                let order = lhs.name.localizedStandardCompare(rhs.name)
                if order == .orderedSame { return lhs.deviceID < rhs.deviceID }
                return order == .orderedAscending
            }
    }

    private static func hasOutputStreams(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func reading(for device: AudioDeviceID) -> AudioRouteReading? {
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            device,
            &transportAddress,
            0,
            nil,
            &size,
            &transport
        ) == noErr else { return nil }

        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanagedName: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let nameStatus = AudioObjectGetPropertyData(
            device,
            &nameAddress,
            0,
            nil,
            &size,
            &unmanagedName
        )
        let name = nameStatus == noErr
            ? unmanagedName?.takeUnretainedValue() as String? ?? "Audio Device"
            : "Audio Device"
        return AudioRouteReading(deviceID: device, name: name, transport: transport)
    }
}

enum AudioRouteContextPolicy {
    static let externalTransports: Set<UInt32> = [
        kAudioDeviceTransportTypeBluetooth,
        kAudioDeviceTransportTypeBluetoothLE,
        kAudioDeviceTransportTypeUSB,
        kAudioDeviceTransportTypeAirPlay,
        kAudioDeviceTransportTypeHDMI,
        kAudioDeviceTransportTypeDisplayPort,
        kAudioDeviceTransportTypeThunderbolt,
    ]

    static func isReliableExternalRoute(_ reading: AudioRouteReading?) -> Bool {
        guard let reading else { return false }
        return externalTransports.contains(reading.transport)
    }

    static func snapshot(
        previous: AudioRouteReading?,
        current: AudioRouteReading?,
        now: Date = Date()
    ) -> ContextSnapshot? {
        guard previous?.deviceID != current?.deviceID else { return nil }
        let wasExternal = isReliableExternalRoute(previous)
        let isExternal = isReliableExternalRoute(current)
        guard wasExternal || isExternal else { return nil }
        if isExternal, let current {
            return ContextSnapshot(
                kind: .audioRoute,
                title: "Audio Connected",
                subtitle: current.name,
                metric: "Connected",
                accentHex: "#30D158",
                createdAt: now,
                expiresAt: now.addingTimeInterval(4),
                mayInterruptMedia: true
            )
        }
        return ContextSnapshot(
            kind: .audioRoute,
            title: "Audio Disconnected",
            subtitle: previous?.name,
            metric: "Disconnected",
            accentHex: "#FF9F0A",
            createdAt: now,
            expiresAt: now.addingTimeInterval(4),
            mayInterruptMedia: true
        )
    }
}

@MainActor
final class AudioRouteMonitor {
    var onTransition: ((ContextSnapshot) -> Void)?
    private var previous: AudioRouteReading?
    private var listener: AudioObjectPropertyListenerBlock?
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    func start() {
        guard listener == nil else { return }
        previous = AudioOutputDeviceService.currentOutput()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        listener = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            .main,
            block
        )
    }

    func stop() {
        if let listener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                .main,
                listener
            )
        }
        listener = nil
        previous = nil
    }

    private func refresh() {
        let current = AudioOutputDeviceService.currentOutput()
        defer { previous = current }
        guard let snapshot = AudioRouteContextPolicy.snapshot(
            previous: previous,
            current: current
        ) else { return }
        onTransition?(snapshot)

        // The card is shown immediately with what Core Audio knows, then
        // amended once the system's Bluetooth report answers. Waiting for that
        // first would delay the card by a second or more for every accessory,
        // including the ones that report no battery at all.
        guard let routeName = current?.name, snapshot.metric == "Connected" else { return }
        Task { [weak self] in
            guard let battery = await BluetoothAccessoryBatteryService.shared
                .battery(forRouteNamed: routeName) else { return }
            await MainActor.run {
                guard let self else { return }
                var amended = snapshot
                amended.accessory = battery
                // Long enough to read three numbers, where the plain
                // "Connected" card only had to be glanced at.
                amended.expiresAt = Date().addingTimeInterval(5)
                self.onTransition?(amended)
            }
        }
    }

}
