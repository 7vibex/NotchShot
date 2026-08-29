import AppKit
import CoreGraphics
import Foundation
import Observation
import SwiftUI
import Vision

public struct PrivacyFinding: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case email
        case phone
        case address
        case accessToken
        case face
        case accountIdentifier
        case paymentCard
        case ipAddress

        public var title: String {
            switch self {
            case .email: "Email address"
            case .phone: "Phone number"
            case .address: "Postal address"
            case .accessToken: "Possible access token"
            case .face: "Face"
            case .accountIdentifier: "Possible account identifier"
            case .paymentCard: "Possible payment card"
            case .ipAddress: "IP address"
            }
        }

        public var symbolName: String {
            switch self {
            case .email: "envelope"
            case .phone: "phone"
            case .address: "mappin.and.ellipse"
            case .accessToken: "key.horizontal"
            case .face: "face.smiling"
            case .accountIdentifier: "person.text.rectangle"
            case .paymentCard: "creditcard"
            case .ipAddress: "network"
            }
        }
    }

    public let id: UUID
    public let kind: Kind
    /// Pixel-space rectangle with a top-left origin.
    public let rect: CGRect
    public let confidence: Float

    public init(id: UUID = UUID(), kind: Kind, rect: CGRect, confidence: Float) {
        self.id = id
        self.kind = kind
        self.rect = rect
        self.confidence = confidence
    }
}

