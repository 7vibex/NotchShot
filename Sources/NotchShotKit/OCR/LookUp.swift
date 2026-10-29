import Foundation
import NaturalLanguage

/// What a Look Up row does when its button is pressed.
public enum LookUpAction: Sendable, Equatable {
    case open(URL)
    case call(URL)
    case newMail(URL)
    case openInMaps(URL)
    case addToCalendar(PlannerDraft)
    case copy(String)

    public var title: String {
        switch self {
        case .open: "Open"
        case .call: "Call"
        case .newMail: "New Mail"
        case .openInMaps: "Open in Maps"
        case .addToCalendar: "Add to Calendar"
        case .copy: "Copy"
        }
    }

    /// Actions that hand the user to another app. The card has done its job
    /// once one of these runs, so it closes behind it.
    public var leavesNotch: Bool {
        switch self {
        case .open, .call, .newMail, .openInMaps: true
        case .addToCalendar, .copy: false
        }
    }

    /// What the button says once the action has run, for the actions that
    /// leave the card open.
    public var completedTitle: String? {
        switch self {
        case .addToCalendar: "Added"
        case .copy: "Copied"
        case .open, .call, .newMail, .openInMaps: nil
        }
    }

    /// Copying again is harmless; adding the same event twice is not.
    public var canRepeat: Bool {
        if case .addToCalendar = self { return false }
        return true
    }
}

/// One thing Look Up found in the selected area.
public struct LookUpItem: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var kind: DetectedItem.Kind
    /// What was found, in the form the action uses it.
    public var title: String
    /// The kind in words; for a date, the event it would add.
    public var detail: String
    public var action: LookUpAction

    public init(
        id: UUID = UUID(),
        kind: DetectedItem.Kind,
        title: String,
        detail: String,
        action: LookUpAction
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.action = action
    }
}

