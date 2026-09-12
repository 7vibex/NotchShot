import AppKit
import CoreAudio
import Foundation
import Testing
@testable import NotchShotKit

private final class SummaryPDFTextView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let text = "This normal text PDF contains enough readable content to use direct PDF extraction without the scanned-page OCR fallback."
        (text as NSString).draw(
            in: NSRect(x: 20, y: 20, width: 560, height: 100),
            withAttributes: [.font: NSFont.systemFont(ofSize: 12)]
        )
    }
}

@Suite("Context modules")
struct ContextFeatureTests {
    @Test("AI activity uses only explicit bounded progress and drops stale records")
    func aiActivityPolicy() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let stale = AIActivitySnapshot(
            id: "old",
            source: .claude,
            state: .finished,
            title: "Old result",
            updatedAt: now.addingTimeInterval(-(AIActivityPolicy.terminalLifetime + 1))
        )
        let finished = AIActivitySnapshot(
            id: "done",
            source: .cursor,
            state: .finished,
            title: "Updated settings",
            updatedAt: now.addingTimeInterval(-5)
        )
        let working = AIActivitySnapshot(
            id: "../task id",
            source: .codex,
            state: .working,
            title: String(repeating: "A", count: 200),
            detail: String(repeating: "B", count: 300),
            progress: 1.4,
            steps: [AIActivityStep(id: "../step", label: "Build", state: .working)],
            updatedAt: now.addingTimeInterval(-10)
        )

        let visible = AIActivityPolicy.visibleActivities(
            from: [stale, finished, working],
            now: now
        )
        #expect(visible.map(\.source) == [.codex, .cursor])
        #expect(visible[0].id == "..taskid")
        #expect(visible[0].title.count == 160)
        #expect(visible[0].detail?.count == 240)
        #expect(visible[0].progress == 1)
        #expect(visible[0].steps.first?.id == "..step")

