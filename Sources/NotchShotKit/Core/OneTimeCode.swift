import AppKit

/// Finds the sign-in code in a notification, so the banner can offer to
/// copy it, as iOS and Safari do with texted codes.
///
/// Only a run of 4 to 8 digits (or two groups of three, "482 913") counts,
/// and only when the text also says it is a code; an order number or a
/// price in an ordinary message is left alone. Nothing is stored: the code
/// is read from the banner on screen and goes no further than the copy.
enum OneTimeCodeDetector {
    /// Words that mark a message as carrying a code, matched as whole words
    /// so "shopping" doesn't count as "pin". A few languages beyond English,
    /// the ones whose services text codes most.
    private static let keywords = try! NSRegularExpression(
        pattern: #"\b(codes?|passcodes?|one[- ]time|otp|2fa|pin|verification|verify|log[- ]?in|sign[- ]?in|código|codigo|verificación|verificação|bestätigungscode|einmalcode|vérification|codice|verifica|код)\b"#,
        options: [.caseInsensitive]
    )

    // One expression for both shapes. The lookarounds keep a code from being
    // one group of a longer number, such as "555-123-4567", while letting a
    // prefix through, as in Google's "G-482913".
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?<!\d)(?<!\d[ \-])(\d{3}[ \-]\d{3}|\d{4,8})(?!\d)(?![ \-]\d)"#
    )

    static func code(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard keywords.firstMatch(in: text, range: range) != nil else { return nil }
        for match in pattern.matches(in: text, range: range) {
            guard let swiftRange = Range(match.range(at: 1), in: text) else { continue }
            let digits = text[swiftRange].filter(\.isNumber)
            // A year next to "code" ("Code of Conduct 2026") isn't a code.
            if digits.count == 4, let year = Int(digits), (1900...2100).contains(year) { continue }
            return String(digits)
        }
        return nil
    }
}

/// Copies a code the way password managers copy a password: marked so
/// clipboard histories (NotchShot's own included) skip it, and wiped after
/// a minute and a half if it is still what the clipboard holds.
@MainActor
enum OneTimeCodeClipboard {
    static let clearDelay: TimeInterval = 90

    static func copy(_ code: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([
            .string,
            NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
            NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        ], owner: nil)
        pasteboard.setString(code, forType: .string)
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let copied = pasteboard.changeCount
        Task {
            try? await Task.sleep(for: .seconds(clearDelay))
            guard pasteboard.changeCount == copied else { return }
            pasteboard.clearContents()
        }
    }
}
