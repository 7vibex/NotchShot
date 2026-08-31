import AppKit
import Foundation
import Testing
@testable import NotchShotKit

@Suite("Design system")
struct DesignSystemTests {
    @Test("Island accents meet the normal-text contrast floor")
    func islandAccentContrast() throws {
        let original = NSColor(srgbRed: 0.02, green: 0.08, blue: 0.35, alpha: 1)
        let readable = NotchShotColorPolicy.readableAccentOnBlack(original)

        #expect(NotchShotColorPolicy.contrastRatio(readable, .black)
            >= NotchShotColorPolicy.minimumTextContrast)
        let foreground = NotchShotColorPolicy.foreground(on: readable)
        #expect(NotchShotColorPolicy.contrastRatio(foreground, readable)
            >= NotchShotColorPolicy.minimumTextContrast)
    }

    @Test("Compact island controls use the shared hit-target floor")
    func islandControlTargets() {
        #expect(NotchIsland.Hit.control == NotchShotDesignSystem.minimumControlTarget)
        #expect(NotchIsland.Hit.control >= 36)
    }

    @Test("Dynamic Island geometry stays compact, concentric, and elastic")
    func dynamicIslandGeometryAndMotion() {
        #expect(NotchIsland.Geometry.syntheticCoreSize == CGSize(width: 126, height: 37))
        #expect(NotchIsland.Geometry.compactActivityWidth == 230)
        #expect(NotchIsland.Geometry.expandedCaptureWidth == 432)
        #expect(NotchIsland.Geometry.expandedCaptureHeight == 164)
        #expect(NotchIsland.Geometry.expandedCornerRadius >= 30)
        #expect(NotchIsland.Motion.shellResponse > NotchIsland.Motion.contentResponse)
        #expect(NotchIsland.Motion.shellDamping < NotchIsland.Motion.contentDamping)
    }

    @Test("Liquid Glass APIs stay centralized in functional chrome")
    func liquidGlassPlacementIsCentralized() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = packageRoot.appending(path: "Sources/NotchShotKit")
        let allowedFilesByToken: [String: Set<String>] = [
            "glassEffect(": ["NotchShape.swift", "NotchShotDesignSystem.swift"],
            "GlassEffectContainer": ["NotchRootView.swift", "NotchShotDesignSystem.swift"],
            ".glassProminent": ["NotchShotDesignSystem.swift"],
        ]

        let enumerator = try #require(
            FileManager.default.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: nil
            )
        )
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            for (token, allowedFiles) in allowedFilesByToken where source.contains(token) {
                #expect(allowedFiles.contains(fileURL.lastPathComponent))
            }
        }
    }

    @Test("Activity cards use native glass without an opaque black wash")
    func activityCardsUseNativeGlass() throws {
        #expect(NotchActivityGlassPolicy.usesLiquidGlass(
            reduceTransparency: false,
            increaseContrast: false
        ))
        #expect(!NotchActivityGlassPolicy.usesLiquidGlass(
            reduceTransparency: true,
            increaseContrast: false
        ))
        #expect(!NotchActivityGlassPolicy.usesLiquidGlass(
            reduceTransparency: false,
            increaseContrast: true
        ))
        #expect(LockedNowPlayingGlassPolicy.usesLiquidGlass(
            reduceTransparency: false,
            increaseContrast: false
        ))
        #expect(LockedNowPlayingGlassPolicy.dimmingOpacity <= 0.08)
        #expect(!LockedNowPlayingGlassPolicy.usesLiquidGlass(
            reduceTransparency: true,
            increaseContrast: false
        ))
        #expect(!LockedNowPlayingGlassPolicy.usesLiquidGlass(
            reduceTransparency: false,
            increaseContrast: true
        ))
        #expect(NotchActivityGlassPolicy.tintOpacity <= 0.12)

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot.appending(
            path: "Sources/NotchShotKit/Productivity/ProductivityNotificationCenterView.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(source.contains(".notchShotActivityGlassSurface("))
        #expect(!source.contains(".fill(.ultraThinMaterial)"))
        #expect(!source.contains("Color.black.opacity(0.50)"))

        let designSystemURL = packageRoot.appending(
            path: "Sources/NotchShotKit/UI/NotchShotDesignSystem.swift"
        )
        let designSystem = try String(contentsOf: designSystemURL, encoding: .utf8)
        #expect(designSystem.contains(".glassEffect(.clear, in: shape)"))
        #expect(designSystem.contains("LockedNowPlayingGlassPolicy.dimmingOpacity"))
        #expect(!designSystem.contains("LockedNowPlayingGlassPolicy.surfaceOpacity"))
        #expect(!designSystem.contains("LockedNowPlayingGlassPolicy.tintOpacity"))

        let lockedCardURL = packageRoot.appending(
            path: "Sources/NotchShotKit/UI/LockedNowPlayingCard.swift"
        )
        let lockedCard = try String(contentsOf: lockedCardURL, encoding: .utf8)
        #expect(lockedCard.contains("Image(systemName: \"waveform\")"))
        #expect(lockedCard.contains("transportSymbol(\"heart.fill\""))
        #expect(lockedCard.contains("transportSymbol(\"display\""))
        #expect(!lockedCard.contains("transportSymbol(\"shuffle\""))
        #expect(!lockedCard.contains("transportSymbol(\"headphones\""))
        #expect(LockedNowPlayingLayout.artworkSize == 64)
        #expect(LockedNowPlayingLayout.cornerRadius == 20)
    }

    @Test("Accessibility appearances replace Liquid Glass with stable chrome")
    func liquidGlassAccessibilityPolicy() {
        #expect(NotchShotDesignSystem.usesLiquidGlass(
            reduceTransparency: false,
            increaseContrast: false
        ))
        #expect(!NotchShotDesignSystem.usesLiquidGlass(
            reduceTransparency: true,
            increaseContrast: false
        ))
        #expect(!NotchShotDesignSystem.usesLiquidGlass(
            reduceTransparency: false,
            increaseContrast: true
        ))
        #expect(NotchMediaGlowPolicy.shouldShow(
            isMedia: true,
            reduceTransparency: false,
            increaseContrast: false
        ))
        #expect(!NotchMediaGlowPolicy.shouldShow(
            isMedia: false,
            reduceTransparency: false,
            increaseContrast: false
        ))
        #expect(!NotchMediaGlowPolicy.shouldShow(
            isMedia: true,
            reduceTransparency: true,
            increaseContrast: false
        ))
        #expect(!NotchMediaGlowPolicy.shouldShow(
            isMedia: true,
            reduceTransparency: false,
            increaseContrast: true
        ))
    }

    @Test("Now Playing keeps an opaque shell and never tints it with the artwork")
    func nowPlayingUsesKeylineInsteadOfShellTint() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot.appending(
            path: "Sources/NotchShotKit/UI/NotchRootView.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let islandStart = try #require(source.range(of: "private var island: some View"))
        let contentStart = try #require(source.range(
            of: "private var styledContent: some View",
            range: islandStart.upperBound..<source.endIndex
        ))
        let shellSource = String(source[islandStart.lowerBound..<contentStart.lowerBound])

        #expect(shellSource.contains(".fill(.black)"))
        #expect(shellSource.contains("mediaShellKeyline"))
        #expect(!shellSource.contains("LinearGradient("))
        // The shell's edge is a neutral hairline. Tracing it in the cover's
        // accent turned the island's corners red for one album and green for
        // the next, which read as a status signal the app never meant.
        #expect(!shellSource.contains("artworkAccentColor"))
        #expect(!shellSource.contains("NotchMediaGlowPolicy.haloOpacity"))

        let mediaStart = try #require(source.range(of: "private struct MediaContent"))
        let scrubberStart = try #require(source.range(
            of: "private struct MediaScrubber",
            range: mediaStart.upperBound..<source.endIndex
        ))
        let mediaSource = String(source[mediaStart.lowerBound..<scrubberStart.lowerBound])
        #expect(!mediaSource.contains("NotchMediaGlowPolicy.keylineOpacity"))
    }

    @Test("Audio output selector opens inside the island as rounded device rows")
    func audioOutputSelectorUsesDeviceCard() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot.appending(
            path: "Sources/NotchShotKit/UI/NotchRootView.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let mediaStart = try #require(source.range(of: "private struct MediaContent"))
        let scrubberStart = try #require(source.range(
            of: "private struct MediaScrubber",
            range: mediaStart.upperBound..<source.endIndex
        ))
        let mediaSource = String(source[mediaStart.lowerBound..<scrubberStart.lowerBound])

        // The list grows the island itself: a popover would be a second window
        // with its own shadow and arrow, which reads as a menu escaping the
        // notch rather than the player expanding.
        #expect(!mediaSource.contains(".popover(isPresented:"))
        #expect(mediaSource.contains("coordinator.setMediaPanel"))
        #expect(mediaSource.contains("LazyVStack(spacing: NotchLayout.mediaPanelRowSpacing)"))
        #expect(!mediaSource.contains("Menu {"))

        #expect(mediaSource.contains("private struct AudioOutputDeviceRow"))
        #expect(mediaSource.contains("checkmark.circle.fill"))
    }

    @Test("Annotation tools adapt instead of exposing a horizontal scrollbar")
    func annotationToolbarAdaptsToWindowWidth() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot.appending(
            path: "Sources/NotchShotKit/Annotation/AnnotationEditorView.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("ViewThatFits(in: .horizontal)"))
        #expect(!source.contains("ScrollView(.horizontal)"))
    }

    @Test("Major utility surfaces use the shared motion system")
    func utilitySurfaceMotionIsCentralized() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = packageRoot.appending(path: "Sources/NotchShotKit")
        let designSystem = try String(
            contentsOf: sourceRoot.appending(path: "UI/NotchShotDesignSystem.swift"),
            encoding: .utf8
        )
        #expect(designSystem.contains("enum NotchShotMotion"))
        #expect(designSystem.contains("notchShotContentSwap"))
        #expect(designSystem.contains("notchShotHoverMotion"))

        for relativePath in [
            "UI/SettingsView.swift",
            "UI/HistoryView.swift",
            "UI/ClipboardView.swift",
        ] {
            let source = try String(
                contentsOf: sourceRoot.appending(path: relativePath),
                encoding: .utf8
            )
            #expect(source.contains("notchShotContentSwap"))
        }
    }

    @Test("Reduce Motion removes spatial movement but keeps stable geometry")
    func reduceMotionPolicy() {
        #expect(NotchShotMotion.allowsSpatialAnimation(reduceMotion: false))
        #expect(!NotchShotMotion.allowsSpatialAnimation(reduceMotion: true))
        #expect(NotchShotMotion.activeScale(
            isActive: true,
            reduceMotion: false
        ) == NotchShotMotion.hoverScale)
        #expect(NotchShotMotion.activeScale(
            isActive: true,
            reduceMotion: true
        ) == 1)
        #expect(NotchShotMotion.activeOffset(
            isActive: true,
            reduceMotion: false
        ) == NotchShotMotion.hoverOffset)
        #expect(NotchShotMotion.activeOffset(
            isActive: true,
            reduceMotion: true
        ) == 0)
        #expect(NotchShotMotion.activeScale(
            isActive: false,
            reduceMotion: false,
            activeScale: NotchShotMotion.pressedScale
        ) == 1)
        #expect(NotchShotMotion.contentTravel > 0)
    }
}