        let context = try #require(AIActivityPolicy.contextSnapshot(
            from: [stale, finished, working],
            now: now,
            mayInterruptMedia: true
        ))
        #expect(context.kind == .ai)
        #expect(context.title == "Codex · Working")
        #expect(context.metric == "100%")
        #expect(context.mayInterruptMedia)
        #expect(context.expiresAt == AIActivityPolicy.deadline(for: finished))
    }

    @Test("AI activity never invents a progress percentage")
    func aiActivityIndeterminateProgress() throws {
        let activity = AIActivitySnapshot(
            id: "session",
            source: .claude,
            state: .waiting,
            title: "Approve the next command"
        )
        let context = try #require(AIActivityPolicy.contextSnapshot(
            from: [activity],
            mayInterruptMedia: false
        ))
        #expect(context.metric == "Needs attention")
        #expect(context.aiActivities.first?.progress == nil)
        #expect(!context.mayInterruptMedia)
    }

    @Test("Power transitions distinguish charging, battery, low, charged, and non-battery sources")
    func powerPolicy() throws {
        let battery = PowerSourceReading(percentage: 65, isConnectedToPower: false, isCharging: false)
        let charging = PowerSourceReading(percentage: 66, isConnectedToPower: true, isCharging: true)
        #expect(PowerContextPolicy.snapshot(previous: battery, current: charging)?.title == "Charging")
        #expect(PowerContextPolicy.snapshot(previous: charging, current: battery)?.title == "On Battery")

        let low = PowerSourceReading(percentage: 15, isConnectedToPower: false, isCharging: false)
        #expect(PowerContextPolicy.snapshot(previous: battery, current: low)?.title == "Low Battery")
        let stillLow = PowerSourceReading(percentage: 14, isConnectedToPower: false, isCharging: false)
        #expect(PowerContextPolicy.snapshot(previous: low, current: stillLow) == nil)
        let full = PowerSourceReading(percentage: 100, isConnectedToPower: true, isCharging: false)
        #expect(PowerContextPolicy.snapshot(previous: charging, current: full)?.title == "Charged")

        let ups = PowerSourceReading(
            percentage: 80,
            isConnectedToPower: true,
            isCharging: true,
            isInternalBattery: false,
            isUPS: true
        )
        #expect(PowerContextPolicy.snapshot(previous: battery, current: ups) == nil)
    }

    @Test("Audio glance reports only reliable public external routes and never invents battery")
    func audioPolicy() throws {
        let builtIn = AudioRouteReading(
            deviceID: 1,
            name: "MacBook Speakers",
            transport: kAudioDeviceTransportTypeBuiltIn
        )
        let headphones = AudioRouteReading(
            deviceID: 2,
            name: "Headphones",
            transport: kAudioDeviceTransportTypeBluetooth
        )
        let connected = try #require(AudioRouteContextPolicy.snapshot(previous: builtIn, current: headphones))
        #expect(connected.title == "Audio Connected")
        #expect(connected.subtitle == "Headphones")
        #expect(connected.metric == "Connected")
        #expect(AudioRouteContextPolicy.snapshot(previous: headphones, current: builtIn)?.title == "Audio Disconnected")
        #expect(AudioRouteContextPolicy.snapshot(previous: builtIn, current: builtIn) == nil)
    }

    @Test("Audio output choices put the current route first and remove duplicate device IDs")
    func audioOutputOrdering() {
        let devices = [
            AudioRouteReading(deviceID: 3, name: "Studio Display", transport: 0),
            AudioRouteReading(deviceID: 2, name: "AirPods", transport: 0),
            AudioRouteReading(deviceID: 3, name: "Duplicate", transport: 0),
            AudioRouteReading(deviceID: 1, name: "MacBook Speakers", transport: 0),
        ]
        let normalized = AudioOutputDeviceService.normalized(devices, currentID: 3)
        #expect(normalized.map(\.deviceID) == [3, 2, 1])
        #expect(normalized.first?.name == "Studio Display")
    }

    @Test("Audio output selector symbols reflect Core Audio transport without inventing products")
    func audioOutputSymbols() {
        func reading(_ transport: UInt32) -> AudioRouteReading {
            AudioRouteReading(deviceID: transport, name: "Output", transport: transport)
        }

        #expect(reading(kAudioDeviceTransportTypeBuiltIn).selectorSymbolName == "laptopcomputer")
        #expect(reading(kAudioDeviceTransportTypeBluetooth).selectorSymbolName == "headphones")
        #expect(reading(kAudioDeviceTransportTypeBluetoothLE).selectorSymbolName == "headphones")
        #expect(reading(kAudioDeviceTransportTypeAirPlay).selectorSymbolName == "airplayaudio")
        #expect(reading(kAudioDeviceTransportTypeUSB).selectorSymbolName == "cable.connector")
        #expect(reading(kAudioDeviceTransportTypeHDMI).selectorSymbolName == "display")
        #expect(reading(0).selectorSymbolName == "speaker.wave.2.fill")
    }

    @Test("Calendar timing never gives an all-day event a false countdown")
    func calendarTiming() {
        let now = Date()
        let allDay = CalendarEventSnapshot(
            id: "1",
            calendarIdentifier: "work",
            title: "Holiday",
            startDate: now,
            endDate: now.addingTimeInterval(86_400),
            isAllDay: true,
            colorHex: "#FF0000"
        )
        #expect(allDay.timingDescription(now: now) == "All day")

        var upcoming = allDay
        upcoming.isAllDay = false
        upcoming.startDate = now.addingTimeInterval(6 * 60)
        upcoming.endDate = now.addingTimeInterval(66 * 60)
        #expect(upcoming.timingDescription(now: now) == "In 6m")
        #expect(upcoming.durationDescription() == "1h")
    }

    @Test("Calendar policy handles empty, overlapping, expired, and imminent events")
    func calendarPolicy() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let later = CalendarEventSnapshot(
            id: "later",
            calendarIdentifier: "work",
            title: "Later",
            startDate: now.addingTimeInterval(8 * 60),
            endDate: now.addingTimeInterval(68 * 60),
            isAllDay: false,
            colorHex: "#00FF00"
        )
        let ongoing = CalendarEventSnapshot(
            id: "ongoing",
            calendarIdentifier: "work",
            title: "Ongoing",
            startDate: now.addingTimeInterval(-20 * 60),
            endDate: now.addingTimeInterval(10 * 60),
            isAllDay: false,
            colorHex: "#FF0000"
        )
        let expired = CalendarEventSnapshot(
            id: "expired",
            calendarIdentifier: "work",
            title: "Expired all day",
            startDate: now.addingTimeInterval(-86_400),
            endDate: now.addingTimeInterval(-60),
            isAllDay: true,
            colorHex: "#0000FF"
        )

        #expect(CalendarContextPolicy.snapshot(events: [], now: now, mayInterruptMedia: true) == nil)
        let active = try #require(CalendarContextPolicy.snapshot(
            events: [later, expired, ongoing],
            now: now,
            mayInterruptMedia: true
        ))
        #expect(active.events.map(\.id) == ["ongoing", "later"])
        #expect(!active.mayInterruptMedia)

        let imminent = try #require(CalendarContextPolicy.snapshot(
            events: [later],
            now: now,
            mayInterruptMedia: true
        ))
        #expect(imminent.mayInterruptMedia)
        #expect(imminent.metric == "8m")
        #expect(CalendarContextPolicy.snapshot(
            events: [later],
            now: now,
            mayInterruptMedia: false
        )?.mayInterruptMedia == false)
    }

    @Test("Deselecting every calendar means none, not all")
    func deselectingEveryCalendarMeansNone() {
        let all = ["home", "work"]
        // The shipped default: nothing stored, everything followed.
        #expect(CalendarSelectionPolicy.isSelected("work", current: [], hasCustomSelection: false))
        #expect(CalendarSelectionPolicy.resolved(
            from: all,
            identifiedBy: { $0 },
            current: [],
            hasCustomSelection: false
        ) == all)

        // Switching one off materialises the implicit default.
        let afterFirst = CalendarSelectionPolicy.updating(
            current: [],
            hasCustomSelection: false,
            allIdentifiers: all,
            setting: "home",
            to: false
        )
        #expect(afterFirst == ["work"])

        // Switching the last one off must not read as "follow everything".
        let afterLast = CalendarSelectionPolicy.updating(
            current: afterFirst,
            hasCustomSelection: true,
            allIdentifiers: all,
            setting: "work",
            to: false
        )
        #expect(afterLast.isEmpty)
        #expect(!CalendarSelectionPolicy.isSelected("work", current: afterLast, hasCustomSelection: true))
        #expect(!CalendarSelectionPolicy.isSelected("home", current: afterLast, hasCustomSelection: true))
        // nil is "query nothing", never EventKit's "query every calendar".
        #expect(CalendarSelectionPolicy.resolved(
            from: all,
            identifiedBy: { $0 },
            current: afterLast,
            hasCustomSelection: true
        ) == nil)

        // And re-selecting one brings exactly that one back.
        let afterReselect = CalendarSelectionPolicy.updating(
            current: afterLast,
            hasCustomSelection: true,
            allIdentifiers: all,
            setting: "home",
            to: true
        )
        #expect(afterReselect == ["home"])
        #expect(CalendarSelectionPolicy.resolved(
            from: all,
            identifiedBy: { $0 },
            current: afterReselect,
            hasCustomSelection: true
        ) == ["home"])
    }

    @Test("An all-day event never hides the next meeting or its imminent alert")
    func allDayDoesNotMaskTimedEvent() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        // Starts at midnight, so it sorts ahead of everything else that day.
        let holiday = CalendarEventSnapshot(
            id: "holiday",
            calendarIdentifier: "work",
            title: "Company Holiday",
            startDate: now.addingTimeInterval(-6 * 3_600),
            endDate: now.addingTimeInterval(18 * 3_600),
            isAllDay: true,
            colorHex: "#0000FF"
        )
        let standup = CalendarEventSnapshot(
            id: "standup",
            calendarIdentifier: "work",
            title: "Standup",
            startDate: now.addingTimeInterval(5 * 60),
            endDate: now.addingTimeInterval(35 * 60),
            isAllDay: false,
            colorHex: "#00FF00"
        )
        let snapshot = try #require(CalendarContextPolicy.snapshot(
            events: [holiday, standup],
            now: now,
            mayInterruptMedia: true
        ))
        #expect(snapshot.title == "Standup")
        #expect(snapshot.metric == "5m")
        #expect(snapshot.mayInterruptMedia)
        // The all-day event is still on the agenda, just not the headline.
        #expect(snapshot.events.map(\.id) == ["holiday", "standup"])

        // With nothing timed left, the all-day event may headline again.
        let allDayOnly = try #require(CalendarContextPolicy.snapshot(
            events: [holiday],
            now: now,
            mayInterruptMedia: true
        ))
        #expect(allDayOnly.title == "Company Holiday")
        #expect(!allDayOnly.mayInterruptMedia)
    }

    @Test("The headline survives an agenda crowded with all-day events")
    func headlineSurvivesCrowdedAgenda() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let allDay = (0 ..< 6).map { index in
            CalendarEventSnapshot(
                id: "allday-\(index)",
                calendarIdentifier: "work",
                title: "Banner \(index)",
                startDate: now.addingTimeInterval(-6 * 3_600),
                endDate: now.addingTimeInterval(TimeInterval(18 + index) * 3_600),
                isAllDay: true,
                colorHex: "#0000FF"
            )
        }
        let meeting = CalendarEventSnapshot(
            id: "meeting",
            calendarIdentifier: "work",
            title: "Review",
            startDate: now.addingTimeInterval(90 * 60),
            endDate: now.addingTimeInterval(150 * 60),
            isAllDay: false,
            colorHex: "#00FF00"
        )
        let snapshot = try #require(CalendarContextPolicy.snapshot(
            events: allDay + [meeting],
            now: now,
            mayInterruptMedia: false
        ))
        #expect(snapshot.title == "Review")
        #expect(snapshot.events.count == 5)
        #expect(snapshot.events.contains { $0.id == "meeting" })
    }

    @Test("Calendar countdown remains correct across a daylight-saving boundary")
    func calendarDSTBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Rome"))
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 29,
            hour: 1,
            minute: 55
        )))
        let start = try #require(calendar.date(byAdding: .minute, value: 10, to: now))
        let event = CalendarEventSnapshot(
            id: "dst",
            calendarIdentifier: "work",
            title: "After clock change",
            startDate: start,
            endDate: try #require(calendar.date(byAdding: .hour, value: 1, to: start)),
            isAllDay: false,
            colorHex: "#FF0000"
        )
        #expect(event.timingDescription(now: now, calendar: calendar) == "In 10m")
        #expect(event.durationDescription() == "1h")
    }

    @Test("Document fallback is bounded and generated summaries parse visibly")
    func documentSummaryMath() {
        let chunks = DocumentSummaryService.chunks(String(repeating: "x", count: 25), maximum: 10)
        #expect(chunks.map(\.count) == [10, 10, 5])
        let parsed = DocumentSummaryService.parseGeneratedSummary(
            "OVERVIEW\nA concise overview.\nKEY POINTS\n- First point\n- Second point"
        )
        #expect(parsed.overview == "A concise overview.")
        #expect(parsed.keyPoints == ["First point", "Second point"])

        let fallback = DocumentSummaryService.extractiveSummary(
            "The project improves local document handling. Local document handling protects privacy. The project validates each selected source before reading it."
        )
        #expect(!fallback.overview.isEmpty)
        #expect(fallback.keyPoints.count <= 5)

        let visible = DocumentSummaryResult(
            sourceName: "Source.txt",
            overview: "Visible overview",
            keyPoints: ["First", "Second"],
            extractedText: "Raw source",
            usedLanguageModel: false,
            truncatedForLanguageModel: false,
            createdAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        #expect(visible.visibleText == "Visible overview\n\n• First\n• Second")
    }

    @Test("Supported text document formats take an explicit local parser route")
    func documentFormatRoutes() throws {
        let source = NSAttributedString(string: "Document body for safe local summary testing.")
        let types: [(String, NSAttributedString.DocumentType)] = [
            ("rtf", .rtf),
            ("rtfd", .rtfd),
            ("doc", .docFormat),
            ("docx", .officeOpenXML),
            ("html", .html),
            ("odt", .openDocument),
        ]
        for (extensionName, type) in types {
            let data = try source.data(
                from: NSRange(location: 0, length: source.length),
                documentAttributes: [.documentType: type]
            )
            let decoded = try DocumentSummaryService.extractAttributedText(
                data: data,
                url: URL(fileURLWithPath: "/tmp/fixture." + extensionName)
            )
            #expect(decoded.contains("Document body"), "Failed route for .\(extensionName)")
        }

        let plain = try DocumentSummaryService.extractAttributedText(
            data: Data("Plain local text".utf8),
            url: URL(fileURLWithPath: "/tmp/fixture.txt")
        )
        #expect(plain == "Plain local text")
    }

    @Test("A normal text PDF takes the direct PDFKit extraction route")
    @MainActor
    func documentTextPDFRoute() throws {
        let view = SummaryPDFTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        let data = view.dataWithPDF(inside: view.bounds)
        let extracted = try DocumentSummaryService.directPDFText(data: data)
        let text = try #require(extracted)
        #expect(text.contains("normal text PDF"))
        #expect(text.contains("scanned-page OCR fallback"))
    }

    @Test("Document validation rejects symlinks before reading source text")
    func documentSymlinkRejected() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.txt")
        let link = directory.appendingPathComponent("linked.txt")
        try Data("Private source text".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)

        var rejected = false
        do {
            _ = try await DocumentSummaryService.shared.summarize(url: link) { _ in }
        } catch {
            rejected = true
        }
        #expect(rejected)
    }

    @Test("Expanded context reserves enough space without exceeding panel bounds")
    func expandedContextLayout() {
        let metrics = NotchMetrics(
            screenFrame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
            hasPhysicalNotch: true,
            notchSize: CGSize(width: 250, height: 37),
            menuBarHeight: 37
        )
        let snapshot = ContextSnapshot(
            kind: .calendar,
            title: "Next event",
            presentation: .expanded
        )
        let layout = NotchLayout.layout(
            for: .context(snapshot),
            metrics: metrics,
            isPeeking: false,
            resultCount: 0
        )
        #expect(layout.size.height >= 390)
        #expect(layout.size.height <= NotchLayout.maximumSize.height)
        #expect(layout.size.width <= NotchLayout.maximumSize.width)
    }
}

