import AppKit
@preconcurrency import ApplicationServices
import Darwin
import Foundation
import Observation
import UserNotifications

public enum ProductivityTool: String, CaseIterable, Identifiable, Sendable {
    case notifications
    case notes
    case schedule
    case lyrics
    case weather
    case systemStats
    case terminal
    case launcher
    case localSend
    case windowSnap
    case camera

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .notifications: "Notification Center"
        case .notes: "Notes"
        case .schedule: "Schedule"
        case .lyrics: "Lyrics"
        case .weather: "Weather"
        case .systemStats: "System Stats"
        case .terminal: "Terminal"
        case .launcher: "Launcher"
        case .localSend: "LocalSend"
        case .windowSnap: "Window Snap"
        case .camera: "Camera"
        }
    }

    public var symbolName: String {
        switch self {
        case .notifications: "bell.badge"
        case .notes: "note.text"
        case .schedule: "calendar.badge.clock"
        case .lyrics: "quote.bubble"
        case .weather: "cloud.sun"
        case .systemStats: "gauge.with.dots.needle.67percent"
        case .terminal: "terminal"
        case .launcher: "command.square"
        case .localSend: "paperplane"
        case .windowSnap: "rectangle.split.2x1"
        case .camera: "video"
        }
    }
}

@MainActor
@Observable
public final class ProductivityCenterRouter {
    public static let shared = ProductivityCenterRouter()
    public var selectedTool: ProductivityTool = .notes
    public var pendingLocalSendFiles: [URL] = []

    public func route(to tool: ProductivityTool, localSendFiles: [URL] = []) {
        selectedTool = tool
        pendingLocalSendFiles = localSendFiles
    }
}

public struct ProductivityNote: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var body: String
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String = "New Note",
        body: String = "",
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.updatedAt = updatedAt
    }
}

@MainActor
@Observable
public final class ProductivityNoteStore {
    public static let shared = ProductivityNoteStore()

    public private(set) var notes: [ProductivityNote] = []
    public private(set) var lastError: String?

    private let storeURL: URL

    public init(storeURL: URL = AppPaths.support.appendingPathComponent("productivity-notes.json")) {
        self.storeURL = storeURL
        load()
    }

    @discardableResult
    public func create() -> ProductivityNote {
        let note = ProductivityNote()
        notes.insert(note, at: 0)
        persist()
        return note
    }

    public func update(_ note: ProductivityNote) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        var updated = note
        updated.title = String(updated.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        if updated.title.isEmpty { updated.title = "Untitled Note" }
        updated.body = String(updated.body.prefix(200_000))
        updated.updatedAt = Date()
        notes[index] = updated
        notes.sort { $0.updatedAt > $1.updatedAt }
        persist()
    }

    public func delete(id: UUID) {
        notes.removeAll { $0.id == id }
        persist()
    }

    private func load() {
        // Bound the read: a runaway or corrupted notes file must not be
        // decoded into memory.
        guard let values = try? storeURL.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size <= 8 * 1_024 * 1_024 else {
            lastError = "Notes file is missing or too large to load safely."
            return
        }
        guard let data = try? Data(contentsOf: storeURL) else { return }
        do {
            notes = try JSONDecoder().decode([ProductivityNote].self, from: data)
                .sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            lastError = "Notes could not be loaded: \(error.localizedDescription)"
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(notes)
            try data.write(to: storeURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: storeURL.path
            )
            lastError = nil
        } catch {
            lastError = "Notes could not be saved: \(error.localizedDescription)"
        }
    }
}

@MainActor
@Observable
public final class LyricsStore {
    public static let shared = LyricsStore()

    public private(set) var lyricsByTrack: [String: String] = [:]
    private let storeURL: URL

    public init(storeURL: URL = AppPaths.support.appendingPathComponent("lyrics.json")) {
        self.storeURL = storeURL
        // Bound the read: an oversized lyrics file must not be decoded.
        guard let values = try? storeURL.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size <= 8 * 1_024 * 1_024 else { return }
        if let data = try? Data(contentsOf: storeURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            lyricsByTrack = decoded
        }
    }

