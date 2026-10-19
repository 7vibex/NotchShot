import Foundation

/// One thing the clipboard can turn a clipping into: pretty JSON, a decoded
/// token, a readable date. Detection is conservative so the menu only offers
/// what would actually help with this clipping.
public struct ClipboardTransform: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case formatJSON
        case minifyJSON
        case decodeJWT
        case decodeBase64
        case decodeURL
        case timestampDate
        case cleanLink
        case colorRGB
        case colorHSL
    }

    public var kind: Kind
    public var title: String
    /// A short look at the result for the menu, never the whole output.
    public var preview: String
    public var output: String

    public var id: String { kind.rawValue }

    public var symbolName: String {
        switch kind {
        case .formatJSON: "curlybraces"
        case .minifyJSON: "arrow.right.and.line.vertical.and.arrow.left"
        case .decodeJWT: "key"
        case .decodeBase64: "lock.open"
        case .decodeURL: "percent"
        case .timestampDate: "calendar"
        case .cleanLink: "link"
        case .colorRGB, .colorHSL: "paintpalette"
        }
    }
}

public enum ClipboardSmartActions {
    /// Bigger clippings are logs or files, not something to reformat by hand.
    static let maximumInputBytes = 256 * 1_024

    public static func transforms(
        for text: String,
        kind: ClipboardKind,
        timeZone: TimeZone = .current,
        locale: Locale = .current
    ) -> [ClipboardTransform] {
        guard kind == .text || kind == .link || kind == .color else { return [] }
        guard text.utf8.count <= maximumInputBytes else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var result: [ClipboardTransform] = []
        if kind == .color {
            result += colorTransforms(trimmed)
            return result
        }
        if kind == .link {
            if let cleaned = cleanedLink(trimmed) {
                result.append(.init(kind: .cleanLink, title: "Copy Without Tracking", preview: cleaned, output: cleaned))
            }
        }
        if let json = jsonTransforms(trimmed) {
            result += json
        } else if let jwt = decodedJWT(trimmed) {
            result.append(.init(kind: .decodeJWT, title: "Decode JWT", preview: preview(jwt), output: jwt))
        } else if let decoded = decodedBase64(trimmed) {
            result.append(.init(kind: .decodeBase64, title: "Decode Base64", preview: preview(decoded), output: decoded))
        }
        if let decoded = decodedPercentEncoding(trimmed) {
            result.append(.init(kind: .decodeURL, title: "Decode URL Encoding", preview: preview(decoded), output: decoded))
        }
        if let date = timestampDate(trimmed, timeZone: timeZone, locale: locale) {
            result.append(.init(kind: .timestampDate, title: "Copy as Date", preview: date.readable, output: date.iso))
        }
        return result
    }

    // MARK: JSON

