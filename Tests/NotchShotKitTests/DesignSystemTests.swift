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

    @Test("Liquid Glass APIs stay centralized in functional chrome")
    func liquidGlassPlacementIsCentralized() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = packageRoot.appending(path: "Sources/NotchShotKit")
        let allowedFilesByToken: [String: Set<String>] = [
            "glassEffect(": ["NotchShape.swift", "NotchShotDesignSystem.swift"],
            "GlassEffectContainer": ["NotchRootView.swift"],
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
        #expect(NotchDictationShellPolicy.shouldUseLiquidGlass(
            isActive: true,
            reduceTransparency: false,
            increaseContrast: false
        ))
        #expect(!NotchDictationShellPolicy.shouldUseLiquidGlass(
            isActive: true,
            reduceTransparency: true,
            increaseContrast: false
        ))
        #expect(!NotchDictationShellPolicy.shouldUseLiquidGlass(
            isActive: true,
            reduceTransparency: false,
            increaseContrast: true
        ))
        #expect(NotchDictationShellPolicy.fillOpacity(
            isActive: false,
            reduceTransparency: false,
            increaseContrast: false
        ) == 1)
    }

    @Test("Now Playing glow covers the shell above the content inset")
    func nowPlayingGlowCoversWholeShell() throws {
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
        #expect(shellSource.contains("mediaShellGlow"))
        #expect(shellSource.contains("NotchMediaGlowPolicy.shellOpacity"))

        let mediaStart = try #require(source.range(of: "private struct MediaContent"))
        let scrubberStart = try #require(source.range(
            of: "private struct MediaScrubber",
            range: mediaStart.upperBound..<source.endIndex
        ))
        let mediaSource = String(source[mediaStart.lowerBound..<scrubberStart.lowerBound])
        #expect(!mediaSource.contains("NotchMediaGlowPolicy.shellOpacity"))
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
