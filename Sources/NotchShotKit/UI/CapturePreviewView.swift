import AppKit
import SwiftUI

/// A focused, read-only view of one shelf capture. Export remains an explicit
/// action: captures arrive on the clipboard and in managed History first, then
/// Save As creates a user document only when requested.
public struct CapturePreviewView: View {
    @Bindable var coordinator: AppCoordinator
    @Bindable var item: ShelfItem

    @State private var image: NSImage?
    /// Keeps "Preview unavailable" from flashing while the file is read.
    @State private var finishedLoading: Bool
    @State private var fileSizeDescription = ""

    public init(coordinator: AppCoordinator, item: ShelfItem) {
        self.coordinator = coordinator
        self.item = item
        let inMemory = item.image?.makeNSImage()
        _image = State(initialValue: inMemory)
        _finishedLoading = State(initialValue: inMemory != nil)
    }

    public var body: some View {
        VStack(spacing: 0) {
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.asset.displayName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text([item.asset.dimensionsDescription, fileSizeDescription]
                        .filter { !$0.isEmpty }
                        .joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    coordinator.perform(.copy, on: item)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .help("Copy the screenshot again")

                Button {
                    coordinator.perform(.save, on: item)
                } label: {
                    Label("Save…", systemImage: "square.and.arrow.down")
                }
                .keyboardShortcut("s", modifiers: .command)
                .notchShotPrimaryActionStyle()
                .help("Choose where to save this screenshot")
            }
            .padding(14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Capture preview")
        .task(id: item.asset.url) {
            await loadFromDisk()
        }
    }

    /// The read and the decode both stay off the main actor. Without
    /// `decodeImmediately` the decode lands on the first commit instead.
    private func loadFromDisk() async {
        let asset = item.asset
        let needsImage = image == nil
        let loaded = await Task.detached(priority: .userInitiated) {
            let image = needsImage
                ? SafeImageFile.capturedImage(for: asset, decodeImmediately: true)
                : nil
            return (image: image, size: asset.fileSizeDescription)
        }.value
        guard !Task.isCancelled else { return }
        fileSizeDescription = loaded.size
        if let cgImage = loaded.image?.cgImage {
            image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        finishedLoading = true
    }

    @ViewBuilder
    private var preview: some View {
        if let image {
            GeometryReader { geometry in
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .background(Color.black.opacity(0.88))
                    .accessibilityLabel("Screenshot \(item.asset.displayName)")
            }
        } else if finishedLoading {
            ContentUnavailableView(
                "Preview unavailable",
                systemImage: "photo.badge.exclamationmark",
                description: Text("The managed screenshot could not be read.")
            )
        }
    }
}
