import AppKit
import AudioToolbox
import CoreAudio
import Foundation
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
    private let listenerQueue = DispatchQueue.main
    private var brightnessTimer: Timer?
    private var lastVolume: Double?
    private var lastMuted: Bool?
    private var brightness = BrightnessChangeClassifier()
    private var observers: [NSObjectProtocol] = []
    private var isRunning = false

    public init() {}

    // MARK: Lifecycle

    public func start() {
        guard !isRunning else { return }
        isRunning = true

        // Seed the baselines so the first sample doesn't fire a phantom HUD.
        lastVolume = readVolume()
        lastMuted = readMuted()
        brightness.reset(to: BrightnessReader.shared.brightness())

        installVolumeListeners()
        startBrightnessSampling()
        installSleepObservers()
    }

    public func stop() {
        isRunning = false
        removeVolumeListeners()
        brightnessTimer?.invalidate()
        brightnessTimer = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    public func clearLatest() {
        latest = nil
    }

    // MARK: Volume

    private func installVolumeListeners() {
        installDefaultDeviceListenerIfNeeded()
        audioDeviceID = defaultOutputDevice()
        installDeviceVolumeListeners()
    }

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
                self.installDeviceVolumeListeners()
                // Headphones sit at their own volume. Re-baseline against the
                // new device, or the next change would be measured against the
                // old one and show a HUD for a switch nobody asked for.
                self.lastVolume = self.readVolume()
                self.lastMuted = self.readMuted()
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
    }

    private func installDeviceVolumeListeners() {
        guard audioDeviceID != AudioObjectID(kAudioObjectUnknown) else { return }
        for selector in [
            kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            kAudioDevicePropertyMute,
        ] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
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
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(audioDeviceID, &address, 0, nil, &size, &volume)
        guard status == noErr else { return nil }
        return Double(min(max(volume, 0), 1))
    }

    private func readMuted() -> Bool? {
        guard audioDeviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(audioDeviceID, &address, 0, nil, &size, &muted)
        guard status == noErr else { return nil }
        return muted != 0
    }

    // MARK: Brightness

    private func startBrightnessSampling() {
        guard Preferences.shared.mirrorsBrightnessChanges else { return }
        guard BrightnessReader.shared.isAvailable else {
            Log.app.notice("Brightness monitoring unavailable on this system")
            return
        }
        brightnessTimer?.invalidate()
        // 5 Hz: fast enough that a key-repeat ramp looks continuous, slow enough
        // to be invisible in Instruments. Each tick is one IOKit property read.
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleBrightness() }
        }
        RunLoop.main.add(timer, forMode: .common)
        brightnessTimer = timer
    }

    private func sampleBrightness() {
        guard isRunning, let value = BrightnessReader.shared.brightness() else { return }
        // The classifier decides whether this was a person or the ambient light
        // sensor; only the former reaches the notch.
        guard case .report(let reported) = brightness.classify(
            value,
            at: ProcessInfo.processInfo.systemUptime
        ) else { return }
        publish(SystemLevel(kind: .brightness, value: reported, isMuted: false))
    }

    /// Turns brightness mirroring on or off without disturbing volume.
    public func setBrightnessMirroringEnabled(_ enabled: Bool) {
        guard isRunning else { return }
        if enabled {
            brightness.reset(to: BrightnessReader.shared.brightness())
            startBrightnessSampling()
        } else {
            brightnessTimer?.invalidate()
            brightnessTimer = nil
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
            }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                // Brightness usually differs after a wake; re-baseline instead
                // of firing a HUD nobody asked for.
                self.brightness.reset(to: BrightnessReader.shared.brightness())
                self.startBrightnessSampling()
            }
        })
    }

    private func publish(_ level: SystemLevel) {
        latest = level
        onChange?(level)
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

    /// 0…1 for the main display, or nil if unavailable.
    func brightness(displayID: CGDirectDisplayID = CGMainDisplayID()) -> Double? {
        guard let getBrightness else { return nil }
        var value: Float = 0
        guard getBrightness(displayID, &value) == 0 else { return nil }
        guard value.isFinite else { return nil }
        return Double(min(max(value, 0), 1))
    }
}