    nonisolated public static func key(artist: String?, title: String?) -> String? {
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !cleanTitle.isEmpty else { return nil }
        let cleanArtist = artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(cleanArtist.lowercased())\u{1F}\(cleanTitle.lowercased())"
    }

    public func lyrics(for key: String) -> String { lyricsByTrack[key] ?? "" }

    public func setLyrics(_ text: String, for key: String) throws {
        let bounded = String(text.prefix(300_000))
        if bounded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lyricsByTrack.removeValue(forKey: key)
        } else {
            lyricsByTrack[key] = bounded
        }
        let data = try JSONEncoder().encode(lyricsByTrack)
        try data.write(to: storeURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
    }
}

public struct WeatherReading: Equatable, Sendable {
    public var temperatureCelsius: Double
    public var apparentTemperatureCelsius: Double
    public var windKilometersPerHour: Double
    public var weatherCode: Int
    public var observedAt: Date

    public var summary: String {
        switch weatherCode {
        case 0: "Clear"
        case 1, 2: "Partly cloudy"
        case 3: "Overcast"
        case 45, 48: "Fog"
        case 51 ... 57: "Drizzle"
        case 61 ... 67: "Rain"
        case 71 ... 77: "Snow"
        case 80 ... 82: "Rain showers"
        case 85, 86: "Snow showers"
        case 95 ... 99: "Thunderstorm"
        default: "Current conditions"
        }
    }
}

public enum WeatherServiceError: LocalizedError, Equatable {
    case invalidCoordinate
    case invalidResponse
    case responseTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidCoordinate: "Enter a latitude from -90 to 90 and longitude from -180 to 180."
        case .invalidResponse: "The weather service returned an invalid response."
        case .responseTooLarge: "The weather response exceeded the safety limit."
        }
    }
}

