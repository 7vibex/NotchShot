import Darwin
import Foundation

/// Wire format for the local Live Activity API.
///
/// A client (the `notchshot activity` CLI, or anything speaking the same
/// newline-terminated JSON) connects to a per-user, owner-only Unix socket,
/// writes exactly one message, and reads one acknowledgement line. The app
/// verifies the peer's user id before reading anything.
///
/// Everything a client sends is untrusted. The format has no field that can
/// name an executable, a command, a URL, a file path, markup, or a custom
/// image: icons and accents are chosen from fixed catalogs, text is bounded and
/// stripped of control and bidirectional-override characters, and numbers must
/// be finite and in range. See `LiveActivitySanitizer`.
public enum LiveActivitySocket {
    public static let fileNamePrefix = "notchshot-activity"

    public static var path: String {
        let name = "\(fileNamePrefix)-\(getuid()).sock"
        let preferred = FileManager.default.temporaryDirectory
            .appendingPathComponent(name).path
        if preferred.utf8.count < 104 { return preferred }
        return "/tmp/\(name)"
    }

    /// Same peer check as the Claude hook socket: only the current user.
    public static func isTrustedPeer(_ fileDescriptor: Int32) -> Bool {
        ClaudeHookSocket.isTrustedPeer(fileDescriptor)
    }
}

public enum LiveActivityCommand: String, Codable, Sendable, CaseIterable {
    case start
    case update
    case finish
    case fail
    case dismiss
}

public enum LiveActivityUrgency: String, Codable, Sendable, CaseIterable {
    /// Shown only when nothing else is going on.
    case passive
    case normal
    /// May take the primary slot when it needs the user.
    case important
}

public enum LiveActivityUnit: String, Codable, Sendable, CaseIterable {
    case bytes
    case items
    case count
}

/// The only icons a reporter can ask for. Each maps to a system symbol inside
/// the app; a reporter can never supply image data or a symbol name directly.
public enum LiveActivityIcon: String, Codable, Sendable, CaseIterable {
    case build
    case test
    case terminal
    case sparkles
    case download
    case upload
    case archive
    case backup
    case package
    case render
    case export
    case git
    case sync
    case gear
    case document
    case clock

    public var symbolName: String {
        switch self {
        case .build: "hammer.fill"
        case .test: "checklist"
        case .terminal: "terminal.fill"
        case .sparkles: "sparkles"
        case .download: "arrow.down.circle.fill"
        case .upload: "arrow.up.circle.fill"
        case .archive: "archivebox.fill"
        case .backup: "externaldrive.fill.badge.timemachine"
        case .package: "shippingbox.fill"
        case .render: "film.stack"
        case .export: "square.and.arrow.up.fill"
        case .git: "arrow.triangle.branch"
        case .sync: "arrow.triangle.2.circlepath"
        case .gear: "gearshape.fill"
        case .document: "doc.fill"
        case .clock: "clock.fill"
        }
    }
}

public enum LiveActivityAccent: String, Codable, Sendable, CaseIterable {
    case blue, green, orange, red, purple, pink, teal, yellow, gray

    public var hex: String {
        switch self {
        case .blue: "#0A84FF"
        case .green: "#30D158"
        case .orange: "#FF9F0A"
        case .red: "#FF453A"
        case .purple: "#BF5AF2"
        case .pink: "#FF375F"
        case .teal: "#64D2FF"
        case .yellow: "#FFD60A"
        case .gray: "#98989D"
        }
    }
}

/// The raw message as a client encodes it. Every field but `command` and `id`
/// is optional; unknown keys are ignored by `JSONDecoder`.
public struct LiveActivityMessage: Codable, Sendable, Equatable {
    public var version: Int?
    public var command: String
    public var id: String
    public var source: String?
    public var title: String?
    public var subtitle: String?
    public var state: String?
    /// Completion in 0...1.
    public var progress: Double?
    public var current: Double?
    public var total: Double?
    public var unit: String?
    /// Seconds remaining, when the reporter measured it.
    public var etaSeconds: Double?
    public var icon: String?
    public var accent: String?
    public var urgency: String?
    public var expiresInSeconds: Double?