@Suite("Document summary advertised formats")
struct DocumentSummarySupportTests {
    @Test("The advertised formats are all actually reachable")
    func supportedFormatsAreReachable() {
        for ext in ["pdf", "txt", "text", "md", "rtf", "doc", "docx", "html", "htm", "odt"] {
            #expect(
                DocumentSummaryService.supports(URL(fileURLWithPath: "/tmp/sample.\(ext)")),
                "\(ext) should be supported"
            )
        }
    }

    @Test("Standard RTFD is not advertised, because it cannot be opened")
    func rtfdIsNotAdvertised() {
        // RTFD is a directory wrapper. `SafeAssetFile.identity` requires a
        // regular file and the open panel refuses directories, so advertising
        // it only produced a failure at the end of the flow.
        #expect(!DocumentSummaryService.supports(URL(fileURLWithPath: "/tmp/sample.rtfd")))
    }

    @Test("Non-file URLs and unknown extensions are refused")
    func unsupportedInputsAreRefused() {
        #expect(!DocumentSummaryService.supports(URL(string: "https://example.com/a.pdf")!))
        #expect(!DocumentSummaryService.supports(URL(fileURLWithPath: "/tmp/sample.exe")))
    }
}

@Suite("Voice note recording filenames")
@MainActor
struct VoiceNoteFilenameTests {
    @Test("Two notes started in the same second get different files")
    func sameSecondNamesDoNotCollide() {
        // The regression this pins: a second-resolution name meant two notes
        // started inside one second resolved to the same path, and
        // `AVAudioFile(forWriting:)` truncates whatever is already there — so
        // the first recording was destroyed by the second.
        let instant = Date(timeIntervalSince1970: 1_755_000_000)
        let firstID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        let first = VoiceNoteCoordinator.recordingFilename(
            now: instant,
            identifier: firstID
        )
        let second = VoiceNoteCoordinator.recordingFilename(
            now: instant,
            identifier: secondID
        )
        #expect(first != second)
        #expect(first.contains(firstID.uuidString))
        #expect(second.contains(secondID.uuidString))
    }

