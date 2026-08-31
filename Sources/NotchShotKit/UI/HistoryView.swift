import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Local capture history browser.
public struct HistoryView: View {
    @Bindable var coordinator: AppCoordinator
    @State private var query = ""
    @State private var selection: UUID?
    @State private var favoritesOnly = false
    @State private var collectionFilter: String?

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    private var entries: [HistoryEntry] {
        coordinator.history.search(query).filter { entry in
            (!favoritesOnly || entry.favorite)
                && (collectionFilter == nil || entry.collectionName == collectionFilter)
        }
    }

    public var body: some View {
        NavigationSplitView {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView(
                        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "No captures yet" : "No matching captures",
                        systemImage: query.isEmpty ? "camera.viewfinder" : "magnifyingglass",
                        description: Text(
                            query.isEmpty
                                ? "New screenshots and recordings will appear here."
                                : "Try a different name, app, or recognized-text search."
                        )
                    )
                } else {
                    List(entries, selection: $selection) { entry in
                        HistoryRow(entry: entry)
                            .tag(entry.id)
                            .contextMenu { contextMenu(for: entry) }
                    }
                }
            }
            .searchable(text: $query, prompt: searchPrompt)
            .navigationSplitViewColumnWidth(min: 280, ideal: 320)
        } detail: {
            Group {
                if let selection, let entry = coordinator.history.entry(id: selection) {
                    HistoryDetail(entry: entry, coordinator: coordinator)
                } else {
                    ContentUnavailableView(
                        "No capture selected",
                        systemImage: "clock.arrow.circlepath",
                        description: Text(
                            "Captures are kept for \(retentionText). Retention removes app-managed temporary files, but keeps captures you saved or dragged in."
                        )
                    )
                }
            }
            .notchShotContentSwap(id: selection)
        }
        .frame(minWidth: 760, minHeight: 460)
        .toolbar {
            Toggle(isOn: $favoritesOnly) {
                Label("Favorites", systemImage: favoritesOnly ? "star.fill" : "star")
            }
            Menu {
                Button("All Collections") { collectionFilter = nil }
                ForEach(coordinator.history.collectionNames, id: \.self) { name in
                    Button(name) { collectionFilter = name }
                }
            } label: {
                Label(collectionFilter ?? "All Collections", systemImage: "folder")
            }
        }
    }

    private var searchPrompt: String {
        Preferences.shared.indexesCaptureText
            ? "Search names, apps, and text"
            : "Search names and apps"
    }

    private var retentionText: String {
        let days = Preferences.shared.historyRetentionDays
        return days == 0 ? "as long as you like" : "\(days) days"
    }

    @ViewBuilder
    private func contextMenu(for entry: HistoryEntry) -> some View {
        if entry.fileExists {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([entry.fileURL])
            }
            Button("Copy") {
                ImageExport.copyToPasteboard(fileURL: entry.fileURL)
            }
            Button("Share…") {
                coordinator.share(entry.asset)
            }
            Button(entry.favorite ? "Remove Favorite" : "Favorite") {
                coordinator.history.setFavorite(id: entry.id, !entry.favorite)
            }
            if entry.kind.isImage {
                Button("Annotate") {
                    coordinator.openEditor(for: entry)
                }
                Button("Inspect") { coordinator.openInspector(for: entry.asset) }
                Button("Optimize Export…") { coordinator.openSmartExport(for: entry.asset) }
            } else if entry.kind == .recording {
                Button("Export GIF or Exact-Size Video…") {
                    coordinator.openRecordingExport(for: entry.asset)
                }
            }
        }
        Divider()
        Button(entry.fileExists ? "Remove from History" : "Remove Missing Capture from History") {
            do {
                try coordinator.history.delete(id: entry.id, includingFile: false)
            } catch {
                coordinator.present(error: error)
            }
        }
        if entry.fileExists {
            Button(entry.kind == .recording ? "Move Recording and Captions to Trash" : "Move File to Trash", role: .destructive) {
                do {
                    try coordinator.history.delete(id: entry.id, includingFile: true)
                } catch {
                    coordinator.present(error: error)
                }
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay {
                            Image(systemName: entry.kind.symbolName)
                                .foregroundStyle(.secondary)
                                // Decorative stand-in for a thumbnail that has
                                // not loaded; the row's filename already names
                                // the item.
                                .accessibilityHidden(true)
                        }
                }
            }
            .frame(width: 52, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.fileURL.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(entry.createdAt, style: .date)
                    Text(entry.dimensionsDescription)
                    if let name = entry.sourceApplicationName {
                        Text(name)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if !entry.fileExists {
                Image(systemName: "questionmark.folder")
                    .foregroundStyle(.orange)
                    .help("The file has moved or been deleted")
                    // `help` is a pointer tooltip, not a label — without this
                    // the only warning that a capture's file is gone was
                    // invisible to VoiceOver.
                    .accessibilityLabel("File missing")
                    .accessibilityHint("The file has moved or been deleted")
            }
        }
        .task { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        if let url = entry.thumbnailURL, let image = NSImage(contentsOf: url) {
            thumbnail = image
            return
        }
        // Fall back to Quick Look so rows still render if a thumbnail was
        // pruned or never generated (recordings, dropped files).
        guard entry.fileExists else { return }
        let request = QLThumbnailGenerator.Request(
            fileAt: entry.fileURL,
            size: CGSize(width: 104, height: 72),
            scale: 2,
            representationTypes: .thumbnail
        )
        if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            thumbnail = representation.nsImage
        }
    }
}

