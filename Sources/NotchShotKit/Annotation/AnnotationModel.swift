import AppKit
import CoreGraphics
import Foundation

public enum AnnotationKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case arrow
    case rectangle
    case ellipse
    case line
    case text
    case pencil
    case highlighter
    case counter
    /// Opaque fill. Nothing of the original survives in the export.
    case blackout
    /// Destructive pixelation of the underlying pixels.
    case pixelate

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .line: "Line"
        case .text: "Text"
        case .pencil: "Pencil"
        case .highlighter: "Highlighter"
        case .counter: "Step"
        case .blackout: "Blackout"
        case .pixelate: "Pixelate"
        }
    }

    public var symbolName: String {
        switch self {
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .text: "textformat"
        case .pencil: "pencil"
        case .highlighter: "highlighter"
        case .counter: "1.circle"
        case .blackout: "rectangle.fill"
        case .pixelate: "mosaic"
        }
    }

    /// Kinds that permanently destroy the pixels beneath them on export.
    public var isRedaction: Bool { self == .blackout || self == .pixelate }

    /// Kinds defined by a freehand path rather than two handles.
    public var isFreehand: Bool { self == .pencil || self == .highlighter }

    /// Kinds defined by a single anchor point.
    public var isPointAnchored: Bool { self == .counter || self == .text }
}

public struct AnnotationStyle: Codable, Sendable, Equatable {
    public var colorHex: String
    public var lineWidth: Double
    public var opacity: Double
    public var isFilled: Bool
    public var fontSize: Double
    public var cornerRadius: Double
    /// Edge length of one pixelation block, in source pixels.
    public var pixelBlockSize: Double
    public var hasShadow: Bool

    public init(
        colorHex: String = "#FF3B30",
        lineWidth: Double = 4,
        opacity: Double = 1,
        isFilled: Bool = false,
        fontSize: Double = 24,
        cornerRadius: Double = 4,
        pixelBlockSize: Double = 14,
        hasShadow: Bool = true
    ) {
        self.colorHex = colorHex
        self.lineWidth = lineWidth
        self.opacity = opacity
        self.isFilled = isFilled
        self.fontSize = fontSize
        self.cornerRadius = cornerRadius
        self.pixelBlockSize = pixelBlockSize
        self.hasShadow = hasShadow
    }

    public var color: NSColor {
        NSColor(hex: colorHex) ?? .systemRed
    }

    public static func `default`(for kind: AnnotationKind, baseColorHex: String, lineWidth: Double) -> AnnotationStyle {
        var style = AnnotationStyle(colorHex: baseColorHex, lineWidth: lineWidth)
        switch kind {
        case .highlighter:
            style.colorHex = "#FFD60A"
            style.lineWidth = max(lineWidth * 4, 18)
            style.opacity = 0.4
            style.hasShadow = false
        case .blackout:
            style.colorHex = "#000000"
            style.isFilled = true
            style.hasShadow = false
        case .pixelate:
            style.hasShadow = false
        case .text:
            style.hasShadow = false
        case .counter:
            style.isFilled = true
        default:
            break
        }
        return style
    }
}

/// One drawn element.
///
/// Geometry lives in the *source image's* pixel space with a top-left origin,
/// so crop, rotation and background composition can all be applied afterwards
/// without rewriting every element.
public struct AnnotationElement: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: AnnotationKind
    /// Two points for shapes (start, end); many for freehand; one for anchored.
    public var points: [CGPoint]
    public var style: AnnotationStyle
    public var text: String
    /// Stacking order, ascending.
    public var order: Int
    /// Number shown by a `.counter` element.
    public var counterValue: Int

    public init(
        id: UUID = UUID(),
        kind: AnnotationKind,
        points: [CGPoint],
        style: AnnotationStyle,
        text: String = "",
        order: Int = 0,
        counterValue: Int = 1
    ) {
        self.id = id
        self.kind = kind
        self.points = points
        self.style = style
        self.text = text
        self.order = order
        self.counterValue = counterValue
    }

    /// Axis-aligned bounds in source space.
    public var boundingRect: CGRect {
        guard let first = points.first else { return .zero }
        if kind.isPointAnchored {
            let side = max(style.fontSize * 2, 44)
            return CGRect(x: first.x - side / 2, y: first.y - side / 2, width: side, height: side)
        }
        var minPoint = first
        var maxPoint = first
        for point in points {
            minPoint.x = min(minPoint.x, point.x)
            minPoint.y = min(minPoint.y, point.y)
            maxPoint.x = max(maxPoint.x, point.x)
            maxPoint.y = max(maxPoint.y, point.y)
        }
        return CGRect(
            x: minPoint.x,
            y: minPoint.y,
            width: maxPoint.x - minPoint.x,
            height: maxPoint.y - minPoint.y
        )
    }

    /// Bounds grown by the stroke so hit-testing and dirty rects include it.
    public var hitRect: CGRect {
        boundingRect.insetBy(dx: -style.lineWidth - 6, dy: -style.lineWidth - 6)
    }

    public func contains(_ point: CGPoint) -> Bool {
        hitRect.contains(point)
    }

    public func moved(by delta: CGSize) -> AnnotationElement {
        var copy = self
        copy.points = points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) }
        return copy
    }
}

