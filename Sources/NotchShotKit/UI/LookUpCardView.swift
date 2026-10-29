import AppKit
import SwiftUI
@preconcurrency import Translation

/// The Look Up card's measurements. `NotchLayout` sizes the island from
/// these rather than from the rendered card, so every height the card can
/// take is a function of `LookUpCard`.
enum LookUpCardMetrics {
    static let width: CGFloat = 440
    static let markSize = NotchIsland.Mark.size
    /// The 36 pt button target with 6 pt above and below.
    static let rowHeight: CGFloat = 48
    /// Beyond this the rows scroll, with half a row showing that they do.
    static let maximumVisibleRows = 4
    static let previewLines = 3
    /// One line of 12 pt text, rounded up so the frame never clips a line.
    static let lineHeight: CGFloat = 15
    static let textPadding: CGFloat = 8
    static let actionsHeight = NotchIsland.Hit.control
    static let bottomPadding: CGFloat = 10
    /// Below the camera band, inside `NotchLayout.maximumSize`.
    static let maximumBodyHeight: CGFloat = 380

    static var textWidth: CGFloat {
        width - 2 * NotchAlertStyle.horizontalInset - markSize - NotchAlertStyle.leadingGap
    }

    static func rowsHeight(for card: LookUpCard) -> CGFloat {
        let count = card.result.items.count
        guard count > maximumVisibleRows else { return CGFloat(count) * rowHeight }
        return (CGFloat(maximumVisibleRows) + 0.5) * rowHeight
    }

    /// Lines of text the card shows: a short preview, or as many as fit
    /// once the user asks for all of it. The rest scrolls.
    static func visibleLines(for card: LookUpCard) -> Int {
        guard !card.result.text.isEmpty else { return 0 }
        let lines = max(1, card.displayedLineCount)
        guard card.showsAllText else { return min(lines, previewLines) }
        let room = maximumBodyHeight - rowsHeight(for: card) - actionsHeight - bottomPadding - 2 * textPadding
        return min(lines, max(previewLines, Int(room / lineHeight)))
    }

    static func textRowHeight(for card: LookUpCard) -> CGFloat {
        let lines = visibleLines(for: card)
        return lines == 0 ? 0 : CGFloat(lines) * lineHeight + 2 * textPadding
    }

    static func bodyHeight(for card: LookUpCard) -> CGFloat {
        rowsHeight(for: card) + textRowHeight(for: card) + actionsHeight + bottomPadding
    }

    /// Lines `text` wraps to in the card's text column. Measured a few points
    /// narrower than the column, so a line that only just fits is counted as
    /// wrapping rather than clipped.
    static func lineCount(of text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let font = NSFont.systemFont(ofSize: 12)
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: textWidth - 4, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        return max(1, Int((bounds.height / lineHeight).rounded(.up)))
    }
}

/// What Look Up found in an area, in the notch: a row for each thing that can
/// be acted on, then the area's text, laid out like the notification stack.
struct LookUpCardView: View {
    let card: LookUpCard
    let coordinator: AppCoordinator

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var translationConfiguration: TranslationSession.Configuration?
    @State private var rowsContinueBelow = true

    private var hasText: Bool { !card.result.text.isEmpty }

