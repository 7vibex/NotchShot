import CoreAudio
import CoreMediaIO
import Darwin
import Foundation

/// All backend operations, including registration/removal, run on the worker's
/// serial queue. Implementations must deliver listeners on the supplied queue.
protocol PrivacyIndicatorBackend: Sendable {
    func addListener(_ property: PrivacyIndicatorProperty, queue: DispatchQueue,
                     handler: @escaping @Sendable () -> Void) -> PrivacyIndicatorListener?
    func otherAudioProcesses() -> [UInt32]
    func cameraDeviceIDs() -> [UInt32]
    func isRecording(_ process: UInt32) -> Bool
    func isCameraRunning(_ device: UInt32) -> Bool
    func client(for process: UInt32) -> MicrophoneClient?
}

enum PrivacyIndicatorProperty: Equatable, Sendable {
    case audioProcesses, cameraDevices, audioRunning(UInt32), cameraRunning(UInt32)
}

/// Keeps the exact queue and block pair alive until its corresponding removal.
final class PrivacyIndicatorListener {
    private let remove: () -> Void
    init(remove: @escaping () -> Void) { self.remove = remove }
    func cancel() { remove() }
}

struct PrivacyIndicatorSnapshot: Sendable {
    var microphone: Bool
    var camera: Bool
    var clients: [MicrophoneClient]
}

/// Mutable state is confined to `queue`; callbacks capture this worker weakly.
/// Start/stop requests retain it only until queued lifecycle work completes, so
/// monitor deinitialization also removes all registered listeners.
final class PrivacyIndicatorWorker: @unchecked Sendable {
    private let queue: DispatchQueue
    private let backend: any PrivacyIndicatorBackend
    private var generation: UInt64?
    private var publish: (@Sendable (PrivacyIndicatorSnapshot) -> Void)?
    private var listListeners: [PrivacyIndicatorListener] = []
    private var runningListeners: [PrivacyIndicatorListener] = []
    private var audioProcesses: [UInt32] = []
    private var cameraDevices: [UInt32] = []

    init(backend: any PrivacyIndicatorBackend,
         queue: DispatchQueue = DispatchQueue(label: "com.notchshot.privacy-indicators", qos: .userInitiated)) {
        self.backend = backend
        self.queue = queue
    }

    func start(generation: UInt64, publish: @escaping @Sendable (PrivacyIndicatorSnapshot) -> Void) {
        queue.async { [self] in
            stopOnQueue()
            self.generation = generation
            self.publish = publish
            for property in [PrivacyIndicatorProperty.audioProcesses, .cameraDevices] {
                if let listener = backend.addListener(property, queue: queue, handler: { [weak self] in
                    self?.rebuild(generation: generation)
                }) { listListeners.append(listener) }
            }
            rebuild(generation: generation)
        }
    }

    func stop() {
        queue.async { [self] in stopOnQueue() }
    }

    private func stopOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        generation = nil
        publish = nil
        removeRunningListeners()
        listListeners.forEach { $0.cancel() }
        listListeners.removeAll()
    }

    private func removeRunningListeners() {
        runningListeners.forEach { $0.cancel() }
        runningListeners.removeAll()
        audioProcesses.removeAll()
        cameraDevices.removeAll()
    }

    private func rebuild(generation: UInt64) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard self.generation == generation else { return }
        removeRunningListeners()
        audioProcesses = backend.otherAudioProcesses()
        cameraDevices = backend.cameraDeviceIDs()
        let properties = audioProcesses.map(PrivacyIndicatorProperty.audioRunning)
            + cameraDevices.map(PrivacyIndicatorProperty.cameraRunning)
        for property in properties {
            if let listener = backend.addListener(property, queue: queue, handler: { [weak self] in
                self?.refresh(generation: generation)
            }) { runningListeners.append(listener) }
        }
        refresh(generation: generation)
    }

    private func refresh(generation: UInt64) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard self.generation == generation else { return }
        let recording = audioProcesses.filter(backend.isRecording)
        var seen: Set<String> = []
        let clients = recording.compactMap(backend.client)
            .filter { seen.insert($0.bundleIdentifier).inserted }
        publish?(PrivacyIndicatorSnapshot(microphone: !recording.isEmpty,
                                          camera: cameraDevices.contains(where: backend.isCameraRunning),
                                          clients: clients))
    }
}

