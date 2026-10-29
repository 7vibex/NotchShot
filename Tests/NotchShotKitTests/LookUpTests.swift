import AppKit
import Foundation
import Testing
@testable import NotchShotKit

@Suite("Look Up")
struct LookUpTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private static let now = date(2026, 10, 29, 9)

    private static func item(
        _ detected: DetectedItem,
        regions: [RecognizedTextRegion] = []
    ) -> LookUpItem? {
        LookUpResult.item(for: detected, regions: regions, now: now, calendar: calendar)
    }

    private static func region(_ text: String, items: [DetectedItem] = []) -> RecognizedTextRegion {
        RecognizedTextRegion(text: text, rect: .zero, confidence: 1, detectedItems: items)
    }

    private static func row(_ kind: DetectedItem.Kind, title: String) -> LookUpItem {
        LookUpItem(kind: kind, title: title, detail: "", action: .copy(title))
    }

    // MARK: Rows

    @Test("A link reads the way it is printed and opens the full URL")
    func linkRow() throws {
        let row = try #require(Self.item(DetectedItem(kind: .link, value: "https://www.example.com/docs/")))
        #expect(row.title == "example.com/docs")
        #expect(row.detail == "Link")
        #expect(row.action == .open(URL(string: "https://www.example.com/docs/")!))
        #expect(row.action.title == "Open")
    }

    @Test("Email, phone and address rows hand off to Mail, a call and Maps")
    func handOffRows() throws {
        let email = try #require(Self.item(DetectedItem(kind: .email, value: "sam@example.com")))
        #expect(email.action == .newMail(URL(string: "mailto:sam@example.com")!))
        #expect(email.action.title == "New Mail")

        let phone = try #require(Self.item(DetectedItem(kind: .phone, value: "+1 (555) 010-2030")))
        #expect(phone.title == "+1 (555) 010-2030")
        #expect(phone.action == .call(URL(string: "tel:+15550102030")!))
        #expect(phone.action.title == "Call")

        let address = try #require(Self.item(DetectedItem(kind: .address, value: "1 Apple Park Way\nCupertino, CA")))
        #expect(address.title == "1 Apple Park Way, Cupertino, CA")
        guard case .openInMaps(let url) = address.action else {
            Issue.record("Expected Open in Maps, got \(address.action)")
            return
        }
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "maps")
        #expect(components.queryItems?.first { $0.name == "q" }?.value == "1 Apple Park Way, Cupertino, CA")
    }

    @Test("A phone match with no digits is not offered as a call")
    func phoneNeedsDigits() {
        #expect(Self.item(DetectedItem(kind: .phone, value: "CALL-NOW")) == nil)
    }

    @Test("Codes open a web link and copy anything else")
    func codeRows() throws {
        let link = try #require(Self.item(DetectedItem(kind: .qrCode, value: "https://example.com/menu")))
        #expect(link.title == "https://example.com/menu")
        #expect(link.action == .open(URL(string: "https://example.com/menu")!))

        let wifi = try #require(Self.item(DetectedItem(kind: .qrCode, value: "WIFI:S:Cafe;T:WPA;P:secret;;")))
        #expect(wifi.action == .copy("WIFI:S:Cafe;T:WPA;P:secret;;"))
        #expect(wifi.detail == "QR code")

        let barcode = try #require(Self.item(DetectedItem(kind: .barcode, value: "4006381333931")))
        #expect(barcode.action == .copy("4006381333931"))
        #expect(barcode.detail == "Barcode")
    }

    @Test("A date becomes an event titled by the rest of its line")
    func dateRow() throws {
        let start = Self.date(2026, 11, 4, 15)
        let detected = DetectedItem(
            kind: .date,
            value: "Wed 4 Nov at 3 PM",
            date: DetectedDate(start: start, end: start.addingTimeInterval(1_800))
        )
        let row = try #require(Self.item(
            detected,
            regions: [Self.region("Design review on Wed 4 Nov at 3 PM", items: [detected])]
        ))
        #expect(row.kind == .date)
        #expect(row.detail == "Design review")
        #expect(row.action == .addToCalendar(PlannerDraft(
            kind: .event,
            title: "Design review",
            date: start,
            duration: 1_800
        )))
        #expect(row.action.title == "Add to Calendar")
    }

    @Test("An all-day date lasts a day; a bare time lasts an hour")
    func dateDurations() throws {
        let day = Self.date(2026, 12, 24)
        let allDay = try #require(Self.item(DetectedItem(
            kind: .date,
            value: "24 December",
            date: DetectedDate(start: day, isAllDay: true)
        )))
        guard case .addToCalendar(let allDayDraft) = allDay.action else {
            Issue.record("Expected Add to Calendar")
            return
        }
        #expect(allDayDraft.duration == 86_400)
        #expect(allDayDraft.isAllDay)

        let timed = try #require(Self.item(DetectedItem(
            kind: .date,
            value: "at 3 PM",
            date: DetectedDate(start: day.addingTimeInterval(15 * 3_600))
        )))
        guard case .addToCalendar(let timedDraft) = timed.action else {
            Issue.record("Expected Add to Calendar")
            return
        }
        #expect(timedDraft.duration == 3_600)
        #expect(!timedDraft.isAllDay)
        #expect(timedDraft.title == "Event")
    }

    @Test("A date alone on its line takes the heading above it")
    func eventTitleFromHeading() {
        let detected = DetectedItem(kind: .date, value: "12 March", date: DetectedDate(start: Self.now))
        let regions = [Self.region("Team offsite"), Self.region("12 March", items: [detected])]
        #expect(LookUpResult.eventTitle(for: detected, in: regions) == "Team offsite")

        // A line above that is itself a link or a number is not a heading.
        let link = DetectedItem(kind: .link, value: "example.com")
        let linked = [Self.region("example.com", items: [link]), Self.region("12 March", items: [detected])]
        #expect(LookUpResult.eventTitle(for: detected, in: linked) == "Event")
    }

    @Test("Connecting words and punctuation around a date are dropped")
    func titleText() {
        #expect(LookUpResult.titleText(from: "Lunch with Sam at 1 PM", removing: "1 PM") == "Lunch with Sam")
        #expect(LookUpResult.titleText(from: "Invoice due by Friday.", removing: "Friday") == "Invoice")
        #expect(LookUpResult.titleText(from: "— on 3 May —", removing: "3 May") == nil)
        #expect(LookUpResult.titleText(from: "12", removing: nil) == nil)
    }

    @Test("Dates read back the day they resolved to, with the year only when it differs")
    func dateText() {
        let thisYear = LookUpResult.dateText(
            for: DetectedDate(start: Self.date(2026, 11, 4, 15), end: Self.date(2026, 11, 4, 16)),
            now: Self.now,
            calendar: Self.calendar
        )
        #expect(thisYear.contains("Nov"))
        #expect(thisYear.contains("Wed"))
        #expect(thisYear.contains("–"))
        #expect(!thisYear.contains("2026"))

        let nextYear = LookUpResult.dateText(
            for: DetectedDate(start: Self.date(2027, 1, 8), isAllDay: true),
            now: Self.now,
            calendar: Self.calendar
        )
        #expect(nextYear.contains("2027"))
        #expect(!nextYear.contains(":"))
    }

    @Test("Link display text drops the scheme, www and a trailing slash")
    func displayText() {
        #expect(LookUpResult.displayText(for: URL(string: "https://www.example.com/")!) == "example.com")
        #expect(LookUpResult.displayText(for: URL(string: "http://example.com/a/b")!) == "example.com/a/b")
        #expect(LookUpResult.displayText(for: URL(string: "https://wwwx.example.com")!) == "wwwx.example.com")
    }

    // MARK: Summary

    @Test("The summary counts at most two kinds, then folds the rest")
    func summary() {
        #expect(LookUpResult.summary(
            items: [Self.row(.link, title: "a"), Self.row(.link, title: "b"), Self.row(.date, title: "c")],
            text: ""
        ) == "2 links · 1 date")
        #expect(LookUpResult.summary(items: [Self.row(.phone, title: "1")], text: "") == "1 phone")
        #expect(LookUpResult.summary(
            items: [Self.row(.link, title: "a"), Self.row(.date, title: "b"), Self.row(.email, title: "c")],
            text: ""
        ) == "1 link · 2 more")
        #expect(LookUpResult.summary(
            items: [Self.row(.qrCode, title: "a"), Self.row(.barcode, title: "b")],
            text: ""
        ) == "2 codes")
    }

    @Test("With nothing detected the summary counts words")
    func wordSummary() {
        #expect(LookUpResult.summary(items: [], text: "Hello there world") == "3 words")
        #expect(LookUpResult.summary(items: [], text: "Hello") == "1 word")
        #expect(LookUpResult.summary(items: [], text: "") == "")
    }

    @Test("A result keeps Capture Text's text and drops rows it can't act on")
    func resultFromOCR() {
        let ocr = OCRResult(
            regions: [Self.region("Call CALL-NOW"), Self.region("example.com")],
            fullText: "Call CALL-NOW\nexample.com\n",
            detectedItems: [
                DetectedItem(kind: .phone, value: "CALL-NOW"),
                DetectedItem(kind: .link, value: "example.com"),
            ]
        )
        let result = LookUpResult(ocr: ocr, now: Self.now, calendar: Self.calendar)
        #expect(result.text == "Call CALL-NOW\nexample.com")
        #expect(result.items.map(\.kind) == [.link])
        #expect(result.summary == "1 link")
        #expect(!result.isEmpty)
        #expect(LookUpResult(ocr: .empty).isEmpty)
    }

    // MARK: Card

    @Test("Actions that open another app close the card; the rest say what they did")
    func actionOutcomes() {
        let url = URL(string: "https://example.com")!
        #expect(LookUpAction.open(url).leavesNotch)
        #expect(LookUpAction.call(url).leavesNotch)
        #expect(!LookUpAction.copy("x").leavesNotch)
        #expect(LookUpAction.copy("x").completedTitle == "Copied")
        #expect(LookUpAction.copy("x").canRepeat)
        let draft = PlannerDraft(kind: .event, title: "x", date: Self.now)
        #expect(LookUpAction.addToCalendar(draft).completedTitle == "Added")
        #expect(!LookUpAction.addToCalendar(draft).canRepeat)
    }

    @Test("The card shows the translation only while it is switched on")
    func displayedText() {
        let result = LookUpResult(
            ocr: OCRResult(regions: [Self.region("Bonjour")], fullText: "Bonjour", detectedItems: []),
            now: Self.now,
            calendar: Self.calendar
        )
        var card = LookUpCard(result: result, textLineCount: 1, canTranslate: true)
        #expect(card.displayedText == "Bonjour")
        card.translation = .translated(text: "Hello\nthere", lineCount: 2)
        #expect(card.displayedText == "Bonjour")
        card.showsTranslation = true
        #expect(card.displayedText == "Hello\nthere")
        #expect(card.displayedLineCount == 2)
    }

    @Test("Text already in the target language is not offered for translation")
    func translationNeed() {
        let english = Locale.Language(identifier: "en-US")
        #expect(!LookUpCard.needsTranslation(
            "The meeting has moved to the larger room on the second floor.",
            into: english
        ))
        #expect(LookUpCard.needsTranslation(
            "La réunion a été déplacée dans la grande salle du deuxième étage.",
            into: english
        ))
    }

    @Test("Arbiter: Look Up answers the user above an older shelf, below a file drag")
    func arbiterOrder() {
        let card = LookUpCard(result: LookUpResult(ocr: .empty), textLineCount: 0, canTranslate: false)
        var arbiter = ActivityArbiter()
        arbiter.hasResult = true
        arbiter.userExpanded = true
        arbiter.lookUp = card
        #expect(arbiter.resolve() == .lookUp(card))
        arbiter.isDraggingFiles = true
        #expect(arbiter.resolve() == .fileDrop)
        arbiter.isDraggingFiles = false
        arbiter.isProcessing = "Looking up"
        #expect(arbiter.resolve() == .processing("Looking up"))
    }

    // MARK: Layout

    private static func card(items: Int, text: String, lines: Int) -> LookUpCard {
        var result = LookUpResult(ocr: OCRResult(regions: [], fullText: text, detectedItems: []))
        result.items = (0..<items).map { row(.link, title: "\($0)") }
        return LookUpCard(result: result, textLineCount: lines, canTranslate: false)
    }

    @Test("The card is as tall as its rows, a short preview and the buttons")
    func bodyHeight() {
        let metrics = LookUpCardMetrics.self
        let card = Self.card(items: 2, text: "Two lines", lines: 2)
        #expect(metrics.visibleLines(for: card) == 2)
        #expect(metrics.bodyHeight(for: card)
            == 2 * metrics.rowHeight + 2 * metrics.lineHeight + 2 * metrics.textPadding
            + metrics.actionsHeight + metrics.bottomPadding)

        let long = Self.card(items: 0, text: "Long", lines: 40)
        #expect(metrics.visibleLines(for: long) == metrics.previewLines)

        let codesOnly = Self.card(items: 1, text: "", lines: 0)
        #expect(metrics.textRowHeight(for: codesOnly) == 0)
        #expect(metrics.bodyHeight(for: codesOnly) == metrics.rowHeight + metrics.actionsHeight + metrics.bottomPadding)
    }

    @Test("Many rows scroll with half a row showing")
    func rowOverflow() {
        let metrics = LookUpCardMetrics.self
        let card = Self.card(items: 7, text: "", lines: 0)
        #expect(metrics.rowsHeight(for: card) == 4.5 * metrics.rowHeight)
    }

    @Test("Show All grows the card but never past the island's largest size")
    func showAllIsBounded() {
        let metrics = LookUpCardMetrics.self
        for items in [0, 2, 9] {
            var card = Self.card(items: items, text: "Long", lines: 200)
            card.showsAllText = true
            #expect(metrics.visibleLines(for: card) > metrics.previewLines)
            #expect(metrics.bodyHeight(for: card) <= metrics.maximumBodyHeight)
            let island = NotchLayout.layout(
                for: .lookUp(card),
                metrics: NotchMetrics(
                    screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                    hasPhysicalNotch: true,
                    notchSize: CGSize(width: 185, height: 32),
                    menuBarHeight: 32
                ),
                isPeeking: false,
                resultCount: 0
            )
            #expect(island.size.height <= NotchLayout.maximumSize.height)
            #expect(island.size.width == metrics.width)
        }

        var short = Self.card(items: 0, text: "Short", lines: 2)
        short.showsAllText = true
        #expect(metrics.visibleLines(for: short) == 2)
    }

    @Test("Nothing found is a status line, not a card")
    func emptyLayout() {
        let empty = LookUpCard(result: LookUpResult(ocr: .empty), textLineCount: 0, canTranslate: false)
        let island = NotchLayout.layout(
            for: .lookUp(empty),
            metrics: NotchMetrics(
                screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                hasPhysicalNotch: false,
                notchSize: NotchMetrics.syntheticIslandSize,
                menuBarHeight: 32
            ),
            isPeeking: false,
            resultCount: 0
        )
        #expect(island.size.width == 340)
        #expect(island.size.width < LookUpCardMetrics.width)
    }

    @Test("Line counts follow wrapping and explicit breaks")
    func lineCount() {
        #expect(LookUpCardMetrics.lineCount(of: "") == 0)
        #expect(LookUpCardMetrics.lineCount(of: "Hello") == 1)
        #expect(LookUpCardMetrics.lineCount(of: "One\nTwo\nThree") == 3)
        let paragraph = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 12)
        #expect(LookUpCardMetrics.lineCount(of: paragraph) > 3)
    }

    // MARK: Detection

    @Test("The matched text of a detection is one trimmed line")
    func matchedText() {
        let transcript = "Lunch on\nFriday at noon "
        let range = transcript.range(of: "Friday at noon ")!
        #expect(OCRService.matchedText(in: transcript, range: range) == "Friday at noon")
        let spanning = transcript.range(of: "on\nFriday")!
        #expect(OCRService.matchedText(in: transcript, range: spanning) == "on Friday")
    }

    @Test("Recognition finds the date and link in a rendered area")
    func recognisesDatesAndLinks() async throws {
        let image = try #require(Self.renderedText([
            "Design review on November 4, 2026 at 3:00 PM",
            "Notes at https://example.com/review",
        ]))
        let ocr = try await OCRService.shared.recognizeText(in: image)
        // The shelf's one click goes to the first item, so the link stays
        // ahead of the date even though the date was read first.
        #expect(ocr.detectedItems.first?.kind == .link)
        #expect(ocr.detectedItems.last?.kind == .date)
        let result = LookUpResult(ocr: ocr, now: Self.now, calendar: Self.calendar)
        #expect(result.items.contains { $0.kind == .link && $0.title == "example.com/review" })
        let date = try #require(result.items.first { $0.kind == .date })
        #expect(date.detail.localizedCaseInsensitiveContains("Design review"))
        guard case .addToCalendar(let draft) = date.action else {
            Issue.record("Expected Add to Calendar, got \(date.action)")
            return
        }
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour], from: draft.date)
        #expect(parts.year == 2026)
        #expect(parts.month == 11)
        #expect(parts.day == 4)
        #expect(parts.hour == 15)
    }

    /// Black text on white at 2x, the way a Retina capture of a page looks.
    private static func renderedText(_ lines: [String]) -> CGImage? {
        let width = 1_400
        let lineHeight = 64
        let height = lineHeight * lines.count + 80
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 36),
            .foregroundColor: NSColor.black,
        ]
        for (index, line) in lines.enumerated() {
            let y = height - 40 - lineHeight * (index + 1)
            (line as NSString).draw(at: CGPoint(x: 40, y: y), withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
