import AppKit
import Foundation

/// Isolated, best-effort access to the WindowServer Space used by the
/// experimental Lock Screen card.
///
/// AppKit's `canBecomeVisibleWithoutLogin` permits a window to exist before a
/// login completes, but it does not move an ordinary app window into the
/// secure Lock Screen's separate Space. macOS has no public API for that move.
/// Direct-distribution builds therefore resolve the minimum SkyLight surface
/// at runtime and fail closed when Apple removes or changes it. The supported
/// UserNotifications fallback remains independent of this bridge.
@MainActor
final class LockScreenSpaceBridge {
    static let shared = LockScreenSpaceBridge()

    /// Private WindowServer constants observed on macOS 26. They live here so
    /// the unsupported dependency is obvious, reviewable, and easy to remove.
    static let screenLockAbsoluteLevel: Int32 = 300
    static let sharedSpaceType: Int32 = 1
    static let sharedSpaceOptions: Int32 = 0
    static let moveWindowOptions: Int32 = 7

    enum AttachmentResult: Equatable {
        case attached(spaceID: Int32)
        case alreadyAttached(spaceID: Int32)
        case unavailable
        case failed(operation: String, code: Int32)
    }

    typealias MainConnection = () -> Int32
    typealias CreateSpace = (Int32, Int32, Int32) -> Int32
    typealias SetAbsoluteLevel = (Int32, Int32, Int32) -> Int32
    typealias ShowSpaces = (Int32, CFArray) -> Int32
    typealias MoveWindows = (Int32, Int32, CFArray, Int32) -> Int32

    private let mainConnection: MainConnection?
    private let createSpace: CreateSpace?
    private let setAbsoluteLevel: SetAbsoluteLevel?
    private let showSpaces: ShowSpaces?
    private let moveWindows: MoveWindows?

    private var connectionID: Int32?
    private var spaceID: Int32?
    private var attachedWindowNumbers: Set<Int> = []
    private struct Failure {
        let result: AttachmentResult
        let attempts: Int
        let retryAt: TimeInterval
    }

    // The lock shield and its Space can settle after the distributed lock
    // event. Retry transient failures with a bound, rather than disabling the
    // card for the entire lock session after the first race.
    private static let maximumAttempts = 3
    private static let presentationRefreshInterval: TimeInterval = 1
    private let now: () -> TimeInterval
    private var setupFailure: Failure?
    private var windowFailures: [Int: Failure] = [:]
    private var lastPresentationAt: TimeInterval?

    var hasAttachedWindows: Bool { !attachedWindowNumbers.isEmpty }
    var isAvailable: Bool {
        mainConnection != nil
            && createSpace != nil
            && setAbsoluteLevel != nil
            && showSpaces != nil
            && moveWindows != nil
    }

    convenience init() {
        typealias SLSMainConnectionID = @convention(c) () -> Int32
        typealias SLSSpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
        typealias SLSSpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
        typealias SLSShowSpaces = @convention(c) (Int32, CFArray) -> Int32
        typealias SLSSpaceAddWindowsAndRemoveFromSpaces = @convention(c) (
            Int32,
            Int32,
            CFArray,
            Int32
        ) -> Int32

        let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
            RTLD_LAZY
        )

        func resolve<T>(_ name: String, as type: T.Type) -> T? {
            guard let handle, let symbol = dlsym(handle, name) else { return nil }
            return unsafeBitCast(symbol, to: type)
        }

        let main = resolve("SLSMainConnectionID", as: SLSMainConnectionID.self)
        let create = resolve("SLSSpaceCreate", as: SLSSpaceCreate.self)
        let setLevel = resolve(
            "SLSSpaceSetAbsoluteLevel",
            as: SLSSpaceSetAbsoluteLevel.self
        )
        let show = resolve("SLSShowSpaces", as: SLSShowSpaces.self)
        let move = resolve(
            "SLSSpaceAddWindowsAndRemoveFromSpaces",
            as: SLSSpaceAddWindowsAndRemoveFromSpaces.self
        )