/// Local-only privacy inspection. It returns suggestions and never changes the
/// capture. Redaction elements are created only after the user selects findings
/// and presses the explicit review action.
public actor PrivacyReviewService {
    public static let shared = PrivacyReviewService()

    public init() {}

    public func review(_ image: CGImage) async throws -> [PrivacyFinding] {
        async let textResult = OCRService.shared.recognizeText(in: image)
        async let faceResult = Self.detectFaces(in: image)

        let (ocr, faces) = try await (textResult, faceResult)
        var findings = faces

        for region in ocr.regions {
            for item in region.detectedItems {
                switch item.kind {
                case .email:
                    findings.append(PrivacyFinding(
                        kind: .email,
                        rect: region.rect.insetBy(dx: -4, dy: -3),
                        confidence: region.confidence
                    ))
                case .phone:
                    findings.append(PrivacyFinding(
                        kind: .phone,
                        rect: region.rect.insetBy(dx: -4, dy: -3),
                        confidence: region.confidence
                    ))
                case .address:
                    findings.append(PrivacyFinding(
                        kind: .address,
                        rect: region.rect.insetBy(dx: -4, dy: -3),
                        confidence: region.confidence
                    ))
                case .link, .qrCode, .barcode:
                    break
                }
            }

            if Self.containsAccessToken(region.text) {
                findings.append(PrivacyFinding(
                    kind: .accessToken,
                    rect: region.rect.insetBy(dx: -4, dy: -3),
                    confidence: region.confidence
                ))
            }
            if Self.containsAccountIdentifier(region.text) {
                findings.append(PrivacyFinding(
                    kind: .accountIdentifier,
                    rect: region.rect.insetBy(dx: -4, dy: -3),
                    confidence: region.confidence
                ))
            }
            if Self.containsPaymentCard(region.text) {
                findings.append(PrivacyFinding(
                    kind: .paymentCard,
                    rect: region.rect.insetBy(dx: -4, dy: -3),
                    confidence: region.confidence
                ))
            }
            if Self.containsIPAddress(region.text) {
                findings.append(PrivacyFinding(
                    kind: .ipAddress,
                    rect: region.rect.insetBy(dx: -4, dy: -3),
                    confidence: region.confidence
                ))
            }
        }

        // A single text line can match more than one detector for the same
        // category. Keep the review concise without ever exposing the matched
        // value itself in app state or logs.
        var deduplicated: [PrivacyFinding] = []
        for finding in findings {
            let isDuplicate = deduplicated.contains {
                $0.kind == finding.kind && $0.rect.intersection(finding.rect).areaRatio(over: $0.rect) > 0.8
            }
            if !isDuplicate { deduplicated.append(finding) }
        }
        return deduplicated.sorted { lhs, rhs in
            if lhs.rect.minY != rhs.rect.minY { return lhs.rect.minY < rhs.rect.minY }
            return lhs.rect.minX < rhs.rect.minX
        }
    }

    static func containsAccessToken(_ text: String) -> Bool {
        matches(
            #"(?i)(?:\bgh[pousr]_[A-Z0-9_]{20,}\b|\bAKIA[A-Z0-9]{16}\b|\bsk-[A-Z0-9_-]{16,}\b|\b(?:api[_ -]?key|access[_ -]?token|bearer)\s*[:=]?\s*[A-Z0-9._-]{16,}\b)"#,
            in: text
        )
    }

    static func containsAccountIdentifier(_ text: String) -> Bool {
        matches(
            #"(?i)(?:\b(?:account|user|customer|member|tenant)[ _-]?(?:id|number)?\s*[:#=]\s*[A-Z0-9][A-Z0-9_-]{4,}\b|(?<![A-Z0-9])@[A-Z0-9_][A-Z0-9_.-]{2,}\b)"#,
            in: text
        )
    }

    static func containsPaymentCard(_ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?<!\d)(?:\d[ -]?){13,19}(?!\d)"#
        ) else { return false }
        let fullRange = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.matches(in: text, range: fullRange).contains { match in
            guard let range = Range(match.range, in: text) else { return false }
            let digits = text[range].compactMap(\.wholeNumberValue)
            guard (13...19).contains(digits.count) else { return false }
            let sum = digits.reversed().enumerated().reduce(0) { partial, pair in
                let (index, digit) = pair
                if index.isMultiple(of: 2) { return partial + digit }
                let doubled = digit * 2
                return partial + (doubled > 9 ? doubled - 9 : doubled)
            }
            return sum.isMultiple(of: 10)
        }
    }

    static func containsIPAddress(_ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?<!\d)(?:\d{1,3}\.){3}\d{1,3}(?!\d)"#
        ) else { return false }
        let fullRange = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.matches(in: text, range: fullRange).contains { match in
            guard let range = Range(match.range, in: text) else { return false }
            return text[range].split(separator: ".").allSatisfy {
                guard let octet = Int($0) else { return false }
                return (0...255).contains(octet)
            }
        }
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    private static func detectFaces(in image: CGImage) async throws -> [PrivacyFinding] {
        let request = DetectFaceRectanglesRequest()
        let observations = try await request.perform(on: image)
        let imageSize = CGSize(width: image.width, height: image.height)
        return observations.map { observation in
            let rect = OCRService.pixelRect(from: observation.boundingBox, imageSize: imageSize)
            let padding = max(6, min(rect.width, rect.height) * 0.08)
            return PrivacyFinding(
                kind: .face,
                rect: rect.insetBy(dx: -padding, dy: -padding),
                confidence: observation.confidence
            )
        }
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }

    func areaRatio(over other: CGRect) -> CGFloat {
        guard other.area > 0 else { return 0 }
        return intersection(other).area / other.area
    }
}

@MainActor
@Observable
public final class PrivacyReviewSession {
    public let asset: CaptureAsset
    public let source: CGImage
    public private(set) var findings: [PrivacyFinding] = []
    public private(set) var isReviewing = false
    public private(set) var errorMessage: String?
    public var selectedFindingIDs: Set<UUID> = []

    public init(asset: CaptureAsset, source: CGImage) {
        self.asset = asset
        self.source = source
    }

    public func run() {
        guard !isReviewing else { return }
        isReviewing = true
        errorMessage = nil
        Task {
            do {
                findings = try await PrivacyReviewService.shared.review(source)
            } catch {
                errorMessage = error.localizedDescription
            }
            isReviewing = false
        }
    }

    public var selectedFindings: [PrivacyFinding] {
        findings.filter { selectedFindingIDs.contains($0.id) }
    }

    public func selectAll() {
        selectedFindingIDs = Set(findings.map(\.id))
    }

    public func deselectAll() {
        selectedFindingIDs.removeAll()
    }
}

