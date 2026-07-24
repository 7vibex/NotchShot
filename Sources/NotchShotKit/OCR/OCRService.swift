import AppKit
import CoreGraphics
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

        public var symbolName: String {
            switch self {
            case .link: "link"
            case .email: "envelope"
            case .phone: "phone"
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
            value.hasPrefix("http") ? URL(string: value) : URL(string: "https://\(value)")
        case .email:
            URL(string: "mailto:\(value)")
        case .phone:
            URL(string: "tel:\(value.filter { $0.isNumber || $0 == "+" })")
        }
    }
}

public struct OCRResult: Sendable, Equatable {
    public var regions: [RecognizedTextRegion]
    /// Reading-order text, one line per region.
    public var fullText: String
    public var detectedItems: [DetectedItem]

    public static let empty = OCRResult(regions: [], fullText: "", detectedItems: [])

    public var isEmpty: Bool { regions.isEmpty }
}

/// On-device text recognition. Nothing leaves the machine.
public actor OCRService {
    public static let shared = OCRService()

    public init() {}

    public func recognizeText(in image: CapturedImage) async throws -> OCRResult {
        try await recognizeText(in: image.cgImage)
    }

    public func recognizeText(in image: CGImage) async throws -> OCRResult {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Screenshots are frequently multilingual and rarely tagged, so let
        // Vision pick rather than pinning to the user's locale.
        request.automaticallyDetectsLanguage = true

        let observations: [RecognizedTextObservation]
        do {
            observations = try await request.perform(on: image)
        } catch {
            Log.ocr.error("Text recognition failed: \(error.localizedDescription)")
            throw NotchShotError.captureFailed("Text recognition failed")
        }

        let imageSize = CGSize(width: image.width, height: image.height)
        var regions: [RecognizedTextRegion] = []

        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let rect = Self.pixelRect(
                from: observation.boundingBox,
                imageSize: imageSize
            )
            regions.append(RecognizedTextRegion(
                text: text,
                rect: rect,
                confidence: candidate.confidence,
                detectedItems: Self.detectItems(in: text)
            ))
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

        let fullText = regions.map(\.text).joined(separator: "\n")
        var seen = Set<String>()
        let items = regions.flatMap(\.detectedItems).filter { seen.insert($0.value).inserted }

        return OCRResult(regions: regions, fullText: fullText, detectedItems: items)
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

    static func detectItems(in text: String) -> [DetectedItem] {
        var items: [DetectedItem] = []
        // The same address or number often appears more than once in a
        // screenshot; the shelf should offer one chip per distinct value, not
        // one per occurrence.
        var seen = Set<String>()

        func append(_ kind: DetectedItem.Kind, _ value: String) {
            let key = "\(kind.rawValue)|\(value.lowercased())"
            guard seen.insert(key).inserted else { return }
            items.append(DetectedItem(kind: kind, value: value))
        }

        let types: NSTextCheckingResult.CheckingType = [.link, .phoneNumber]
        if let detector = try? NSDataDetector(types: types.rawValue) {
            let range = NSRange(text.startIndex ..< text.endIndex, in: text)
            detector.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match else { return }
                switch match.resultType {
                case .link:
                    guard let url = match.url else { return }
                    if url.scheme == "mailto" {
                        let address = url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                        append(.email, address)
                    } else {
                        append(.link, url.absoluteString)
                    }
                case .phoneNumber:
                    guard let number = match.phoneNumber else { return }
                    append(.phone, number)
                default:
                    break
                }
            }
        }

        // NSDataDetector only recognises bare addresses inconsistently, so a
        // conservative regex backstops the common `name@host.tld` form.
        if let regex = try? NSRegularExpression(
            pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            options: .caseInsensitive
        ) {
            let range = NSRange(text.startIndex ..< text.endIndex, in: text)
            for match in regex.matches(in: text, range: range) {
                guard let matchRange = Range(match.range, in: text) else { continue }
                append(.email, String(text[matchRange]))
            }
        }

        return items
    }
}
