import AppKit
import SwiftUI

/// Local clipboard history browser.
///
/// Deliberately its own window rather than a tab inside History: the two stores
/// have different retention, different privacy posture, and different reasons
/// to be open. Mixing them would make one set of controls mean two things.
public struct ClipboardView: View {
    @Bindable var coordinator: AppCoordinator
    @State private var query = ""
    @State private var kindFilter: ClipboardKind?
    @State private var sourceAppFilter: String?
    @State private var selection: UUID?
    @State private var confirmClear = false
    @State private var renameEntry: ClipboardEntry?
    @State private var renameText = ""

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    private var entries: [ClipboardEntry] {
        coordinator.clipboard.search(query).filter { entry in
            (kindFilter == nil || entry.kind == kindFilter)
                && (sourceAppFilter == nil || entry.sourceApplicationName == sourceAppFilter)
        }
    }

    private var sourceApps: [String] { coordinator.clipboardSourceApps }

    public var body: some View {
        Group {
            if !Preferences.shared.clipboardEnabled {
                disabledState
            } else if coordinator.clipboard.entries.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .notchShotContentSwap(id: presentationID)
        .frame(minWidth: 460, minHeight: 420)
        .alert("Label clipping", isPresented: Binding(
            get: { renameEntry != nil },
            set: { if !$0 { renameEntry = nil } }
        )) {
            TextField("Optional label", text: $renameText)
            Button("Save") {
                if let renameEntry {
                    coordinator.clipboard.setLabel(renameText, id: renameEntry.id)
                }
                self.renameEntry = nil
            }
            Button("Cancel", role: .cancel) { renameEntry = nil }
        } message: {
            Text("The label is searchable and does not change what gets pasted. Leave it blank to use the content-derived title.")
        }
    }

    private var disabledState: some View {
        ContentUnavailableView {
            Label("Clipboard history is off", systemImage: "doc.on.clipboard")
        } description: {
            Text("NotchShot does not record what you copy until you switch this on. Nothing is uploaded; the history stays on this Mac and can be cleared at any time.")
        } actions: {
            Button("Turn On Clipboard History") {
                coordinator.setClipboardEnabled(true)
            }
            .notchShotPrimaryActionStyle()
            Button("Open Settings") { coordinator.onOpenSettings?() }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing copied yet", systemImage: "doc.on.clipboard")
        } description: {
            Text("Copy something and it will appear here. Passwords marked as concealed, and anything copied from an excluded app, are never recorded.")
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            Picker("Clipboard type", selection: $kindFilter) {
                Text("All").tag(Optional<ClipboardKind>.none)
                ForEach(ClipboardKind.allCases) { kind in
                    Label(kind.displayName, systemImage: kind.symbolName)
                        .tag(Optional(kind))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if !sourceApps.isEmpty {
                HStack(spacing: 8) {
                    Picker("App", selection: $sourceAppFilter) {
                        Text("All apps").tag(Optional<String>.none)
                        ForEach(sourceApps, id: \.self) { app in
                            Text(app).tag(Optional(app))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 180)
                    .labelsHidden()

                    if sourceAppFilter != nil {
                        Button("Clear") { sourceAppFilter = nil }
                            .font(.caption)
                            .buttonStyle(.borderless)
                    }
                    Spacer()
                    Text("\(entries.count) shown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            Group {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "No matching clippings",
                        systemImage: "magnifyingglass",
                        description: Text("Change the search or filters.")
                    )
                } else {
                    List(entries, selection: $selection) { entry in
                        ClipboardRow(entry: entry)
                            .tag(entry.id)
                            .contextMenu { contextMenu(for: entry) }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    .listStyle(.inset)
                }
            }
            .notchShotContentSwap(id: entries.isEmpty)
            .searchable(text: $query, prompt: "Search clipboard")

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(footerText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Spacer()
                    Button("Clear…", role: .destructive) { confirmClear = true }
                        .confirmationDialog(
                            "Clear clipboard history?",
                            isPresented: $confirmClear
                        ) {
                            Button("Clear Unpinned") {
                                coordinator.clipboard.clear(keepingPinned: true)
                            }
                            Button("Clear Everything", role: .destructive) {
                                coordinator.clipboard.clear()
                            }
                            Button("Cancel", role: .cancel) {}
                        }
                    if let selection, let entry = coordinator.clipboard.entry(id: selection) {
                        Button("Add to Shelf") { coordinator.pushClipboardEntryToShelf(entry) }
                            .help("Place this clipping on the notch shelf to drag it into another app")
                            .accessibilityLabel("Add clipping to shelf")
                        Button("Copy") { coordinator.useClipboardEntry(entry) }
                            .notchShotPrimaryActionStyle()
                    }
                }
            }
            .padding(12)
        }
    }

    private var presentationID: String {
        if !Preferences.shared.clipboardEnabled { return "disabled" }
        return coordinator.clipboard.entries.isEmpty ? "empty" : "list"
    }

    private var footerText: String {
        let days = Preferences.shared.clipboardRetentionDays
        let window = days == 0 ? "kept until cleared" : "kept for \(days) days"
        return "\(coordinator.clipboard.entries.count) items · \(window) · pinned items never expire"
    }

    @ViewBuilder
    private func contextMenu(for entry: ClipboardEntry) -> some View {
        Button("Copy") { coordinator.useClipboardEntry(entry) }
        Button("Add to Shelf") { coordinator.pushClipboardEntryToShelf(entry) }
        Button(entry.isPinned ? "Unpin" : "Pin") {
            coordinator.clipboard.setPinned(!entry.isPinned, id: entry.id)
        }
        Button("Label…") {
            renameEntry = entry
            renameText = entry.label ?? ""
        }
        if entry.kind == .image {
            if let text = entry.text, !text.isEmpty {
                Button("Copy Recognized Text") {
                    coordinator.copyRecognizedClipboardText(entry)
                }
                Button("Recognize Text Again") {
                    coordinator.indexClipboardImageText(entry)
                }
                Button("Remove Recognized Text") {
                    coordinator.clipboard.setRecognizedText(nil, id: entry.id)
                }
            } else {
                Button("Recognize Text for Search") {
                    coordinator.indexClipboardImageText(entry)
                }
            }
        }
        if entry.kind == .files {
            Button("Reveal in Finder") {
                coordinator.revealClipboardFiles(entry)
            }
        }
        if entry.kind == .link, let text = entry.text, let url = URL(string: text) {
            Button("Open Link") { NSWorkspace.shared.open(url) }
        }
        Divider()
        Button("Delete", role: .destructive) {
            coordinator.clipboard.delete(id: entry.id)
        }
    }
}

private struct ClipboardRow: View {
    let entry: ClipboardEntry
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                } else if entry.kind == .color, let color = swatchColor {
                    Rectangle().fill(color)
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay {
                            Image(systemName: entry.kind.symbolName)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: 40, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(entry.preview)
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    Text(entry.createdAt, style: .relative)
                    if let name = entry.sourceApplicationName {
                        Text(name)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if entry.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("Pinned — never expires")
                    .accessibilityLabel("Pinned")
                    .accessibilityHint("This clipping never expires")
            }
        }
        .padding(10)
        // Clipboard rows are primary, dense content. A stable system surface is
        // easier to scan than a separate translucent card for every item.
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.primary.opacity(0.08))
        }
        .task(id: entry.id) { await loadThumbnail() }
    }

    private var swatchColor: Color? {
        guard let hex = entry.text, let color = NSColor(hex: hex) else { return nil }
        return Color(nsColor: color)
    }

    private func loadThumbnail() async {
        guard entry.kind == .image, let url = entry.imageURL else { return }
        thumbnail = SafeImageFile.cgImage(at: url, limits: .generated).map {
            NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
        }
    }
}
