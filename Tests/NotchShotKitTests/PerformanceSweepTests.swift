import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import NotchShotKit

@Suite("Performance sweep equivalence")
struct PerformanceSweepTests {
    @Test("Clipboard hashes retain the exact truncated SHA-256 spelling")
    func hashes() {
        for count in [0, 1, 15, 16, 255, 4096] {
            let data = Data((0..<count).map { UInt8(truncatingIfNeeded: $0) })
            let reference = SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
            #expect(ClipboardEntry.hash(for: data) == reference)
        }
        for text in ["", "ș🐱e\u{301}", "\0\n\t", String(repeating: "a", count: 65_537)] {
            let reference = SHA256.hash(data: Data(text.utf8)).prefix(16)
                .map { String(format: "%02x", $0) }.joined()
            #expect(ClipboardEntry.hash(forText: text) == reference)
        }
    }

    @Test("Hit testing preserves stable ties, negative orders, empty and large documents")
    func hitTesting() {
        for count in [0, 1, 120, 1200] {
            let elements = (0..<count).map { index in
                AnnotationElement(
                    kind: index.isMultiple(of: 9) ? .counter : .rectangle,
                    points: [CGPoint(x: (index * 17) % 150, y: (index * 23) % 150),
                             CGPoint(x: (index * 17) % 150 + 40, y: (index * 23) % 150 + 30)],
                    style: AnnotationStyle(), order: index % 11 - 5
                )
            }
            var document = AnnotationDocument(sourcePixelSize: CGSize(width: 200, height: 200), elements: elements)
            for index in 0..<100 {
                let point = CGPoint(x: (index * 31) % 200, y: (index * 43) % 200)
                let expected = document.sortedElements.reversed().first { $0.contains(point) }
                #expect(document.element(at: point)?.id == expected?.id)
            }
            if !elements.isEmpty {
                document.elements[0].order = .max
                #expect(document.element(at: elements[0].points[0])?.id == elements[0].id)
                document.elements[0].order = .min
                let point = elements[0].points[0]
                #expect(document.element(at: point)?.id
                    == document.sortedElements.reversed().first { $0.contains(point) }?.id)
            }
        }
    }

    @Test("Scrolling comparison is byte-exact across vector tails and early-exit checkpoints")
    func grayscaleDifference() {
        for width in [1, 7, 15, 16, 17, 31, 63, 300] {
            let height = 151
            let left = GrayBuffer(pixels: (0..<(width * height)).map { UInt8(truncatingIfNeeded: $0 * 37) }, width: width, height: height)
            let right = GrayBuffer(pixels: (0..<(width * height)).map { UInt8(truncatingIfNeeded: $0 * 53 + 7) }, width: width, height: height)
            for band in [1, 7, 8, 9, 140] {
                for budget in [-1.0, 0, 3.99, 26, 127, 255, .infinity, .nan] {
                    let actual = left.meanAbsoluteDifference(templateTop: 3, templateHeight: band,
                        against: right, at: 5, earlyExit: budget)
                    #expect(actual == referenceDifference(left, right, top: 3, height: band, position: 5, earlyExit: budget))
                    let identical = left.meanAbsoluteDifference(templateTop: 3, templateHeight: band,
                        against: left, at: 3, earlyExit: budget)
                    #expect(identical == referenceDifference(left, left, top: 3, height: band, position: 3, earlyExit: budget))
                }
            }
        }
    }

    @Test("Transcript dates retain offsets, fallback and bounded message order")
    func transcriptDates() async {
        let timestamps = ["2026-10-13T09:15:00Z", "2026-10-13T12:15:00+03:00", "2026-10-13T01:15:00-08:00"]
        let data = Data((0..<200).map { index in
            "{\"type\":\"assistant\",\"uuid\":\"m\(index)\",\"timestamp\":\"\(timestamps[index % 3])\",\"message\":{\"content\":\"message \(index)\"}}"
        }.joined(separator: "\n").utf8)
        let expected = Date(timeIntervalSince1970: 1_791_882_900)
        await withTaskGroup(of: [ClaudeTranscriptMessage].self) { group in
            for _ in 0..<8 { group.addTask { ClaudeConversationReader.messages(from: data) } }
            for await messages in group {
                #expect(messages.map(\.id) == (120..<200).map { "m\($0)" })
                #expect(messages.allSatisfy { $0.timestamp == expected })
            }
        }
        let before = Date()
        let invalid = Data("{\"type\":\"user\",\"timestamp\":\"invalid\",\"message\":{\"content\":\"fallback\"}}".utf8)
        let fallback = ClaudeConversationReader.messages(from: invalid).first?.timestamp
        #expect(fallback.map { $0 >= before && $0 <= Date() } == true)
    }

    @Test("Stitched images retain their pixels after temporary framework objects drain")
    func stitchedImageLifetime() throws {
        let frames = (0..<4).map { TestImage.page(width: 80, height: 240, offset: $0 * 40) }
        let outputs = try (0..<8).map { _ in
            try autoreleasepool { try ScrollingStitcher.stitch(frames: frames) }
        }
        let first = try #require(outputs.first)
        let bytes = try #require(first.image.dataProvider?.data) as Data
        #expect(!bytes.isEmpty && first.seams.count == 3)
        for output in outputs {
            #expect(output.image.width == first.image.width && output.image.height == first.image.height)
            #expect(output.seams == first.seams && output.warnings == first.warnings)
            #expect(try #require(output.image.dataProvider?.data) as Data == bytes)
        }
    }

    @Test("Clipboard size fast path conservatively accounts for every serialized field")
    func clipboardSizeBound() {
        let identity = ExternalFileIdentity(device: .max, inode: .max, size: .max,
            modifiedSeconds: .min, modifiedNanoseconds: .max, volume: UUID())
        for text in ["", "ordinary text", String(repeating: "\0\"\\\n\t/", count: 200), "ș🐱e\u{301}"] {
            let row = ClipboardEntry(kind: .files, label: text, tags: [text, text], text: text,
                filePaths: [text, text], fileIdentities: [identity, identity], imageFilename: text,
                pixelWidth: .max, pixelHeight: .min, sourceApplicationName: text,
                sourceApplicationBundleID: text, createdAt: .distantFuture, isPinned: true, contentHash: text)
            for count in [0, 1, 100, 500] {
                let rows = [ClipboardEntry](repeating: row, count: count)
                if ClipboardStore.isStoreGuaranteedWithinByteBudget(rows) {
                    #expect(ClipboardStore.encodedStoreBytes(rows) <= ClipboardStore.storeByteBudget)
                }
            }
        }
        #expect(!ClipboardStore.isStoreGuaranteedWithinByteBudget([
            ClipboardEntry(kind: .text, createdAt: Date(timeIntervalSince1970: 1e15), contentHash: "date")
        ]))
        let huge = ClipboardEntry(kind: .text, text: String(repeating: "\0", count: ClipboardStore.storeByteBudget), contentHash: "large")
        #expect(!ClipboardStore.isStoreGuaranteedWithinByteBudget([huge]))
    }

    @Test("Clipboard budgeting preserves exact text reduction, pin priority and row retirement")
    @MainActor
    func clipboardRetention() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notch-sweep-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cases: [(Int, String, Int)] = [
            (500, String(repeating: "small", count: 100), 0),
            (200, String(repeating: "\0", count: 20_000), 20),
            (200, String(repeating: "a", count: 50_000), 200),
            (510, "short", 30),
        ]
        for (index, item) in cases.enumerated() {
            let (count, text, pinCount) = item
            let rows = (0..<count).map { n in
                ClipboardEntry(kind: .text, text: text,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(n)),
                    isPinned: n < pinCount, contentHash: "row-\(n)")
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let url = root.appendingPathComponent("store-\(index).json")
            try encoder.encode(rows).write(to: url)
            let store = ClipboardStore(storeURL: url, imageDirectory: root, isEnabled: { true })
            #expect(store.entries == referenceBudget(rows))
            try store.save()
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            #expect(try decoder.decode([ClipboardEntry].self, from: Data(contentsOf: url)) == store.entries)
        }
    }

    private func referenceDifference(_ left: GrayBuffer, _ right: GrayBuffer, top: Int,
        height: Int, position: Int, earlyExit: Double) -> Double {
        var total = 0
        var counted = 0
        let budget: Int? = earlyExit.isFinite ? Int(min(max(earlyExit, 0), 255)) : nil
        for row in 0..<height {
            for column in 0..<left.width {
                total += abs(Int(left.pixels[(top + row) * left.width + column])
                    - Int(right.pixels[(position + row) * right.width + column]))
            }
            counted += left.width
            if let budget, row % 8 == 7, total / counted > budget { return .greatestFiniteMagnitude }
        }
        return Double(total) / Double(counted)
    }

    private func referenceBudget(_ input: [ClipboardEntry]) -> [ClipboardEntry] {
        var rows = input
        if rows.count > ClipboardStore.maximumEntryCount {
            var unpinnedBudget = ClipboardStore.maximumEntryCount - min(rows.count(where: \.isPinned), ClipboardStore.maximumEntryCount)
            rows = rows.filter { row in
                if row.isPinned { return true }
                guard unpinnedBudget > 0 else { return false }
                unpinnedBudget -= 1
                return true
            }
            rows = Array(rows.prefix(ClipboardStore.maximumEntryCount))
        }
        while ClipboardStore.encodedStoreBytes(rows) > ClipboardStore.storeByteBudget {
            let unpinned = rows.indices.filter { !rows[$0].isPinned && (rows[$0].text?.utf8.count ?? 0) > 4096 }
            let candidates = unpinned.isEmpty ? rows.indices.filter { (rows[$0].text?.utf8.count ?? 0) > 4096 } : unpinned
            if !candidates.isEmpty {
                for index in candidates {
                    let text = rows[index].text!
                    rows[index].text = String(text.prefix(max(2048, text.count / 2))) + "…"
                }
            } else if let index = rows.lastIndex(where: { !$0.isPinned }) ?? rows.indices.last {
                rows.remove(at: index)
            } else { break }
        }
        return rows
    }
}