/// Core Audio, CoreMediaIO, process paths and bundle metadata are accessed only
/// by the serial worker. No AppKit/UI object crosses that boundary.
struct LivePrivacyIndicatorBackend: PrivacyIndicatorBackend {
    func otherAudioProcesses() -> [UInt32] { Self.otherAudioProcesses() }
    func cameraDeviceIDs() -> [UInt32] { Self.cameraDeviceIDs() }
    func isRecording(_ process: UInt32) -> Bool { Self.isRecording(process) }
    func isCameraRunning(_ device: UInt32) -> Bool { Self.isCameraRunning(device) }
    func client(for process: UInt32) -> MicrophoneClient? { Self.pid(of: process).flatMap(Self.client(for:)) }

    func addListener(_ property: PrivacyIndicatorProperty, queue: DispatchQueue,
                     handler: @escaping @Sendable () -> Void) -> PrivacyIndicatorListener? {
        switch property {
        case .audioProcesses, .audioRunning:
            let object: AudioObjectID
            var address: AudioObjectPropertyAddress
            switch property {
            case .audioRunning(let process): object = process; address = Self.audioRunningAddress
            default: object = AudioObjectID(kAudioObjectSystemObject); address = Self.audioProcessesAddress
            }
            let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
            guard AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else { return nil }
            let removalAddress = address
            return PrivacyIndicatorListener {
                var address = removalAddress
                AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
            }
        case .cameraDevices, .cameraRunning:
            let object: CMIOObjectID
            var address: CMIOObjectPropertyAddress
            switch property {
            case .cameraRunning(let device): object = device; address = Self.cameraRunningAddress
            default: object = CMIOObjectID(kCMIOObjectSystemObject); address = Self.cameraDevicesAddress
            }
            let block: CMIOObjectPropertyListenerBlock = { _, _ in handler() }
            guard CMIOObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else { return nil }
            let removalAddress = address
            return PrivacyIndicatorListener {
                var address = removalAddress
                CMIOObjectRemovePropertyListenerBlock(object, &address, queue, block)
            }
        }
    }

    /// The outermost `.app` bundle containing the process's executable.
    private static func client(for pid: pid_t) -> MicrophoneClient? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        guard let range = path.range(of: ".app/") else { return nil }
        let bundleURL = URL(fileURLWithPath: String(path[..<range.lowerBound]) + ".app")
        guard let bundle = Bundle(url: bundleURL), let identifier = bundle.bundleIdentifier else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        return MicrophoneClient(bundleIdentifier: identifier, name: name, applicationURL: bundleURL)
    }

    // MARK: Core Audio

    /// Changes whenever a process starts or stops being a Core Audio client.
    private static let audioProcessesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let audioRunningAddress = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyIsRunningInput,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// Every Core Audio client except this one.
    private static func otherAudioProcesses() -> [AudioObjectID] {
        var address = audioProcessesAddress
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &processes) == noErr
        else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return processes.filter { pid(of: $0) != me }
    }

    private static func pid(of process: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &pid) == noErr ? pid : nil
    }

    private static func isRecording(_ process: AudioObjectID) -> Bool {
        var address = audioRunningAddress
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == noErr && running != 0
    }

    // MARK: CoreMediaIO

    private static let cameraDevicesAddress = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )

    private static let cameraRunningAddress = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )

    private static func cameraDeviceIDs() -> [CMIOObjectID] {
        var address = cameraDevicesAddress
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &devices) == noErr
        else { return [] }
        return Array(devices.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    private static func isCameraRunning(_ device: CMIOObjectID) -> Bool {
        var address = cameraRunningAddress
        var running: UInt32 = 0
        var used: UInt32 = 0
        return CMIOObjectGetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &running) == noErr
            && running != 0
    }
}
