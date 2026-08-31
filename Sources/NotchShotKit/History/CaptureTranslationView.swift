import AppKit
import Foundation
import SwiftUI
@preconcurrency import Translation

/// On-device OCR/caption translation for a single History asset. Apple owns
/// language availability and package download UI; NotchShot never sends text
/// to its own service.
public struct CaptureTranslationView: View {
    private struct LanguageChoice: Identifiable {
        var code: String
        var name: String
        var id: String { code }
    }

    private static let languages = [
        LanguageChoice(code: "en", name: "English"),
        LanguageChoice(code: "es", name: "Spanish"),
        LanguageChoice(code: "fr", name: "French"),
        LanguageChoice(code: "de", name: "German"),
        LanguageChoice(code: "it", name: "Italian"),
        LanguageChoice(code: "pt", name: "Portuguese"),
        LanguageChoice(code: "ro", name: "Romanian"),
        LanguageChoice(code: "ru", name: "Russian"),
        LanguageChoice(code: "uk", name: "Ukrainian"),
        LanguageChoice(code: "pl", name: "Polish"),
        LanguageChoice(code: "tr", name: "Turkish"),
        LanguageChoice(code: "ja", name: "Japanese"),
        LanguageChoice(code: "ko", name: "Korean"),
        LanguageChoice(code: "zh-Hans", name: "Chinese, Simplified"),
    ]
    private static let maximumSourceCharacters = 50_000

    private let asset: CaptureAsset
    @State private var sourceText = ""
    @State private var translatedText = ""
    @State private var targetCode = "en"
    @State private var configuration: TranslationSession.Configuration?
    @State private var isLoadingSource = true
    @State private var isTranslating = false
    @State private var errorMessage: String?
    @State private var wasTruncated = false

    public init(asset: CaptureAsset) {
        self.asset = asset
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Translate Capture").font(.title2.bold())
                    Text("OCR and translation run with Apple frameworks on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Language", selection: $targetCode) {
                    ForEach(Self.languages) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                .frame(width: 190)
                Button("Translate") { beginTranslation() }
                    .disabled(sourceText.isEmpty || isLoadingSource || isTranslating)
                    .notchShotPrimaryActionStyle()
            }

            if isLoadingSource {
                ProgressView("Reading capture text…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView(
                    "Translation Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    textPanel(title: wasTruncated ? "Source (first 50,000 characters)" : "Source", text: sourceText)
                    textPanel(title: "Translation", text: translatedText)
                }
                if isTranslating {
                    ProgressView("Preparing the language model…")
                }
                HStack {
                    Spacer()
                    Button("Copy Translation") {
                        ImageExport.copyToPasteboard(text: translatedText)
                    }
                    .disabled(translatedText.isEmpty)
                }
            }
        }
        .padding(18)
        .frame(minWidth: 760, minHeight: 500)
        .task(id: asset.id) { await loadSource() }
        .translationTask(configuration) { session in
            guard !sourceText.isEmpty else { return }
            isTranslating = true
            errorMessage = nil
            do {
                try await session.prepareTranslation()
                translatedText = try await session.translate(sourceText).targetText
            } catch is CancellationError {
                // Replacing the target language invalidates the old session.
            } catch {
                errorMessage = error.localizedDescription
            }
            isTranslating = false
        }
    }

    private func textPanel(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ScrollView {
                Text(text.isEmpty ? "Choose a language and translate." : text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
            }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }
        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func beginTranslation() {
        var request = TranslationSession.Configuration(
            source: nil,
            target: Locale(identifier: targetCode).language
        )
        request.invalidate()
        configuration = request
    }

    private func loadSource() async {
        isLoadingSource = true
        errorMessage = nil
        do {
            let fullText = try await Self.sourceText(for: asset)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fullText.isEmpty else {
                throw NotchShotError.exportFailed("No readable text was found in this capture.")
            }
            wasTruncated = fullText.count > Self.maximumSourceCharacters
            sourceText = String(fullText.prefix(Self.maximumSourceCharacters))
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingSource = false
    }

    private static func sourceText(for asset: CaptureAsset) async throws -> String {
        if asset.kind == .recording {
            guard let captionURL = asset.captionURL else {
                throw NotchShotError.exportFailed(
                    "This recording has no NotchShot caption file to translate."
                )
            }
            let data = try SafeAssetFile.readData(
                at: captionURL,
                maximumBytes: 10_000_000,
                expectedIdentity: asset.captionFileIdentity
            )
            guard let caption = String(data: data, encoding: .utf8) else {
                throw NotchShotError.exportFailed("The caption file is not valid UTF-8 text.")
            }
            return subtitleText(from: caption)
        }
        if let recognized = asset.recognizedText, !recognized.isEmpty {
            return recognized
        }
        guard let image = SafeImageFile.cgImage(for: asset) else {
            throw NotchShotError.exportFailed("The capture is no longer safely readable as an image.")
        }
        return try await OCRService.shared.recognizeText(in: image).fullText
    }

    nonisolated static func subtitleText(from srt: String) -> String {
        srt.components(separatedBy: .newlines)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.isEmpty
                    && Int(trimmed) == nil
                    && !trimmed.contains(" --> ")
            }
            .joined(separator: "\n")
    }
}
