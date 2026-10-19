import CoreGraphics
import Foundation
import ImageIO
import SQLite3
import Testing
@testable import NotchShotKit

@Suite("Share links")
struct ShareLinkTests {
    /// AWS's published GET Object example from the Signature Version 4 docs.
    @Test("SigV4 matches AWS's published test vector")
    func awsVector() throws {
        let url = try #require(URL(string: "https://examplebucket.s3.amazonaws.com/test.txt"))
        let authorization = S3Signer.authorization(
            method: "GET",
            url: url,
            headers: [
                "x-amz-date": "20130524T000000Z",
                "x-amz-content-sha256": S3Signer.emptyPayloadHash,
                "range": "bytes=0-9",
            ],
            payloadHash: S3Signer.emptyPayloadHash,
            accessKeyID: "AKIAIOSFODNN7EXAMPLE",
            secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            region: "us-east-1"
        )
        #expect(authorization == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    @Test("Keys, upload addresses and public links")
    func addresses() {
        var configuration = ShareLinkConfiguration()
        configuration.endpoint = "https://acct.r2.cloudflarestorage.com"
        configuration.bucket = "shots"
        configuration.accessKeyID = "key"
        #expect(configuration.isComplete)

        let file = URL(fileURLWithPath: "/tmp/My Shot (1).PNG")
        let key = configuration.objectKey(for: file, randomID: "abc123")
        #expect(key == "notchshot/abc123.png")
        #expect(configuration.uploadURL(forKey: key)?.absoluteString == "https://acct.r2.cloudflarestorage.com/shots/notchshot/abc123.png")
        #expect(configuration.publicURL(forKey: key) == configuration.uploadURL(forKey: key))

        configuration.randomizesNames = false
        configuration.pathPrefix = ""
        #expect(configuration.objectKey(for: file, randomID: "x") == "x-My-Shot--1-.png")

        configuration.usesPathStyle = false
        #expect(configuration.uploadURL(forKey: "a b.png")?.absoluteString == "https://shots.acct.r2.cloudflarestorage.com/a%20b.png")

        configuration.publicBaseURL = "https://cdn.example.com/"
        #expect(configuration.publicURL(forKey: "f.png")?.absoluteString == "https://cdn.example.com/f.png")
    }

    @Test("Plain-HTTP endpoints are refused")
    func httpsOnly() {
        var configuration = ShareLinkConfiguration()
        configuration.endpoint = "http://minio.local:9000"
        configuration.bucket = "b"
        configuration.accessKeyID = "k"
        #expect(configuration.endpointURL == nil)
        #expect(!configuration.isComplete)
    }

    @Test("S3 error bodies yield their code")
    func errorCode() {
        let body = Data("<?xml version=\"1.0\"?><Error><Code>SignatureDoesNotMatch</Code></Error>".utf8)
        #expect(ShareLinkUploader.errorCode(in: body) == "SignatureDoesNotMatch")
        #expect(ShareLinkUploader.errorCode(in: Data("nope".utf8)) == nil)
    }
}

@Suite("Media conversion")
struct MediaConversionTests {
    @Test("Targets never include the file's own format")
    func targets() {
        #expect(MediaConversion.targets(for: URL(fileURLWithPath: "/a.mov")) == [.gif, .mp4, .m4a])
        #expect(MediaConversion.targets(for: URL(fileURLWithPath: "/a.mp4")) == [.gif, .mov, .m4a])
        #expect(MediaConversion.targets(for: URL(fileURLWithPath: "/a.gif")) == [.mp4, .mov])
        #expect(MediaConversion.targets(for: URL(fileURLWithPath: "/a.pdf")) == [.pngPages])
        #expect(MediaConversion.targets(for: URL(fileURLWithPath: "/a.png")).isEmpty)
        #expect(MediaConversion.targets(for: URL(fileURLWithPath: "/a.txt")).isEmpty)
    }