public actor WeatherService {
    public static let shared = WeatherService()

    private struct Response: Decodable {
        struct Current: Decodable {
            var temperature2m: Double
            var apparentTemperature: Double
            var windSpeed10m: Double
            var weatherCode: Int
            var time: String

            enum CodingKeys: String, CodingKey {
                case temperature2m = "temperature_2m"
                case apparentTemperature = "apparent_temperature"
                case windSpeed10m = "wind_speed_10m"
                case weatherCode = "weather_code"
                case time
            }
        }

        var current: Current
    }

    public func fetch(latitude: Double, longitude: Double) async throws -> WeatherReading {
        guard (-90 ... 90).contains(latitude), (-180 ... 180).contains(longitude) else {
            throw WeatherServiceError.invalidCoordinate
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.open-meteo.com"
        components.path = "/v1/forecast"
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,wind_speed_10m"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        guard let url = components.url else { throw WeatherServiceError.invalidCoordinate }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        let (data, response) = try await URLSession(configuration: configuration).data(from: url)
        guard data.count <= 64_000 else { throw WeatherServiceError.responseTooLarge }
        guard let http = response as? HTTPURLResponse,
              (200 ..< 300).contains(http.statusCode),
              http.url?.scheme == "https" else {
            throw WeatherServiceError.invalidResponse
        }
        let payload = try JSONDecoder().decode(Response.self, from: data)
        let formatter = ISO8601DateFormatter()
        return WeatherReading(
            temperatureCelsius: payload.current.temperature2m,
            apparentTemperatureCelsius: payload.current.apparentTemperature,
            windKilometersPerHour: payload.current.windSpeed10m,
            weatherCode: payload.current.weatherCode,
            observedAt: formatter.date(from: payload.current.time) ?? Date()
        )
    }
}

public struct SystemStatsSnapshot: Equatable, Sendable {
    public var logicalProcessors: Int
    public var physicalMemoryBytes: UInt64
    public var systemUptime: TimeInterval
    public var loadAverage1Minute: Double
    public var loadAverage5Minutes: Double
    public var loadAverage15Minutes: Double
    public var thermalState: String
    public var lowPowerModeEnabled: Bool

    public static func capture(processInfo: ProcessInfo = .processInfo) -> SystemStatsSnapshot {
        var loads = [Double](repeating: 0, count: 3)
        _ = getloadavg(&loads, 3)
        let thermal = switch processInfo.thermalState {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
        return SystemStatsSnapshot(
            logicalProcessors: processInfo.activeProcessorCount,
            physicalMemoryBytes: processInfo.physicalMemory,
            systemUptime: processInfo.systemUptime,
            loadAverage1Minute: loads[0],
            loadAverage5Minutes: loads[1],
            loadAverage15Minutes: loads[2],
            thermalState: thermal,
            lowPowerModeEnabled: processInfo.isLowPowerModeEnabled
        )
    }
}

public struct TerminalResult: Equatable, Sendable {
    public var output: String
    public var exitCode: Int32
    public var timedOut: Bool
    public var wasTruncated: Bool
}

public enum TerminalRunner {
    public static let maximumOutputBytes = 256_000

    public static func run(_ command: String, timeout: TimeInterval = 30) async throws -> TerminalResult {
        let bounded = String(command.prefix(8_000)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bounded.isEmpty else { return TerminalResult(output: "", exitCode: 0, timedOut: false, wasTruncated: false) }
        return try await Task.detached(priority: .userInitiated) {
            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("notchshot-terminal-\(UUID().uuidString).log")
            guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil),
                  let handle = try? FileHandle(forWritingTo: temporaryURL) else {
                throw CocoaError(.fileWriteUnknown)
            }
            defer {
                try? handle.close()
                try? FileManager.default.removeItem(at: temporaryURL)
            }

            let shellURL = URL(fileURLWithPath: "/bin/zsh")
            guard let runnerURL = MediaRemoteAdapterSource.defaultRunnerURL,
                  let shellIdentity = SafeAssetFile.identity(
                      at: shellURL,
                      maximumBytes: SafeAssetFile.maximumExternalBytes
                  ) else {
                throw CocoaError(.executableNotLoadable)
            }

            // The bundled runner creates a dedicated process group before it
            // execs zsh. Killing only the shell is insufficient: a command can
            // fork a child that keeps running after the visible terminal says
            // it timed out.
            let process = Process()
            process.executableURL = runnerURL
            process.arguments = [
                String(shellIdentity.device),
                String(shellIdentity.inode),
                String(shellIdentity.size),
                String(shellIdentity.modifiedSeconds),
                String(shellIdentity.modifiedNanoseconds),
                shellURL.path,
                "-f",
                "-c",
                outputLimitWrapper,
                "notchshot-terminal",
                bounded,
            ]
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            let processID = process.processIdentifier
            guard waitForDedicatedProcessGroup(processID: processID) else {
                process.terminate()
                process.waitUntilExit()
                throw CocoaError(.executableNotLoadable)
            }

            let deadline = ProcessInfo.processInfo.systemUptime + max(1, min(timeout, 120))
            var timedOut = false
            var exceededOutputLimit = false
            while process.isRunning {
                if outputSize(at: temporaryURL) > maximumOutputBytes {
                    exceededOutputLimit = true
                    break
                }
                if ProcessInfo.processInfo.systemUptime >= deadline {
                    timedOut = true
                    break
                }
                try await Task.sleep(for: .milliseconds(40))
            }

            if process.isRunning, timedOut || exceededOutputLimit {
                await terminateProcessGroup(processID)
            }
            process.waitUntilExit()
            // A shell can exit successfully after forking. Do not let a
            // descendant escape the timeout/output boundary just because its
            // parent returned first.
            if processGroupExists(processID) {
                await terminateProcessGroup(processID)
            }
            try handle.synchronize()

            let byteCount = outputSize(at: temporaryURL)
            let readHandle = try FileHandle(forReadingFrom: temporaryURL)
            defer { try? readHandle.close() }
            let data = try readHandle.read(upToCount: maximumOutputBytes) ?? Data()
            return TerminalResult(
                output: String(decoding: data, as: UTF8.self),
                exitCode: process.terminationStatus,
                timedOut: timedOut,
                wasTruncated: exceededOutputLimit
                    || byteCount > maximumOutputBytes
                    || (byteCount >= maximumOutputBytes && process.terminationStatus != 0)
            )
        }.value
    }

    /// zsh's file-size limit uses 512-byte blocks. Lowering both the hard and
    /// soft limit before the user's login shell starts means descendants
    /// cannot raise it again, so a fast producer cannot outrun our polling
    /// loop and fill the disk-backed output file.
    private static let outputLimitWrapper = """
    ulimit -H -f \(maximumOutputBytes / 512)
    ulimit -S -f \(maximumOutputBytes / 512)
    exec /bin/zsh -lc "$1"
    """

    private static func outputSize(at url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return 0
        }
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    private static func waitForDedicatedProcessGroup(processID: pid_t) -> Bool {
        for _ in 0 ..< 100 {
            if getpgid(processID) == processID { return true }
            if kill(processID, 0) != 0 { return true }
            usleep(1_000)
        }
        return false
    }

    private static func processGroupExists(_ processGroupID: pid_t) -> Bool {
        errno = 0
        return kill(-processGroupID, 0) == 0 || errno == EPERM
    }

    private static func terminateProcessGroup(_ processGroupID: pid_t) async {
        _ = kill(-processGroupID, SIGTERM)
        let graceDeadline = ProcessInfo.processInfo.systemUptime + 0.2
        while processGroupExists(processGroupID),
              ProcessInfo.processInfo.systemUptime < graceDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if processGroupExists(processGroupID) {
            _ = kill(-processGroupID, SIGKILL)
        }
    }
}

public struct ApplicationDescriptor: Equatable, Identifiable, Sendable {
    public var url: URL
    public var name: String
    public var bundleIdentifier: String?
    public var id: String { url.path }
}

public enum ApplicationCatalog {
    public static func discover(fileManager: FileManager = .default) -> [ApplicationDescriptor] {
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
        var seen = Set<String>()
        var applications: [ApplicationDescriptor] = []
        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
                let path = url.standardizedFileURL.path
                guard seen.insert(path).inserted else { continue }
                let bundle = Bundle(url: url)
                let displayName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                applications.append(ApplicationDescriptor(
                    url: url,
                    name: displayName,
                    bundleIdentifier: bundle?.bundleIdentifier
                ))
            }
        }
        return applications.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @MainActor
    public static func open(_ application: ApplicationDescriptor) {
        NSWorkspace.shared.openApplication(at: application.url, configuration: .init())
    }
}

public enum WindowSnapPosition: String, CaseIterable, Identifiable, Sendable {
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case maximize
    case centered

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .maximize: "Maximize"
        case .centered: "Center"
        }
    }
    public var symbolName: String {
        switch self {
        case .leftHalf: "rectangle.lefthalf.inset.filled"
        case .rightHalf: "rectangle.righthalf.inset.filled"
        case .topHalf: "rectangle.tophalf.inset.filled"
        case .bottomHalf: "rectangle.bottomhalf.inset.filled"
        case .maximize: "rectangle.inset.filled"
        case .centered: "rectangle.center.inset.filled"
        }
    }
}

