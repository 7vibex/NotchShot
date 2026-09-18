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
    /// The island transfer for an AirDrop share. AirDrop's public API reports
    /// only that sharing started, succeeded, or failed — never bytes — so the
    /// activity stays indeterminate and says "Shared", not "Delivered".
    private var airDropTransferID: UUID?
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
        } else if let service, Self.isAirDrop(service) {
            airDropTransferID = TransferActivityStore.shared.begin(
                service: .airDrop,
                peerName: "AirDrop",
                fileCount: retainedItems.count
            )
        }
    }

    public func sharingService(_ sharingService: NSSharingService, willShareItems items: [Any]) {
        guard let airDropTransferID else { return }
        TransferActivityStore.shared.markTransferring(airDropTransferID)
    }

    private static func isAirDrop(_ service: NSSharingService) -> Bool {
        guard let airDrop = NSSharingService(named: .sendViaAirDrop) else { return false }
        return service.title == airDrop.title
    }

    public func sharingService(
        _ sharingService: NSSharingService,
        didShareItems items: [Any]
    ) {
        if let airDropTransferID { TransferActivityStore.shared.finish(airDropTransferID) }
        finish()
    }

    public func sharingService(
        _ sharingService: NSSharingService,
        didFailToShareItems items: [Any],
        error: any Error
    ) {
        if let airDropTransferID {
            TransferActivityStore.shared.finish(airDropTransferID, error: error.localizedDescription)
        }
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
        airDropTransferID = nil
        activePicker = nil
        retainedItems.removeAll()
    }
}