private struct HistoryDetail: View {
    let entry: HistoryEntry
    @Bindable var coordinator: AppCoordinator
    @State private var image: NSImage?
    @State private var finishedLoading = false
    @State private var tagsText = ""
    @State private var collectionText = ""
    @State private var showsTranslation = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .accessibilityLabel("Preview of \(entry.fileURL.lastPathComponent)")
                } else if entry.fileExists, !finishedLoading {
                    ProgressView()
                } else if entry.fileExists {
                    ContentUnavailableView(
                        "Preview unavailable",
                        systemImage: entry.kind.symbolName,
                        description: Text("Reveal the file in Finder to open it in another app.")
                    )
                } else {
                    ContentUnavailableView(
                        "File not found",
                        systemImage: "questionmark.folder",
                        description: Text(entry.fileURL.path)
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
            .notchShotContentSwap(id: previewPhase)

            HStack(spacing: 10) {
                TextField("Tags (comma separated)", text: $tagsText)
                    .onSubmit { saveLibraryMetadata() }
                TextField("Collection", text: $collectionText)
                    .onSubmit { saveLibraryMetadata() }
                Button {
                    coordinator.history.setFavorite(id: entry.id, !entry.favorite)
                } label: {
                    Label(
                        entry.favorite ? "Remove Favorite" : "Favorite",
                        systemImage: entry.favorite ? "star.fill" : "star"
                    )
                }
                Button("Save Organization") { saveLibraryMetadata() }
            }
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Divider()

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.fileURL.lastPathComponent).font(.headline).lineLimit(1)
                    Text("\(entry.kind.displayName) · \(entry.dimensionsDescription)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if entry.fileExists {
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([entry.fileURL])
                    }
                    Button("Copy") {
                        ImageExport.copyToPasteboard(fileURL: entry.fileURL)
                    }
                    Button("Share…") { coordinator.share(entry.asset) }
                    if entry.kind.isImage || entry.kind == .text || entry.kind == .recording {
                        Button("Translate…") { showsTranslation = true }
                    }
                    if entry.kind.isImage {
                        Menu("More") {
                            Button("Inspect") { coordinator.openInspector(for: entry.asset) }
                            Button("Optimize Export…") { coordinator.openSmartExport(for: entry.asset) }
                        }
                        Button("Annotate") { coordinator.openEditor(for: entry) }
                            .notchShotPrimaryActionStyle()
                    } else if entry.kind == .recording {
                        Button("Export…") { coordinator.openRecordingExport(for: entry.asset) }
                            .notchShotPrimaryActionStyle()
                    }
                } else {
                    Button("Remove from History") { removeMissingEntry() }
                        .notchShotPrimaryActionStyle()
                }
            }
            .padding(12)
        }
        .task(id: entry.id) {
            tagsText = entry.libraryTags.joined(separator: ", ")
            collectionText = entry.collectionName ?? ""
            finishedLoading = false
            image = nil
            guard entry.fileExists else {
                finishedLoading = true
                return
            }
            if entry.kind == .recording {
                image = await VideoThumbnail.make(for: entry.fileURL)
            } else if entry.kind.isImage {
                image = SafeImageFile.nsImage(for: entry.asset)
            }
            finishedLoading = true
        }
        .sheet(isPresented: $showsTranslation) {
            CaptureTranslationView(asset: entry.asset)
        }
    }

    private func saveLibraryMetadata() {
        coordinator.history.updateLibraryMetadata(
            id: entry.id,
            tags: tagsText.split(separator: ",").map(String.init),
            collectionName: collectionText,
            isFavorite: entry.favorite
        )
    }

    private var previewPhase: Int {
        if image != nil { return 0 }
        if entry.fileExists, !finishedLoading { return 1 }
        return entry.fileExists ? 2 : 3
    }

    private func removeMissingEntry() {
        do {
            try coordinator.history.delete(id: entry.id, includingFile: false)
        } catch {
            coordinator.present(error: error)
        }
    }
}
