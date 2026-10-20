import Foundation
import NotchShotKit

/// Synthetic, in-memory conversation reads. No user transcripts or file lookup.
enum TranscriptWindowBenchmarks {
    static func run(enabled: (String) -> Bool) {
        guard enabled("transcript-window") else { return }
        let timestamp = "2026-10-13T09:15:00Z"
        let date = Date(timeIntervalSince1970: 1_791_882_900)
        let ignored = [
            "{\"type\":\"progress\"}",
            "{\"type\":\"assistant\",\"isMeta\":true,\"message\":{\"content\":\"hidden meta\"}}",
            "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"thinking\",\"thinking\":\"hidden reasoning\"}]}}",
            "not JSON",
            "",
        ].joined(separator: "\n")

        for (name, count, padding, suffix) in [
            ("short", 20, 0, false),
            ("at limit", 80, 0, false),
            ("long", 1500, 0, false),
            ("large text", 1500, 1800, false),
            ("ignored suffix", 1500, 0, true),
        ] {
            let extra = String(repeating: "x", count: padding)
            var lines = (0..<count).map { index in
                "{\"type\":\"assistant\",\"uuid\":\"m\(index)\",\"timestamp\":\"\(timestamp)\",\"message\":{\"content\":\"Visible \(index)\(extra)\"}}"
            }
            if suffix { lines += [String](repeating: ignored, count: 1500) }
            let data = Data(lines.joined(separator: "\n").utf8)
            precondition(data.count <= ClaudeConversationReader.maximumFileBytes)
            let first = max(0, count - ClaudeConversationReader.maximumMessages)
            let expectedIDs = (first..<count).map { "m\($0)" }
            let expectedText = (first..<count).map { "Visible \($0)\(extra)" }
            let output = ClaudeConversationReader.messages(from: data)
            precondition(output.map(\.id) == expectedIDs && output.map(\.text) == expectedText
                && output.allSatisfy { $0.timestamp == date && $0.role == .assistant && $0.toolName == nil })
            let result = Benchmark.measure("transcript-window.\(name)", iterations: 9) {
                Benchmark.blackHole(ClaudeConversationReader.messages(from: data))
            }
            precondition(result.isValid)
        }

        let seed = UInt64(ProcessInfo.processInfo.processIdentifier) | 0x243F_6A88_85A3_0000
        Benchmark.measure("transcript-window.control", iterations: 9) {
            var value = seed
            for _ in 0..<4_000_000 {
                value ^= value << 13
                value ^= value >> 7
                value ^= value << 17
            }
            Benchmark.blackHole(value)
        }
    }
}
