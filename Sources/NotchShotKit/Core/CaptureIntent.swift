import CoreGraphics
import Foundation

/// What the user asked to capture.
public enum CaptureIntent: String, Sendable, Codable, CaseIterable, Identifiable {
    case area
    case window
    case display
    case scrolling
    case ocr
    /// Select an area and see what can be done with it: its links, dates,
    /// numbers and text, in the notch.
    case lookUp
    case previousArea

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .area: "Capture Area"
        case .window: "Capture Window"
        case .display: "Capture Full Screen"
        case .scrolling: "Scrolling Capture"
        case .ocr: "Capture Text (OCR)"
        case .lookUp: "Look Up"
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
        case .lookUp: "Look Up"
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
        case .lookUp: "text.magnifyingglass"
        case .previousArea: "arrow.uturn.backward.square"
        }
    }

    /// Intents that put an interactive overlay on screen before capturing.
    public var needsSelection: Bool {
        switch self {
        case .area, .window, .scrolling, .ocr, .lookUp: true
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
    /// The frozen display the user drew the selection on, when the result
    /// should be exactly that frame. See `FrozenSelectionPolicy`.
    public var selectionFreezeFrame: CapturedImage?

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

extension CaptureRequest {
    /// Folds the overlay's answer into the request. Returns false when the
    /// user cancelled.
    ///
    /// Window mode takes a drag as an area, as its instructions say ("Click a
    /// window · drag for an area"). The request used to keep `.window` with no
    /// window id for that drag, so the capture failed as "window not found".
    mutating func apply(_ selection: SelectionResult) -> Bool {
        switch selection {
        case .area(let selected, let displayID):
            rect = selected
            self.displayID = displayID
            if intent == .window { intent = .area }
            return true
        case .window(let window):
            windowID = window.id
            intent = .window
            return true
        case .cancelled:
            return false
        }
    }
}

/// When an area capture is cut from the frozen frame the user selected on
/// instead of being taken again.
enum FrozenSelectionPolicy {
    static func usesFreezeFrame(
        intent: CaptureIntent,
        timer: CaptureTimer,
        includesCursor: Bool,
        freezeWasShown: Bool
    ) -> Bool {
        // What was on screen is the point only when the user was looking at
        // the frozen frame and the capture fires straight away. A countdown
        // means "capture what is there when it ends"; the cursor isn't in the
        // freeze frame; scrolling captures live frames by design.
        freezeWasShown
            && timer == .none
            && !includesCursor
            && (intent == .area || intent == .ocr || intent == .lookUp)
    }
}
