import AppKit
import Foundation

/// Look Up: what the user can do with an area of the screen, shown in the
/// notch. It reads the area with the same OCR and detectors as Capture Text,
/// but saves nothing: no history entry, no shelf item, no clipboard change
/// unless the user asks for one.
@MainActor
extension AppCoordinator {
    func handleLookUpCapture(_ image: CapturedImage, operationID: UUID) async {
        arbiter.isProcessing = "Looking up"
        refreshActivity()
        do {
            let ocr = try await OCRService.shared.recognizeText(in: image)
            guard isCurrentCapture(operationID) else { return }
            // Measuring the text and guessing its language are both text
            // layout and model work; neither belongs on the main thread.
            let card = await Task.detached(priority: .userInitiated) {
                let result = LookUpResult(ocr: ocr)
                return LookUpCard(
                    result: result,
                    textLineCount: LookUpCardMetrics.lineCount(of: result.text),
                    canTranslate: !result.text.isEmpty
                        && LookUpCard.needsTranslation(result.text, into: LookUpCard.translationTarget)
                )
            }.value
            guard isCurrentCapture(operationID) else { return }
            presentLookUp(card)
        } catch {
            guard isCurrentCapture(operationID), !(error is CancellationError) else { return }
            present(error: error)
        }
    }

    func presentLookUp(_ card: LookUpCard) {
        lookUpDismissTask?.cancel()
        arbiter.lookUp = card
        refreshActivity()
        // Key, so Escape reaches the card. The panel never activates the app,
        // so the window the user was reading stays in front.
        windowController?.focusActivePanel()
        installLookUpClickMonitor()
        if card.result.isEmpty {
            announceForAccessibility("Look Up found no text", priority: .medium)
            lookUpDismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { return }
                self?.dismissLookUp()
            }
        } else {
            announceForAccessibility("Look Up: \(card.result.summary)", priority: .medium)
        }
    }

    public func dismissLookUp() {
        lookUpDismissTask?.cancel()
        lookUpDismissTask = nil
        if let lookUpClickMonitor {
            NSEvent.removeMonitor(lookUpClickMonitor)
            self.lookUpClickMonitor = nil
        }
        guard arbiter.lookUp != nil else { return }
        arbiter.lookUp = nil
        refreshActivity()
        windowController?.resignFocus()
    }

    /// A global monitor only sees events bound for other apps, so clicks on
    /// the card itself never reach it.
    private func installLookUpClickMonitor() {
        guard lookUpClickMonitor == nil else { return }
        lookUpClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissLookUp() }
        }
    }

    private func updateLookUp(_ change: (inout LookUpCard) -> Void) {
        guard var card = arbiter.lookUp else { return }
        change(&card)
        arbiter.lookUp = card
        refreshActivity()
    }

    // MARK: Actions

    public func performLookUpAction(_ item: LookUpItem) {
        switch item.action {
        case .open(let url), .call(let url), .newMail(let url), .openInMaps(let url):
            NSWorkspace.shared.open(url)
        case .copy(let text):
            ImageExport.copyToPasteboard(text: text)
        case .addToCalendar(let draft):
            let resultID = arbiter.lookUp?.result.id
            Task { [weak self] in
                do {
                    try await PlannerEntryService.shared.save(draft)
                    guard let self, self.arbiter.lookUp?.result.id == resultID else { return }
                    self.updateLookUp { $0.completedItemIDs.insert(item.id) }
                    self.announceForAccessibility("Added to Calendar", priority: .medium)
                } catch {
                    self?.present(error: error)
                }
            }
            return
        }
        if item.action.leavesNotch {
            dismissLookUp()
        } else {
            updateLookUp { $0.completedItemIDs.insert(item.id) }
        }
    }

    /// Copies whichever text the card is showing, the translation included.
    public func copyLookUpText() {
        guard let card = arbiter.lookUp, !card.displayedText.isEmpty else { return }
        ImageExport.copyToPasteboard(text: card.displayedText)
        updateLookUp { $0.copiedText = true }
    }

    public func setLookUpShowsAllText(_ showsAll: Bool) {
        updateLookUp { $0.showsAllText = showsAll }
    }

    // MARK: Translation

    /// The card's view runs the translation itself: the Translation framework
    /// only hands out sessions to a view. The coordinator keeps the state the
    /// island's height depends on.
    public func beginLookUpTranslation() {
        updateLookUp {
            $0.translation = .translating
            $0.showsTranslation = false
        }
    }

    public func finishLookUpTranslation(_ text: String, for resultID: UUID) async {
        let translated = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lineCount = await Task.detached(priority: .userInitiated) {
            LookUpCardMetrics.lineCount(of: translated)
        }.value
        guard arbiter.lookUp?.result.id == resultID else { return }
        updateLookUp {
            $0.translation = translated.isEmpty ? .failed : .translated(text: translated, lineCount: lineCount)
            $0.showsTranslation = !translated.isEmpty
            $0.copiedText = false
        }
    }

    public func failLookUpTranslation(for resultID: UUID) {
        guard arbiter.lookUp?.result.id == resultID else { return }
        updateLookUp { $0.translation = .failed }
    }

    public func setLookUpShowsTranslation(_ showsTranslation: Bool) {
        updateLookUp {
            guard case .translated = $0.translation else { return }
            $0.showsTranslation = showsTranslation
            $0.copiedText = false
        }
    }
}
