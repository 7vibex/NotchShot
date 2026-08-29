import Foundation

/// A table recovered by Vision, kept as cells so callers can choose a format
/// that preserves rows and columns instead of receiving flattened OCR lines.
public struct RecognizedTable: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var rows: [[String]]

    public init(id: UUID = UUID(), rows: [[String]]) {
        self.id = id
        self.rows = rows.map { row in
            row.map { Self.cleanedCell($0) }
        }
    }

    public var columnCount: Int { rows.map(\.count).max() ?? 0 }

    public var tabSeparatedText: String {
        normalizedRows.map { row in
            row.map(Self.tsvCell).joined(separator: "\t")
        }
        .joined(separator: "\n")
    }

    public var markdown: String {
        guard columnCount > 0, let first = normalizedRows.first else { return "" }
        let header = "| " + first.map(Self.markdownCell).joined(separator: " | ") + " |"
        let divider = "| " + Array(repeating: "---", count: columnCount).joined(separator: " | ") + " |"
        let body = normalizedRows.dropFirst().map { row in
            "| " + row.map(Self.markdownCell).joined(separator: " | ") + " |"
        }
        return ([header, divider] + body).joined(separator: "\n")
    }

    private var normalizedRows: [[String]] {
        guard columnCount > 0 else { return [] }
        return rows.map { row in
            row + Array(repeating: "", count: max(0, columnCount - row.count))
        }
    }

    private static func cleanedCell(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tsvCell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private static func markdownCell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "\r", with: "<br>")
    }
}

public extension OCRResult {
    var tablesAsTSV: String {
        tables.map(\.tabSeparatedText).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    func clipboardText(format: OCRClipboardFormat) -> String {
        switch format {
        case .text:
            return structuredText.isEmpty ? fullText : structuredText
        case .markdown:
            return markdownText.isEmpty ? fullText : markdownText
        case .tsv:
            let tables = tablesAsTSV
            return tables.isEmpty ? fullText : tables
        }
    }
}
