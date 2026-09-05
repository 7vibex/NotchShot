import Foundation

/// Edits one boolean without reserializing the user's TOML. This deliberately
/// supports explicit feature tables only; representations that need a full
/// TOML rewrite are rejected before either configuration file is changed.
enum CodexHookConfigurationEditor {
    static func enablingHooks(in text: String) throws -> String? {
        let bytes = Array(text.utf8)
        let statements = try statements(in: bytes)
        var section: [String] = []
        var featureHeader: Statement?
        var hookValue: Token?

        for statement in statements {
            let tokens = statement.tokens
            if tokens.first?.text == "[" {
                let arrayTable = tokens.dropFirst().first?.text == "["
                let brackets = arrayTable ? 2 : 1
                guard tokens.count > brackets * 2,
                      tokens.suffix(brackets).allSatisfy({ $0.text == "]" }) else {
                    throw AIHookInstallerError.malformedConfiguration
                }
                section = try key(Array(tokens.dropFirst(brackets).dropLast(brackets)))
                if section == ["features"] {
                    guard !arrayTable, featureHeader == nil else {
                        throw AIHookInstallerError.unsupportedCodexConfiguration
                    }
                    featureHeader = statement
                } else if section.starts(with: ["features", "codex_hooks"]) {
                    throw AIHookInstallerError.unsupportedCodexConfiguration
                }
                continue
            }

            guard let equal = tokens.firstIndex(where: { $0.text == "=" }) else {
                throw AIHookInstallerError.malformedConfiguration
            }
            let name = try key(Array(tokens[..<equal]))
            let value = Array(tokens.dropFirst(equal + 1))
            guard !value.isEmpty else { throw AIHookInstallerError.malformedConfiguration }
            // Inline and dotted definitions at the root may have already
            // defined the feature table. Appending [features] could invalidate
            // them, so leave the entire installation untouched.
            if section.isEmpty, name.first == "features" {
                throw AIHookInstallerError.unsupportedCodexConfiguration
            }
            guard section == ["features"], name.first == "codex_hooks" else { continue }
            guard name == ["codex_hooks"], hookValue == nil,
                  value.count == 1, value[0].kind == .word,
                  value[0].text == "true" || value[0].text == "false" else {
                throw AIHookInstallerError.unsupportedCodexConfiguration
            }
            hookValue = value[0]
        }

        if let hookValue {
            guard hookValue.text != "true" else { return nil }
            var output = bytes
            output.replaceSubrange(hookValue.range, with: Array("true".utf8))
            return String(decoding: output, as: UTF8.self)
        }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        if let featureHeader {
            let offset = featureHeader.end
            let prefix = offset > 0 && bytes[offset - 1] == 10 ? "" : newline
            var output = bytes
            output.insert(contentsOf: Array((prefix + "codex_hooks = true" + newline).utf8), at: offset)
            return String(decoding: output, as: UTF8.self)
        }
        let prefix = bytes.isEmpty || bytes.last == 10 ? "" : newline
        return text + prefix + "[features]" + newline + "codex_hooks = true" + newline
    }

    private struct Token {
        enum Kind { case word, string, symbol }
        var kind: Kind
        var text: String
        var range: Range<Int>
    }

    private struct Statement {
        var tokens: [Token]
        /// Includes the terminating newline, when present, and trailing comments.
        var end: Int
    }