public enum RotationAngle: Int, Codable, Sendable, CaseIterable {
    case none = 0
    case ninety = 90
    case oneEighty = 180
    case twoSeventy = 270

    public var radians: CGFloat { CGFloat(rawValue) * .pi / 180 }
    /// True when the rotation swaps width and height.
    public var swapsAxes: Bool { self == .ninety || self == .twoSeventy }

    public func rotatedLeft() -> RotationAngle {
        RotationAngle(rawValue: (rawValue + 270) % 360) ?? .none
    }

    public func rotatedRight() -> RotationAngle {
        RotationAngle(rawValue: (rawValue + 90) % 360) ?? .none
    }
}

/// The complete editable state of an annotated capture.
public struct AnnotationDocument: Codable, Sendable, Equatable {
    /// Format version, so future changes can migrate rather than fail.
    public var version = 1
    /// Pixel size of the source image the geometry refers to.
    public var sourcePixelSize: CGSize
    /// Backing scale of the original capture.
    public var sourceScale: CGFloat
    /// Crop in source pixel space; nil means the whole image.
    public var cropRect: CGRect?
    public var rotation: RotationAngle
    public var elements: [AnnotationElement]
    public var background: BackgroundConfiguration
    public var createdAt: Date
    public var modifiedAt: Date

    public init(
        sourcePixelSize: CGSize,
        sourceScale: CGFloat = 2,
        cropRect: CGRect? = nil,
        rotation: RotationAngle = .none,
        elements: [AnnotationElement] = [],
        background: BackgroundConfiguration = .none,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.sourcePixelSize = sourcePixelSize
        self.sourceScale = sourceScale
        self.cropRect = cropRect
        self.rotation = rotation
        self.elements = elements
        self.background = background
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    public var effectiveCrop: CGRect {
        cropRect ?? CGRect(origin: .zero, size: sourcePixelSize)
    }

    /// Next number for a new step marker.
    public var nextCounterValue: Int {
        (elements.filter { $0.kind == .counter }.map(\.counterValue).max() ?? 0) + 1
    }

    public var sortedElements: [AnnotationElement] {
        elements.sorted { $0.order < $1.order }
    }

    public mutating func add(_ element: AnnotationElement) {
        var element = element
        element.order = (elements.map(\.order).max() ?? 0) + 1
        elements.append(element)
        modifiedAt = Date()
    }

    public mutating func update(_ element: AnnotationElement) {
        guard let index = elements.firstIndex(where: { $0.id == element.id }) else { return }
        elements[index] = element
        modifiedAt = Date()
    }

    public mutating func remove(id: UUID) {
        elements.removeAll { $0.id == id }
        modifiedAt = Date()
    }

    /// Topmost element under a point, for selection.
    public func element(at point: CGPoint) -> AnnotationElement? {
        sortedElements.reversed().first { $0.contains(point) }
    }

    public var hasRedactions: Bool {
        elements.contains { $0.kind.isRedaction }
    }
}

// MARK: - Colour helpers

public extension NSColor {
    /// Parses `#RGB`, `#RRGGBB` and `#RRGGBBAA`.
    convenience init?(hex: String) {
        var string = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.hasPrefix("#") { string.removeFirst() }
        if string.count == 3 {
            string = string.map { "\($0)\($0)" }.joined()
        }
        guard string.count == 6 || string.count == 8,
              let value = UInt64(string, radix: 16) else { return nil }

        let hasAlpha = string.count == 8
        let red, green, blue, alpha: CGFloat
        if hasAlpha {
            red = CGFloat((value >> 24) & 0xFF) / 255
            green = CGFloat((value >> 16) & 0xFF) / 255
            blue = CGFloat((value >> 8) & 0xFF) / 255
            alpha = CGFloat(value & 0xFF) / 255
        } else {
            red = CGFloat((value >> 16) & 0xFF) / 255
            green = CGFloat((value >> 8) & 0xFF) / 255
            blue = CGFloat(value & 0xFF) / 255
            alpha = 1
        }
        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    var hexString: String {
        guard let converted = usingColorSpace(.sRGB) else { return "#000000" }
        let red = Int((converted.redComponent * 255).rounded())
        let green = Int((converted.greenComponent * 255).rounded())
        let blue = Int((converted.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
