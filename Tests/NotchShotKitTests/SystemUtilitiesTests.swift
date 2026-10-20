import Foundation
import Testing

@testable import NotchShotKit

@Suite("System utilities")
@MainActor
struct SystemUtilitiesTests {
    // MARK: Keyboard

    @Test("Caps Lock bursts share the mode-switch pill and coalesce")
    func capsLockEvent() {
        let on = AppCoordinator.capsLockEvent(isOn: true)
        let off = AppCoordinator.capsLockEvent(isOn: false)
        #expect(on.kind == .capsLock)
        #expect(on.symbolName == "capslock.fill")
        #expect(off.symbolName == "capslock")
        #expect(on.title == "Caps Lock On")
        #expect(off.title == "Caps Lock Off")
        #expect(on.coalescingKey == off.coalescingKey)

        var queue = IslandTransientQueue()
        _ = queue.enqueue(on)
        _ = queue.enqueue(off)
        #expect(queue.pending.count + (queue.current == nil ? 0 : 1) == 1)
    }

    @Test("Input source bursts carry the layout name")
    func inputSourceEvent() {
        let source = KeyboardStateMonitor.InputSource(id: "ro", name: "Romanian – Standard", language: "ro")
        #expect(source.shortName == "Romanian")
        #expect(source.badge == "RO")
        #expect(KeyboardStateMonitor.InputSource(id: "d", name: "Dvorak", language: nil).badge == "DV")
        #expect(KeyboardStateMonitor.InputSource(id: "z", name: "Chinese", language: "zh-Hans").badge == "ZH")
        let event = AppCoordinator.inputSourceEvent(name: source.shortName, badge: source.badge)
        #expect(event.kind == .inputSource)
        #expect(event.title == "Romanian")
        #expect(event.detail == "RO")
    }

    // MARK: Brightness

    @Test("DDC packets match the VESA layout and checksum")
    func ddcPackets() {
        #expect(DDCPacket.set(code: 0x10, value: 50) == [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
        #expect(DDCPacket.get(code: 0x10) == [0x82, 0x01, 0x10, 0xAC])
    }

    @Test("DDC replies parse current and maximum, and reject errors")
    func ddcReply() {
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x46, 0x00]
        let parsed = DDCPacket.parseReply(reply, code: 0x10)
        #expect(parsed?.current == 70)
        #expect(parsed?.maximum == 100)

