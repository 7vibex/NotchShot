import AppIntents
#if !NOTCHSHOT_METADATA_EXTRACTION
import AppKit
#endif
import Foundation

#if !NOTCHSHOT_METADATA_EXTRACTION
private enum NotchShotIntentRunner {
    @MainActor
    static func run(_ command: NotchShotURLCommand) throws {
        guard let delegate = NSApplication.shared.delegate as? AppDelegate else {
            throw NotchShotIntentError.appUnavailable
        }
        delegate.performAutomationCommand(command)
    }
}
#endif

private enum NotchShotIntentError: LocalizedError {
    case appUnavailable

    var errorDescription: String? {
        "NotchShot is still starting. Run the action again in a moment."
    }
}

public struct CaptureAreaAppIntent: AppIntent {
    public static let title: LocalizedStringResource = "Capture Area"
    public static let description = IntentDescription(
        "Select an area of the screen and capture it with NotchShot."
    )
    public static let supportedModes: IntentModes = .foreground(.immediate)

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
#if !NOTCHSHOT_METADATA_EXTRACTION
        try NotchShotIntentRunner.run(.capture(URLCaptureCommand(
            intent: .area,
            displayNumber: nil,
            presetID: nil,
            action: .defaultBehavior
        )))
#endif
        return .result()
    }
}

public struct CaptureDisplayAppIntent: AppIntent {
    public static let title: LocalizedStringResource = "Capture Display"
    public static let description = IntentDescription(
        "Capture the active display with NotchShot."
    )
    public static let supportedModes: IntentModes = .foreground(.immediate)

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
#if !NOTCHSHOT_METADATA_EXTRACTION
        try NotchShotIntentRunner.run(.capture(URLCaptureCommand(
            intent: .display,
            displayNumber: nil,
            presetID: nil,
            action: .defaultBehavior
        )))
#endif
        return .result()
    }
}

public struct CapturePreviousAreaAppIntent: AppIntent {
    public static let title: LocalizedStringResource = "Capture Previous Area"
    public static let description = IntentDescription(
        "Capture the most recently selected screen area."
    )
    public static let supportedModes: IntentModes = .foreground(.immediate)

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
#if !NOTCHSHOT_METADATA_EXTRACTION
        try NotchShotIntentRunner.run(.capture(URLCaptureCommand(
            intent: .previousArea,
            displayNumber: nil,
            presetID: nil,
            action: .defaultBehavior
        )))
#endif
        return .result()
    }
}

public struct RecordAreaAppIntent: AppIntent {
    public static let title: LocalizedStringResource = "Record Area"
    public static let description = IntentDescription(
        "Select an area and start a screen recording with the current NotchShot settings."
    )
    public static let supportedModes: IntentModes = .foreground(.immediate)

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
#if !NOTCHSHOT_METADATA_EXTRACTION
        try NotchShotIntentRunner.run(.recordArea)
#endif
        return .result()
    }
}

public struct ReadClipboardTextAppIntent: AppIntent {
    public static let title: LocalizedStringResource = "Read Text from Clipboard Image"
    public static let description = IntentDescription(
        "Recognize structured text in the clipboard image and copy the result."
    )
    public static let supportedModes: IntentModes = .foreground(.immediate)

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
#if !NOTCHSHOT_METADATA_EXTRACTION
        try NotchShotIntentRunner.run(.ocrClipboard(.text))
#endif
        return .result()
    }
}

public struct OpenLatestCaptureAppIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Latest Capture"
    public static let description = IntentDescription(
        "Open the latest safely readable capture in NotchShot."
    )
    public static let supportedModes: IntentModes = .foreground(.immediate)

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
#if !NOTCHSHOT_METADATA_EXTRACTION
        try NotchShotIntentRunner.run(.openLatest)
#endif
        return .result()
    }
}

public struct NotchShotAppShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureAreaAppIntent(),
            phrases: ["Capture an area with \(.applicationName)"],
            shortTitle: "Capture Area",
            systemImageName: "viewfinder"
        )
        AppShortcut(
            intent: CaptureDisplayAppIntent(),
            phrases: ["Capture my display with \(.applicationName)"],
            shortTitle: "Capture Display",
            systemImageName: "display"
        )
        AppShortcut(
            intent: CapturePreviousAreaAppIntent(),
            phrases: ["Capture the previous area with \(.applicationName)"],
            shortTitle: "Capture Previous Area",
            systemImageName: "arrow.counterclockwise"
        )
        AppShortcut(
            intent: RecordAreaAppIntent(),
            phrases: ["Record an area with \(.applicationName)"],
            shortTitle: "Record Area",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: ReadClipboardTextAppIntent(),
            phrases: ["Read my clipboard image with \(.applicationName)"],
            shortTitle: "Read Clipboard Image",
            systemImageName: "text.viewfinder"
        )
        AppShortcut(
            intent: OpenLatestCaptureAppIntent(),
            phrases: ["Open my latest \(.applicationName) capture"],
            shortTitle: "Open Latest Capture",
            systemImageName: "clock.arrow.circlepath"
        )
    }

    public static var shortcutTileColor: ShortcutTileColor { .navy }
}

/// Lets Xcode's metadata processor discover App Intents defined in this Swift
/// package when producing the final macOS bundle metadata.
public struct NotchShotKitAppIntentsPackage: AppIntentsPackage {
    public init() {}
}