    var body: some View {
        if card.result.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                bandHeader
                VStack(spacing: 0) {
                    rows
                    if hasText {
                        textRow
                            .overlay(alignment: .top) {
                                if !card.result.items.isEmpty { LookUpSeparator() }
                            }
                            .islandReveal(stage: 2)
                    }
                    actions
                        .islandReveal(stage: 2)
                }
                .padding(.horizontal, NotchAlertStyle.horizontalInset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(NotchMotion.selection(reduceMotion: reduceMotion), value: card)
            .translationTask(translationConfiguration) { session in
                let resultID = card.result.id
                do {
                    try await session.prepareTranslation()
                    let response = try await session.translate(card.result.text)
                    await coordinator.finishLookUpTranslation(response.targetText, for: resultID)
                } catch is CancellationError {
                    // The card closed, or a retry replaced this session.
                } catch {
                    coordinator.failLookUpTranslation(for: resultID)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Look Up")
        }
    }

    // MARK: Header

    private var bandHeader: some View {
        IslandBandHeader(leadingInset: 16, trailingInset: 16) {
            LookUpBandTitle()
        } trailing: {
            Text(card.result.summary)
                .font(NotchAlertStyle.meta)
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                .lineLimit(1)
        }
    }

    /// Nothing to show: one quiet line beside the camera that closes itself.
    /// A click or Escape closes it sooner.
    private var emptyState: some View {
        Button {
            coordinator.dismissLookUp()
        } label: {
            IslandBandHeader(leadingInset: 16, trailingInset: 16) {
                LookUpBandTitle()
            } trailing: {
                Text("No text found")
                    .font(NotchAlertStyle.meta)
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("Look Up found no text. Close.")
    }

    // MARK: Rows

    @ViewBuilder
    private var rows: some View {
        let items = card.result.items
        let list = VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                LookUpItemRow(
                    item: item,
                    isCompleted: card.completedItemIDs.contains(item.id),
                    showsSeparator: index > 0,
                    onAction: { coordinator.performLookUpAction(item) }
                )
                .islandReveal(stage: min(index + 1, 2))
            }
        }
        if items.count > LookUpCardMetrics.maximumVisibleRows {
            ScrollView { list }
                .scrollIndicators(.never)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentSize.height - geometry.contentOffset.y > geometry.containerSize.height + 1
                } action: { _, continues in
                    rowsContinueBelow = continues
                }
                // The half row fades out rather than being cut through, which
                // read as clipping rather than "there is more".
                .mask {
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: rowsContinueBelow ? LookUpCardMetrics.rowHeight / 2 : 0)
                    }
                }
                .frame(height: LookUpCardMetrics.rowsHeight(for: card))
        } else {
            list
        }
    }

    // MARK: Text

    private var textRow: some View {
        HStack(alignment: .top, spacing: NotchAlertStyle.leadingGap) {
            NotchAlertStyle.symbol(
                card.showsTranslation ? "translate" : "text.alignleft",
                color: .islandInk(NotchIsland.Ink.secondary),
                size: 15
            )
                .frame(width: LookUpCardMetrics.markSize, height: LookUpCardMetrics.lineHeight)
                .accessibilityHidden(true)
            ZStack(alignment: .topLeading) {
                textBody
                    .id(card.showsTranslation)
                    .transition(IslandMotion.levelTransition(reduceMotion: reduceMotion))
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: CGFloat(LookUpCardMetrics.visibleLines(for: card)) * LookUpCardMetrics.lineHeight,
                alignment: .topLeading
            )
            .clipped()
        }
        .padding(.vertical, LookUpCardMetrics.textPadding)
        .frame(height: LookUpCardMetrics.textRowHeight(for: card), alignment: .top)
    }

    @ViewBuilder
    private var textBody: some View {
        let text = Text(card.displayedText)
            .font(NotchAlertStyle.body)
            .foregroundStyle(Color.islandInk(NotchIsland.Ink.body))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        if card.showsAllText, card.displayedLineCount > LookUpCardMetrics.visibleLines(for: card) {
            ScrollView {
                text.fixedSize(horizontal: false, vertical: true)
            }
            .scrollIndicators(.automatic)
        } else {
            text
                .lineLimit(LookUpCardMetrics.visibleLines(for: card))
                .truncationMode(.tail)
        }
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: NotchIsland.Spacing.element) {
            actionStatus
            Spacer(minLength: 0)
            NotchCapsuleButton("Close", accessibilityLabel: "Close Look Up") { coordinator.dismissLookUp() }
                .keyboardShortcut(.cancelAction)
            if hasText, card.canTranslate {
                NotchCapsuleButton(card.showsTranslation ? "Show Original" : "Translate") {
                    toggleTranslation()
                }
                .disabled(card.translation == .translating)
            }
            if hasText {
                NotchCapsuleButton(
                    card.copiedText ? "Copied" : "Copy Text",
                    systemImage: card.copiedText ? "checkmark" : nil,
                    prominence: .primary,
                    accessibilityLabel: card.showsTranslation ? "Copy translation" : "Copy text"
                ) {
                    coordinator.copyLookUpText()
                }
            }
        }
        .padding(.leading, hasText ? LookUpCardMetrics.markSize + NotchAlertStyle.leadingGap : 0)
        .frame(height: LookUpCardMetrics.actionsHeight)
    }

    /// The left of the button row: how a translation is going, or the way
    /// to the rest of the text.
    @ViewBuilder
    private var actionStatus: some View {
        if card.translation == .translating {
            LookUpStatusText(text: "Translating…")
        } else if card.translation == .failed, !card.showsTranslation {
            LookUpStatusText(text: "Couldn't translate")
        } else if card.displayedLineCount > LookUpCardMetrics.previewLines {
            LookUpTextButton(title: card.showsAllText ? "Show Less" : "Show All") {
                coordinator.setLookUpShowsAllText(!card.showsAllText)
            }
        }
    }

    private func toggleTranslation() {
        if card.showsTranslation {
            coordinator.setLookUpShowsTranslation(false)
            return
        }
        if case .translated = card.translation {
            coordinator.setLookUpShowsTranslation(true)
            return
        }
        coordinator.beginLookUpTranslation()
        if translationConfiguration == nil {
            translationConfiguration = TranslationSession.Configuration(
                source: nil,
                target: LookUpCard.translationTarget
            )
        } else {
            // A retry: the same configuration only runs again once invalidated.
            translationConfiguration?.invalidate()
        }
    }
}

