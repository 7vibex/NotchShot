import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import IOKit
import Observation

public enum SystemLevelKind: String, Sendable, Equatable {
    case volume
    case brightness
    case keyboardBrightness

    public var title: String {
        switch self {
        case .volume: "Volume"
        case .brightness: "Brightness"
        case .keyboardBrightness: "Keyboard Brightness"
        }
    }

    /// Symbol reflecting how full the level is, matching the system HUD's habit
    /// of showing fewer waves as volume drops.
    public func symbolName(for value: Double, isMuted: Bool) -> String {
        switch self {
        case .volume:
            if isMuted || value <= 0.001 { return "speaker.slash.fill" }
            if value < 0.33 { return "speaker.wave.1.fill" }
            if value < 0.66 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        case .brightness:
            return value < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .keyboardBrightness:
            return "light.max"
        }
    }
}

public struct SystemLevel: Sendable, Equatable {
    public var kind: SystemLevelKind
    /// 0…1.
    public var value: Double
    public var isMuted: Bool
    /// Display that produced the level when it is display-specific.
    public var displayID: CGDirectDisplayID? = nil

    public var symbolName: String { kind.symbolName(for: value, isMuted: isMuted) }
}

/// Watches system volume and display brightness so the notch can mirror them.
///
/// Volume uses CoreAudio property listeners — event-driven, no polling, no
/// permissions. Brightness has no public change notification, so it is sampled
/// at a low rate; the sample is a single IOKit read, and it pauses entirely
/// while the display is asleep.
@MainActor
@Observable
public final class SystemLevelMonitor {
    public static let shared = SystemLevelMonitor()

    /// Most recent change, cleared by the coordinator once shown.
    public private(set) var latest: SystemLevel?

    /// Fires on each *change*, not on each sample.
    public var onChange: ((SystemLevel) -> Void)?

    private struct AudioListenerRegistration {
        var objectID: AudioObjectID
        var address: AudioObjectPropertyAddress
        var block: AudioObjectPropertyListenerBlock
    }

    private var audioDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var deviceListeners: [AudioListenerRegistration] = []
    private var defaultDeviceListener: AudioListenerRegistration?
    private var serviceRestartListener: AudioListenerRegistration?
    private let listenerQueue = DispatchQueue.main
    private var brightnessTimer: Timer?
    private var lastVolume: Double?
    private var lastMuted: Bool?
    private var brightness = BrightnessChangeClassifier()
    private var brightnessDisplayID: CGDirectDisplayID?
    private var brightnessIntent = BrightnessKeyIntentGate()
    private var globalBrightnessKeyMonitor: Any?
    private var localBrightnessKeyMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var displayObserver: NSObjectProtocol?
    private var isRunning = false

    public init() {}

    // MARK: Lifecycle

    public func start() {
        guard !isRunning else { return }
        isRunning = true

        // Resolve the device before seeding. Reading first would always return
        // nil because `audioDeviceID` still held kAudioObjectUnknown, making the
        // first CoreAudio callback look like a user change.
        installDefaultDeviceListenerIfNeeded()
        installServiceRestartListenerIfNeeded()
        audioDeviceID = defaultOutputDevice()

        // Seed the baselines so the first real event doesn't fire a phantom HUD.
        lastVolume = readVolume()
        lastMuted = readMuted()
        if Preferences.shared.mirrorsBrightnessChanges {
            rebaselineBrightness()
        } else {
            brightnessDisplayID = nil
            brightness.reset(to: nil)
        }

        installDeviceVolumeListeners()
        startBrightnessSampling()
        installSleepObservers()
        installDisplayObserver()
    }

    public func stop() {
        isRunning = false
        removeVolumeListeners()
        brightnessTimer?.invalidate()
        brightnessTimer = nil
        removeBrightnessKeyMonitors()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        if let displayObserver {
            NotificationCenter.default.removeObserver(displayObserver)
            self.displayObserver = nil
        }
    }

    public func clearLatest() {
        latest = nil
    }

    // MARK: Volume