    public init(
        command: LiveActivityCommand,
        id: String,
        source: String? = nil,
        title: String? = nil,
        subtitle: String? = nil,
        state: String? = nil,
        progress: Double? = nil,
        current: Double? = nil,
        total: Double? = nil,
        unit: LiveActivityUnit? = nil,
        etaSeconds: Double? = nil,
        icon: LiveActivityIcon? = nil,
        accent: LiveActivityAccent? = nil,
        urgency: LiveActivityUrgency? = nil,
        expiresInSeconds: Double? = nil
    ) {
        self.version = LiveActivitySanitizer.protocolVersion
        self.command = command.rawValue
        self.id = id
        self.source = source
        self.title = title
        self.subtitle = subtitle
        self.state = state
        self.progress = progress
        self.current = current
        self.total = total
        self.unit = unit?.rawValue
        self.etaSeconds = etaSeconds
        self.icon = icon?.rawValue
        self.accent = accent?.rawValue
        self.urgency = urgency?.rawValue
        self.expiresInSeconds = expiresInSeconds
    }
}

/// A message after validation: every value typed, bounded, and safe to show.
public struct LiveActivityUpdate: Sendable, Equatable {
    public var command: LiveActivityCommand
    public var id: String
    public var source: String?
    public var title: String?
    public var subtitle: String?
    public var stateLabel: String?
    public var progress: Double?
    public var current: Int64?
    public var total: Int64?
    public var unit: LiveActivityUnit?
    public var etaSeconds: TimeInterval?
    public var icon: LiveActivityIcon?
    public var accent: LiveActivityAccent?
    public var urgency: LiveActivityUrgency?
    public var expiresIn: TimeInterval?

    public init(
        command: LiveActivityCommand,
        id: String,
        source: String? = nil,
        title: String? = nil,
        subtitle: String? = nil,
        stateLabel: String? = nil,
        progress: Double? = nil,
        current: Int64? = nil,
        total: Int64? = nil,
        unit: LiveActivityUnit? = nil,
        etaSeconds: TimeInterval? = nil,
        icon: LiveActivityIcon? = nil,
        accent: LiveActivityAccent? = nil,
        urgency: LiveActivityUrgency? = nil,
        expiresIn: TimeInterval? = nil
    ) {
        self.command = command
        self.id = id
        self.source = source
        self.title = title
        self.subtitle = subtitle
        self.stateLabel = stateLabel
        self.progress = progress
        self.current = current
        self.total = total
        self.unit = unit
        self.etaSeconds = etaSeconds
        self.icon = icon
        self.accent = accent
        self.urgency = urgency
        self.expiresIn = expiresIn
    }
}

public struct LiveActivityValidationError: Error, Sendable, Equatable, CustomStringConvertible {
    public var reason: String
    public init(_ reason: String) { self.reason = reason }
    public var description: String { reason }
}

public enum LiveActivitySanitizer {
    public static let protocolVersion = 1
    public static let maximumMessageBytes = 4_096
    public static let maximumIDLength = 64
    public static let maximumSourceLength = 32
    public static let maximumTitleLength = 80
    public static let maximumSubtitleLength = 120
    public static let maximumStateLength = 24
    public static let maximumMeasuredValue: Double = 1e15
    public static let maximumETA: TimeInterval = 7 * 24 * 60 * 60
    public static let expiryRange: ClosedRange<TimeInterval> = 1 ... 24 * 60 * 60

    public static func decode(_ data: Data) -> Result<LiveActivityUpdate, LiveActivityValidationError> {
        guard !data.isEmpty else { return .failure(.init("empty message")) }
        guard data.count <= maximumMessageBytes else { return .failure(.init("message too large")) }
        guard let message = try? JSONDecoder().decode(LiveActivityMessage.self, from: data) else {
            return .failure(.init("malformed message"))
        }
        return validate(message)
    }