    @Test("A PDF becomes one PNG per page")
    func pdfPages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("conv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = directory.appendingPathComponent("doc.pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 100)
        let context = try #require(CGContext(pdf as CFURL, mediaBox: &box, nil))
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 10, y: 10, width: 50, height: 50))
            context.endPDFPage()
        }
        context.closePDF()

        let outputs = try await MediaConversion.convert(pdf, to: .pngPages, in: directory)
        #expect(outputs.map(\.lastPathComponent) == ["doc-page1.png", "doc-page2.png"])
        let image = try #require(CGImageSourceCreateWithURL(outputs[0] as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(image.width == 400 && image.height == 200)
    }
}

@Suite("Notch extras")
struct ExtrasFeatureTests {
    @Test("Shortcut lists are trimmed and de-duplicated")
    func shortcutList() {
        #expect(ShortcutsService.parseList("Morning\n  Log Water \n\nMorning\n") == ["Morning", "Log Water"])
    }

    @Test("Review requests decode from gh's JSON, newest first")
    func reviewDecode() throws {
        let json = """
        [{"number":4,"title":"Old","url":"https://github.com/o/r/pull/4","repository":{"nameWithOwner":"o/r"},"author":{"login":"a"},"updatedAt":"2026-07-01T10:00:00Z","isDraft":false},
         {"number":9,"title":"New","url":"https://github.com/o/r/pull/9","repository":{"nameWithOwner":"o/r"},"author":{"login":"b"},"updatedAt":"2026-07-02T10:00:00Z","isDraft":true}]
        """
        let requests = try ReviewQueueService.decode(Data(json.utf8))
        #expect(requests.map(\.number) == [9, 4])
        #expect(requests[0].isDraft == true)
    }