public struct PrivacyReviewView: View {
    @Bindable var session: PrivacyReviewSession
    var onApply: ([PrivacyFinding]) -> Void

    public init(session: PrivacyReviewSession, onApply: @escaping ([PrivacyFinding]) -> Void) {
        self.session = session
        self.onApply = onApply
    }

    public var body: some View {
        HSplitView {
            preview
                .frame(minWidth: 520, minHeight: 460)
            sidebar
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 340)
        }
        .frame(minWidth: 820, minHeight: 520)
        .task { session.run() }
    }

    private var preview: some View {
        GeometryReader { geometry in
            let fitted = aspectFit(
                CGSize(width: session.source.width, height: session.source.height),
                in: geometry.size.insetBy(24)
            )
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                Image(nsImage: NSImage(
                    cgImage: session.source,
                    size: NSSize(width: session.source.width, height: session.source.height)
                ))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .accessibilityLabel("Capture being reviewed for private details")
                .frame(width: fitted.width, height: fitted.height)
                .position(x: fitted.midX, y: fitted.midY)

                ForEach(session.findings) { finding in
                    let rect = map(finding.rect, into: fitted)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(session.selectedFindingIDs.contains(finding.id)
                              ? Color.red.opacity(0.22) : Color.orange.opacity(0.12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(.black.opacity(0.82), lineWidth: 4)
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(session.selectedFindingIDs.contains(finding.id)
                                        ? Color.red : Color.orange, lineWidth: 2)
                        }
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Share Ready")
                .font(.title2.weight(.semibold))
            Text("NotchShot checks locally for likely private details. Detection is not perfect, so inspect the whole capture before sharing.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if session.isReviewing {
                ProgressView("Looking for private details…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = session.errorMessage {
                ContentUnavailableView("Review failed", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if session.findings.isEmpty {
                ContentUnavailableView(
                    "No likely private details",
                    systemImage: "checkmark.shield",
                    description: Text("Still inspect the capture yourself before sharing.")
                )
            } else {
                HStack {
                    Button("Select All") { session.selectAll() }
                    Button("Deselect All") { session.deselectAll() }
                    Spacer()
                    Text("Confidence is shown for context")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                List(session.findings) { finding in
                    Toggle(isOn: selectionBinding(for: finding.id)) {
                        HStack {
                            Label(finding.kind.title, systemImage: finding.kind.symbolName)
                            Spacer()
                            Text(finding.confidence, format: .percent.precision(.fractionLength(0)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                .listStyle(.inset)
            }

            Spacer(minLength: 0)
            HStack {
                Text("\(session.selectedFindingIDs.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Review Redactions in Editor") {
                    onApply(session.selectedFindings)
                }
                .notchShotPrimaryActionStyle()
                .disabled(session.selectedFindingIDs.isEmpty)
            }
        }
        .padding(16)
    }

    private func selectionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { session.selectedFindingIDs.contains(id) },
            set: { selected in
                if selected { session.selectedFindingIDs.insert(id) }
                else { session.selectedFindingIDs.remove(id) }
            }
        )
    }

    private func aspectFit(_ source: CGSize, in container: CGSize) -> CGRect {
        guard source.width > 0, source.height > 0 else { return .zero }
        let scale = min(container.width / source.width, container.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2 + 12,
            y: (container.height - size.height) / 2 + 12,
            width: size.width,
            height: size.height
        )
    }

    private func map(_ sourceRect: CGRect, into fitted: CGRect) -> CGRect {
        let scaleX = fitted.width / CGFloat(session.source.width)
        let scaleY = fitted.height / CGFloat(session.source.height)
        return CGRect(
            x: fitted.minX + sourceRect.minX * scaleX,
            y: fitted.minY + sourceRect.minY * scaleY,
            width: sourceRect.width * scaleX,
            height: sourceRect.height * scaleY
        )
    }
}

private extension CGSize {
    func insetBy(_ amount: CGFloat) -> CGSize {
        CGSize(width: max(1, width - amount * 2), height: max(1, height - amount * 2))
    }
}
