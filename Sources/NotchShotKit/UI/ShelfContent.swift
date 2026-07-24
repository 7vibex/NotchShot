import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The post-capture shelf: CleanShot's Quick Access Overlay idea, moved into
/// the notch so results appear where the capture was launched from.
struct ShelfContent: View {
    @Bindable var coordinator: AppCoordinator

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var items: [ShelfItem] { coordinator.shelfItems }
    private var selected: ShelfItem? { coordinator.selectedShelfItem }

    var body: some View {
        VStack(spacing: 10) {
            header

            if let selected {
                HStack(spacing: 12) {
                    thumbnail(for: selected)
                    details(for: selected)
                    Spacer(minLength: 0)
                }

                actions(for: selected)
            }

            if items.count > 1 {
                pager
            }
        }
        .padding(14)
        .focusable()
        .onKeyPress(.leftArrow) {
            coordinator.advanceShelfSelection(by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            coordinator.advanceShelfSelection(by: 1)
            return .handled
        }
        .onKeyPress(.escape) {
            coordinator.hideShelf()
            return .handled
        }
        .animation(reduceMotion ? nil : .snappy, value: coordinator.selectedShelfIndex)
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: selected?.asset.kind.symbolName ?? "photo")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
            Text(selected?.asset.kind.displayName ?? "Capture")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)

            if let warnings = selected?.stitchWarnings, !warnings.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help(warnings.joined(separator: "\n"))
                    .accessibilityLabel("Stitch warnings: \(warnings.joined(separator: ". "))")
            }

            Spacer()

            NotchIconButton(systemName: "eye.slash", label: "Hide shelf") {
                coordinator.hideShelf()
            }
            .scaleEffect(0.72)
        }
    }

    private func thumbnail(for item: ShelfItem) -> some View {
        Group {
            if let thumbnail = item.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.white.opacity(0.1))
                    .overlay {
                        Image(systemName: item.asset.kind.symbolName)
                            .foregroundStyle(.white.opacity(0.5))
                    }
            }
        }
        .frame(width: 96, height: 66)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(.white.opacity(0.16))
        }
        // Dragging the thumbnail is the fastest route into Finder, Mail,
        // Slack, or an upload field — no save dialog in between.
        .onDrag {
            let provider = NSItemProvider(contentsOf: item.asset.url) ?? NSItemProvider()
            provider.suggestedName = item.asset.url.lastPathComponent
            return provider
        } preview: {
            if let thumbnail = item.thumbnail {
                Image(nsImage: thumbnail).resizable().frame(width: 160, height: 110)
            } else {
                Color.gray.frame(width: 160, height: 110)
            }
        }
        .help("Drag to a folder or an app")
        .accessibilityLabel("Capture preview. Draggable.")
    }

    private func details(for item: ShelfItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.asset.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 6) {
                Text(item.asset.dimensionsDescription)
                if let duration = item.asset.duration {
                    Text(durationText(duration))
                }
                Text(item.asset.fileSizeDescription)
            }
            .font(.system(size: 9))
            .foregroundStyle(.white.opacity(0.55))

            if let text = item.ocrResult?.fullText, !text.isEmpty {
                Text(text)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(2)
            }

            if let items = item.ocrResult?.detectedItems, !items.isEmpty {
                HStack(spacing: 6) {
                    ForEach(items.prefix(3)) { detected in
                        Button {
                            if let url = detected.actionURL { NSWorkspace.shared.open(url) }
                        } label: {
                            Label(detected.value, systemImage: detected.kind.symbolName)
                                .font(.system(size: 9))
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
        }
    }

    private func actions(for item: ShelfItem) -> some View {
        HStack(spacing: 6) {
            ForEach(ShareAction.allCases.filter { $0.isAvailable(for: item.asset) }) { action in
                Button {
                    coordinator.perform(action, on: item)
                } label: {
                    Image(systemName: action.symbolName)
                        .font(.system(size: 12))
                        .frame(width: 30, height: 26)
                        .foregroundStyle(action == .delete ? Color.red.opacity(0.9) : .white)
                        .glassEffect(.regular, in: .rect(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help(action.title)
                .accessibilityLabel(action.title)
            }
        }
    }

    private var pager: some View {
        HStack(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button {
                    coordinator.selectShelfItem(at: index)
                } label: {
                    Group {
                        if let thumbnail = item.thumbnail {
                            Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.white.opacity(0.12)
                        }
                    }
                    .frame(width: 34, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(
                                index == coordinator.selectedShelfIndex
                                    ? Color.accentColor : .white.opacity(0.18),
                                lineWidth: index == coordinator.selectedShelfIndex ? 2 : 1
                            )
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Capture \(index + 1) of \(items.count)")
                .accessibilityAddTraits(index == coordinator.selectedShelfIndex ? [.isSelected] : [])
            }

            Spacer()

            if coordinator.canRestoreDismissed {
                Button {
                    coordinator.restoreLastDismissed()
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