/// What Look Up made of an area: the things in it that can be acted on, its
/// text, and a short count of what was found.
///
/// Built from the same `OCRResult` Capture Text produces, so Look Up reads an
/// area exactly the way the rest of the app does.
public struct LookUpResult: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var items: [LookUpItem]
    /// The recognised text, as Capture Text would copy it.
    public var text: String
    /// "3 links · 1 date", or the word count when nothing was detected.
    public var summary: String

    public var isEmpty: Bool { items.isEmpty && text.isEmpty }

    public init(
        id: UUID = UUID(),
        ocr: OCRResult,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.id = id
        text = ocr.clipboardText(format: .text).trimmingCharacters(in: .whitespacesAndNewlines)
        items = ocr.detectedItems.compactMap {
            Self.item(for: $0, regions: ocr.regions, now: now, calendar: calendar)
        }
        summary = Self.summary(items: items, text: text)
    }

    // MARK: Rows

    static func item(
        for detected: DetectedItem,
        regions: [RecognizedTextRegion],
        now: Date,
        calendar: Calendar
    ) -> LookUpItem? {
        switch detected.kind {
        case .link:
            guard let url = detected.actionURL else { return nil }
            return LookUpItem(kind: .link, title: displayText(for: url), detail: "Link", action: .open(url))
        case .email:
            guard let url = detected.actionURL else { return nil }
            return LookUpItem(kind: .email, title: detected.value, detail: "Email", action: .newMail(url))
        case .phone:
            guard detected.value.contains(where: \.isNumber), let url = detected.actionURL else { return nil }
            return LookUpItem(kind: .phone, title: detected.value, detail: "Phone", action: .call(url))
        case .address:
            let address = singleLine(detected.value)
            guard !address.isEmpty, let url = mapsURL(for: address) else { return nil }
            return LookUpItem(kind: .address, title: address, detail: "Address", action: .openInMaps(url))
        case .date:
            guard let date = detected.date else { return nil }
            let title = eventTitle(for: detected, in: regions)
            let duration: TimeInterval = if let end = date.end, end > date.start {
                end.timeIntervalSince(date.start)
            } else {
                date.isAllDay ? 86_400 : 3_600
            }
            return LookUpItem(
                kind: .date,
                title: dateText(for: date, now: now, calendar: calendar),
                detail: title,
                action: .addToCalendar(PlannerDraft(
                    kind: .event,
                    title: title,
                    date: date.start,
                    duration: duration,
                    isAllDay: date.isAllDay
                ))
            )
        case .qrCode:
            // A code's payload can't be seen in the image, so a link inside
            // one is shown in full, scheme and all, before anything opens it.
            if let url = detected.actionURL {
                return LookUpItem(kind: .qrCode, title: url.absoluteString, detail: "QR code", action: .open(url))
            }
            return LookUpItem(kind: .qrCode, title: detected.value, detail: "QR code", action: .copy(detected.value))
        case .barcode:
            return LookUpItem(kind: .barcode, title: detected.value, detail: "Barcode", action: .copy(detected.value))
        }
    }

    /// A link without its scheme, "www." or trailing slash: the way it is
    /// usually printed.
    static func displayText(for url: URL) -> String {
        var text = url.absoluteString
        for scheme in ["https://", "http://"] where text.lowercased().hasPrefix(scheme) {
            text.removeFirst(scheme.count)
        }
        if text.lowercased().hasPrefix("www.") { text.removeFirst(4) }
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// Opens Maps itself rather than a web page.
    static func mapsURL(for address: String) -> URL? {
        var components = URLComponents()
        components.scheme = "maps"
        components.host = ""
        components.queryItems = [URLQueryItem(name: "q", value: address)]
        return components.url
    }

    static func singleLine(_ value: String) -> String {
        value
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// The date as the detector resolved it, so a relative phrase on screen
    /// ("tomorrow at 3") reads back as the day it means. The year appears only
    /// when it is not this one.
    static func dateText(for date: DetectedDate, now: Date, calendar: Calendar) -> String {
        var day = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.abbreviated)
            .day()
            .month(.abbreviated)
            .locale(calendar.locale ?? .autoupdatingCurrent)
        if calendar.component(.year, from: date.start) != calendar.component(.year, from: now) {
            day = day.year()
        }
        guard !date.isAllDay else { return date.start.formatted(day) }
        let time = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
            .hour()
            .minute()
            .locale(calendar.locale ?? .autoupdatingCurrent)
        var text = date.start.formatted(day.hour().minute())
        if let end = date.end, end > date.start, calendar.isDate(end, inSameDayAs: date.start) {
            text += " – " + end.formatted(time)
        }
        return text
    }

    /// A title for the event a date would add: the rest of the line the date
    /// sits on ("Design review" from "Design review on Tue at 3 PM"), or else
    /// the line above it, which is usually a heading.
    static func eventTitle(for detected: DetectedItem, in regions: [RecognizedTextRegion]) -> String {
        let fallback = "Event"
        let index = regions.firstIndex { region in
            region.detectedItems.contains { $0.kind == .date && $0.value == detected.value }
        } ?? regions.firstIndex { $0.text.localizedCaseInsensitiveContains(detected.value) }
        guard let index else { return fallback }
        if let rest = titleText(from: regions[index].text, removing: detected.value) {
            return rest
        }
        if index > 0, regions[index - 1].detectedItems.isEmpty,
           let above = titleText(from: regions[index - 1].text, removing: nil) {
            return above
        }
        return fallback
    }

    /// Words that only lead into a date ("on", "at") and mean nothing once the
    /// date is gone.
    private static let dateConnectors: Set<String> = [
        "on", "at", "from", "by", "until", "due", "starts", "starting",
    ]

    static func titleText(from line: String, removing value: String?) -> String? {
        var text = line
        if let value, let range = text.range(of: value, options: .caseInsensitive) {
            text.removeSubrange(range)
        }
        let trim = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",.;:-–—|·•@()"))
        var words = text.trimmingCharacters(in: trim).split(whereSeparator: \.isWhitespace)
        while let last = words.last, dateConnectors.contains(last.lowercased()) {
            words.removeLast()
        }
        let title = words.joined(separator: " ").trimmingCharacters(in: trim)
        guard title.count >= 2, title.contains(where: \.isLetter) else { return nil }
        return String(title.prefix(120))
    }

    // MARK: Summary

    private struct SummaryGroup {
        var kinds: Set<DetectedItem.Kind>
        var singular: String
        var plural: String
    }

    /// Short nouns: the summary shares the band beside the camera with
    /// nothing else, and a phone number there would not fit.
    private static let summaryGroups = [
        SummaryGroup(kinds: [.link], singular: "link", plural: "links"),
        SummaryGroup(kinds: [.date], singular: "date", plural: "dates"),
        SummaryGroup(kinds: [.phone], singular: "phone", plural: "phones"),
        SummaryGroup(kinds: [.email], singular: "email", plural: "emails"),
        SummaryGroup(kinds: [.address], singular: "address", plural: "addresses"),
        SummaryGroup(kinds: [.qrCode, .barcode], singular: "code", plural: "codes"),
    ]

    /// At most two counts, so the line fits beside the camera; a third kind
    /// folds into "N more".
    static func summary(items: [LookUpItem], text: String) -> String {
        let counts = summaryGroups.compactMap { group -> (count: Int, label: String)? in
            let count = items.filter { group.kinds.contains($0.kind) }.count
            guard count > 0 else { return nil }
            return (count, "\(count) \(count == 1 ? group.singular : group.plural)")
        }
        switch counts.count {
        case 0:
            let words = text.split(whereSeparator: \.isWhitespace).count
            guard words > 0 else { return "" }
            return words == 1 ? "1 word" : "\(words) words"
        case 1, 2:
            return counts.map(\.label).joined(separator: " · ")
        default:
            return counts[0].label + " · \(items.count - counts[0].count) more"
        }
    }
}

