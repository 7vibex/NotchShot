import Foundation
import Testing
@testable import NotchShotKit

@Suite("Transcript visible window")
struct TranscriptWindowTests {
    @Test("The last visible messages retain order, duplicate IDs, fallback line IDs and privacy filtering")
    func visibleWindow() throws {
        let date = Date(timeIntervalSince1970: 1_791_882_900)
        for count in [0, 1, 79, 80, 81, 1500] {
            var lines: [String] = []
            var expected: [ClaudeTranscriptMessage] = []
            var nonemptyLineCount = 0
            func append(_ line: String) {
                lines.append(line)
                if !line.isEmpty { nonemptyLineCount += 1 }
            }
            for index in 0..<count {
                for line in [
                    "", "not JSON", "{\"type\":\"progress\"}",
                    "{\"type\":\"user\",\"isMeta\":true,\"message\":{\"content\":\"private meta\"}}",
                    "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"thinking\",\"thinking\":\"private reasoning\"}]}}",
                    "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"content\":\"private payload\"}]}}",
                    "{\"type\":\"user\",\"message\":{\"content\":\"<command-name>hidden\"}}",
                ] { append(line) }

                let useFallback = index.isMultiple(of: 3)
                let id = useFallback ? "line-\(nonemptyLineCount)" : "duplicate"
                let content: Any
                let role: ClaudeTranscriptRole
                let text: String
                let toolName: String?
                switch index % 3 {
                case 0:
                    content = "  Visible \(index) ș🐱  "
                    role = .user
                    text = "Visible \(index) ș🐱"
                    toolName = nil
                case 1:
                    content = [["type": "tool_use", "name": "Bash", "input": ["private": "payload"]]]
                    role = .tool
                    text = "Used Bash"
                    toolName = "Bash"
                default:
                    content = [["type": "text", "text": "Visible \(index)"],
                        ["type": "tool_use", "name": "Read", "input": ["private": "payload"]]]
                    role = .assistant
                    text = "Visible \(index)\n\nTool: Read"
                    toolName = nil
                }
                var object: [String: Any] = [
                    "type": role == .user ? "user" : "assistant",
                    "timestamp": "2026-10-13T12:15:00+03:00",
                    "message": ["content": content],
                ]
                object["uuid"] = useFallback ? "  " : id
                let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                append(String(decoding: data, as: UTF8.self))
                expected.append(ClaudeTranscriptMessage(id: id, role: role, text: text,
                    toolName: toolName, timestamp: date))
            }
            // Ignored trailing rows must not consume slots in the visible window.
            for _ in 0..<100 { append("{\"type\":\"assistant\",\"message\":{\"content\":\"   \"}}") }
            let actual = ClaudeConversationReader.messages(from: Data(lines.joined(separator: "\n").utf8))
            #expect(actual == Array(expected.suffix(ClaudeConversationReader.maximumMessages)))
            #expect(!actual.contains { $0.text.contains("private") })
        }
    }

    @Test("Fallback timestamps are resolved in original message order within the read")
    func fallbackDates() {
        let data = Data((0..<100).map { index in
            let timestamp = index.isMultiple(of: 2) ? ",\"timestamp\":\"invalid\"" : ""
            return "{\"type\":\"user\"\(timestamp),\"message\":{\"content\":\"Visible \(index)\"}}"
        }.joined(separator: "\n").utf8)
        let start = Date()
        let messages = ClaudeConversationReader.messages(from: data)
        let end = Date()
        #expect(messages.count == 80)
        #expect(messages.allSatisfy { $0.timestamp >= start && $0.timestamp <= end })
        #expect(zip(messages, messages.dropFirst()).allSatisfy { $0.timestamp <= $1.timestamp })
    }

    @Test("Whole-input byte and UTF-8 limits still apply even to a discarded prefix")
    func inputLimits() {
        let valid = Data("{\"type\":\"user\",\"message\":{\"content\":\"Visible\"}}\n".utf8)
        let suffix = Data((0..<80).flatMap { _ in valid })
        var invalid = Data([0xFF, 0x0A])
        invalid.append(suffix)
        #expect(ClaudeConversationReader.messages(from: invalid).isEmpty)
        var oversized = Data(repeating: 0x20,
            count: ClaudeConversationReader.maximumFileBytes - suffix.count + 1)
        oversized.append(suffix)
        #expect(ClaudeConversationReader.messages(from: oversized).isEmpty)
        #expect(ClaudeConversationReader.messages(from: Data()).isEmpty)
    }
}
