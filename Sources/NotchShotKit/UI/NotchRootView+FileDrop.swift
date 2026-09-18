import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The entire island is one drop destination. Mapping its horizontal quarters
/// here avoids nested drop handlers fighting over the same Finder drag while
/// still making each visible option a real release target.
struct NotchFileDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    @Binding var selectedAction: FileDropAction
    @Binding var itemCount: Int
    @Binding var usesManualSelection: Bool
    /// -1…1 toward the pointer, for the shell's subtle stretch.
    @Binding var pointerPull: CGFloat

    var layoutSize: CGSize
    var supportsActionSelection: Bool
    var onPerform: ([NSItemProvider], FileDropAction) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        !fileProviders(in: info).isEmpty
    }

    func dropEntered(info: DropInfo) {
        let providers = fileProviders(in: info)
        guard !providers.isEmpty else { return }
        isTargeted = true
        itemCount = providers.count
        usesManualSelection = false
        updateSelection(for: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let providers = fileProviders(in: info)
        guard !providers.isEmpty else { return DropProposal(operation: .forbidden) }
        itemCount = providers.count
        updateSelection(for: info)
        pointerPull = FileDropPullPolicy.pull(x: info.location.x, width: layoutSize.width)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        reset()
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = fileProviders(in: info)
        guard !providers.isEmpty else {
            reset()
            return false
        }
        updateSelection(for: info)
        let action = supportsActionSelection ? selectedAction : .shelf
        reset()
        onPerform(providers, action)
        return true
    }

    private func fileProviders(in info: DropInfo) -> [NSItemProvider] {
        info.itemProviders(for: [.fileURL])
    }

    private func updateSelection(for info: DropInfo) {
        guard !usesManualSelection else { return }
        let action = supportsActionSelection
            ? FileDropActionSelection.action(atX: info.location.x, width: layoutSize.width)
            : .shelf
        // The user is steering this drag: a new target locking in under the
        // pointer is direct feedback, not a background notification.
        if action != selectedAction, supportsActionSelection {
            IslandHaptics.perform(.dropTargetLocked)
        }
        selectedAction = action
    }

    private func reset() {
        pointerPull = 0
        isTargeted = false
        itemCount = 0
        selectedAction = .shelf
        usesManualSelection = false
    }
}

/// A compact destination row modelled after AirDrop: the destination under the
/// pointer lifts and brightens, then owns the action when the user releases.
struct FileDropActionTray: View {
    let itemCount: Int
    @Binding var selectedAction: FileDropAction
    let onManualSelection: (FileDropAction) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: NotchIsland.Spacing.element) {
            HStack(spacing: NotchIsland.Spacing.snug) {
                Image(systemName: itemCount == 1 ? "doc.fill" : "doc.on.doc.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.cyan)

                Text(itemCountDescription)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))

                Spacer(minLength: NotchIsland.Spacing.element)

                Text("Release over a destination")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
            }

            HStack(spacing: NotchIsland.Spacing.element) {
                ForEach(FileDropAction.allCases) { action in
                    actionTarget(action)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .focusable()
        // Arrow-key selection without the blue focus ring drawing over the
        // drop targets. See `ShelfContent` for the same reason.
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .left:
                onManualSelection(FileDropActionSelection.adjacent(
                    to: selectedAction,
                    delta: -1
                ))
            case .right:
                onManualSelection(FileDropActionSelection.adjacent(
                    to: selectedAction,
                    delta: 1
                ))
            default:
                break
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("File drop actions")
        .accessibilityValue(selectedAction.title + " selected")
        .accessibilityHint("Use left or right to choose a destination, then release the files")
        .accessibilityAdjustableAction { direction in
            onManualSelection(FileDropActionSelection.adjacent(
                to: selectedAction,
                delta: direction == .increment ? 1 : -1
            ))
        }
        .accessibilityAction(named: "Keep on Shelf") { onManualSelection(.shelf) }
        .accessibilityAction(named: "Send with AirDrop") { onManualSelection(.airDrop) }
        .accessibilityAction(named: "Open Share Menu") { onManualSelection(.share) }
        .accessibilityAction(named: "Create ZIP Archive") { onManualSelection(.compress) }
    }

    private var itemCountDescription: String {
        let count = max(itemCount, 1)
        return String(count) + " " + (count == 1 ? "file" : "files") + " ready"
    }

    /// A destination tile rather than a labelled circle.
    ///
    /// The dashed edge is the standard "drop here" affordance, and it does the
    /// work the old circle could not: an idle target now looks like somewhere
    /// files go, and the one under the pointer fills with its own accent
    /// instead of merely inverting a glyph.
    private func actionTarget(_ action: FileDropAction) -> some View {
        let isSelected = action == selectedAction
        let accent = accent(for: action)
        return VStack(spacing: NotchIsland.Spacing.snug) {
            Image(systemName: action.symbolName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(isSelected ? accent : Color.islandInk(NotchIsland.Ink.secondary))

            VStack(spacing: NotchIsland.Spacing.hairline) {
                Text(action.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                    .lineLimit(1)

                Text(action.subtitle)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, NotchIsland.Spacing.tight)

            // The target under the pointer restates what it is about to
            // receive, so a mis-aimed release is visible before it happens.
            Text(itemCountChip)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
                .padding(.horizontal, NotchIsland.Spacing.snug)
                .padding(.vertical, 2)
                .background(accent, in: Capsule(style: .continuous))
                .opacity(isSelected ? 1 : 0)
        }
        .padding(.vertical, NotchIsland.Spacing.row)
        .frame(maxWidth: .infinity, minHeight: 108)
        .background {
            RoundedRectangle(cornerRadius: NotchIsland.Radius.card + 3, style: .continuous)
                .fill(
                    isSelected
                        ? accent.opacity(reduceTransparency ? 0.28 : 0.18)
                        : Color.islandInk(reduceTransparency ? 0.10 : 0.05)
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: NotchIsland.Radius.card + 3, style: .continuous)
                .strokeBorder(
                    isSelected ? accent : Color.islandInk(NotchIsland.Ink.recessed),
                    style: StrokeStyle(
                        lineWidth: isSelected ? 1.6 : 1,
                        dash: isSelected ? [] : [4, 3]
                    )
                )
        }
        .shadow(color: isSelected ? accent.opacity(0.34) : .clear, radius: 12, y: 4)
        .scaleEffect(isSelected && !reduceMotion ? 1.035 : 1)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(action.title + ", " + action.subtitle)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityAction { onManualSelection(action) }
    }

    private var itemCountChip: String {
        let count = max(itemCount, 1)
        return count == 1 ? "1 file" : "\(count) files"
    }

    private func accent(for action: FileDropAction) -> Color {
        switch action {
        case .shelf: .cyan
        case .airDrop: .blue
        case .share: .purple
        case .localSend: .green
        case .compress: .orange
        }
    }
}
