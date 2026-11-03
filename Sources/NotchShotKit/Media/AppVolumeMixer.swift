import AppKit
import AudioToolbox
import CoreAudio
import Observation
import Synchronization

/// An app the mixer lists: one that is playing sound now, or one the user
/// has turned down that is still running.
public struct AppVolumeSource: Identifiable, Equatable, Sendable {
    public var bundleIdentifier: String
    public var name: String
    public var isPlaying: Bool

    public var id: String { bundleIdentifier }
}

/// Per-app volume, the one sound control macOS has never had.
///
/// An app left at full volume is never touched. Turning one down puts a
/// Core Audio process tap on it that mutes its own output while NotchShot
/// plays the tapped copy to the same speakers at the chosen level. Quitting
/// NotchShot, or turning the mixer off, removes every tap and the apps play
/// as before. Levels are remembered per app.
@MainActor
@Observable
public final class AppVolumeMixer {
    public static let shared = AppVolumeMixer()

    public private(set) var sources: [AppVolumeSource] = []
    public private(set) var isRunning = false

    /// A tap couldn't start; the message is for the notch.
    @ObservationIgnored var onFailure: ((String) -> Void)?

    @ObservationIgnored private var taps: [String: AppVolumeTap] = [:]
    @ObservationIgnored private var listeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []
    /// Apps whose tap failed, so a broken one isn't retried on every change.
    @ObservationIgnored private var refused: Set<String> = []

    init() {}

    /// Applies the Settings switch. Called at launch and on every flip.
    func reconcileEnabled() {
        let enabled = ExtrasPreferences.shared.appVolumesEnabled
        guard enabled != isRunning else {
            if enabled { reconcileTaps() }
            return
        }
        isRunning = enabled
        if enabled {
            listen(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
                // Every tap plays to the old speakers until it is rebuilt.
                self?.rebuildAllTaps()
            }
            listen(kAudioHardwarePropertyProcessObjectList) { [weak self] in
                self?.reconcileTaps()
                self?.refreshSources()
            }
            refused.removeAll()
            reconcileTaps()
            refreshSources()
        } else {
            for (selector, block) in listeners {
                var address = Self.address(selector)
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
            }
            listeners.removeAll()
            taps.values.forEach { $0.stop() }
            taps.removeAll()
            sources = []
        }
    }

    public func volume(for bundleIdentifier: String) -> Double {
        ExtrasPreferences.shared.appVolumes[bundleIdentifier] ?? 1
    }

    /// Sets an app's level. Full volume removes its tap altogether, but only
    /// once a drag ends: a drag that passes through the end keeps the tap at
    /// full gain, since every new tap costs a handover.
    public func setVolume(_ volume: Double, for bundleIdentifier: String, isFinal: Bool = true) {
        let clamped = min(max(volume, 0), 1)
        let extras = ExtrasPreferences.shared
        let tap = taps[bundleIdentifier]
        // Snaps the last percent to full, so dragging to the end really
        // gives the app its own output back.
        let isFull = clamped >= 0.99
        if isFull, tap == nil || isFinal {
            extras.appVolumes[bundleIdentifier] = nil
            reconcileTaps()
            return
        }
        extras.appVolumes[bundleIdentifier] = isFull ? 1 : clamped
        if let tap {
            tap.setGain(isFull ? 1 : Float(clamped))
        } else {
            refused.remove(bundleIdentifier)
            reconcileTaps()
        }
    }