public enum WindowSnapLayout {
    public static func frame(for position: WindowSnapPosition, in visibleFrame: CGRect) -> CGRect {
        let halfWidth = floor(visibleFrame.width / 2)
        let halfHeight = floor(visibleFrame.height / 2)
        return switch position {
        case .leftHalf:
            CGRect(x: visibleFrame.minX, y: visibleFrame.minY, width: halfWidth, height: visibleFrame.height)
        case .rightHalf:
            CGRect(x: visibleFrame.minX + halfWidth, y: visibleFrame.minY, width: visibleFrame.width - halfWidth, height: visibleFrame.height)
        case .topHalf:
            CGRect(x: visibleFrame.minX, y: visibleFrame.minY + halfHeight, width: visibleFrame.width, height: visibleFrame.height - halfHeight)
        case .bottomHalf:
            CGRect(x: visibleFrame.minX, y: visibleFrame.minY, width: visibleFrame.width, height: halfHeight)
        case .maximize:
            visibleFrame
        case .centered:
            CGRect(
                x: visibleFrame.minX + visibleFrame.width * 0.1,
                y: visibleFrame.minY + visibleFrame.height * 0.1,
                width: visibleFrame.width * 0.8,
                height: visibleFrame.height * 0.8
            )
        }
    }
}