        var unsupported = reply
        unsupported[3] = 0x01
        #expect(DDCPacket.parseReply(unsupported, code: 0x10) == nil)
        #expect(DDCPacket.parseReply(reply, code: 0x12) == nil)
        #expect(DDCPacket.parseReply(Array(reply.prefix(6)), code: 0x10) == nil)
    }

    @Test("Displays pair with registry links by serial first, then model")
    func ddcPairing() {
        let displays = [
            DDCDisplayIdentity(displayID: 2, vendor: 1, model: 7, serial: 0),
            DDCDisplayIdentity(displayID: 3, vendor: 1, model: 7, serial: 99),
        ]
        let links: [(vendor: UInt32, model: UInt32, serial: UInt32)] = [
            (1, 7, 99),
            (1, 7, 0),
            (4, 4, 4),
        ]
        let pairs = DDCPacket.pair(displays: displays, links: links)
        #expect(pairs[3] == 0)
        #expect(pairs[2] == 1)
    }

    @Test("Software dimming never goes fully dark")
    func gammaScale() {
        #expect(GammaDimmer.scale(for: 1) == 1)
        #expect(GammaDimmer.scale(for: 0) == GammaDimmer.minimumScale)
        #expect(GammaDimmer.scale(for: -3) == GammaDimmer.minimumScale)
        #expect(GammaDimmer.scale(for: 0.5) > GammaDimmer.minimumScale)
    }

    // MARK: Downloads

    @Test("Download names drop the browser's in-progress suffix")
    func downloadNames() {
        #expect(DownloadProgressPolicy.displayName(for: URL(fileURLWithPath: "/D/movie.mp4.download")) == "movie.mp4")
        #expect(DownloadProgressPolicy.displayName(for: URL(fileURLWithPath: "/D/setup.dmg.crdownload")) == "setup.dmg")
        #expect(DownloadProgressPolicy.displayName(for: URL(fileURLWithPath: "/D/notes.pdf")) == "notes.pdf")
    }

    @Test("Only downloading progress counts, and a short stop reads as stopped")
    func downloadPolicy() {
        #expect(DownloadProgressPolicy.isDownload(kind: .file, operation: .downloading))
        #expect(!DownloadProgressPolicy.isDownload(kind: .file, operation: .copying))
        #expect(DownloadProgressPolicy.byteCount(-1) == nil)
        #expect(DownloadProgressPolicy.byteCount(10) == 10)
        #expect(DownloadProgressPolicy.outcome(isCancelled: false, completed: 10, total: 10) == .completed)
        #expect(DownloadProgressPolicy.outcome(isCancelled: false, completed: 4, total: 10) == .cancelled)
        #expect(DownloadProgressPolicy.outcome(isCancelled: true, completed: 10, total: 10) == .cancelled)
        #expect(DownloadProgressPolicy.outcome(isCancelled: false, completed: 4, total: -1) == .completed)
    }

    @Test("Downloads get their own transfer wording")
    @MainActor
    func downloadTransferTitle() {
        let store = TransferActivityStore()
        let id = store.begin(service: .download, direction: .incoming, peerName: "a.zip", fileCount: 1)
        store.markTransferring(id)
        #expect(store.transfers.first?.title == "Downloading")
    }

    // MARK: Archives

    @Test("Archive formats and names follow Archive Utility")
    func archiveNames() {
        #expect(ArchiveExtractor.format(of: URL(fileURLWithPath: "/a/Photos.zip")) == .zip)
        #expect(ArchiveExtractor.format(of: URL(fileURLWithPath: "/a/src.tar.gz")) == .tarFamily)
        #expect(ArchiveExtractor.format(of: URL(fileURLWithPath: "/a/log.gz")) == .gzip)
        #expect(ArchiveExtractor.format(of: URL(fileURLWithPath: "/a/data.7z")) == .tarFamily)
        #expect(ArchiveExtractor.format(of: URL(fileURLWithPath: "/a/notes.txt")) == nil)
        #expect(ArchiveExtractor.baseName(of: URL(fileURLWithPath: "/a/src.tar.gz")) == "src")
        #expect(ArchiveExtractor.baseName(of: URL(fileURLWithPath: "/a/Photos.zip")) == "Photos")
    }

    @Test("Extraction lands beside the archive, wrapped only when needed")
    func extractArchives() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: source.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: source.appendingPathComponent("b.txt"))

        // A ZIP of one folder unpacks to that folder, renamed if taken.
        let zip = folder.appendingPathComponent("Project.zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", source.path, zip.path])
        let zipResult = try ArchiveExtractor.extract(zip)
        #expect(zipResult.outputURL.lastPathComponent == "Project 2")
        #expect(FileManager.default.fileExists(atPath: zipResult.outputURL.appendingPathComponent("b.txt").path))

        // A tarball of loose files is wrapped in a folder named after it.
        let tarball = folder.appendingPathComponent("loose.tar.gz")
        try run("/usr/bin/tar", ["-c", "-z", "-f", tarball.path, "-C", source.path, "a.txt", "b.txt"])
        let tarResult = try ArchiveExtractor.extract(tarball)
        #expect(tarResult.outputURL.lastPathComponent == "loose")
        #expect(tarResult.itemCount == 2)

        // A lone gzip file decompresses to the file inside.
        let gzip = folder.appendingPathComponent("a.txt.gz")
        try run("/usr/bin/gzip", ["-k", "-c", source.appendingPathComponent("a.txt").path], stdout: gzip)
        let gzipResult = try ArchiveExtractor.extract(gzip)
        #expect(gzipResult.outputURL.lastPathComponent == "a.txt")
        #expect(try String(contentsOf: gzipResult.outputURL, encoding: .utf8) == "a")

        // No staging folder is left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(!leftovers.contains { $0.hasPrefix(".notchshot-extract-") })
    }

    @Test("A corrupt archive fails without leaving files")
    func corruptArchive() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let bogus = folder.appendingPathComponent("broken.zip")
        try Data("not a zip".utf8).write(to: bogus)
        #expect(throws: ArchiveExtractor.Failure.self) { try ArchiveExtractor.extract(bogus) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["broken.zip"])
    }

    @Test("What a downloaded archive holds stays quarantined, as Archive Utility leaves it")
    func extractedItemsKeepQuarantine() throws {
        let folder = try temporaryFolder()
        defer {
            try? run("/bin/chmod", ["-R", "u+w", folder.path])
            try? FileManager.default.removeItem(at: folder)
        }
        let source = folder.appendingPathComponent("Tool", isDirectory: true)
        let bin = source.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = bin.appendingPathComponent("run.command")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        try FileManager.default.createSymbolicLink(
            atPath: source.appendingPathComponent("link").path,
            withDestinationPath: "bin/run.command"
        )
        // A member can store its own quarantine, one claiming it was approved.
        let approved = source.appendingPathComponent("approved.command")
        try Data("#!/bin/sh\n".utf8).write(to: approved)
        try setQuarantine("00c1;6710e2c0;Safari;", on: approved)
        // Read-only items refuse new attributes until made writable.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: script.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bin.path)

        let tarball = folder.appendingPathComponent("Tool.tar.gz")
        try run("/usr/bin/tar", ["-c", "-z", "-f", tarball.path, "-C", folder.path, "Tool"])
        let gzip = folder.appendingPathComponent("run.command.gz")
        try run("/usr/bin/gzip", ["-c", script.path], stdout: gzip)
        let local = folder.appendingPathComponent("local.tar")
        try run("/usr/bin/tar", ["-c", "-f", local.path, "-C", bin.path, "run.command"])
        let download = "0083;6710e2c0;Safari;11111111-2222-3333-4444-555555555555"
        try setQuarantine(download, on: tarball)
        try setQuarantine(download, on: gzip)

        let tarOutput = try ArchiveExtractor.extract(tarball).outputURL
        #expect(quarantine(of: tarOutput) == download)
        var marked = 0
        let walker = try #require(FileManager.default.enumerator(atPath: tarOutput.path))
        for case let relative as String in walker {
            let item = tarOutput.appendingPathComponent(relative)
            guard try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { continue }
            #expect(quarantine(of: item) == download, "\(relative)")
            marked += 1
        }
        #expect(marked == 3)
        let permissions = { (url: URL) in
            try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        }
        #expect(try permissions(tarOutput.appendingPathComponent("bin")) == 0o555)
        #expect(try permissions(tarOutput.appendingPathComponent("bin/run.command")) == 0o555)

        let gzipOutput = try ArchiveExtractor.extract(gzip).outputURL
        #expect(quarantine(of: gzipOutput) == download)

        // An archive made on this Mac carries no quarantine and gains none.
        let localOutput = try ArchiveExtractor.extract(local).outputURL
        #expect(quarantine(of: localOutput) == nil)
    }

    // MARK: Uninstall

    @Test("Leftovers match the bundle identifier exactly and the name only when distinctive")
    func leftoverScan() {
        let app = UninstallableApp(
            url: URL(fileURLWithPath: "/Applications/Rectangle.app"),
            name: "Rectangle",
            bundleIdentifier: "com.knollsoft.Rectangle"
        )
        let library = URL(fileURLWithPath: "/Users/test/Library")
        let listing: [String: [String]] = [
            "Application Support": ["Rectangle", "com.knollsoft.Rectangle", "RectangleExtra", "Other"],
            "Caches": ["com.knollsoft.Rectangle", "com.knollsoft.RectangleLauncher"],
            "Preferences": ["com.knollsoft.Rectangle.plist", "com.knollsoft.Hookshot.plist"],
            "Containers": ["com.knollsoft.Rectangle.widget", "com.other.app"],
            "Group Containers": ["ABCDE.com.knollsoft.Rectangle"],
            "LaunchAgents": ["com.knollsoft.Rectangle.launcher.plist"],
        ]
        let found = AppLeftoverScanner.leftovers(for: app, library: library) { folder in
            listing[folder.path.replacingOccurrences(of: library.path + "/", with: "")] ?? []
        }
        let names = Set(found.map(\.url.lastPathComponent))
        #expect(names == [
            "Rectangle", "com.knollsoft.Rectangle", "com.knollsoft.Rectangle.plist",
            "com.knollsoft.Rectangle.widget", "ABCDE.com.knollsoft.Rectangle",
            "com.knollsoft.Rectangle.launcher.plist",
        ])
        #expect(found.first { $0.url.lastPathComponent == "ABCDE.com.knollsoft.Rectangle" }?.confidence == .likely)
        #expect(found.first { $0.url.lastPathComponent == "Rectangle" }?.confidence == .likely)
        #expect(found.first { $0.url.lastPathComponent == "com.knollsoft.Rectangle.plist" }?.confidence == .exact)
    }

    @Test("Generic app names never match by name")
    func genericNames() {
        let app = UninstallableApp(
            url: URL(fileURLWithPath: "/Applications/Code.app"),
            name: "Code",
            bundleIdentifier: "com.example.code"
        )
        let found = AppLeftoverScanner.leftovers(for: app, library: URL(fileURLWithPath: "/L")) { _ in ["Code"] }
        #expect(found.isEmpty)
    }

    @Test("Apple apps, NotchShot and non-apps are refused")
    func refusals() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let thirdParty = try makeApp(in: folder, name: "Tool", identifier: "com.example.tool")
        let apple = try makeApp(in: folder, name: "Fake Apple", identifier: "com.apple.fake")
        let own = try makeApp(in: folder, name: "Own", identifier: "com.example.notchshot")

        #expect(try AppLeftoverScanner.app(at: thirdParty, ownBundleIdentifier: "x").bundleIdentifier == "com.example.tool")
        #expect(throws: AppUninstallRefusal.appleApp("Fake Apple")) {
            try AppLeftoverScanner.app(at: apple, ownBundleIdentifier: "x")
        }
        #expect(throws: AppUninstallRefusal.notchShot) {
            try AppLeftoverScanner.app(at: own, ownBundleIdentifier: "com.example.notchshot")
        }
        #expect(throws: AppUninstallRefusal.notAnApp("plain")) {
            try AppLeftoverScanner.app(at: folder.appendingPathComponent("plain"), ownBundleIdentifier: "x")
        }
        #expect(AppLeftoverScanner.isProtected(identifier: "com.example.tool", url: URL(fileURLWithPath: "/System/Applications/Tool.app")))
    }

    // MARK: Helpers

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SystemUtilitiesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeApp(in folder: URL, name: String, identifier: String) throws -> URL {
        let app = folder.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleName": name, "CFBundlePackageType": "APPL"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    private func run(_ tool: String, _ arguments: [String], stdout: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let stdout {
            FileManager.default.createFile(atPath: stdout.path, contents: nil)
            process.standardOutput = try FileHandle(forWritingTo: stdout)
        }
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func setQuarantine(_ value: String, on url: URL) throws {
        let bytes = Array(value.utf8)
        try #require(setxattr(url.path, "com.apple.quarantine", bytes, bytes.count, 0, XATTR_NOFOLLOW) == 0)
    }

    private func quarantine(of url: URL) -> String? {
        let length = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
        guard length > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: length)
        guard getxattr(url.path, "com.apple.quarantine", &bytes, length, 0, XATTR_NOFOLLOW) == length else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}
