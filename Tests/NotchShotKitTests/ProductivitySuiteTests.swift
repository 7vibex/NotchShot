import Foundation
import Testing
@testable import NotchShotKit

@Suite("Productivity Center")
struct ProductivitySuiteTests {
    private struct SearchSection: Equatable {
        var id: String
        var title: String
        var keywords: [String]
    }

    @Test("Settings keep the full recording title while the sidebar label fits")
    func recordingSettingsLabels() {
        #expect(SettingsSection.recording.title == "Recording")
        #expect(SettingsSection.recording.sidebarTitle == "Record")
    }

    @Test("Settings search matches every term across titles and synonyms")
    func settingsSearch() {
        let sections = [
            SearchSection(id: "capture", title: "Capture & Export", keywords: ["screenshot", "image"]),
            SearchSection(id: "integrations", title: "Integrations", keywords: ["spotify", "airplay", "music"]),
        ]
        let music = SettingsSearchPolicy.matchingSections(
            query: "spotify music",
            sections: sections,
            id: \SearchSection.id,
            title: \SearchSection.title,
            keywords: \SearchSection.keywords
        )
        #expect(music == [sections[1]])
        #expect(SettingsSearchPolicy.matchingSections(
            query: "   ",
            sections: sections,
            id: \SearchSection.id,
            title: \SearchSection.title,
            keywords: \SearchSection.keywords
        ) == sections)
    }

    @Test("Local notes persist updates and deletion")
    @MainActor
    func notePersistence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("notes.json")
        let first = ProductivityNoteStore(storeURL: storeURL)
        var note = first.create()
        note.title = "Research"
        note.body = "Keep this on the Mac"
        first.update(note)

        let reloaded = ProductivityNoteStore(storeURL: storeURL)
        #expect(reloaded.notes.count == 1)
        #expect(reloaded.notes.first?.title == "Research")
        #expect(reloaded.notes.first?.body == "Keep this on the Mac")
        reloaded.delete(id: note.id)
        #expect(ProductivityNoteStore(storeURL: storeURL).notes.isEmpty)
    }

    @Test("Lyrics keys normalize artist and track without inventing remote lyrics")
    func lyricsKey() {
        #expect(LyricsStore.key(artist: "  Artist ", title: " Song ") == "artist\u{1F}song")
        #expect(LyricsStore.key(artist: nil, title: "   ") == nil)
    }

    @Test("Weather rejects invalid coordinates before network access")
    func invalidWeatherCoordinates() async {
        await #expect(throws: WeatherServiceError.invalidCoordinate) {
            try await WeatherService.shared.fetch(latitude: 91, longitude: 0)
        }
    }

    @Test("System statistics contain bounded host facts")
    func systemStatistics() {
        let snapshot = SystemStatsSnapshot.capture()
        #expect(snapshot.logicalProcessors > 0)
        #expect(snapshot.physicalMemoryBytes > 0)
        #expect(snapshot.systemUptime > 0)
        #expect(snapshot.loadAverage1Minute >= 0)
    }

    @Test("Window snap geometry remains inside the visible display")
    func windowSnapGeometry() {
        let display = CGRect(x: 100, y: 50, width: 1_441, height: 901)
        let left = WindowSnapLayout.frame(for: .leftHalf, in: display)
        let right = WindowSnapLayout.frame(for: .rightHalf, in: display)
        #expect(left.minX == display.minX)
        #expect(right.maxX == display.maxX)
        #expect(left.width + right.width == display.width)
        #expect(WindowSnapLayout.frame(for: .maximize, in: display) == display)
        #expect(display.contains(WindowSnapLayout.frame(for: .centered, in: display)))
    }

    @Test("LocalSend accepts only private and local receiver hosts")
    func localSendHostPolicy() {
        #expect(LocalNetworkHostPolicy.isAllowed("192.168.1.20"))
        #expect(LocalNetworkHostPolicy.isAllowed("10.0.0.4"))
        #expect(LocalNetworkHostPolicy.isAllowed("172.31.10.2"))
        #expect(LocalNetworkHostPolicy.isAllowed("macbook.local"))
        #expect(LocalNetworkHostPolicy.isAllowed("fe80::1"))
        #expect(!LocalNetworkHostPolicy.isAllowed("8.8.8.8"))
        #expect(!LocalNetworkHostPolicy.isAllowed("example.com"))
        #expect(!LocalNetworkHostPolicy.isAllowed("192.168.1.2/path"))
    }

    @Test("Terminal executes only the explicit command and reports its exit status")
    func terminalRunner() async throws {
        let result = try await TerminalRunner.run("printf notchshot", timeout: 5)
        #expect(result.output == "notchshot")
        #expect(result.exitCode == 0)
        #expect(!result.timedOut)
        #expect(!result.wasTruncated)
    }

    @Test("Terminal bounds output and stops descendants on timeout")
    func terminalRunnerSafetyBoundaries() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshot-terminal-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let escapedMarker = root.appendingPathComponent("escaped-child")

        let largeOutput = try await TerminalRunner.run(
            "yes x | head -c \(TerminalRunner.maximumOutputBytes + 8_192)",
            timeout: 5
        )
        #expect(largeOutput.output.utf8.count <= TerminalRunner.maximumOutputBytes)
        #expect(largeOutput.wasTruncated)

        let timeout = try await TerminalRunner.run(
            "(sleep 2; /usr/bin/touch '\(escapedMarker.path)') & sleep 10",
            timeout: 1
        )
        #expect(timeout.timedOut)
        try await Task.sleep(for: .milliseconds(2_200))
        #expect(!FileManager.default.fileExists(atPath: escapedMarker.path))
    }
}