// MARK: - Pieces

private struct LookUpBandTitle: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: CaptureIntent.lookUp.symbolName)
                .font(.system(size: NotchIsland.TextSize.meta, weight: .semibold))
                .accessibilityHidden(true)
            Text("Look Up")
                .font(.system(size: NotchIsland.TextSize.meta, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
    }
}

/// The notification stack's divider: a hairline from the text column on.
private struct LookUpSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.islandInk(NotchIsland.Ink.hairline))
            .frame(height: NotchIsland.Stroke.hairline)
            .padding(.leading, LookUpCardMetrics.markSize + NotchAlertStyle.leadingGap)
            .accessibilityHidden(true)
    }
}

private struct LookUpItemRow: View {
    let item: LookUpItem
    let isCompleted: Bool
    let showsSeparator: Bool
    let onAction: () -> Void

    private var buttonTitle: String {
        isCompleted ? item.action.completedTitle ?? item.action.title : item.action.title
    }

    var body: some View {
        HStack(spacing: NotchAlertStyle.leadingGap) {
            NotchAlertStyle.symbol(item.kind.symbolName, color: .islandInk(NotchIsland.Ink.secondary), size: 17)
                .frame(width: LookUpCardMetrics.markSize, height: LookUpCardMetrics.markSize)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(NotchAlertStyle.title)
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                    .lineLimit(1)
                    // A link's end is what tells two links apart.
                    .truncationMode(item.kind == .link || item.kind == .qrCode ? .middle : .tail)
                Text(item.detail)
                    .font(NotchAlertStyle.body)
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.body))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Done draws a checkmark on, like Copy and Save on the shelf.
            NotchCapsuleButton(
                buttonTitle,
                systemImage: isCompleted ? "checkmark" : nil,
                accessibilityLabel: "\(buttonTitle), \(item.title)",
                action: onAction
            )
            .disabled(isCompleted && !item.action.canRepeat)
        }
        .frame(height: LookUpCardMetrics.rowHeight)
        .overlay(alignment: .top) {
            if showsSeparator { LookUpSeparator() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.detail), \(item.title)")
    }
}

private struct LookUpStatusText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(NotchAlertStyle.meta)
            .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
            .lineLimit(1)
    }
}

/// A quiet text control for the button row, with a full-height target.
private struct LookUpTextButton: View {
    let title: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: NotchIsland.TextSize.body, weight: .semibold))
                .foregroundStyle(Color.islandInk(isHovered ? NotchIsland.Ink.primary : NotchIsland.Ink.secondary))
                .lineLimit(1)
                .frame(minHeight: NotchIsland.Hit.control)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressButtonStyle())
        .onHover { isHovered = $0 }
        .fixedSize()
    }
}
