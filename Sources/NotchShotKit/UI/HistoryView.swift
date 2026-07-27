import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Local capture history browser.
public struct HistoryView: View {
    @Bindable var coordinator: AppCoordinator
    @State private var query = ""
    @State private var selection: UUID?

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    private var entries: [HistoryEntry] {
        coordinator.history.search(query)
    }

    public var body: some View {
        NavigationSplitView {
            List(entries, selection: $selection) { entry in
                HistoryRow(entry: entry)
                    .tag(entry.id)
                    .contextMenu { contextMenu(for: entry) }
            }
            .searchable(text: $query, prompt: searchPrompt)
            .navigationSplitViewColumnWidth(min: 280, ideal: 320)
        } detail: {
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
        .frame(minWidth: 760, minHeight: 460)
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
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([entry.fileURL])
        }
        Button("Copy") {
            ImageExport.copyToPasteboard(fileURL: entry.fileURL)
        }
        if entry.kind != .recording {
            Button("Annotate") {
                coordinator.openEditor(for: entry)
            }
        }
        Divider()
        Button("Remove from History") {
            try? coordinator.history.delete(id: entry.id, includingFile: false)
        }
        Button(entry.kind == .recording ? "Move Recording and Captions to Trash" : "Move File to Trash", role: .destructive) {
            do {
                try coordinator.history.delete(id: entry.id, includingFile: true)
            } catch {
                coordinator.present(error: error)
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
                        .overlay { Image(systemName: entry.kind.symbolName).foregroundStyle(.secondary) }
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

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
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

            Divider()

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.fileURL.lastPathComponent).font(.headline).lineLimit(1)
                    Text("\(entry.kind.displayName) · \(entry.dimensionsDescription)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([entry.fileURL])
                }
                Button("Copy") {
                    ImageExport.copyToPasteboard(fileURL: entry.fileURL)
                }
                if entry.kind != .recording {
                    Button("Annotate") { coordinator.openEditor(for: entry) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(12)
        }
        .task(id: entry.id) {
            finishedLoading = false
            image = nil
            guard entry.fileExists else {
                finishedLoading = true
                return
            }
            if entry.kind == .recording {
                image = await VideoThumbnail.make(for: entry.fileURL)
            } else {
                image = SafeImageFile.nsImage(for: entry.asset)
            }
            finishedLoading = true
        }
    }
}