    @Test("Names stay sortable, readable, and safe as path components")
    func nameShapeIsSound() {
        let instant = Date(timeIntervalSince1970: 1_755_000_000)
        let name = VoiceNoteCoordinator.recordingFilename(now: instant)
        #expect(name.hasPrefix("Voice Note "))
        #expect(name.hasSuffix(".wav"))
        // A path separator or a colon here would break the write entirely.
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
    }
}

@Suite("AI activity file ordering")
@MainActor
struct AIActivityOrderingTests {
    @Test("The newest sessions survive the 32-file budget")
    func newestFilesWinTheBudget() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NotchShotAIOrder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // 40 files, oldest first. The unsorted `prefix(32)` this replaces could
        // fill its whole budget with the stale ones and never show the session
        // the user is actually running.
        var expectedNewest: [String] = []
        for index in 0 ..< 40 {
            let url = directory.appendingPathComponent("session-\(index).json")
            try Data("{}".utf8).write(to: url)
            let modified = Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            if index >= 8 { expectedNewest.append(url.lastPathComponent) }
        }

        let monitor = AIActivityMonitor(directory: directory)
        let selected = monitor.activityURLs().map(\.lastPathComponent)

        #expect(selected.count == 32)
        #expect(Set(selected) == Set(expectedNewest))
        // Newest first, so the most recent session is never the one dropped.
        #expect(selected.first == "session-39.json")
    }
}

