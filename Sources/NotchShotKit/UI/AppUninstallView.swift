import AppKit
import SwiftUI

/// Confirms an uninstall or reset dropped on the notch: what goes, how big it
/// is, and one button that moves the selection to the Trash.
public struct AppUninstallView: View {
    @Bindable var session: AppUninstallSession
    var onClose: () -> Void

    public init(session: AppUninstallSession, onClose: @escaping () -> Void) {
        self.session = session
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            content
            Spacer(minLength: 0)
            controls
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
    }

    private var header: some View {
        HStack(spacing: 12) {
            if session.apps.count == 1 {
                Image(nsImage: NSWorkspace.shared.icon(forFile: session.apps[0].url.path))
                    .resizable()
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                    .frame(width: 48, height: 48)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(session.mode == .uninstall
                     ? "The app and the data it left in your Library go to the Trash. Put Back restores them."
                     : "The app stays. Its settings, caches and saved data go to the Trash, so it opens as if newly installed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch session.stage {
        case .scanning:
            VStack(spacing: 12) {
                ProgressView()
                Text("Looking for leftovers…").font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready, .removing, .failed:
            VStack(alignment: .leading, spacing: 10) {
                if !session.runningApps.isEmpty {
                    runningBanner
                }
                if case .failed(let message) = session.stage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
                itemList
            }
        case .finished(let count, let bytes):
            ContentUnavailableView(
                session.mode == .uninstall ? "Moved to the Trash" : "Reset complete",
                systemImage: "checkmark.circle.fill",
                description: Text("\(count) \(count == 1 ? "item" : "items")"
                    + (bytes > 0 ? ", \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))" : "")
                    + ". Empty the Trash to free the space.")
            )
        }
    }

    private var runningBanner: some View {
        HStack {
            Label(
                "\(session.runningApps.map(\.name).joined(separator: ", ")) \(session.runningApps.count == 1 ? "is" : "are") open",
                systemImage: "exclamationmark.circle.fill"
            )
            .foregroundStyle(.orange)
            Spacer()
            Button("Quit") {
                Task { await session.quitRunningApps() }
            }
        }
        .font(.callout)
        .padding(10)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var itemList: some View {
        List {
            ForEach(session.apps) { app in
                Section {
                    if session.mode == .uninstall {
                        row(
                            url: app.url,
                            title: app.url.lastPathComponent,
                            subtitle: app.url.deletingLastPathComponent().path,
                            bytes: session.appSizes[app.url]
                        )
                    }
                    let leftovers = session.leftovers(for: app)
                    if leftovers.isEmpty {
                        Text("No leftovers found in your Library")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(leftovers) { leftover in
                        row(
                            url: leftover.url,
                            title: leftover.url.lastPathComponent,
                            subtitle: subtitle(for: leftover),
                            bytes: leftover.byteCount
                        )
                    }
                } header: {
                    Text(app.version.map { "\(app.name) \($0)" } ?? app.name)
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .disabled(session.stage == .removing)
    }

    private func subtitle(for leftover: AppLeftover) -> String {
        if leftover.category == AppLeftoverScanner.sharedContainerCategory {
            return "Shared with the developer's other apps"
        }
        return leftover.confidence == .likely ? leftover.category + " · matched by name" : leftover.category
    }

    private func row(url: URL, title: String, subtitle: String, bytes: Int64?) -> some View {
        Toggle(isOn: Binding(
            get: { session.selection.contains(url) },
            set: { isOn in
                if isOn { session.selection.insert(url) } else { session.selection.remove(url) }
            }
        )) {
            HStack(spacing: 8) {
                // Finder's own icon: a plist looks like a plist, a folder like
                // a folder, and the app like itself.
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1).truncationMode(.middle)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack {
            if session.stage == .ready || session.stage == .removing {
                Text(selectionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if case .finished = session.stage {
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    Task { await session.perform() }
                } label: {
                    if session.stage == .removing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Move to Trash")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(session.selection.isEmpty || session.stage == .scanning || session.stage == .removing)
            }
        }
    }

    private var selectionSummary: String {
        let count = session.selection.count
        let bytes = session.selectedByteCount
        return "\(count) \(count == 1 ? "item" : "items") selected"
            + (bytes > 0 ? ", \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))" : "")
    }
}