    private func installDefaultDeviceListenerIfNeeded() {
        guard defaultDeviceListener == nil else { return }
        // Switching output device (headphones in/out) changes the volume we
        // should be watching, so follow that too.
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.removeDeviceVolumeListeners()
                self.audioDeviceID = self.defaultOutputDevice()
                // Headphones sit at their own volume. Re-baseline against the
                // new device, or the next change would be measured against the
                // old one and show a HUD for a switch nobody asked for.
                self.lastVolume = self.readVolume()
                self.lastMuted = self.readMuted()
                self.installDeviceVolumeListeners()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            systemObject,
            &deviceAddress,
            listenerQueue,
            block
        )
        if status == noErr {
            defaultDeviceListener = AudioListenerRegistration(
                objectID: systemObject,
                address: deviceAddress,
                block: block
            )
        }
    }

    private func installServiceRestartListenerIfNeeded() {
        guard serviceRestartListener == nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyServiceRestarted,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.rebuildAudioAfterServiceRestart()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            systemObject,
            &address,
            listenerQueue,
            block
        )
        if status == noErr {
            serviceRestartListener = AudioListenerRegistration(
                objectID: systemObject,
                address: address,
                block: block
            )
        }
    }

    private func rebuildAudioAfterServiceRestart() {
        guard isRunning else { return }
        removeVolumeListeners()
        installDefaultDeviceListenerIfNeeded()
        installServiceRestartListenerIfNeeded()
        audioDeviceID = defaultOutputDevice()
        lastVolume = readVolume()
        lastMuted = readMuted()
        installDeviceVolumeListeners()
    }

    private func removeVolumeListeners() {
        removeDeviceVolumeListeners()
        if var registration = defaultDeviceListener {
            _ = AudioObjectRemovePropertyListenerBlock(
                registration.objectID,
                &registration.address,
                listenerQueue,
                registration.block
            )
            defaultDeviceListener = nil
        }
        if var registration = serviceRestartListener {
            _ = AudioObjectRemovePropertyListenerBlock(
                registration.objectID,
                &registration.address,
                listenerQueue,
                registration.block
            )
            serviceRestartListener = nil
        }
    }

    private func installDeviceVolumeListeners() {
        guard audioDeviceID != AudioObjectID(kAudioObjectUnknown) else { return }
        // Built-in speakers usually expose a virtual master. USB, HDMI and
        // aggregate devices often expose only per-channel volume. Listen to
        // every readable public CoreAudio address so those devices work too.
        let addresses = availableAddresses(
            for: kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        ) + availableAddresses(for: kAudioDevicePropertyVolumeScalar)
          + availableAddresses(for: kAudioDevicePropertyMute)

        for candidate in addresses {
            var address = candidate
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.volumeDidChange() }
            }
            let status = AudioObjectAddPropertyListenerBlock(
                audioDeviceID,
                &address,
                listenerQueue,
                block
            )
            if status == noErr {
                deviceListeners.append(AudioListenerRegistration(
                    objectID: audioDeviceID,
                    address: address,
                    block: block
                ))
            }
        }
    }

    private func removeDeviceVolumeListeners() {
        for var registration in deviceListeners {
            _ = AudioObjectRemovePropertyListenerBlock(
                registration.objectID,
                &registration.address,
                listenerQueue,
                registration.block
            )
        }
        deviceListeners.removeAll()
    }

    private func volumeDidChange() {
        guard isRunning else { return }
        let volume = readVolume()
        let muted = readMuted()
        guard volume != lastVolume || muted != lastMuted else { return }
        lastVolume = volume
        lastMuted = muted
        publish(SystemLevel(kind: .volume, value: volume ?? 0, isMuted: muted ?? false))
    }

    private func defaultOutputDevice() -> AudioObjectID {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr ? deviceID : AudioObjectID(kAudioObjectUnknown)
    }

    private func readVolume() -> Double? {
        guard audioDeviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        if let master = readFloat32(
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            element: kAudioObjectPropertyElementMain
        ) ?? readFloat32(
            selector: kAudioDevicePropertyVolumeScalar,
            element: kAudioObjectPropertyElementMain
        ) {
            return Double(min(max(master, 0), 1))
        }

        let channels = (1 ... 32).compactMap {
            readFloat32(selector: kAudioDevicePropertyVolumeScalar, element: UInt32($0))
        }
        guard !channels.isEmpty else { return nil }
        let average = channels.reduce(0, +) / Float32(channels.count)
        return Double(min(max(average, 0), 1))
    }

    private func readMuted() -> Bool? {
        guard audioDeviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        if let master = readUInt32(
            selector: kAudioDevicePropertyMute,
            element: kAudioObjectPropertyElementMain
        ) {
            return master != 0
        }

        let channels = (1 ... 32).compactMap {
            readUInt32(selector: kAudioDevicePropertyMute, element: UInt32($0))
        }
        guard !channels.isEmpty else { return nil }
        return channels.allSatisfy { $0 != 0 }
    }

    private func availableAddresses(
        for selector: AudioObjectPropertySelector
    ) -> [AudioObjectPropertyAddress] {
        ([kAudioObjectPropertyElementMain] + (1 ... 32).map(UInt32.init)).compactMap { element in
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            return AudioObjectHasProperty(audioDeviceID, &address) ? address : nil
        }
    }

    private func readFloat32(
        selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement
    ) -> Float32? {
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        let status = AudioObjectGetPropertyData(audioDeviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private func readUInt32(
        selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement
    ) -> UInt32? {
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        let status = AudioObjectGetPropertyData(audioDeviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    // MARK: Brightness

    private func startBrightnessSampling() {
        guard Preferences.shared.mirrorsBrightnessChanges else { return }
        guard BrightnessReader.shared.isAvailable else {
            Log.app.notice("Brightness monitoring unavailable on this system")
            return
        }
        installBrightnessKeyMonitorsIfNeeded()
        brightnessTimer?.invalidate()
        // 5 Hz: fast enough that a key-repeat ramp looks continuous, while each
        // tick remains one bounded compatibility-shim read.
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleBrightness() }
        }
        RunLoop.main.add(timer, forMode: .common)
        brightnessTimer = timer
    }

    private func sampleBrightness() {
        guard isRunning, let reading = BrightnessReader.shared.reading() else { return }
        guard brightnessDisplayID == reading.displayID else {
            brightnessDisplayID = reading.displayID
            brightness.reset(to: reading.value)
            return
        }
        // Shape classification plus the recent key-event gate prevents a
        // sensor-driven value from opening the notch.
        let now = ProcessInfo.processInfo.systemUptime
        guard case .report(let reported) = brightness.classify(
            reading.value,
            at: now
        ), brightnessIntent.allowsPublication(at: now) else { return }
        publish(SystemLevel(
            kind: .brightness,
            value: reported,
            isMuted: false,
            displayID: reading.displayID
        ))
    }

    private func rebaselineBrightness() {
        let reading = BrightnessReader.shared.reading()
        brightnessDisplayID = reading?.displayID
        brightness.reset(to: reading?.value)
    }

    /// Turns brightness mirroring on or off without disturbing volume.
    public func setBrightnessMirroringEnabled(_ enabled: Bool) {
        guard isRunning else { return }
        if enabled {
            rebaselineBrightness()
            startBrightnessSampling()
        } else {
            brightnessTimer?.invalidate()
            brightnessTimer = nil
            removeBrightnessKeyMonitors()
            brightnessDisplayID = nil
            brightness.reset(to: nil)
            brightnessIntent.reset()
        }
    }

    private func installSleepObservers() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.brightnessTimer?.invalidate()
                self?.brightnessTimer = nil
                self?.brightnessIntent.reset()
            }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                guard Preferences.shared.mirrorsBrightnessChanges else { return }
                // Brightness usually differs after a wake; re-baseline instead
                // of firing a HUD nobody asked for.
                self.rebaselineBrightness()
                self.startBrightnessSampling()
            }
        })
    }

    private func installDisplayObserver() {
        guard displayObserver == nil else { return }
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      self.isRunning,
                      Preferences.shared.mirrorsBrightnessChanges else { return }
                // The main display may have changed. Never compare a sample
                // from one panel against another display's previous value.
                self.rebaselineBrightness()
            }
        }
    }

    private func publish(_ level: SystemLevel) {
        latest = level
        onChange?(level)
    }

    private func installBrightnessKeyMonitorsIfNeeded() {
        if globalBrightnessKeyMonitor == nil {
            globalBrightnessKeyMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: .systemDefined
            ) { [weak self] event in
                Task { @MainActor in self?.recordBrightnessKeyEvent(event) }
            }
        }
        if localBrightnessKeyMonitor == nil {
            localBrightnessKeyMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .systemDefined
            ) { [weak self] event in
                MainActor.assumeIsolated { self?.recordBrightnessKeyEvent(event) }
                return event
            }
        }
    }

    private func removeBrightnessKeyMonitors() {
        if let globalBrightnessKeyMonitor {
            NSEvent.removeMonitor(globalBrightnessKeyMonitor)
            self.globalBrightnessKeyMonitor = nil
        }
        if let localBrightnessKeyMonitor {
            NSEvent.removeMonitor(localBrightnessKeyMonitor)
            self.localBrightnessKeyMonitor = nil
        }
        brightnessIntent.reset()
    }

    private func recordBrightnessKeyEvent(_ event: NSEvent) {
        guard event.subtype.rawValue == NX_SUBTYPE_AUX_CONTROL_BUTTONS else { return }
        let keyType = (event.data1 & 0xFFFF_0000) >> 16
        guard keyType == NX_KEYTYPE_BRIGHTNESS_UP
                || keyType == NX_KEYTYPE_BRIGHTNESS_DOWN else { return }
        brightnessIntent.noteKeyEvent(at: ProcessInfo.processInfo.systemUptime)
    }
}

