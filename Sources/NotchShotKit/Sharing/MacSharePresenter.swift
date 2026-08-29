import AppKit

/// Presents the system share sheet without teaching the app about individual
/// destinations. Mail, Messages, AirDrop, Notes, and third-party services stay
/// owned by macOS instead of becoming separate NotchShot integrations.
@MainActor
public final class MacSharePresenter: NSObject,
    @preconcurrency NSSharingServicePickerDelegate,
    NSSharingServiceDelegate {
    public static let shared = MacSharePresenter()

    private var activePicker: NSSharingServicePicker?
    private var retainedItems: [Any] = []
    public var onFailure: ((Error) -> Void)?

    private override init() {}

    public func present(items: [Any], from preferredWindow: NSWindow? = nil) throws {
        guard !items.isEmpty else {
            throw NotchShotError.exportFailed("There is nothing to share")
        }
        guard let sourceView = sourceView(preferredWindow: preferredWindow) else {
            throw NotchShotError.exportFailed("The Share menu needs a visible NotchShot window")
        }

        retainedItems = items
        let picker = NSSharingServicePicker(items: items)
        picker.delegate = self
        activePicker = picker
        picker.show(relativeTo: sourceView.bounds, of: sourceView, preferredEdge: .minY)
    }

    public func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        didChoose service: NSSharingService?
    ) {
        service?.delegate = self
        if service == nil {
            finish()
        }
    }

    public func sharingService(
        _ sharingService: NSSharingService,
        didShareItems items: [Any]
    ) {
        finish()
    }

    public func sharingService(
        _ sharingService: NSSharingService,
        didFailToShareItems items: [Any],
        error: any Error
    ) {
        onFailure?(error)
        finish()
    }

    private func sourceView(preferredWindow: NSWindow?) -> NSView? {
        if let view = preferredWindow?.contentView { return view }
        if let view = NSApp.currentEvent?.window?.contentView { return view }
        if let view = NSApp.keyWindow?.contentView { return view }
        if let view = NSApp.mainWindow?.contentView { return view }
        return NSApp.windows.first(where: { $0.isVisible })?.contentView
    }

    private func finish() {
        activePicker = nil
        retainedItems.removeAll()
    }
}
