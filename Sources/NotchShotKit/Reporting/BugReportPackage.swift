import AppKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

public struct BugReportOptions: Sendable, Codable, Equatable {
    public var notes = ""
    public var includesSourceApplication = false
    public var includesMacOSVersion = false
    public var includesDisplayDetails = false
    public var includesCaptureMetadata = false
    /// Editable projects contain the unredacted source. This must stay opt-in.
    public var includesEditableProject = false

    public init() {}
}

public struct BugReportManifest: Sendable, Codable, Equatable {
    public var createdAt: Date
    public var attachmentName: String
    public var sourceApplicationName: String?
    public var sourceApplicationBundleID: String?
    public var operatingSystem: String?
    public var displays: [String]?
    public var captureKind: String?
    public var captureDimensions: String?
    public var captureDuration: TimeInterval?
    public var includesEditableProject: Bool
}

/// Builds a transparent, inspectable package. It never reads unified logs,
/// crash reports, device serials, account data, or unrelated files.
@MainActor
public enum BugReportPackager {
    @discardableResult
    public static func write(
        asset: CaptureAsset,
        options: BugReportOptions,
        to destination: URL
    ) throws -> URL {
        let fileManager = FileManager.default
        guard SafeAssetFile.isCurrentAndSafe(asset) else {
            throw NotchShotError.exportFailed("The capture file changed or is no longer safely readable")
        }
        // No existence check: the save panel has already asked the user whether
        // to replace, and refusing here turned that answered question into a
        // dead end. The package is assembled in a sibling temporary directory
        // and swapped in, so a failure part-way through leaves whatever was
        // already at `destination` untouched.
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".notchbug-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
        do {
            let attachmentName = "Capture.\(asset.url.pathExtension.isEmpty ? "bin" : asset.url.pathExtension)"
            try SafeAssetFile.copy(
                asset,
                to: temporary.appendingPathComponent(attachmentName)
            )

            var includedProject = false
            if options.includesEditableProject, let project = asset.projectURL,
               fileManager.fileExists(atPath: project.path) {
                let contents = try NotchShotPackage.read(from: project)
                _ = try NotchShotPackage.write(
                    document: contents.document,
                    source: contents.source,
                    to: temporary.appendingPathComponent("Editable.notchshot", isDirectory: true)
                )
                includedProject = true
            }

            let manifest = BugReportManifest(
                createdAt: Date(),
                attachmentName: attachmentName,
                sourceApplicationName: options.includesSourceApplication
                    ? asset.sourceApplicationName : nil,
                sourceApplicationBundleID: options.includesSourceApplication
                    ? asset.sourceApplication : nil,
                operatingSystem: options.includesMacOSVersion
                    ? ProcessInfo.processInfo.operatingSystemVersionString : nil,
                displays: options.includesDisplayDetails
                    ? NSScreen.screens.map { screen in
                        "\(Int(screen.frame.width))x\(Int(screen.frame.height)) @ \(screen.backingScaleFactor)x"
                    } : nil,
                captureKind: options.includesCaptureMetadata ? asset.kind.rawValue : nil,
                captureDimensions: options.includesCaptureMetadata
                    ? asset.dimensionsDescription : nil,
                captureDuration: options.includesCaptureMetadata ? asset.duration : nil,
                includesEditableProject: includedProject
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(
                to: temporary.appendingPathComponent("Manifest.json"),
                options: .atomic
            )
            try reportMarkdown(manifest: manifest, notes: options.notes).write(
                to: temporary.appendingPathComponent("Report.md"),
                atomically: true,
                encoding: .utf8
            )
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
            return destination
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private static func reportMarkdown(manifest: BugReportManifest, notes: String) -> String {
        var lines = [
            "# Bug Report",
            "",
            notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Describe what happened and what you expected."
                : notes.trimmingCharacters(in: .whitespacesAndNewlines),
            "",
            "## Included by the user",
            "",
            "- Attachment: \(manifest.attachmentName)",
        ]
        if let app = manifest.sourceApplicationName {
            lines.append("- App: \(app)")
        }
        if let bundle = manifest.sourceApplicationBundleID {
            lines.append("- Bundle identifier: \(bundle)")
        }
        if let os = manifest.operatingSystem {
            lines.append("- macOS: \(os)")
        }
        if let displays = manifest.displays {
            lines.append("- Displays: \(displays.joined(separator: ", "))")
        }
        if let kind = manifest.captureKind {
            lines.append("- Capture kind: \(kind)")
        }
        if let dimensions = manifest.captureDimensions {
            lines.append("- Dimensions: \(dimensions)")
        }
        if let duration = manifest.captureDuration {
            lines.append("- Duration: \(String(format: "%.1f", duration)) seconds")
        }
        if manifest.includesEditableProject {
            lines.append("- Editable project: included by explicit choice; it may contain the unredacted original")
        }
        lines.append(contentsOf: [
            "",
            "No logs, device serial numbers, account data, or unrelated files were collected.",
            "",
        ])
        return lines.joined(separator: "\n")
    }
}

@MainActor
@Observable
public final class BugReportSession {
    public let asset: CaptureAsset
    public var options = BugReportOptions()
    public var errorMessage: String?
    public var exportedURL: URL?

    public init(asset: CaptureAsset) {
        self.asset = asset
    }

    public func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Bug Report.notchbug"
        panel.directoryURL = Preferences.shared.outputFolder
        panel.message = "Creates an inspectable folder with only the attachment and details selected below."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            exportedURL = try BugReportPackager.write(asset: asset, options: options, to: url)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func shareExportedPackage() {
        guard let exportedURL,
              let values = try? exportedURL.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey,
              ]),
              values.isDirectory == true,
              values.isSymbolicLink != true else {
            errorMessage = "Create the package before sharing it."
            return
        }
        do {
            try MacSharePresenter.shared.present(items: [exportedURL])
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

public struct BugReportView: View {
    @Bindable var session: BugReportSession

    public init(session: BugReportSession) {
        self.session = session
    }

    public var body: some View {
        Form {
            Section("What happened?") {
                TextEditor(text: $session.options.notes)
                    .frame(minHeight: 120)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25))
                    }
            }

            Section("Attach") {
                LabeledContent("Capture") {
                    Text(session.asset.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if session.asset.projectURL != nil {
                    Toggle(
                        "Include editable project (may contain the unredacted original)",
                        isOn: $session.options.includesEditableProject
                    )
                }
            }

            Section("Diagnostic details — all off until you select them") {
                Toggle("Source app name and bundle identifier", isOn: $session.options.includesSourceApplication)
                Toggle("macOS version", isOn: $session.options.includesMacOSVersion)
                Toggle("Display sizes and scales", isOn: $session.options.includesDisplayDetails)
                Toggle("Capture type, dimensions, and duration", isOn: $session.options.includesCaptureMetadata)
            }

            Section {
                Label(
                    "NotchShot never adds logs, serial numbers, account data, or unrelated files.",
                    systemImage: "hand.raised.fill"
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                HStack {
                    if let url = session.exportedURL {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        Button("Share…") { session.shareExportedPackage() }
                    }
                    if let error = session.errorMessage {
                        InlineErrorMessage(message: error)
                    }
                    Spacer()
                    Button("Create Package…") { session.export() }
                        .notchShotPrimaryActionStyle()
                }
            }
        }
        .notchShotFormStyle()
        .frame(minWidth: 560, minHeight: 520)
    }
}
