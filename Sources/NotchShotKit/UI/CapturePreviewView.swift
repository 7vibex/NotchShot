import AppKit
import SwiftUI

/// A focused, read-only view of one shelf capture. Export remains an explicit
/// action: captures arrive on the clipboard and in managed History first, then
/// Save As creates a user document only when requested.
public struct CapturePreviewView: View {
    @Bindable var coordinator: AppCoordinator
    @Bindable var item: ShelfItem

    @State private var image: NSImage?

    public init(coordinator: AppCoordinator, item: ShelfItem) {
        self.coordinator = coordinator
        self.item = item
        _image = State(initialValue: item.image?.makeNSImage() ?? SafeImageFile.nsImage(for: item.asset))
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
                    Text("\(item.asset.dimensionsDescription) · \(item.asset.fileSizeDescription)")
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
        } else {
            ContentUnavailableView(
                "Preview unavailable",
                systemImage: "photo.badge.exclamationmark",
                description: Text("The managed screenshot could not be read.")
            )
        }
    }
}
