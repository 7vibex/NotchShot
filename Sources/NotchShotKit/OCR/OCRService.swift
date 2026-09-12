import AppKit
import CoreGraphics
import DataDetection
import Foundation
import Vision

/// One recognised line, with where it sits in the image.
public struct RecognizedTextRegion: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let text: String
    /// Rect in image pixel space, top-left origin.
    public let rect: CGRect
    public let confidence: Float
    /// Data detectors that fired inside this line.
    public let detectedItems: [DetectedItem]

    public init(
        id: UUID = UUID(),
        text: String,
        rect: CGRect,
        confidence: Float,
        detectedItems: [DetectedItem] = []
    ) {
        self.id = id
        self.text = text
        self.rect = rect
        self.confidence = confidence
        self.detectedItems = detectedItems
    }
}

public struct DetectedItem: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case link
        case email
        case phone
        case address
        case qrCode
        case barcode

        public var symbolName: String {
            switch self {
            case .link: "link"
            case .email: "envelope"
            case .phone: "phone"
            case .address: "mappin.and.ellipse"
            case .qrCode: "qrcode"
            case .barcode: "barcode"
            }
        }
    }

    public let id: UUID
    public let kind: Kind
    public let value: String

    public init(id: UUID = UUID(), kind: Kind, value: String) {
        self.id = id
        self.kind = kind
        self.value = value
    }

    /// URL to open when the user clicks the item.
    public var actionURL: URL? {
        switch kind {
        case .link:
            let candidate = value.contains("://") ? value : "https://\(value)"
            guard let url = URL(string: candidate), ["http", "https"].contains(url.scheme?.lowercased()) else {
                return nil
            }
            return url
        case .email:
            return URL(string: "mailto:\(value)")
        case .phone:
            return URL(string: "tel:\(value.filter { $0.isNumber || $0 == "+" })")
        case .qrCode:
            guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased()) else {
                return nil
            }
            return url
        case .address, .barcode:
            return nil
        }
    }
}

public struct OCRResult: Sendable, Equatable {
    public var regions: [RecognizedTextRegion]
    /// Reading-order text, one line per region.
    public var fullText: String
    public var detectedItems: [DetectedItem]
    public var tables: [RecognizedTable]
    /// Reading-order text with table columns preserved as TSV.
    public var structuredText: String
    /// Reading-order Markdown with tables and lists preserved.
    public var markdownText: String

    public init(
        regions: [RecognizedTextRegion],
        fullText: String,
        detectedItems: [DetectedItem],
        tables: [RecognizedTable] = [],
        structuredText: String? = nil,
        markdownText: String? = nil
    ) {
        self.regions = regions
        self.fullText = fullText
        self.detectedItems = detectedItems
        self.tables = tables
        self.structuredText = structuredText ?? fullText
        self.markdownText = markdownText ?? fullText
    }

    public static let empty = OCRResult(regions: [], fullText: "", detectedItems: [])

    public var isEmpty: Bool {
        regions.isEmpty
            && detectedItems.isEmpty
            && tables.isEmpty
            && fullText.isEmpty
            && structuredText.isEmpty
            && markdownText.isEmpty
    }
}