@MainActor
public enum WindowSnapService {
    public static func isAccessibilityTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public static func snapFrontmost(to position: WindowSnapPosition) throws {
        guard isAccessibilityTrusted(prompt: true) else {
            throw NotchShotError.exportFailed("Accessibility permission is required to move another app's window")
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw NotchShotError.exportFailed("Bring another app to the front, then try Window Snap again")
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        var rawWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &rawWindow) == .success,
              let rawWindow,
              CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else {
            throw NotchShotError.exportFailed("The frontmost app did not expose a movable window")
        }
        let window = rawWindow as! AXUIElement
        var rawPosition: CFTypeRef?
        var rawSize: CFTypeRef?
        var currentPosition = CGPoint.zero
        var currentSize = CGSize(width: 800, height: 600)
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &rawPosition) == .success,
           let rawPosition,
           CFGetTypeID(rawPosition) == AXValueGetTypeID() {
            AXValueGetValue(rawPosition as! AXValue, .cgPoint, &currentPosition)
        }
        if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &rawSize) == .success,
           let rawSize,
           CFGetTypeID(rawSize) == AXValueGetTypeID() {
            AXValueGetValue(rawSize as! AXValue, .cgSize, &currentSize)
        }
        // AX positions are global CoreGraphics (top-left) points, while
        // `NSScreen.frame` and `WindowSnapLayout` are Cocoa (bottom-left).
        // Converting both here is what keeps Top Half on the top half and
        // keeps a window on the display that actually contains it.
        let primaryFrame = ScreenLookup.primaryFrame
        let centerInCG = CGPoint(
            x: currentPosition.x + currentSize.width / 2,
            y: currentPosition.y + currentSize.height / 2
        )
        let centerInCocoa = ScreenGeometry.cocoaPoint(
            fromCG: centerInCG,
            primaryFrame: primaryFrame
        )
        let screen = NSScreen.screens.first(where: { NSMouseInRect(centerInCocoa, $0.frame, false) })
            ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            throw NotchShotError.exportFailed("No display is available for Window Snap")
        }
        let target = ScreenGeometry.cgRect(
            fromCocoa: WindowSnapLayout.frame(for: position, in: visibleFrame),
            primaryFrame: primaryFrame
        )
        var targetPosition = target.origin
        var targetSize = target.size
        guard let positionValue = AXValueCreate(.cgPoint, &targetPosition),
              let sizeValue = AXValueCreate(.cgSize, &targetSize),
              AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue) == .success,
              AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) == .success else {
            throw NotchShotError.exportFailed("macOS refused to resize that window")
        }
    }
}

@MainActor
public final class PointerLocatorService {
    public static let shared = PointerLocatorService()
    private var panel: NSPanel?

    public func show() {
        // Replacing the panel cancels the old one's delayed cleanup, which
        // would otherwise skip its registry unregister and leak the window.
        if let panel {
            WindowExclusionRegistry.shared.unregister(panel)
            panel.close()
        }
        let size = CGSize(width: 92, height: 92)
        let pointer = NSEvent.mouseLocation
        let panel = NSPanel(
            contentRect: CGRect(
                x: pointer.x - size.width / 2,
                y: pointer.y - size.height / 2,
                width: size.width,
                height: size.height
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.sharingType = .none
        panel.contentView = PointerLocatorView(frame: CGRect(origin: .zero, size: size))
        WindowExclusionRegistry.shared.register(panel)
        panel.orderFrontRegardless()
        self.panel = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self, weak panel] in
            guard self?.panel === panel else { return }
            if let panel { WindowExclusionRegistry.shared.unregister(panel) }
            panel?.close()
            self?.panel = nil
        }
    }
}

private final class PointerLocatorView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let ring = bounds.insetBy(dx: 8, dy: 8)
        NSColor.systemYellow.withAlphaComponent(0.18).setFill()
        NSBezierPath(ovalIn: ring).fill()
        NSColor.systemYellow.setStroke()
        let path = NSBezierPath(ovalIn: ring)
        path.lineWidth = 5
        path.stroke()
    }
}