    /// Only objects and arrays: a bare `42` or `"x"` is JSON too, but nobody
    /// copies those wanting them formatted.
    static func jsonTransforms(_ text: String) -> [ClipboardTransform]? {
        guard let first = text.first, first == "{" || first == "[" else { return nil }
        guard let data = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [])) != nil
        else { return nil }
        var transforms: [ClipboardTransform] = []
        let pretty = reindentJSON(text, indent: "  ")
        if pretty != text {
            transforms.append(.init(kind: .formatJSON, title: "Format JSON", preview: preview(pretty), output: pretty))
        }
        let minified = reindentJSON(text, indent: nil)
        if minified != text {
            transforms.append(.init(kind: .minifyJSON, title: "Minify JSON", preview: preview(minified), output: minified))
        }
        return transforms
    }

    /// Re-spaces already valid JSON without parsing it into objects, so key
    /// order and number spellings survive exactly. `indent == nil` minifies.
    static func reindentJSON(_ text: String, indent: String?) -> String {
        var output = ""
        output.reserveCapacity(text.utf8.count)
        var depth = 0
        var inString = false
        var escaped = false
        var pendingOpen = false

        func newline() {
            guard let indent else { return }
            output.append("\n")
            output.append(String(repeating: indent, count: depth))
        }

        for character in text {
            if inString {
                output.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            if character.isWhitespace { continue }
            if pendingOpen {
                pendingOpen = false
                if character == "}" || character == "]" {
                    // Empty containers stay on one line: {} and [].
                    depth -= 1
                    output.append(character)
                    continue
                }
                newline()
            }
            switch character {
            case "\"":
                inString = true
                output.append(character)
            case "{", "[":
                output.append(character)
                depth += 1
                pendingOpen = true
            case "}", "]":
                depth -= 1
                newline()
                output.append(character)
            case ",":
                output.append(character)
                newline()
            case ":":
                output.append(indent == nil ? ":" : ": ")
            default:
                output.append(character)
            }
        }
        return output
    }

    // MARK: Tokens and encodings

    /// Header and claims of a JWT, as formatted JSON. The signature is not
    /// checked; this is for reading, and the menu title says decode, not
    /// verify.
    static func decodedJWT(_ text: String) -> String? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, text.hasPrefix("ey"),
              !text.contains(where: { $0.isWhitespace }),
              let header = base64URLDecoded(String(parts[0])).flatMap(jsonText),
              let claims = base64URLDecoded(String(parts[1])).flatMap(jsonText)
        else { return nil }
        return reindentJSON(header, indent: "  ") + "\n" + reindentJSON(claims, indent: "  ")
    }

    static func decodedBase64(_ text: String) -> String? {
        guard text.count >= 12, text.count % 4 == 0,
              text.range(of: #"^[A-Za-z0-9+/]+={0,2}$"#, options: .regularExpression) != nil,
              // All letters, or all digits, is a word or a number, not Base64.
              text.contains(where: \.isNumber) || text.contains("+") || text.contains("/") || text.hasSuffix("="),
              text.contains(where: \.isLetter),
              let data = Data(base64Encoded: text)
        else { return nil }
        return printableText(data)
    }

    static func base64URLDecoded(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }

    static func jsonText(_ data: Data) -> String? {
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decoded bytes are only worth offering when they read as text.
    static func printableText(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        let controls = text.unicodeScalars.filter {
            CharacterSet.controlCharacters.contains($0) && !"\n\r\t".unicodeScalars.contains($0)
        }
        return controls.isEmpty ? text : nil
    }

    static func decodedPercentEncoding(_ text: String) -> String? {
        guard text.range(of: #"%[0-9A-Fa-f]{2}"#, options: .regularExpression) != nil,
              let decoded = text.removingPercentEncoding,
              decoded != text
        else { return nil }
        return decoded
    }

    // MARK: Dates

    /// Unix seconds or milliseconds between 2001 and 2100. Outside that
    /// range a long number is far more likely an ID than a date.
    static func timestampDate(
        _ text: String,
        timeZone: TimeZone,
        locale: Locale
    ) -> (iso: String, readable: String)? {
        guard text.count == 10 || text.count == 13, text.allSatisfy(\.isASCII), let value = Double(text),
              text.allSatisfy(\.isNumber)
        else { return nil }
        let seconds = text.count == 13 ? value / 1_000 : value
        guard seconds >= 978_307_200, seconds < 4_102_444_800 else { return nil }
        let date = Date(timeIntervalSince1970: seconds)
        let iso = ISO8601DateFormatter()
        iso.timeZone = timeZone
        let readable = DateFormatter()
        readable.locale = locale
        readable.timeZone = timeZone
        readable.dateStyle = .medium
        readable.timeStyle = .medium
        return (iso.string(from: date), readable.string(from: date))
    }

    // MARK: Links

    static let trackingParameters: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "mc_cid", "mc_eid",
        "igshid", "yclid", "_hsenc", "_hsmi", "mkt_tok", "si", "ref_src", "ref_url", "spm"
    ]

    static func cleanedLink(_ text: String) -> String? {
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let items = components.queryItems, !items.isEmpty
        else { return nil }
        let kept = items.filter { item in
            let name = item.name.lowercased()
            return !name.hasPrefix("utm_") && !trackingParameters.contains(name)
        }
        guard kept.count != items.count else { return nil }
        components.queryItems = kept.isEmpty ? nil : kept
        return components.string
    }

    // MARK: Colours

    static func colorTransforms(_ text: String) -> [ClipboardTransform] {
        guard let rgb = rgbComponents(text) else { return [] }
        let (r, g, b) = rgb
        let rgbText = "rgb(\(r), \(g), \(b))"
        let (h, s, l) = hsl(r: r, g: g, b: b)
        let hslText = "hsl(\(h), \(s)%, \(l)%)"
        return [
            .init(kind: .colorRGB, title: "Copy as RGB", preview: rgbText, output: rgbText),
            .init(kind: .colorHSL, title: "Copy as HSL", preview: hslText, output: hslText),
        ]
    }

    static func rgbComponents(_ text: String) -> (Int, Int, Int)? {
        var hex = text.hasPrefix("#") ? String(text.dropFirst()) : text
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        if hex.count == 8 { hex = String(hex.prefix(6)) }
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
    }

    static func hsl(r: Int, g: Int, b: Int) -> (Int, Int, Int) {
        let red = Double(r) / 255, green = Double(g) / 255, blue = Double(b) / 255
        let maximum = max(red, green, blue), minimum = min(red, green, blue)
        let lightness = (maximum + minimum) / 2
        let delta = maximum - minimum
        guard delta > 0 else { return (0, 0, Int((lightness * 100).rounded())) }
        let saturation = delta / (1 - abs(2 * lightness - 1))
        var hue: Double
        switch maximum {
        case red: hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        case green: hue = (blue - red) / delta + 2
        default: hue = (red - green) / delta + 4
        }
        hue *= 60
        if hue < 0 { hue += 360 }
        return (Int(hue.rounded()) % 360, Int((saturation * 100).rounded()), Int((lightness * 100).rounded()))
    }

    // MARK: Preview

    static func preview(_ text: String, limit: Int = 60) -> String {
        let flattened = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
        return flattened.count > limit ? String(flattened.prefix(limit - 1)) + "…" : flattened
    }
}