/// On-device text recognition. Nothing leaves the machine.
public actor OCRService {
    public static let shared = OCRService()

    public init() {}

    public func recognizeText(in image: CapturedImage) async throws -> OCRResult {
        try await recognizeText(in: image.cgImage)
    }

    public func recognizeText(in image: CGImage) async throws -> OCRResult {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.automaticallyDetectLanguage = true
        request.textRecognitionOptions.useLanguageCorrection = true
        request.barcodeDetectionOptions.enabled = true

        let observations: [DocumentObservation]
        do {
            observations = try await request.perform(on: image)
        } catch {
            Log.ocr.error("Document recognition failed: \(error.localizedDescription)")
            throw NotchShotError.captureFailed("Document recognition failed")
        }

        let imageSize = CGSize(width: image.width, height: image.height)
        var regions: [RecognizedTextRegion] = []
        var tables: [RecognizedTable] = []
        var blocks: [DocumentBlock] = []
        var allItems: [DetectedItem] = []
        var codes: [DetectedItem] = []
        var transcripts: [String] = []

        for observation in observations {
            let document = observation.document
            let transcript = document.text.transcript
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !transcript.isEmpty { transcripts.append(transcript) }

            let detections = Self.structuredDetections(in: document, imageSize: imageSize)
            allItems.append(contentsOf: detections.map(\.item))

            for line in document.text.lines {
                guard let candidate = line.topCandidates(1).first else { continue }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let rect = Self.pixelRect(from: line.boundingBox, imageSize: imageSize)
                let lineItems = detections
                    .filter { Self.meaningfullyIntersects(rect, $0.rect) }
                    .map(\.item)
                regions.append(RecognizedTextRegion(
                    text: text,
                    rect: rect,
                    confidence: candidate.confidence,
                    detectedItems: Self.uniqued(lineItems)
                ))
            }

            let documentTables = document.tables.compactMap(Self.recognizedTable)
            tables.append(contentsOf: documentTables)
            blocks.append(contentsOf: Self.documentBlocks(
                from: document,
                imageSize: imageSize
            ))

            let documentCodes = Self.barcodes(in: document).compactMap(Self.detectedItem)
            codes.append(contentsOf: documentCodes)
            allItems.append(contentsOf: documentCodes)
        }

        // Vision returns observations roughly in reading order already, but
        // sorting by band then x makes multi-column captures come out sane.
        regions.sort { lhs, rhs in
            let bandHeight = max(imageSize.height * 0.012, 8)
            let lhsBand = (lhs.rect.midY / bandHeight).rounded(.down)
            let rhsBand = (rhs.rect.midY / bandHeight).rounded(.down)
            if lhsBand != rhsBand { return lhsBand < rhsBand }
            return lhs.rect.minX < rhs.rect.minX
        }

        blocks.sort(by: Self.readingOrder)
        let uniqueCodes = Self.uniqued(codes)
        var fullText = transcripts.joined(separator: "\n\n")
        let codeText = uniqueCodes.map(\.value).filter { !fullText.contains($0) }.joined(separator: "\n")
        if !codeText.isEmpty {
            fullText = fullText.isEmpty ? codeText : fullText + "\n" + codeText
        }

        var structuredText = blocks.map(\.plainText).filter { !$0.isEmpty }.joined(separator: "\n\n")
        var markdownText = blocks.map(\.markdown).filter { !$0.isEmpty }.joined(separator: "\n\n")
        for payload in uniqueCodes.map(\.value) {
            if !structuredText.contains(payload) {
                structuredText = structuredText.isEmpty ? payload : structuredText + "\n" + payload
            }
            if !markdownText.contains(payload) {
                markdownText = markdownText.isEmpty ? payload : markdownText + "\n" + payload
            }
        }
        return OCRResult(
            regions: regions,
            fullText: fullText,
            detectedItems: Self.uniqued(allItems),
            tables: tables,
            structuredText: structuredText,
            markdownText: markdownText
        )
    }

    /// Vision reports a normalised, bottom-left-origin box; images and every
    /// other part of this app use top-left pixel space.
    static func pixelRect(from normalized: NormalizedRect, imageSize: CGSize) -> CGRect {
        let rect = normalized.cgRect
        return CGRect(
            x: rect.origin.x * imageSize.width,
            y: (1 - rect.origin.y - rect.height) * imageSize.height,
            width: rect.width * imageSize.width,
            height: rect.height * imageSize.height
        )
    }

    private struct StructuredDetection {
        var item: DetectedItem
        var rect: CGRect
    }

    private struct DocumentBlock {
        var rect: CGRect
        var plainText: String
        var markdown: String
    }

    private static func structuredDetections(
        in container: DocumentObservation.Container,
        imageSize: CGSize
    ) -> [StructuredDetection] {
        dataMatches(in: container).compactMap { detected in
            guard let item = detectedItem(from: detected.match.details) else { return nil }
            return StructuredDetection(
                item: item,
                rect: pixelRect(from: detected.boundingRegion.boundingBox, imageSize: imageSize)
            )
        }
    }

    private static func dataMatches(
        in container: DocumentObservation.Container
    ) -> [DocumentObservation.Container.DataDetectorMatch] {
        var matches = container.text.detectedData
        for table in container.tables {
            for row in table.rows {
                for cell in row {
                    matches.append(contentsOf: dataMatches(in: cell.content))
                }
            }
        }
        for list in container.lists {
            for item in list.items {
                matches.append(contentsOf: dataMatches(in: item.content))
            }
        }
        return matches
    }

    private static func detectedItem(
        from details: DataDetector.Match.SemanticDetails
    ) -> DetectedItem? {
        switch details {
        case .link(let link):
            return DetectedItem(kind: .link, value: link.url.absoluteString)
        case .emailAddress(let email):
            return DetectedItem(kind: .email, value: email.emailAddress)
        case .phoneNumber(let phone):
            return DetectedItem(kind: .phone, value: phone.phoneNumber)
        case .postalAddress(let address):
            return DetectedItem(kind: .address, value: address.fullAddress)
        default:
            return nil
        }
    }

    private static func barcodes(
        in container: DocumentObservation.Container
    ) -> [BarcodeObservation] {
        var observations = container.barcodes
        for table in container.tables {
            for row in table.rows {
                for cell in row {
                    observations.append(contentsOf: barcodes(in: cell.content))
                }
            }
        }
        for list in container.lists {
            for item in list.items {
                observations.append(contentsOf: barcodes(in: item.content))
            }
        }
        return observations
    }

    private static func detectedItem(from observation: BarcodeObservation) -> DetectedItem? {
        guard let payload = observation.payloadString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !payload.isEmpty else { return nil }
        let kind: DetectedItem.Kind = switch observation.symbology {
        case .qr, .microQR: .qrCode
        default: .barcode
        }
        return DetectedItem(kind: kind, value: payload)
    }

    private static func recognizedTable(
        _ table: DocumentObservation.Container.Table
    ) -> RecognizedTable? {
        let rows = table.rows.map { row in
            row.map { $0.content.text.transcript }
        }
        guard rows.contains(where: { row in
            row.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }) else { return nil }
        return RecognizedTable(rows: rows)
    }

    private static func documentBlocks(
        from document: DocumentObservation.Container,
        imageSize: CGSize
    ) -> [DocumentBlock] {
        var blocks: [DocumentBlock] = []
        let tableRects = document.tables.map {
            pixelRect(from: $0.boundingRegion.boundingBox, imageSize: imageSize)
        }
        let listRects = document.lists.map {
            pixelRect(from: $0.boundingRegion.boundingBox, imageSize: imageSize)
        }
        let structuralRects = tableRects + listRects

        if let title = document.title {
            let text = title.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                blocks.append(DocumentBlock(
                    rect: pixelRect(from: title.boundingRegion.boundingBox, imageSize: imageSize),
                    plainText: text,
                    markdown: "# \(text)"
                ))
            }
        }

        for paragraph in document.paragraphs {
            let rect = pixelRect(from: paragraph.boundingRegion.boundingBox, imageSize: imageSize)
            guard !structuralRects.contains(where: { meaningfullyIntersects(rect, $0) }),
                  !blocks.contains(where: { meaningfullyIntersects(rect, $0.rect) }) else { continue }
            let text = paragraph.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                blocks.append(DocumentBlock(rect: rect, plainText: text, markdown: text))
            }
        }

        for table in document.tables {
            guard let recognized = recognizedTable(table) else { continue }
            blocks.append(DocumentBlock(
                rect: pixelRect(from: table.boundingRegion.boundingBox, imageSize: imageSize),
                plainText: recognized.tabSeparatedText,
                markdown: recognized.markdown
            ))
        }

        for list in document.lists {
            let plain = list.items.map { item in
                [item.markerString, item.itemString]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            let markdown = list.items.enumerated().map { index, item in
                let prefix: String = switch item.markerType {
                case .decimal, .decorativeDecimal, .compositeDecimal,
                     .lowercaseLatin, .uppercaseLatin:
                    "\(index + 1)."
                default:
                    "-"
                }
                return "\(prefix) \(item.itemString)"
            }
            blocks.append(DocumentBlock(
                rect: pixelRect(from: list.boundingRegion.boundingBox, imageSize: imageSize),
                plainText: plain.joined(separator: "\n"),
                markdown: markdown.joined(separator: "\n")
            ))
        }

        if blocks.isEmpty {
            let transcript = document.text.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !transcript.isEmpty {
                blocks.append(DocumentBlock(
                    rect: pixelRect(from: document.boundingRegion.boundingBox, imageSize: imageSize),
                    plainText: transcript,
                    markdown: transcript
                ))
            }
        }
        return blocks
    }

    private static func readingOrder(_ lhs: DocumentBlock, _ rhs: DocumentBlock) -> Bool {
        let bandHeight: CGFloat = 8
        let lhsBand = (lhs.rect.minY / bandHeight).rounded(.down)
        let rhsBand = (rhs.rect.minY / bandHeight).rounded(.down)
        if lhsBand != rhsBand { return lhsBand < rhsBand }
        return lhs.rect.minX < rhs.rect.minX
    }

    private static func meaningfullyIntersects(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return false }
        let intersectionArea = intersection.width * intersection.height
        let smallerArea = min(lhs.width * lhs.height, rhs.width * rhs.height)
        return smallerArea > 0 && intersectionArea / smallerArea >= 0.45
    }

    private static func uniqued(_ items: [DetectedItem]) -> [DetectedItem] {
        var seen = Set<String>()
        return items.filter {
            seen.insert("\($0.kind.rawValue)|\($0.value.lowercased())").inserted
        }
    }
}
