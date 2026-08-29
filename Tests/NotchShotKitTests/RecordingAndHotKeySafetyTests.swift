import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Testing
@testable import NotchShotKit

@Suite("Video trim presentation")
@MainActor
struct VideoTrimPresentationTests {
    @Test("A missing recording stays unavailable instead of exposing zero-duration controls")
    func missingRecording() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-missing-\(UUID().uuidString).mp4")
        let asset = CaptureAsset(
            url: missing,
            kind: .recording,
            pixelSize: .zero,
            scale: 1
        )
        let session = VideoTrimSession(asset: asset)

        #expect(session.isLoading)
        #expect(!session.isReady)

        await session.load()

        #expect(!session.isLoading)
        #expect(!session.isReady)
        #expect(session.duration == 0)
        #expect(session.errorMessage != nil)
    }

    @Test("A replaced external recording is rejected before AVFoundation reads it")
    func replacedExternalRecording() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-trim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("recording.mp4")
        try Data("original".utf8).write(to: source)
        let asset = CaptureAsset(
            url: source,
            kind: .recording,
            pixelSize: .zero,
            scale: 1,
            ownership: .externalReference
        )
        try Data("replacement with a different identity".utf8)
            .write(to: source, options: .atomic)
        let session = VideoTrimSession(asset: asset)

        await session.load()

        #expect(!session.isReady)
        #expect(session.errorMessage?.localizedCaseInsensitiveContains("changed") == true)
        #expect(session.player.currentItem == nil)
    }
}

@Suite("Recording disk capacity policy")
struct RecordingCapacityPolicyTests {
    @Test("Recording warns and stops before exhausting the volume")
    func thresholds() {
        #expect(RecordingCapacityPolicy.action(for: 2_000_000_000) == .continueRecording)
        #expect(RecordingCapacityPolicy.action(for: 700_000_000) == .warn)
        #expect(RecordingCapacityPolicy.action(for: 500_000_000) == .stopAndFinalize)
        #expect(RecordingCapacityPolicy.action(for: 0) == .stopAndFinalize)
        #expect(RecordingCapacityPolicy.minimumStartBytes > RecordingCapacityPolicy.automaticStopBytes)
    }
}

@Suite("Recording scratch retirement")
struct RecordingScratchRetirementTests {
    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-retirement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    @Test("A source that cannot be removed stays excluded from recovery")
    func removalFailureLeavesMarker() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("segment.mp4")
        try Data("video".utf8).write(to: source)

        let operations = RecordingScratchRetirement.Operations(
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            writeMarker: { try Data().write(to: $0, options: .atomic) },
            removeItem: { url in
                if url.standardizedFileURL == source.standardizedFileURL {
                    throw NSError(
                        domain: NSCocoaErrorDomain,
                        code: NSFileWriteNoPermissionError
                    )
                }
                try FileManager.default.removeItem(at: url)
            }
        )

        let retained = try RecordingScratchRetirement.retireCommitted(
            [source],
            operations: operations
        )

        #expect(retained == [source.standardizedFileURL])
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(
            atPath: RecordingScratchRetirement.marker(for: source).path
        ))
    }

    @MainActor
    @Test("A marker failure occurs before any source deletion")
    func markerFailurePreservesEverySource() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.mp4")
        let second = directory.appendingPathComponent("second.mp4")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        var removedSources: [URL] = []

        let operations = RecordingScratchRetirement.Operations(
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            writeMarker: { marker in
                if marker == RecordingScratchRetirement.marker(for: second) {
                    throw NSError(
                        domain: NSCocoaErrorDomain,
                        code: NSFileWriteNoPermissionError
                    )
                }
                try Data().write(to: marker, options: .atomic)
            },
            removeItem: { url in
                if url.pathExtension == "mp4" { removedSources.append(url) }
                try FileManager.default.removeItem(at: url)
            }
        )

        do {
            _ = try RecordingScratchRetirement.retireCommitted(
                [first, second],
                operations: operations
            )
            Issue.record("Expected marker preflight to fail")
        } catch {
            #expect(removedSources.isEmpty)
            #expect(FileManager.default.fileExists(atPath: first.path))
            #expect(FileManager.default.fileExists(atPath: second.path))
            #expect(!FileManager.default.fileExists(
                atPath: RecordingScratchRetirement.marker(for: first).path
            ))
        }
    }
}