/// Reads display brightness.
///
/// There is no public API for this, so `DisplayServices` is resolved at runtime
/// with `dlsym`. Nothing is patched, injected, or linked against — if the
/// symbol is missing on a future macOS, brightness reporting simply turns
/// itself off and the rest of the notch is unaffected.
final class BrightnessReader: @unchecked Sendable {
    static let shared = BrightnessReader()

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

    private let handle: UnsafeMutableRawPointer?
    private let getBrightness: GetBrightness?

    var isAvailable: Bool { getBrightness != nil }

    struct Reading {
        var displayID: CGDirectDisplayID
        var value: Double
    }

    private init() {
        handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_LAZY
        )
        if let handle, let symbol = dlsym(handle, "DisplayServicesGetBrightness") {
            getBrightness = unsafeBitCast(symbol, to: GetBrightness.self)
        } else {
            getBrightness = nil
        }
    }

    /// Prefer an active built-in display because that is the one controlled by
    /// a MacBook's ambient sensor and brightness keys. Fall back to the main or
    /// any other active display that implements DisplayServices brightness.
    func reading() -> Reading? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return brightness(displayID: CGMainDisplayID()).map {
                Reading(displayID: CGMainDisplayID(), value: $0)
            }
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }
        displays = Array(displays.prefix(Int(count)))

        var candidates = displays.filter { CGDisplayIsBuiltin($0) != 0 }
        let main = CGMainDisplayID()
        if !candidates.contains(main) { candidates.append(main) }
        candidates.append(contentsOf: displays.filter { !candidates.contains($0) })

        for displayID in candidates {
            if let value = brightness(displayID: displayID) {
                return Reading(displayID: displayID, value: value)
            }
        }
        return nil
    }

    /// 0…1 for one display, or nil if its private compatibility shim is absent.
    private func brightness(displayID: CGDirectDisplayID) -> Double? {
        guard let getBrightness else { return nil }
        var value: Float = 0
        guard getBrightness(displayID, &value) == 0 else { return nil }
        guard value.isFinite else { return nil }
        return Double(min(max(value, 0), 1))
    }
}