    /// Re-reads which apps are playing. The panels call it as they open.
    public func refreshSources() {
        guard isRunning else { return }
        let levels = ExtrasPreferences.shared.appVolumes
        let processes = ProcessAudioTap.audioProcessObjects().compactMap { object -> (String, Bool)? in
            ProcessAudioTap.bundleID(of: object).map { ($0, ProcessAudioTap.isRunningOutput(object)) }
        }
        let ownID = Bundle.main.bundleIdentifier
        var result: [AppVolumeSource] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != ownID else { continue }
            let matched = Set(AudioTapProcessPolicy.matches(for: id, among: processes.map(\.0)))
            let playing = processes.contains { matched.contains($0.0) && $0.1 }
            guard playing || levels[id] != nil else { continue }
            result.append(AppVolumeSource(
                bundleIdentifier: id,
                name: app.localizedName ?? id,
                isPlaying: playing
            ))
        }
        result.sort { ($0.isPlaying ? 0 : 1, $0.name) < ($1.isPlaying ? 0 : 1, $1.name) }
        if result != sources { sources = result }
    }

    // MARK: Taps

    private func reconcileTaps() {
        guard isRunning else { return }
        let levels = ExtrasPreferences.shared.appVolumes
        for (id, tap) in taps where levels[id] == nil {
            tap.stop()
            taps[id] = nil
        }
        let running = ProcessAudioTap.audioProcessBundleIDs()
        for (id, level) in levels where !refused.contains(id) {
            let matched = AudioTapProcessPolicy.matches(for: id, among: running).sorted()
            if let existing = taps[id] {
                // A helper that started after the tap isn't in it. Spotify
                // and Chrome start and quit helpers all the time, so the
                // running tap is changed rather than rebuilt.
                guard existing.bundleIDs != matched, !existing.update(bundleIDs: matched) else { continue }
                existing.stop()
                taps[id] = nil
            }
            guard !matched.isEmpty else { continue }
            do {
                taps[id] = try AppVolumeTap(bundleIDs: matched, gain: Float(level))
            } catch {
                refused.insert(id)
                Log.app.error("App volume tap for \(id) failed: \(error.localizedDescription)")
                onFailure?("Couldn't change that app's volume. NotchShot needs System Audio Recording in Privacy & Security.")
            }
        }
    }

    private func rebuildAllTaps() {
        taps.values.forEach { $0.stop() }
        taps.removeAll()
        refused.removeAll()
        reconcileTaps()
    }

    private func listen(_ selector: AudioObjectPropertySelector, _ handler: @escaping @MainActor () -> Void) {
        var address = Self.address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { handler() }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr {
            listeners.append((selector, block))
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

/// One app's tap: its sound muted at the source and replayed, scaled, to
/// the current output through a private aggregate device.
///
/// The tap starts unmuted, with the replay silent, and mutes the app only
/// once the replay is running. Muting first would leave a gap of a few audio
/// cycles while the aggregate device starts. Stopping hands back the same
/// way. Both handovers overlap by a cycle or so rather than leave a gap.
final class AppVolumeTap: @unchecked Sendable {
    private(set) var bundleIDs: [String]
    private let gain = AppVolumeGain()
    private let handover = AppVolumeHandover()
    private let description = CATapDescription(stereoMixdownOfProcesses: [])
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var isMuting = false

    /// Cycles the replay must run before the app is muted. The first ones
    /// can carry silence while the tap's drift compensation fills.
    private static let cyclesBeforeMute = 3
    private static let handoverPoll: DispatchTimeInterval = .milliseconds(5)
    private static let handoverTimeout: TimeInterval = 1

    init(bundleIDs: [String], gain: Float) throws {
        self.bundleIDs = bundleIDs
        self.gain.store(gain)
        do {
            try start()
        } catch {
            stop()
            throw error
        }
        scheduleMute(deadline: Date().addingTimeInterval(Self.handoverTimeout))
    }

    deinit { stop() }

    func setGain(_ value: Float) {
        gain.store(min(max(value, 0), 1))
    }

    /// Changes which processes the running tap takes. False if Core Audio
    /// refused, and the tap has to be rebuilt.
    func update(bundleIDs: [String]) -> Bool {
        guard tapID != kAudioObjectUnknown else { return false }
        description.bundleIDs = bundleIDs
        guard applyDescription() else {
            description.bundleIDs = self.bundleIDs
            return false
        }
        self.bundleIDs = bundleIDs
        return true
    }

    private func start() throws {
        guard let outputUID = Self.defaultOutputUID() else {
            throw ProcessAudioTap.TapError.coreAudio("output", kAudioHardwareBadDeviceError)
        }
        description.bundleIDs = bundleIDs
        description.isProcessRestoreEnabled = true
        description.name = "NotchShot app volume"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw ProcessAudioTap.TapError.coreAudio("tap", status) }
        tapID = tap

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &size, &format)
        let tapChannels = Int(max(format.mChannelsPerFrame, 1))

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NotchShot App Volume",
            kAudioAggregateDeviceUIDKey: "com.notchshot.app-volume.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard status == noErr else { throw ProcessAudioTap.TapError.coreAudio("device", status) }
        aggregateID = device

        let gain = self.gain
        let handover = self.handover
        // Silent until the handover, then ramps up over one buffer.
        var current: Float = 0
        var proc: AudioDeviceIOProcID?
        // No queue: the block runs on the HAL's real-time thread, which is
        // what writing to an output needs.
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { _, input, _, output, _ in
            let target = handover.isLive ? gain.load() : 0
            AppVolumeRenderer.render(
                input: UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)),
                output: UnsafeMutableAudioBufferListPointer(output),
                tapChannels: tapChannels,
                from: current,
                to: target
            )
            current = target
            handover.countCycle()
        }
        guard status == noErr, let proc else { throw ProcessAudioTap.TapError.coreAudio("io", status) }
        procID = proc
        status = AudioDeviceStart(device, proc)
        guard status == noErr else { throw ProcessAudioTap.TapError.coreAudio("start", status) }
    }

    /// Mutes the app once the replay has run a few cycles. The replay goes
    /// live first, so the slop is a short overlap, not a gap. If it never
    /// runs, the app is left playing on its own at full volume.
    private func scheduleMute(deadline: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.handoverPoll) { [weak self] in
            guard let self, self.tapID != kAudioObjectUnknown, !self.isMuting else { return }
            guard self.handover.cycles >= Self.cyclesBeforeMute else {
                if Date() < deadline {
                    self.scheduleMute(deadline: deadline)
                } else {
                    Log.app.error("App volume tap for \(self.bundleIDs) never ran; leaving the app unmuted")
                }
                return
            }
            self.handover.goLive()
            self.description.muteBehavior = .mutedWhenTapped
            if self.applyDescription() {
                self.isMuting = true
            } else {
                // Without the mute the app would play twice.
                self.handover.goSilent()
                self.description.muteBehavior = .unmuted
                Log.app.error("App volume tap for \(self.bundleIDs) couldn't mute the app")
            }
        }
    }

    private func applyDescription() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = Unmanaged.passUnretained(description)
        let size = UInt32(MemoryLayout<Unmanaged<CATapDescription>>.size)
        return AudioObjectSetPropertyData(tapID, &address, 0, nil, size, &value) == noErr
    }

    func stop() {
        // Unmute before the replay stops, so the app's own sound is back
        // by the replay's last cycle.
        if isMuting, tapID != kAudioObjectUnknown {
            description.muteBehavior = .unmuted
            _ = applyDescription()
        }
        isMuting = false
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }
}

