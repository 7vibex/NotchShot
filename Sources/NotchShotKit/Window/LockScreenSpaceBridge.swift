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
    /// Prevents the one-second presence timer from repeatedly creating Spaces
    /// or hammering a private operation after it has failed this lock session.
    private var setupFailure: AttachmentResult?
    private var windowFailures: [Int: AttachmentResult] = [:]

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
        moveWindows: MoveWindows?
    ) {
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
        if let failure = windowFailures[windowNumber] { return failure }
        if let setupFailure { return setupFailure }
        guard isAvailable,
              let mainConnection,
              let createSpace,
              let setAbsoluteLevel,
              let showSpaces,
              let moveWindows else {
            setupFailure = .unavailable
            return .unavailable
        }

        if attachedWindowNumbers.contains(windowNumber), let spaceID {
            return .alreadyAttached(spaceID: spaceID)
        }

        let connection: Int32
        let lockSpace: Int32
        if let connectionID, let spaceID {
            connection = connectionID
            lockSpace = spaceID
        } else {
            connection = mainConnection()
            guard connection > 0 else {
                let result = AttachmentResult.failed(
                    operation: "SLSMainConnectionID",
                    code: connection
                )
                setupFailure = result
                return result
            }

            lockSpace = createSpace(
                connection,
                Self.sharedSpaceType,
                Self.sharedSpaceOptions
            )
            guard lockSpace > 0 else {
                let result = AttachmentResult.failed(
                    operation: "SLSSpaceCreate",
                    code: lockSpace
                )
                setupFailure = result
                return result
            }

            let levelCode = setAbsoluteLevel(
                connection,
                lockSpace,
                Self.screenLockAbsoluteLevel
            )
            guard levelCode == 0 else {
                let result = AttachmentResult.failed(
                    operation: "SLSSpaceSetAbsoluteLevel",
                    code: levelCode
                )
                setupFailure = result
                return result
            }

            let spaces = NSArray(object: NSNumber(value: lockSpace)) as CFArray
            let showCode = showSpaces(connection, spaces)
            guard showCode == 0 else {
                let result = AttachmentResult.failed(
                    operation: "SLSShowSpaces",
                    code: showCode
                )
                setupFailure = result
                return result
            }

            connectionID = connection
            spaceID = lockSpace
        }

        let windows = NSArray(object: NSNumber(value: windowNumber)) as CFArray
        let moveCode = moveWindows(
            connection,
            lockSpace,
            windows,
            Self.moveWindowOptions
        )
        guard moveCode == 0 else {
            let result = AttachmentResult.failed(
                operation: "SLSSpaceAddWindowsAndRemoveFromSpaces",
                code: moveCode
            )
            windowFailures[windowNumber] = result
            return result
        }

        attachedWindowNumbers.insert(windowNumber)
        return .attached(spaceID: lockSpace)
    }

    /// Attached panels are discarded and rebuilt after unlock. Forgetting the
    /// old window numbers is enough; the process-owned Space is reused on the
    /// next lock and is reclaimed by WindowServer when the process exits.
    func resetAttachedWindows() {
        attachedWindowNumbers.removeAll()
        setupFailure = nil
        windowFailures.removeAll()
    }
}
