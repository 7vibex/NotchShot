import AppKit
import CoreGraphics
import Foundation

public enum BackgroundFill: Codable, Sendable, Equatable {
    case none
    case solid(hex: String)
    /// Angle in degrees, 0 = left→right, 90 = bottom→top.
    case gradient(startHex: String, endHex: String, angle: Double)
    /// Relative path inside the `.notchshot` package, or an absolute file path.
    case image(path: String)

    public var isTransparent: Bool { self == .none }
}

/// Preset framings offered in the editor.
public struct BackgroundPreset: Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let configuration: BackgroundConfiguration

    public static let all: [BackgroundPreset] = [
        BackgroundPreset(id: "none", title: "None", configuration: .none),
        BackgroundPreset(
            id: "paper",
            title: "Paper",
            configuration: BackgroundConfiguration(
                fill: .solid(hex: "#F5F5F7"),
                padding: 56,
                cornerRadius: 12,
                shadowRadius: 24,
                shadowOpacity: 0.18
            )
        ),
        BackgroundPreset(
            id: "graphite",
            title: "Graphite",
            configuration: BackgroundConfiguration(
                fill: .solid(hex: "#1C1C1E"),
                padding: 56,
                cornerRadius: 12,
                shadowRadius: 30,
                shadowOpacity: 0.5
            )
        ),
        BackgroundPreset(
            id: "sunset",
            title: "Sunset",
            configuration: BackgroundConfiguration(
                fill: .gradient(startHex: "#FF5F6D", endHex: "#FFC371", angle: 135),
                padding: 72,
                cornerRadius: 14,
                shadowRadius: 34,
                shadowOpacity: 0.32
            )
        ),
        BackgroundPreset(
            id: "ocean",
            title: "Ocean",
            configuration: BackgroundConfiguration(
                fill: .gradient(startHex: "#2E3192", endHex: "#1BFFFF", angle: 120),
                padding: 72,
                cornerRadius: 14,
                shadowRadius: 34,
                shadowOpacity: 0.32
            )
        ),
        BackgroundPreset(
            id: "social",
            title: "Social 16:9",
            configuration: BackgroundConfiguration(
                fill: .gradient(startHex: "#8E2DE2", endHex: "#4A00E0", angle: 135),
                padding: 90,
                cornerRadius: 16,
                shadowRadius: 40,
                shadowOpacity: 0.38,
                aspectRatio: 16.0 / 9.0
            )
        ),
    ]

    public static func preset(id: String) -> BackgroundPreset? {
        all.first { $0.id == id }
    }
}

public struct BackgroundConfiguration: Codable, Sendable, Equatable {
    public var fill: BackgroundFill
    /// Padding around the screenshot, in points at 1×.
    public var padding: Double
    public var cornerRadius: Double
    public var shadowRadius: Double
    public var shadowOpacity: Double
    /// Forces an output aspect ratio (width / height); nil keeps the natural one.
    public var aspectRatio: Double?
    /// -1…1 horizontal bias, 0 = centred.
    public var horizontalAlignment: Double
    public var verticalAlignment: Double
    /// Nudges the image toward optical centre when an aspect ratio is forced.
    public var balancesAutomatically: Bool
    /// Draws a subtle inset border on the screenshot, like a window edge.
    public var drawsInnerBorder: Bool

    public init(
        fill: BackgroundFill = .none,
        padding: Double = 0,
        cornerRadius: Double = 0,
        shadowRadius: Double = 0,
        shadowOpacity: Double = 0,
        aspectRatio: Double? = nil,
        horizontalAlignment: Double = 0,
        verticalAlignment: Double = 0,
        balancesAutomatically: Bool = true,
        drawsInnerBorder: Bool = true
    ) {
        self.fill = fill
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadowRadius = shadowRadius
        self.shadowOpacity = shadowOpacity
        self.aspectRatio = aspectRatio
        self.horizontalAlignment = horizontalAlignment
        self.verticalAlignment = verticalAlignment
        self.balancesAutomatically = balancesAutomatically
        self.drawsInnerBorder = drawsInnerBorder
    }

    public static let none = BackgroundConfiguration()

    public var isEnabled: Bool {
        !(fill.isTransparent && padding == 0 && cornerRadius == 0 && shadowRadius == 0 && aspectRatio == nil)
    }

    /// Computes the output canvas and where the screenshot sits inside it.
    ///
    /// Pure so the layout — especially the aspect-ratio and optical-balance
    /// behaviour — can be verified without rendering anything.
    public func layout(for contentPixelSize: CGSize, scale: CGFloat) -> (canvas: CGSize, content: CGRect) {
        guard contentPixelSize.width > 0, contentPixelSize.height > 0 else {
            return (CGSize(width: 1, height: 1), CGRect(x: 0, y: 0, width: 1, height: 1))
        }

        let paddingPixels = padding * Double(scale)
        var canvasWidth = Double(contentPixelSize.width) + paddingPixels * 2
        var canvasHeight = Double(contentPixelSize.height) + paddingPixels * 2

        if let aspectRatio, aspectRatio > 0 {
            // Grow the short side rather than cropping — a background should
            // never remove pixels from the capture.
            let currentRatio = canvasWidth / canvasHeight
            if currentRatio < aspectRatio {
                canvasWidth = canvasHeight * aspectRatio
            } else {
                canvasHeight = canvasWidth / aspectRatio
            }
        }

        let freeX = canvasWidth - Double(contentPixelSize.width)
        let freeY = canvasHeight - Double(contentPixelSize.height)

        var originX = freeX / 2 + (horizontalAlignment * freeX / 2)
        var originY = freeY / 2 + (verticalAlignment * freeY / 2)

        if balancesAutomatically, aspectRatio != nil {
            // Optical centring: a shape placed at the exact geometric centre
            // reads as slightly low, so lift it by a small fraction of the
            // vertical slack.
            originY -= freeY * 0.04
        }

        originX = min(max(originX, 0), max(0, freeX))
        originY = min(max(originY, 0), max(0, freeY))

        return (
            CGSize(width: canvasWidth.rounded(), height: canvasHeight.rounded()),
            CGRect(
                x: originX.rounded(),
                y: originY.rounded(),
                width: contentPixelSize.width,
                height: contentPixelSize.height
            )
        )
    }
}