    public static func validate(_ message: LiveActivityMessage) -> Result<LiveActivityUpdate, LiveActivityValidationError> {
        if let version = message.version, version > protocolVersion {
            return .failure(.init("unsupported protocol version"))
        }
        guard let command = LiveActivityCommand(rawValue: message.command) else {
            return .failure(.init("unknown command"))
        }
        guard isValidIdentifier(message.id) else {
            return .failure(.init("id must be 1-\(maximumIDLength) characters of A-Z a-z 0-9 . _ : -"))
        }

        var update = LiveActivityUpdate(command: command, id: message.id)
        update.source = text(message.source, maximum: maximumSourceLength)
        update.title = text(message.title, maximum: maximumTitleLength)
        update.subtitle = text(message.subtitle, maximum: maximumSubtitleLength)
        update.stateLabel = text(message.state, maximum: maximumStateLength)

        if let progress = message.progress {
            guard progress.isFinite, (0 ... 1).contains(progress) else {
                return .failure(.init("progress must be between 0 and 1"))
            }
            update.progress = progress
        }
        switch measured(message.current) {
        case .failure(let error): return .failure(error)
        case .success(let value): update.current = value
        }
        switch measured(message.total) {
        case .failure(let error): return .failure(error)
        case .success(let value): update.total = value
        }
        if let current = update.current, let total = update.total, current > total {
            return .failure(.init("current exceeds total"))
        }
        if let unit = message.unit {
            guard let parsed = LiveActivityUnit(rawValue: unit) else {
                return .failure(.init("unknown unit"))
            }
            update.unit = parsed
        }
        if let eta = message.etaSeconds {
            guard eta.isFinite, eta >= 0, eta <= maximumETA else {
                return .failure(.init("etaSeconds out of range"))
            }
            update.etaSeconds = eta
        }
        if let icon = message.icon {
            guard let parsed = LiveActivityIcon(rawValue: icon) else {
                return .failure(.init("unknown icon"))
            }
            update.icon = parsed
        }
        if let accent = message.accent {
            guard let parsed = LiveActivityAccent(rawValue: accent) else {
                return .failure(.init("unknown accent"))
            }
            update.accent = parsed
        }
        if let urgency = message.urgency {
            guard let parsed = LiveActivityUrgency(rawValue: urgency) else {
                return .failure(.init("unknown urgency"))
            }
            update.urgency = parsed
        }
        if let expires = message.expiresInSeconds {
            guard expires.isFinite, expiryRange.contains(expires) else {
                return .failure(.init("expiresInSeconds out of range"))
            }
            update.expiresIn = expires
        }
        if command == .start, update.title == nil {
            return .failure(.init("start requires a title"))
        }
        return .success(update)
    }

    public static func isValidIdentifier(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= maximumIDLength else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "A" ... "Z", "a" ... "z", "0" ... "9", ".", "_", ":", "-": true
            default: false
            }
        }
    }

    /// Bounded, single-line, printable text. Returns nil for empty results.
    public static func text(_ value: String?, maximum: Int) -> String? {
        guard let value else { return nil }
        var scalars = String.UnicodeScalarView()
        var lastWasSpace = false
        for scalar in value.unicodeScalars {
            if isDisallowed(scalar) { continue }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                guard !lastWasSpace else { continue }
                scalars.append(" ")
                lastWasSpace = true
            } else {
                scalars.append(scalar)
                lastWasSpace = false
            }
        }
        let collapsed = String(scalars).trimmingCharacters(in: .whitespaces)
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maximum else { return collapsed }
        return String(collapsed.prefix(max(1, maximum - 1))) + "…"
    }

    private static func isDisallowed(_ scalar: Unicode.Scalar) -> Bool {
        if CharacterSet.controlCharacters.contains(scalar),
           !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            return true
        }
        switch scalar.value {
        // Bidirectional overrides and isolates can visually reorder a title so
        // it misrepresents what is running.
        case 0x202A ... 0x202E, 0x2066 ... 0x2069, 0x200E, 0x200F:
            return true
        // Zero-width characters and the byte-order mark.
        case 0x200B ... 0x200D, 0xFEFF:
            return true
        default:
            return false
        }
    }

    private static func measured(_ value: Double?) -> Result<Int64?, LiveActivityValidationError> {
        guard let value else { return .success(nil) }
        guard value.isFinite, value >= 0, value <= maximumMeasuredValue else {
            return .failure(.init("measured values must be finite, non-negative, and bounded"))
        }
        return .success(Int64(value.rounded(.down)))
    }

    /// One-line JSON acknowledgement written back to the client.
    public static func acknowledgement(error: LiveActivityValidationError?) -> Data {
        var object: [String: Any] = ["ok": error == nil]
        if let error { object["error"] = String(error.reason.prefix(160)) }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return data + Data([10])
    }
}
