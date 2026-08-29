import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct DocumentSummaryView: View {
    @Bindable var session: DocumentSummarySession
    var onForget: () -> Void

    public init(session: DocumentSummarySession, onForget: @escaping () -> Void) {
        self.session = session
        self.onForget = onForget
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.sourceURL.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                    Text("Processed locally. The document and unsaved summary are not added to History.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            content

            Spacer(minLength: 0)
            controls
        }
        .padding(20)
        .frame(minWidth: 580, minHeight: 420)
    }

    @ViewBuilder
    private var content: some View {
        switch session.stage {
        case .awaitingConfirmation:
            ContentUnavailableView(
                "Summarize this document?",
                systemImage: "text.document",
                description: Text("NotchShot validates and reads the selected file only after you confirm.")
            )
        case .validating, .extracting, .recognizingScans, .summarizing:
            VStack(spacing: 12) {
                ProgressView()
                Text(session.stage.title).font(.headline)
                Text("You can cancel safely at any stage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(session.stage.title)
        case .complete:
            if let result = session.result {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Overview").font(.headline)
                        Text(result.overview).textSelection(.enabled)
                        if !result.keyPoints.isEmpty {
                            Text("Key points").font(.headline)
                            ForEach(Array(result.keyPoints.enumerated()), id: \.offset) { _, point in
                                Label(point, systemImage: "circle.fill")
                                    .labelStyle(.titleAndIcon)
                                    .font(.body)
                            }
                        }
                        Label(
                            result.usedLanguageModel
                                ? "Created with Apple Intelligence on this Mac"
                                : "Local extractive fallback used; Apple Intelligence was unavailable",
                            systemImage: result.usedLanguageModel ? "apple.intelligence" : "text.quote"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        DisclosureGroup("Extracted text") {
                            Button("Copy Extracted Text") { session.copyExtractedText() }
                            Text(String(result.extractedText.prefix(8_000)))
                                .font(.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if result.extractedText.count > 8_000 {
                                Text("Previewing the first 8,000 characters. Copy Extracted Text includes everything that was read.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .failed:
            ContentUnavailableView(
                "Could not summarize",
                systemImage: "exclamationmark.triangle",
                description: Text(session.errorMessage ?? "The document could not be processed.")
            )
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack {
            if [.validating, .extracting, .recognizingScans, .summarizing].contains(session.stage) {
                Button("Cancel", role: .cancel) { session.cancel() }
            } else if session.stage == .awaitingConfirmation || session.stage == .failed {
                Button("Summarize") { session.start() }
                    .notchShotPrimaryActionStyle()
                    .keyboardShortcut(.defaultAction)
            }

            Spacer()

            if session.stage == .complete {
                Button("Open Original") { session.openOriginal() }
                Button("Save…") { save() }
                Button("Copy Summary") { session.copySummary() }
                    .notchShotPrimaryActionStyle()
                    .keyboardShortcut("c", modifiers: [.command, .shift])
            }
            Button("Forget", role: .destructive) {
                session.forget()
                onForget()
            }
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = session.sourceURL.deletingPathExtension().lastPathComponent + " Summary.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try session.saveSummary(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
