import AppKit
import QuickLookUI

/// Shows the system Quick Look panel for shelf and History items.
///
/// Quick Look asks the responder chain which object is driving it, and an
/// accessory app whose only windows are nonactivating panels has nothing useful
/// in that chain. `AppDelegate` therefore answers on this presenter's behalf —
/// the application delegate is always in the chain — and this type owns nothing
/// but the list of URLs being previewed.
@MainActor
public final class QuickLookPresenter: NSObject,
    @preconcurrency QLPreviewPanelDataSource,
    QLPreviewPanelDelegate {
    public static let shared = QuickLookPresenter()

    private var urls: [URL] = []

    private override init() { super.init() }

    public var isPresenting: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    public func present(_ candidates: [URL]) throws {
        let readable = candidates.filter { url in
            guard url.isFileURL else { return false }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values?.isRegularFile == true && values?.isSymbolicLink != true
        }
        guard !readable.isEmpty else {
            throw NotchShotError.exportFailed("There is nothing left to preview at that location")
        }
        urls = readable

        // Quick Look is a real window with real keyboard focus, so unlike the
        // notch itself this genuinely needs the app foregrounded.
        NSApp.activate(ignoringOtherApps: true)
        let panel = QLPreviewPanel.shared()
        panel?.updateController()
        panel?.makeKeyAndOrderFront(nil)
        panel?.reloadData()
    }

    public func dismiss() {
        guard isPresenting else { return }
        QLPreviewPanel.shared()?.orderOut(nil)
    }

    // MARK: QLPreviewPanelDataSource

    public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
    }
}
