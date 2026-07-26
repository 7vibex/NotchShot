import AppKit
import CoreGraphics
import Foundation
import Observation

public enum RecipeDestination: String, Sendable, Codable, CaseIterable {
    case configuredFolder
    case clipboardOnly
    case askEveryTime

    public var title: String {
        switch self {
        case .configuredFolder: "Capture folder"
        case .clipboardOnly: "Clipboard only"
        case .askEveryTime: "Ask every time"
        }
    }
}

public enum RecipeAnnotationMode: String, Sendable, Codable, CaseIterable {
    case none
    case openEditor
    case privacyReview

    public var title: String {
        switch self {
        case .none: "None"
        case .openEditor: "Open annotation editor"
        case .privacyReview: "Run privacy review"
        }
    }
}

public struct CaptureRecipe: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let detail: String
    public let outputPixelSize: CGSize?
    public let background: BackgroundConfiguration
    public let annotationMode: RecipeAnnotationMode
    public let filenameTemplate: String
    public let destination: RecipeDestination
    public let imageFormat: ImageFormat?

    public var sizeDescription: String {
        guard let outputPixelSize else { return "Original size" }
        return "\(Int(outputPixelSize.width)) × \(Int(outputPixelSize.height))"
    }

    public static let all: [CaptureRecipe] = [
        CaptureRecipe(
            id: "standard",
            name: "Standard",
            detail: "Use the regular capture settings without extra framing.",
            outputPixelSize: nil,
            background: .none,
            annotationMode: .none,
            filenameTemplate: "NotchShot {date} at {time}",
            destination: .configuredFolder,
            imageFormat: nil
        ),
        CaptureRecipe(
            id: "github-issue",
            name: "GitHub Issue",
            detail: "Neutral framing and immediate markup for a reproducible issue.",
            outputPixelSize: nil,
            background: BackgroundPreset.preset(id: "graphite")?.configuration ?? .none,
            annotationMode: .openEditor,
            filenameTemplate: "GitHub Issue {date} {app}",
            destination: .configuredFolder,
            imageFormat: .png
        ),
        CaptureRecipe(
            id: "app-store",
            name: "App Store Screenshot",
            detail: "Apple's current 16:10 Mac screenshot size at 2880 × 1800.",
            outputPixelSize: CGSize(width: 2880, height: 1800),
            background: BackgroundConfiguration(
                fill: .solid(hex: "#F5F5F7"),
                padding: 72,
                cornerRadius: 18,
                shadowRadius: 34,
                shadowOpacity: 0.24,
                aspectRatio: 16.0 / 10.0
            ),
            annotationMode: .none,
            filenameTemplate: "App Store {date} {app}",
            destination: .askEveryTime,
            imageFormat: .png
        ),
        CaptureRecipe(
            id: "documentation",
            name: "Documentation",
            detail: "Readable light framing and markup for a step or help article.",
            outputPixelSize: nil,
            background: BackgroundPreset.preset(id: "paper")?.configuration ?? .none,
            annotationMode: .openEditor,
            filenameTemplate: "Documentation {date} {app}",
            destination: .configuredFolder,
            imageFormat: .png
        ),
        CaptureRecipe(
            id: "social-post",
            name: "Social Post",
            detail: "A framed 16:9 image ready for a social post.",
            outputPixelSize: CGSize(width: 1600, height: 900),
            background: BackgroundPreset.preset(id: "social")?.configuration ?? .none,
            annotationMode: .openEditor,
            filenameTemplate: "Social Post {date} {app}",
            destination: .askEveryTime,
            imageFormat: .png
        ),
        CaptureRecipe(
            id: "bug-report",
            name: "Bug Report",
            detail: "Privacy review first, then editable redactions and markup.",
            outputPixelSize: nil,
            background: .none,
            annotationMode: .privacyReview,
            filenameTemplate: "Bug Report {date} {app}",
            destination: .configuredFolder,
            imageFormat: .png
        ),
    ]
}

@MainActor
@Observable
public final class CaptureRecipeStore {
    public static let shared = CaptureRecipeStore()

    public var activeRecipeID: String {
        didSet { UserDefaults.standard.set(activeRecipeID, forKey: "notchshot.captureRecipe") }
    }

    public init() {
        let stored = UserDefaults.standard.string(forKey: "notchshot.captureRecipe")
        activeRecipeID = CaptureRecipe.all.contains(where: { $0.id == stored })
            ? (stored ?? "standard") : "standard"
    }

    public var activeRecipe: CaptureRecipe {
        CaptureRecipe.all.first(where: { $0.id == activeRecipeID }) ?? CaptureRecipe.all[0]
    }
}

public enum CaptureRecipeRenderer {
    public static func render(_ image: CapturedImage, recipe: CaptureRecipe) throws -> CapturedImage {
        guard recipe.id != "standard" else { return image }

        let document = AnnotationDocument(
            sourcePixelSize: image.pixelSize,
            sourceScale: image.scale,
            background: recipe.background
        )
        var output = try AnnotationRenderer.render(document: document, source: image.cgImage)

        if let target = recipe.outputPixelSize,
           output.width != Int(target.width) || output.height != Int(target.height) {
            guard let context = AnnotationRenderer.makeContext(
                width: Int(target.width),
                height: Int(target.height)
            ) else {
                throw NotchShotError.exportFailed("Could not allocate the recipe canvas")
            }
            context.interpolationQuality = .high
            context.draw(output, in: CGRect(origin: .zero, size: target))
            guard let resized = context.makeImage() else {
                throw NotchShotError.exportFailed("Could not resize the recipe output")
            }
            output = resized
        }

        return CapturedImage(
            cgImage: output,
            scale: image.scale,
            sourceRect: image.sourceRect
        )
    }
}