    /// Tokenize strings before examining comments or line boundaries. Thus a
    /// literal [features] inside a multiline prompt can never become a header.
    private static func statements(in bytes: [UInt8]) throws -> [Statement] {
        var result: [Statement] = []
        var tokens: [Token] = []
        var nesting: [UInt8] = []
        var index = 0

        func token(_ kind: Token.Kind, _ start: Int, _ end: Int) -> Token {
            Token(kind: kind, text: String(decoding: bytes[start..<end], as: UTF8.self), range: start..<end)
        }

        while index < bytes.count {
            let byte = bytes[index]
            if byte == 32 || byte == 9 || byte == 13 { index += 1; continue }
            if byte == 35 {
                while index < bytes.count, bytes[index] != 10 { index += 1 }
                continue
            }
            if byte == 10 {
                index += 1
                if nesting.isEmpty, !tokens.isEmpty {
                    result.append(Statement(tokens: tokens, end: index))
                    tokens.removeAll(keepingCapacity: true)
                }
                continue
            }
            if byte == 34 || byte == 39 {
                let start = index
                let multiline = index + 2 < bytes.count
                    && bytes[index + 1] == byte && bytes[index + 2] == byte
                index += multiline ? 3 : 1
                var closed = false
                while index < bytes.count {
                    if bytes[index] == 92, byte == 34 {
                        guard index + 1 < bytes.count else { break }
                        index += 2
                        continue
                    }
                    if bytes[index] == byte {
                        if !multiline {
                            index += 1
                            closed = true
                            break
                        }
                        var end = index
                        while end < bytes.count, bytes[end] == byte { end += 1 }
                        if end - index >= 3 {
                            guard end - index <= 5 else { throw AIHookInstallerError.malformedConfiguration }
                            index = end
                            closed = true
                            break
                        }
                        index = end
                        continue
                    }
                    if bytes[index] == 10, !multiline { break }
                    index += 1
                }
                guard closed else { throw AIHookInstallerError.malformedConfiguration }
                tokens.append(token(.string, start, index))
                continue
            }
            if [UInt8(91), 93, 123, 125, 61, 46, 44].contains(byte) {
                if byte == 91 || byte == 123 { nesting.append(byte) }
                if byte == 93 || byte == 125 {
                    let expected: UInt8 = byte == 93 ? 91 : 123
                    guard nesting.popLast() == expected else {
                        throw AIHookInstallerError.malformedConfiguration
                    }
                }
                tokens.append(token(.symbol, index, index + 1))
                index += 1
                continue
            }
            let start = index
            while index < bytes.count,
                  ![UInt8(32), 9, 10, 13, 35, 34, 39, 91, 93, 123, 125, 61, 46, 44].contains(bytes[index]) {
                index += 1
            }
            tokens.append(token(.word, start, index))
        }
        guard nesting.isEmpty else { throw AIHookInstallerError.malformedConfiguration }
        if !tokens.isEmpty { result.append(Statement(tokens: tokens, end: bytes.count)) }
        return result
    }

    private static func key(_ tokens: [Token]) throws -> [String] {
        guard !tokens.isEmpty, tokens.count % 2 == 1 else {
            throw AIHookInstallerError.malformedConfiguration
        }
        var parts: [String] = []
        for (index, token) in tokens.enumerated() {
            if index % 2 == 1 {
                guard token.text == "." else { throw AIHookInstallerError.malformedConfiguration }
                continue
            }
            switch token.kind {
            case .word:
                guard token.text.utf8.allSatisfy({
                    (65...90).contains($0) || (97...122).contains($0)
                        || (48...57).contains($0) || $0 == 95 || $0 == 45
                }) else { throw AIHookInstallerError.malformedConfiguration }
                parts.append(token.text)
            case .string:
                guard !token.text.hasPrefix("\"\"\""), !token.text.hasPrefix("'''") else {
                    throw AIHookInstallerError.malformedConfiguration
                }
                if token.text.first == "'" {
                    parts.append(String(token.text.dropFirst().dropLast()))
                } else {
                    // Unsupported TOML-only escape forms are rejected, never
                    // approximated into a different key or table name.
                    guard let decoded = try? JSONDecoder().decode(String.self, from: Data(token.text.utf8)) else {
                        throw AIHookInstallerError.unsupportedCodexConfiguration
                    }
                    parts.append(decoded)
                }
            case .symbol:
                throw AIHookInstallerError.malformedConfiguration
            }
        }
        return parts
    }
}
