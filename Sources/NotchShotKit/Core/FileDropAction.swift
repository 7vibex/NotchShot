import AppKit
import Foundation

/// The destinations revealed while the user holds Finder files over the notch.
///
/// Which ones appear depends on what is being dragged: see
/// `FileDropContext`. Within a context the order is the left-to-right order
/// in the tray. Keep it stable so a drag does not move underneath the pointer
/// between releases.
public enum FileDropAction: String, Sendable, CaseIterable, Identifiable {
    case shelf
    case airDrop
    case share
    case localSend
    case compress
    case extract
    case uninstall
    case resetApp

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .shelf: "Shelf"
        case .airDrop: "AirDrop"
        case .share: "Share"
        case .localSend: "LocalSend"
        case .compress: "ZIP"
        case .extract: "Extract"
        case .uninstall: "Uninstall"
        case .resetApp: "Reset"
        }
    }

    public var subtitle: String {
        switch self {
        case .shelf: "Keep here"
        case .airDrop: "Send nearby"
        case .share: "Choose an app"
        case .localSend: "Send on LAN"
        case .compress: "Make archive"
        case .extract: "Unpack here"
        case .uninstall: "App and its data"
        case .resetApp: "Erase data only"
        }
    }

    public var symbolName: String {
        switch self {
        case .shelf: "tray.and.arrow.down.fill"
        case .airDrop: "airplayaudio"
        case .share: "square.and.arrow.up"
        case .localSend: "paperplane.fill"
        case .compress: "doc.zipper"
        case .extract: "archivebox.fill"
        case .uninstall: "trash.fill"
        case .resetApp: "arrow.counterclockwise"
        }
    }
}

/// What the user is holding over the notch, which decides the tray's
/// destinations.
public enum FileDropContext: Sendable, Equatable {
    case files
    /// Every item is an archive: Extract takes ZIP's place, since zipping a
    /// ZIP is rarely what anyone wants.
    case archives
    /// Every item is an app bundle. Apps get their own pair of actions;
    /// sharing a whole bundle over AirDrop is better done from Finder.
    case apps

    public var actions: [FileDropAction] {
        switch self {
        case .files: [.shelf, .airDrop, .share, .localSend, .compress]
        case .archives: [.shelf, .airDrop, .share, .localSend, .extract]
        case .apps: [.uninstall, .resetApp]
        }
    }

    public var defaultAction: FileDropAction { actions[0] }

    /// A mixed drag falls back to plain files.
    public static func classify(_ urls: [URL]) -> FileDropContext {
        guard !urls.isEmpty else { return .files }
        if urls.allSatisfy({ $0.pathExtension.lowercased() == "app" }) { return .apps }
        if urls.allSatisfy({ ArchiveExtractor.format(of: $0) != nil }) { return .archives }
        return .files
    }

    /// Reads the drag in flight. SwiftUI's item providers only load file URLs
    /// asynchronously, too late to lay out the tray, while the drag
    /// pasteboard has them already.
    @MainActor
    public static func currentDrag() -> FileDropContext {
        let urls = NSPasteboard(name: .drag).readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return classify(urls)
    }
}

/// Maps the pointer to one of the equal-width AirDrop-style destinations.
/// Kept outside SwiftUI so boundary behavior is deterministic and testable.
public enum FileDropActionSelection {
    public static func action(
        atX x: CGFloat,
        width: CGFloat,
        actions: [FileDropAction] = FileDropContext.files.actions
    ) -> FileDropAction {
        guard x.isFinite, width.isFinite, width > 0, !actions.isEmpty else {
            return actions.first ?? .shelf
        }

        let clampedX = min(max(x, 0), width)
        let fraction = min(clampedX / width, 1.nextDown)
        let index = min(Int(fraction * CGFloat(actions.count)), actions.count - 1)
        return actions[index]
    }

    public static func adjacent(
        to action: FileDropAction,
        delta: Int,
        actions: [FileDropAction] = FileDropContext.files.actions
    ) -> FileDropAction {
        guard let index = actions.firstIndex(of: action) else {
            return actions.first ?? .shelf
        }
        return actions[min(max(index + delta, 0), actions.count - 1)]
    }
}
