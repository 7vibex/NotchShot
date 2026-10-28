import AudioToolbox
import CoreAudio
import Foundation
import OSLog

/// A Core Audio process tap: a private copy of what one app — or the whole
/// Mac — is playing, delivered as float samples on a background queue.
///
/// The sound still plays normally (the tap is unmuted), nothing is written
/// anywhere, and the tap and its private aggregate device are torn down on
/// `stop()`. The first tap asks for macOS's "System Audio Recording Only"
/// permission; a denial surfaces as `start` throwing.
final class ProcessAudioTap: @unchecked Sendable {
    enum Target: Equatable {
        /// Only these apps (and their helper processes).
        case applications([String])
        /// Everything the Mac plays except NotchShot itself.
        case system
    }

    enum TapError: LocalizedError {
        case noProcess
        case coreAudio(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .noProcess: "That app isn't playing any sound right now."
            case .coreAudio(let step, let status): "Couldn't listen to the Mac's audio (\(step), \(status))."
            }
        }
    }

    /// Mono-ish float frames, the format they arrived in, and the sample rate.
    typealias Handler = (_ samples: UnsafeBufferPointer<Float>, _ channels: Int, _ sampleRate: Double) -> Void

    private let queue = DispatchQueue(label: "com.notchshot.audio-tap", qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private(set) var sampleRate: Double = 48_000
    private(set) var isRunning = false

    deinit { stop() }

    func start(_ target: Target, handler: @escaping Handler) throws {
        stop()
        let description: CATapDescription
        switch target {
        case .applications(let bundleIDs):
            let matched = Self.audioBundleIDs(matching: bundleIDs)
            guard !matched.isEmpty else { throw TapError.noProcess }
            description = CATapDescription(stereoMixdownOfProcesses: [])
            description.bundleIDs = matched
            description.isProcessRestoreEnabled = true
        case .system:
            let own = Self.processObject(for: ProcessInfo.processInfo.processIdentifier)
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: own.map { [$0] } ?? [])
        }
        description.name = "NotchShot level tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw TapError.coreAudio("tap", status) }
        tapID = tap

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NotchShot Tap",
            kAudioAggregateDeviceUIDKey: "com.notchshot.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard status == noErr else {
            stop()
            throw TapError.coreAudio("device", status)
        }
        aggregateID = device

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format) == noErr, format.mSampleRate > 0 {
            sampleRate = format.mSampleRate
        }
        let rate = sampleRate
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 || format.mFormatFlags == 0

        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { _, input, _, _, _ in
            guard isFloat else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = buffers.first, let data = first.mData else { return }
            let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            guard count > 0 else { return }
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)
            // Non-interleaved delivers one channel per buffer; the first is
            // enough for a level meter and for matching.
            handler(samples, interleaved ? Int(max(first.mNumberChannels, 1)) : 1, rate)
        }
        guard status == noErr, let proc else {
            stop()
            throw TapError.coreAudio("io", status)
        }
        procID = proc
        status = AudioDeviceStart(device, proc)
        guard status == noErr else {
            stop()
            throw TapError.coreAudio("start", status)
        }
        isRunning = true
    }

    func stop() {
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
        isRunning = false
    }

    // MARK: Process lookup

    /// Audio comes from helpers as often as from the app itself: Chrome's and
    /// Spotify's sound is played by `….helper` processes, and every WebKit
    /// app's by WebKit's GPU process.
    static func audioBundleIDs(matching bundleIDs: [String]) -> [String] {
        let running = audioProcessBundleIDs()
        var matched = Set<String>()
        for id in bundleIDs {
            matched.formUnion(AudioTapProcessPolicy.matches(for: id, among: running))
        }
        return matched.sorted()
    }

    static func audioProcessBundleIDs() -> [String] {
        audioProcessObjects().compactMap(bundleID(of:))
    }

    /// Every process Core Audio knows about: each one that has opened audio,
    /// playing or not.
    static func audioProcessObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    /// Whether the process is sending sound to an output right now.
    static func isRunningOutput(_ process: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    static func bundleID(of process: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr,
              let id = value?.takeRetainedValue() as String?, !id.isEmpty else { return nil }
        return id
    }

    private static func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &object
        )
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}

/// Which audio processes belong to a player app.
enum AudioTapProcessPolicy {
    static let webKitAudioProcess = "com.apple.WebKit.GPU"
    /// Apps whose web content plays through WebKit's shared GPU process.
    static let webKitHosts: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]

    static func matches(for bundleID: String, among running: [String]) -> [String] {
        var result = running.filter { $0 == bundleID || $0.hasPrefix(bundleID + ".") }
        if webKitHosts.contains(bundleID), running.contains(webKitAudioProcess) {
            result.append(webKitAudioProcess)
        }
        return result
    }
}