@MainActor
public final class ProductivityNotificationCenter: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = ProductivityNotificationCenter()

    private static let categoryIdentifier = "NOTCHSHOT_REMINDER"
    private static let doneActionIdentifier = "NOTCHSHOT_DONE"
    private static let replyActionIdentifier = "NOTCHSHOT_REPLY"
    private static let itemIDKey = "notchshot.notification.id"

    private var onOpenCenter: (() -> Void)?

    public func configure(onOpenCenter: (() -> Void)? = nil) {
        self.onOpenCenter = onOpenCenter
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let done = UNNotificationAction(
            identifier: Self.doneActionIdentifier,
            title: "Mark Done"
        )
        let reply = UNTextInputNotificationAction(
            identifier: Self.replyActionIdentifier,
            title: "Reply in NotchShot",
            textInputButtonTitle: "Save Reply",
            textInputPlaceholder: "Add a reply to this NotchShot alert"
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [done, reply],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        center.setNotificationCategories([category])
        Task { await synchronizeWithSystemCenter() }
    }

    public func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    @discardableResult
    public func schedule(
        title: String,
        body: String,
        priority: ProductivityNotificationPriority = .standard,
        at date: Date
    ) async throws -> ProductivityNotificationItem {
        let id = UUID()
        let content = UNMutableNotificationContent()
        let item = ProductivityNotificationItem(
            id: id,
            title: title,
            body: body,
            priority: priority,
            scheduledAt: date
        )
        content.title = item.title
        content.body = item.body
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = [Self.itemIDKey: id.uuidString]
        let interval = max(1, date.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id.uuidString, content: content, trigger: trigger)
        )
        return ProductivityNotificationStore.shared.recordScheduled(
            id: id,
            title: item.title,
            body: item.body,
            priority: item.priority,
            scheduledAt: item.scheduledAt,
            createdAt: item.createdAt
        )
    }

    public func remove(_ item: ProductivityNotificationItem) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [item.id.uuidString])
        center.removeDeliveredNotifications(withIdentifiers: [item.id.uuidString])
        ProductivityNotificationStore.shared.remove(id: item.id)
    }

    public func complete(_ item: ProductivityNotificationItem) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [item.id.uuidString])
        center.removeDeliveredNotifications(withIdentifiers: [item.id.uuidString])
        ProductivityNotificationStore.shared.apply(.completed(Date()), to: item.id)
    }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if let id = Self.itemID(from: notification.request) {
            Task { @MainActor in
                ProductivityNotificationStore.shared.apply(.delivered(Date()), to: id)
            }
        }
        completionHandler([.banner, .sound])
    }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = Self.itemID(from: response.notification.request)
        let actionIdentifier = response.actionIdentifier
        let reply = (response as? UNTextInputNotificationResponse)?.userText
        completionHandler()
        guard let id else { return }
        Task { @MainActor [weak self] in
            self?.handle(id: id, actionIdentifier: actionIdentifier, reply: reply)
        }
    }

    private func handle(id: UUID, actionIdentifier: String, reply: String?) {
        let center = UNUserNotificationCenter.current()
        switch actionIdentifier {
        case Self.doneActionIdentifier:
            ProductivityNotificationStore.shared.apply(.completed(Date()), to: id)
            center.removeDeliveredNotifications(withIdentifiers: [id.uuidString])
        case Self.replyActionIdentifier:
            ProductivityNotificationStore.shared.apply(.replied(reply ?? "", Date()), to: id)
            center.removeDeliveredNotifications(withIdentifiers: [id.uuidString])
            onOpenCenter?()
        case UNNotificationDismissActionIdentifier:
            ProductivityNotificationStore.shared.apply(.dismissed(Date()), to: id)
        case UNNotificationDefaultActionIdentifier:
            ProductivityNotificationStore.shared.apply(.delivered(Date()), to: id)
            onOpenCenter?()
        default:
            break
        }
    }

    private func synchronizeWithSystemCenter() async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let pending = await center.pendingNotificationRequests()
        ProductivityNotificationStore.shared.reconcile(
            deliveredIDs: Set(delivered.compactMap { Self.itemID(from: $0.request) }),
            pendingIDs: Set(pending.compactMap(Self.itemID(from:)))
        )
    }

    nonisolated private static func itemID(from request: UNNotificationRequest) -> UUID? {
        if let raw = request.content.userInfo["notchshot.notification.id"] as? String,
           let id = UUID(uuidString: raw) {
            return id
        }
        return UUID(uuidString: request.identifier)
    }
}