    @Test("Workday progress clamps before and after hours")
    func dayProgress() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        func at(_ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 7, day: 24, hour: hour, minute: minute))!
        }
        let mid = DayProgress.at(at(13, 30), startHour: 9, endHour: 18, calendar: calendar)
        #expect(mid.fraction == 0.5)
        #expect(mid.remaining == 4.5 * 3600)
        #expect(DayProgress.at(at(7), startHour: 9, endHour: 18, calendar: calendar).isBeforeStart)
        let late = DayProgress.at(at(20), startHour: 9, endHour: 18, calendar: calendar)
        #expect(late.isAfterEnd && late.fraction == 1 && late.remaining == 0)
        #expect(DayProgress.at(at(12), startHour: 0, endHour: 24, calendar: calendar).fraction == 0.5)
    }

    @Test("Eye breaks count use and reset after a real break")
    func eyeBreaks() {
        var tracker = EyeBreakTracker()
        func sample(idle: TimeInterval) -> Bool {
            tracker.record(interval: 30, idleSeconds: idle, reminderAfter: 1_200)
        }
        // 19 minutes of use: nothing yet.
        for _ in 0..<38 { #expect(!sample(idle: 2)) }
        // A short pause still counts as screen time.
        #expect(!sample(idle: 60))
        #expect(sample(idle: 1))
        #expect(tracker.activeSeconds == 0)

        for _ in 0..<30 { _ = sample(idle: 1) }
        // Away for six minutes: the count starts over.
        #expect(!sample(idle: 360))
        #expect(tracker.activeSeconds == 0)
    }

    @Test("Screen time keeps two weeks, longest first")
    func screenTime() throws {
        var ledger = ScreenTimeLedger()
        let today = Date()
        ledger.add(30, bundleIdentifier: "com.a", name: "A", at: today)
        ledger.add(90, bundleIdentifier: "com.b", name: "B", at: today)
        ledger.add(30, bundleIdentifier: "com.a", name: "A", at: today)
        #expect(ledger.usage(on: today).map(\.name) == ["B", "A"])
        #expect(ledger.usage(on: today).last?.seconds == 60)

        for day in 1...20 {
            ledger.add(1, bundleIdentifier: "com.a", name: "A", at: try #require(Calendar.current.date(byAdding: .day, value: -day, to: today)))
        }
        #expect(ledger.days.count == ScreenTimeLedger.retainedDays)
        #expect(ledger.days[ScreenTimeLedger.dayKey(today)] != nil)
    }

    @Test("A banner's Reply action is found in any of its spellings")
    func replyAction() {
        let actions = ["AXPress", "Name:Show Details\nTarget:0x0\nSelector:(null)", "Name:Reply\nTarget:0x0\nSelector:(null)"]
        #expect(SystemNotificationMirror.replyAction(in: actions) == actions[2])
        #expect(SystemNotificationMirror.replyAction(in: ["Name:Antworten\nTarget:0x0"]) != nil)
        #expect(SystemNotificationMirror.replyAction(in: ["AXPress", "Name:Close\nTarget:0x0"]) == nil)
    }

    @Test("Meeting shortcuts only for apps that document them")
    func meetingProfiles() {
        #expect(MeetingControls.profile(for: "us.zoom.xos")?.camera != nil)
        #expect(MeetingControls.profile(for: "com.microsoft.teams2")?.mute.flags == [.maskCommand, .maskShift])
        #expect(MeetingControls.profile(for: "com.tinyspeck.slackmacgap")?.camera == nil)
        // Browsers fall back to the system mute: ⌘D in Chrome bookmarks.
        #expect(MeetingControls.profile(for: "com.google.Chrome") == nil)
        #expect(MeetingControls.profile(for: "com.apple.Safari") == nil)
    }
}

@Suite("Clipboard import")
struct ClipboardImportTests {
    private func makeDatabase(_ statements: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString).sqlite")
        var database: OpaquePointer?
        try #require(sqlite3_open(url.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        for sql in statements {
            try #require(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK, "\(sql)")
        }
        return url
    }

    @Test("Maccy text rows import newest first, pins kept")
    func maccy() throws {
        let url = try makeDatabase([
            "CREATE TABLE ZHISTORYITEM (Z_PK INTEGER PRIMARY KEY, ZLASTCOPIEDAT TIMESTAMP, ZAPPLICATION VARCHAR, ZPIN VARCHAR)",
            "CREATE TABLE ZHISTORYITEMCONTENT (Z_PK INTEGER PRIMARY KEY, ZITEM INTEGER, ZTYPE VARCHAR, ZVALUE BLOB)",
            "INSERT INTO ZHISTORYITEM VALUES (1, 100, 'com.apple.Safari', NULL), (2, 200, 'com.apple.Notes', 'b'), (3, 300, NULL, NULL)",
            "INSERT INTO ZHISTORYITEMCONTENT VALUES (1, 1, 'public.utf8-plain-text', CAST('first' AS BLOB))",
            "INSERT INTO ZHISTORYITEMCONTENT VALUES (2, 2, 'public.utf8-plain-text', CAST('second' AS BLOB))",
            "INSERT INTO ZHISTORYITEMCONTENT VALUES (3, 3, 'public.png', x'89504E47')",
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let clippings = try ClipboardImporter.read(.maccy, from: url)
        #expect(clippings.map(\.text) == ["second", "first"])
        #expect(clippings[0].isPinned && !clippings[1].isPinned)
        #expect(clippings[1].applicationName == "Safari")
        #expect(clippings[0].copiedAt == Date(timeIntervalSinceReferenceDate: 200))
    }

    @Test("Alfred text rows import; images and files are skipped")
    func alfred() throws {
        let url = try makeDatabase([
            "CREATE TABLE clipboard (item TEXT, ts DECIMAL, app TEXT, apppath TEXT, dataType INTEGER, dataHash TEXT)",
            "INSERT INTO clipboard VALUES ('hello', 50, 'Mail', '', 0, 'a'), ('img.tiff', 60, 'Preview', '', 1, 'b'), ('later', 70, NULL, '', 0, 'c')",
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let clippings = try ClipboardImporter.read(.alfred, from: url)
        #expect(clippings.map(\.text) == ["later", "hello"])
        #expect(clippings[1].applicationName == "Mail")
    }

    @Test("Another app's database is refused with a clear error")
    func wrongDatabase() throws {
        let url = try makeDatabase(["CREATE TABLE other (x INTEGER)"])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: ClipboardImporter.ImportError.self) { try ClipboardImporter.read(.maccy, from: url) }
        #expect(throws: ClipboardImporter.ImportError.self) { try ClipboardImporter.read(.alfred, from: url) }
    }
}