        self.init(
            mainConnection: main.map { function in { function() } },
            createSpace: create.map { function in { function($0, $1, $2) } },
            setAbsoluteLevel: setLevel.map { function in { function($0, $1, $2) } },
            showSpaces: show.map { function in { function($0, $1) } },
            moveWindows: move.map { function in { function($0, $1, $2, $3) } }
        )
    }

    /// Internal injection seam keeps the ordering and failure behavior under
    /// test without creating a real WindowServer Space in the test process.
    init(
        mainConnection: MainConnection?,
        createSpace: CreateSpace?,
        setAbsoluteLevel: SetAbsoluteLevel?,
        showSpaces: ShowSpaces?,
        moveWindows: MoveWindows?,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.now = now
        self.mainConnection = mainConnection
        self.createSpace = createSpace
        self.setAbsoluteLevel = setAbsoluteLevel
        self.showSpaces = showSpaces
        self.moveWindows = moveWindows
    }

    func attach(_ window: NSWindow) -> AttachmentResult {
        attach(windowNumber: window.windowNumber)
    }

    func attach(windowNumber: Int) -> AttachmentResult {
        guard windowNumber > 0 else {
            return .failed(operation: "windowNumber", code: -1)
        }
        let instant = now()
        if let failure = windowFailures[windowNumber], !canRetry(failure, at: instant) {
            return failure.result
        }
        if let failure = setupFailure, !canRetry(failure, at: instant) {
            return failure.result
        }
        guard isAvailable,
              let mainConnection, let createSpace, let setAbsoluteLevel,
              let showSpaces, let moveWindows else { return .unavailable }

        let connection: Int32
        if let existing = connectionID {
            connection = existing
        } else {
            connection = mainConnection()
            guard connection > 0 else {
                return failSetup("SLSMainConnectionID", code: connection, at: instant)
            }
            connectionID = connection
        }
        let lockSpace: Int32
        if let existing = spaceID {
            lockSpace = existing
        } else {
            lockSpace = createSpace(connection, Self.sharedSpaceType, Self.sharedSpaceOptions)
            guard lockSpace > 0 else {
                return failSetup("SLSSpaceCreate", code: lockSpace, at: instant)
            }
            // Retain the allocated Space even if level/show fails, so retries
            // configure that same Space rather than leaking another one.
            spaceID = lockSpace
        }

        if lastPresentationAt.map({ instant - $0 >= Self.presentationRefreshInterval }) ?? true {
            let levelCode = setAbsoluteLevel(connection, lockSpace, Self.screenLockAbsoluteLevel)
            guard levelCode == 0 else {
                return failSetup("SLSSpaceSetAbsoluteLevel", code: levelCode, at: instant)
            }
            let spaces = NSArray(object: NSNumber(value: lockSpace)) as CFArray
            let showCode = showSpaces(connection, spaces)
            guard showCode == 0 else {
                return failSetup("SLSShowSpaces", code: showCode, at: instant)
            }
            lastPresentationAt = instant
            setupFailure = nil
        }

        if attachedWindowNumbers.contains(windowNumber) {
            return .alreadyAttached(spaceID: lockSpace)
        }
        let windows = NSArray(object: NSNumber(value: windowNumber)) as CFArray
        let moveCode = moveWindows(connection, lockSpace, windows, Self.moveWindowOptions)
        guard moveCode == 0 else {
            let result = AttachmentResult.failed(operation: "SLSSpaceAddWindowsAndRemoveFromSpaces", code: moveCode)
            windowFailures[windowNumber] = failure(result, previous: windowFailures[windowNumber], at: instant)
            return result
        }
        windowFailures[windowNumber] = nil
        attachedWindowNumbers.insert(windowNumber)
        return .attached(spaceID: lockSpace)
    }

    private func canRetry(_ failure: Failure, at instant: TimeInterval) -> Bool {
        failure.attempts < Self.maximumAttempts && instant >= failure.retryAt
    }

    private func failure(_ result: AttachmentResult, previous: Failure?, at instant: TimeInterval) -> Failure {
        let attempts = (previous?.attempts ?? 0) + 1
        return Failure(result: result, attempts: attempts, retryAt: instant + Double(attempts))
    }

    private func failSetup(_ operation: String, code: Int32, at instant: TimeInterval) -> AttachmentResult {
        let result = AttachmentResult.failed(operation: operation, code: code)
        setupFailure = failure(result, previous: setupFailure, at: instant)
        lastPresentationAt = nil
        return result
    }

    /// Wake can hide the process-owned Space without detaching its windows.
    /// Request its presentation again, retaining those window identities.
    func refreshPresentation() {
        lastPresentationAt = nil
        setupFailure = nil
        windowFailures.removeAll()
    }

    /// Reuse the allocated Space after unlock, but always show it again on the
    /// next lock. WindowServer can hide it while the ordinary session resumes.
    func resetAttachedWindows() {
        attachedWindowNumbers.removeAll()
        refreshPresentation()
    }
}
