import Foundation
@preconcurrency import CoreGraphics

/// A filtering CGEvent tap that answers from a thread of its own.
///
/// WindowServer holds every event a filtering tap covers until the tap answers,
/// and switches the tap off when the answer is late. A tap on the main run loop
/// answers only once the main thread gets to it: NotchShot's media-key tap took
/// 0.7 to 1 s per key that way, and once 17.6 s (`CGGetEventTapList`, Oct 30,
/// 2026). Here each tap gets a run loop that does nothing else.
///
/// `@unchecked Sendable`: `port` and `filter` are set before the thread starts
/// and only read after; the run loop handoff is guarded by `lock`.
final class EventTapThread: @unchecked Sendable {
    /// Runs on the tap thread for every covered event. True swallows it.
    typealias Filter = @Sendable (CGEventType, CGEvent) -> Bool

    private let filter: Filter
    private var port: CFMachPort?
    private let lock = NSLock()
    /// Guarded by `lock`.
    private var runLoop: CFRunLoop?
    /// Guarded by `lock`.
    private var isStopped = false

    init?(name: String, eventsOfInterest: CGEventMask, filter: @escaping Filter) {
        self.filter = filter
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventsOfInterest,
            callback: eventTapThreadCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return nil }
        self.port = port

        // The closure keeps `self` alive until the run loop ends, so the
        // unretained pointer the callback receives stays valid.
        let thread = Thread { [self] in run() }
        thread.name = name
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    deinit {
        // Reached once the thread has ended, or if it never got its run loop
        // source; invalidating twice is harmless.
        if let port { CFMachPortInvalidate(port) }
    }

    /// Safe from any thread. Invalidating the port removes its source from the
    /// tap thread's run loop; stopping the run loop ends the thread even if
    /// something else was added to it.
    func stop() {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        lock.lock()
        isStopped = true
        let runLoop = runLoop
        lock.unlock()
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    private func run() {
        guard let port,
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else { return }
        let current = CFRunLoopGetCurrent()
        lock.lock()
        if isStopped {
            lock.unlock()
            return
        }
        runLoop = current
        lock.unlock()
        CFRunLoopAddSource(current, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        CFRunLoopRun()
    }

    fileprivate func shouldSwallow(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        }
        return filter(type, event)
    }
}

private func eventTapThreadCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<EventTapThread>.fromOpaque(userInfo).takeUnretainedValue()
    return tap.shouldSwallow(type, event) ? nil : Unmanaged.passUnretained(event)
}