@Suite("Connectivity card")
struct NetworkContextTests {
    @Test("The state the Mac was already in is never announced")
    func firstReadingIsSilent() {
        #expect(NetworkContextPolicy.snapshot(
            previous: nil,
            current: NetworkReachability(isOnline: false)
        ) == nil)
        #expect(NetworkContextPolicy.snapshot(
            previous: nil,
            current: NetworkReachability(isOnline: true, link: .wifi)
        ) == nil)
    }

    @Test("Only a change in reachability produces a card")
    func steadyStateIsSilent() {
        // Roaming from Wi-Fi to Ethernet is still online, and the user does not
        // need to be told that the internet continues to work.
        #expect(NetworkContextPolicy.snapshot(
            previous: NetworkReachability(isOnline: true, link: .wifi),
            current: NetworkReachability(isOnline: true, link: .wired)
        ) == nil)
        #expect(NetworkContextPolicy.snapshot(
            previous: NetworkReachability(isOnline: false),
            current: NetworkReachability(isOnline: false)
        ) == nil)
    }

    @Test("Losing the connection states the fact and outranks a track change")
    func goingOfflineAlerts() throws {
        let now = Date()
        let snapshot = try #require(NetworkContextPolicy.snapshot(
            previous: NetworkReachability(isOnline: true, link: .wifi),
            current: NetworkReachability(isOnline: false),
            now: now
        ))
        #expect(snapshot.kind == .network)
        #expect(NetworkContextPolicy.isOfflineAlert(snapshot))
        #expect(snapshot.accentHex == NetworkContextPolicy.offlineAccentHex)
        #expect(snapshot.mayInterruptMedia)
        #expect(snapshot.expiresAt == now.addingTimeInterval(NetworkContextPolicy.offlineDuration))
    }

    @Test("Regaining it names the link and does not interrupt")
    func comingBackOnlineIsQuiet() throws {
        let snapshot = try #require(NetworkContextPolicy.snapshot(
            previous: NetworkReachability(isOnline: false),
            current: NetworkReachability(isOnline: true, link: .wired)
        ))
        #expect(NetworkContextPolicy.isNetworkCard(snapshot))
        #expect(!NetworkContextPolicy.isOfflineAlert(snapshot))
        #expect(snapshot.subtitle == "Connected over Ethernet.")
        #expect(!snapshot.mayInterruptMedia)
    }

    @Test("A card from another module is never mistaken for this one")
    func otherKindsAreNotNetworkCards() {
        let power = ContextSnapshot(kind: .power, title: "Low Battery")
        #expect(!NetworkContextPolicy.isNetworkCard(power))
        #expect(!NetworkContextPolicy.isOfflineAlert(power))
        // Same kind, different state: the restored card must not take the
        // alert's taller layout or its buttons.
        let restored = ContextSnapshot(kind: .network, title: NetworkContextPolicy.restoredTitle)
        #expect(!NetworkContextPolicy.isOfflineAlert(restored))
    }

    @Test("The alert reserves button height and the restored row does not")
    func layoutMatchesTheState() {
        let metrics = NotchMetrics(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            hasPhysicalNotch: true,
            notchSize: CGSize(width: 250, height: 37),
            menuBarHeight: 37
        )
        func height(_ title: String) -> CGFloat {
            NotchLayout.layout(
                for: .context(ContextSnapshot(kind: .network, title: title)),
                metrics: metrics,
                isPeeking: false,
                resultCount: 0
            ).size.height
        }
        let alert = height(NetworkContextPolicy.offlineTitle)
        let restored = height(NetworkContextPolicy.restoredTitle)
        #expect(alert > restored)
        #expect(alert <= NotchLayout.maximumSize.height)
    }
}
