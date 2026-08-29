import Foundation

/// The destinations revealed while the user holds Finder files over the notch.
///
/// The order is also the left-to-right order in the tray. Keep it stable so a
/// drag does not move underneath the pointer between releases.
public enum FileDropAction: String, Sendable, CaseIterable, Identifiable {
    case shelf
    case airDrop
    case share
    case compress

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .shelf: "Shelf"
        case .airDrop: "AirDrop"
        case .share: "Share"
        case .compress: "ZIP"
        }
    }

    public var subtitle: String {
        switch self {
        case .shelf: "Keep here"
        case .airDrop: "Send nearby"
        case .share: "Choose an app"
        case .compress: "Make archive"
        }
    }

    public var symbolName: String {
        switch self {
        case .shelf: "tray.and.arrow.down.fill"
        case .airDrop: "airplayaudio"
        case .share: "square.and.arrow.up"
        case .compress: "doc.zipper"
        }
    }
}

/// Maps the pointer to one of the equal-width AirDrop-style destinations.
/// Kept outside SwiftUI so boundary behavior is deterministic and testable.
public enum FileDropActionSelection {
    public static func action(atX x: CGFloat, width: CGFloat) -> FileDropAction {
        let actions = FileDropAction.allCases
        guard x.isFinite, width.isFinite, width > 0, !actions.isEmpty else {
            return .shelf
        }

        let clampedX = min(max(x, 0), width)
        let fraction = min(clampedX / width, 1.nextDown)
        let index = min(Int(fraction * CGFloat(actions.count)), actions.count - 1)
        return actions[index]
    }

    public static func adjacent(
        to action: FileDropAction,
        delta: Int
    ) -> FileDropAction {
        let actions = FileDropAction.allCases
        guard let index = actions.firstIndex(of: action), !actions.isEmpty else {
            return .shelf
        }
        return actions[min(max(index + delta, 0), actions.count - 1)]
    }
}
