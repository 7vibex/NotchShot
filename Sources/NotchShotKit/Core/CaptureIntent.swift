import CoreGraphics
import Foundation

/// What the user asked to capture.
public enum CaptureIntent: String, Sendable, Codable, CaseIterable, Identifiable {
    case area
    case window
    case display
    case scrolling
    case ocr
    case previousArea

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .area: "Capture Area"
        case .window: "Capture Window"
        case .display: "Capture Full Screen"
        case .scrolling: "Scrolling Capture"
        case .ocr: "Capture Text (OCR)"
        case .previousArea: "Capture Previous Area"
        }
    }

    public var shortTitle: String {
        switch self {
        case .area: "Area"
        case .window: "Window"
        case .display: "Screen"
        case .scrolling: "Scrolling"
        case .ocr: "OCR"
        case .previousArea: "Previous"
        }
    }

    public var symbolName: String {
        switch self {
        case .area: "square.dashed"
        case .window: "macwindow"
        case .display: "display"
        case .scrolling: "arrow.up.and.down.text.horizontal"
        case .ocr: "text.viewfinder"
        case .previousArea: "arrow.uturn.backward.square"
        }
    }

    /// Intents that put an interactive overlay on screen before capturing.
    public var needsSelection: Bool {
        switch self {
        case .area, .window, .scrolling, .ocr: true
        case .display, .previousArea: false
        }
    }
}

/// Delay applied before a capture fires.
public enum CaptureTimer: Int, Sendable, Codable, CaseIterable, Identifiable {
    case none = 0
    case three = 3
    case ten = 10

    public var id: Int { rawValue }
    public var title: String { self == .none ? "No Timer" : "\(rawValue)s" }
}

/// A fully-specified capture request handed to `CaptureService`.
public struct CaptureRequest: Sendable {
    public var intent: CaptureIntent
    public var timer: CaptureTimer
    /// Global (top-left origin) rect for `.area` / `.previousArea` / `.scrolling`.
    public var rect: CGRect?
    /// Window id for `.window`.
    public var windowID: CGWindowID?
    /// Display id for `.display`.
    public var displayID: CGDirectDisplayID?
    public var includesCursor: Bool

    public init(
        intent: CaptureIntent,
        timer: CaptureTimer = .none,
        rect: CGRect? = nil,
        windowID: CGWindowID? = nil,
        displayID: CGDirectDisplayID? = nil,
        includesCursor: Bool = false
    ) {
        self.intent = intent
        self.timer = timer
        self.rect = rect
        self.windowID = windowID
        self.displayID = displayID
        self.includesCursor = includesCursor
    }
}