/// Where a Look Up card's translation stands.
public enum LookUpTranslation: Sendable, Equatable {
    case none
    case translating
    case translated(text: String, lineCount: Int)
    case failed
}

/// A Look Up result in the notch, with what the user has done with it since.
///
/// Everything that changes the card's height lives here: the island's size is
/// derived from the activity rather than measured from its content.
public struct LookUpCard: Sendable, Equatable {
    public var result: LookUpResult
    /// Lines the original text wraps to at the card's text width.
    public var textLineCount: Int
    /// False when the text is already in the language it would be
    /// translated into.
    public var canTranslate: Bool
    public var showsAllText = false
    public var translation: LookUpTranslation = .none
    public var showsTranslation = false
    /// Rows whose action has run: a date added to Calendar, a code copied.
    public var completedItemIDs: Set<UUID> = []
    /// Whether the text currently shown has been copied.
    public var copiedText = false

    public init(result: LookUpResult, textLineCount: Int, canTranslate: Bool) {
        self.result = result
        self.textLineCount = textLineCount
        self.canTranslate = canTranslate
    }

    /// The language Look Up translates into: the first one the user prefers.
    public static var translationTarget: Locale.Language {
        Locale.Language(identifier: Locale.preferredLanguages.first ?? "en")
    }

    /// Whether `text` needs translating to read it in `target`. Text whose
    /// language can't be told (a few words, a code) is worth trying.
    public static func needsTranslation(_ text: String, into target: Locale.Language) -> Bool {
        guard let targetCode = target.languageCode?.identifier else { return true }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2_000)))
        guard let dominant = recognizer.dominantLanguage, dominant != .undetermined else { return true }
        let sourceCode = Locale.Language(identifier: dominant.rawValue).languageCode?.identifier
        return sourceCode != targetCode
    }

    /// The text the card is showing: the translation when it is switched on.
    public var displayedText: String {
        if showsTranslation, case .translated(let text, _) = translation { return text }
        return result.text
    }

    public var displayedLineCount: Int {
        if showsTranslation, case .translated(_, let lineCount) = translation { return lineCount }
        return textLineCount
    }
}