/// The level, read on the real-time audio thread, so an atomic rather than
/// a lock.
private final class AppVolumeGain: Sendable {
    private let bits = Atomic<UInt32>(Float(1).bitPattern)

    func load() -> Float { Float(bitPattern: bits.load(ordering: .relaxed)) }
    func store(_ value: Float) { bits.store(value.bitPattern, ordering: .relaxed) }
}

/// What the real-time thread and the main thread share during a handover:
/// how many cycles the replay has run, and whether it is audible yet.
private final class AppVolumeHandover: Sendable {
    private let cycleCount = Atomic<Int>(0)
    private let live = Atomic<Bool>(false)

    var cycles: Int { cycleCount.load(ordering: .relaxed) }
    var isLive: Bool { live.load(ordering: .relaxed) }

    func countCycle() { cycleCount.add(1, ordering: .relaxed) }
    func goLive() { live.store(true, ordering: .relaxed) }
    func goSilent() { live.store(false, ordering: .relaxed) }
}

/// The real-time half of the mixer: copies the tapped sound to the output
/// at the chosen level. Pure, so it can be tested without audio hardware.
enum AppVolumeRenderer {
    /// The tap's channels are the aggregate's last input channels: an
    /// output device that also has a microphone (a USB headset) lists the
    /// microphone first, and it must never be played back. Output channels
    /// past the tap's (a surround interface) stay silent. The level ramps
    /// from `from` to `to` across the buffer, so a slider drag doesn't click.
    static func render(
        input: UnsafeMutableAudioBufferListPointer,
        output: UnsafeMutableAudioBufferListPointer,
        tapChannels: Int,
        from start: Float,
        to end: Float
    ) {
        for buffer in output {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        let inputChannels = input.reduce(0) { $0 + Int($1.mNumberChannels) }
        let tapChannels = min(tapChannels, inputChannels)
        guard tapChannels > 0, start > 0 || end > 0 else { return }
        let firstTapChannel = inputChannels - tapChannels

        var outputChannel = 0
        for buffer in output {
            let channels = Int(buffer.mNumberChannels)
            defer { outputChannel += channels }
            guard channels > 0, let out = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            for channel in 0..<channels {
                let tapChannel = outputChannel + channel
                guard tapChannel < tapChannels else { continue }
                // Find which input buffer, and where in it, the channel is.
                var remaining = firstTapChannel + tapChannel
                for source in input {
                    let sourceChannels = Int(source.mNumberChannels)
                    guard remaining >= sourceChannels else {
                        guard let samples = source.mData?.assumingMemoryBound(to: Float.self) else { break }
                        let sourceFrames = Int(source.mDataByteSize) / (MemoryLayout<Float>.size * sourceChannels)
                        let count = min(frames, sourceFrames)
                        guard count > 0 else { break }
                        let step = (end - start) / Float(count)
                        for frame in 0..<count {
                            out[frame * channels + channel] = samples[frame * sourceChannels + remaining]
                                * (start + step * Float(frame + 1))
                        }
                        break
                    }
                    remaining -= sourceChannels
                }
            }
        }
    }
}