@Suite("Recording area safety")
struct RecordingAreaSafetyTests {
    private let displays = [
        RecordingDisplayBounds(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 100, height: 100)
        ),
        RecordingDisplayBounds(
            displayID: 2,
            frame: CGRect(x: 100, y: 0, width: 100, height: 100)
        ),
    ]

    @Test("A cross-display area is rejected instead of silently truncated")
    func crossDisplayAreaRejected() {
        #expect(throws: NotchShotError.captureFailed(
            "Area recordings must stay on one display. Choose a region that does not cross a display edge."
        )) {
            try RecordingAreaResolver.resolve(
                globalRect: CGRect(x: 80, y: 10, width: 80, height: 50),
                displays: displays
            )
        }
    }

    @Test("An area partly beyond a display is clamped before becoming sourceRect")
    func clampsToDisplay() throws {
        let result = try RecordingAreaResolver.resolve(
            globalRect: CGRect(x: -20, y: -10, width: 70, height: 40),
            displays: displays
        )

        #expect(result.displayID == 1)
        #expect(result.globalRect == CGRect(x: 0, y: 0, width: 50, height: 30))
        #expect(result.displayLocalRect == CGRect(x: 0, y: 0, width: 50, height: 30))
    }

    @Test("An area outside every display is rejected")
    func rejectsOffDisplayArea() {
        #expect(throws: NotchShotError.displayNotFound) {
            try RecordingAreaResolver.resolve(
                globalRect: CGRect(x: 250, y: 10, width: 20, height: 20),
                displays: displays
            )
        }
    }

    @Test("Non-finite recording geometry is rejected")
    func rejectsInvalidGeometry() {
        #expect(throws: NotchShotError.captureFailed("Selection has invalid geometry")) {
            try RecordingAreaResolver.resolve(
                globalRect: CGRect(x: CGFloat.infinity, y: 0, width: 20, height: 20),
                displays: displays
            )
        }
    }
}

@Suite("Global hotkey safety")
struct GlobalHotKeySafetyTests {
    @Test("Caps Lock and Fn do not become a bare global shortcut")
    func nonCarbonModifiersAreRejected() {
        let capsLockOnly = HotKeyBinding.carbonModifiers(from: [.capsLock])
        let functionOnly = HotKeyBinding.carbonModifiers(from: [.function])
        let capsAndFunction = HotKeyBinding.carbonModifiers(from: [.capsLock, .function])

        #expect(capsLockOnly == 0)
        #expect(functionOnly == 0)
        #expect(capsAndFunction == 0)
        #expect(!HotKeyBinding(keyCode: 4, modifiers: capsLockOnly).isValidGlobalShortcut)
        #expect(!HotKeyBinding(keyCode: 4, modifiers: functionOnly).isValidGlobalShortcut)
    }

    @Test("Legitimate Carbon modifier combinations remain valid")
    func preservesLegitimateBindings() {
        let command = HotKeyBinding(
            keyCode: 4,
            modifiers: HotKeyBinding.carbonModifiers(from: [.command])
        )
        let fullCombination = HotKeyBinding(
            keyCode: 4,
            modifiers: HotKeyBinding.carbonModifiers(
                from: [.command, .shift, .option, .control, .capsLock, .function]
            )
        )

        #expect(command.modifiers == UInt32(cmdKey))
        #expect(command.isValidGlobalShortcut)
        #expect(fullCombination.modifiers == UInt32(cmdKey | shiftKey | optionKey | controlKey))
        #expect(fullCombination.isValidGlobalShortcut)
    }

    @Test("Unknown Carbon modifier bits are rejected")
    func rejectsUnknownModifierBits() {
        let binding = HotKeyBinding(
            keyCode: 4,
            modifiers: UInt32(cmdKey) | (1 << 31)
        )
        #expect(!binding.isValidGlobalShortcut)
    }
}
