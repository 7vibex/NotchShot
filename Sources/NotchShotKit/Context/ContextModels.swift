import Foundation

public enum ContextKind: String, Sendable, Codable, Equatable {
    case ai
    case calendar
    case timer
    case voiceNote
    case power
    case audioRoute
    case document
    case network

    public var symbolName: String {
        switch self {
        case .ai: "sparkles"
        case .calendar: "calendar"
        case .timer: "timer"
        case .voiceNote: "waveform.and.mic"
        case .power: "battery.100percent.bolt"
        case .audioRoute: "airpodspro"
        case .document: "doc.text.magnifyingglass"
        case .network: "wifi.slash"
        }
    }
}

public enum FocusTimerState: String, Sendable, Codable, Equatable {
    case running
    case paused
    case completed
}

public struct FocusTimerSnapshot: Sendable, Codable, Equatable {
    public var id: UUID
    public var label: String
    public var state: FocusTimerState
    public var duration: TimeInterval
    public var elapsed: TimeInterval
    public var startedAt: Date

    public init(
        id: UUID = UUID(),
        label: String,
        state: FocusTimerState,
        duration: TimeInterval,
        elapsed: TimeInterval,
        startedAt: Date = Date()
    ) {
        self.id = id
        self.label = label
        self.state = state
        self.duration = duration
        self.elapsed = elapsed
        self.startedAt = startedAt
    }

    public var remaining: TimeInterval { max(0, duration - elapsed) }
}

public enum VoiceNoteState: String, Sendable, Codable, Equatable {
    case recording
    case transcribing
    case completed
    case failed
}

public struct VoiceNoteSnapshot: Sendable, Codable, Equatable {
    public var id: UUID
    public var state: VoiceNoteState
    public var elapsed: TimeInterval
    public var fileURL: URL?
    public var transcript: String?
    public var errorMessage: String?

    public init(
        id: UUID = UUID(),
        state: VoiceNoteState,
        elapsed: TimeInterval = 0,
        fileURL: URL? = nil,
        transcript: String? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.state = state
        self.elapsed = elapsed
        self.fileURL = fileURL
        self.transcript = transcript
        self.errorMessage = errorMessage
    }
}

public enum ContextPresentation: String, Sendable, Codable, Equatable {
    case compact
    case expanded
}

public struct CalendarEventSnapshot: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var calendarIdentifier: String
    public var title: String
    public var startDate: Date
    public var endDate: Date
    public var isAllDay: Bool
    public var colorHex: String
    public var eventURL: URL?

    public init(
        id: String,
        calendarIdentifier: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        colorHex: String,
        eventURL: URL? = nil
    ) {
        self.id = id
        self.calendarIdentifier = calendarIdentifier
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.colorHex = colorHex
        self.eventURL = eventURL
    }

    public func timingDescription(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> String {
        if isAllDay { return "All day" }
        if startDate <= now, endDate > now {
            return "Now · " + Self.durationDescription(endDate.timeIntervalSince(now)) + " left"
        }
        if startDate > now {
            let interval = startDate.timeIntervalSince(now)
            if interval < 86_400 { return "In " + Self.durationDescription(interval) }
        }
        return startDate.formatted(date: .abbreviated, time: .shortened)
    }

    public func durationDescription() -> String {
        isAllDay ? "All day" : Self.durationDescription(endDate.timeIntervalSince(startDate))
    }

    static func durationDescription(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int((interval / 60).rounded(.down)))
        if minutes < 60 { return String(minutes) + "m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0
            ? String(hours) + "h"
            : String(hours) + "h " + String(remainder) + "m"
    }
}

public struct ContextSnapshot: Sendable, Codable, Equatable {
    public var kind: ContextKind
    public var title: String
    public var subtitle: String?
    public var metric: String?
    public var accentHex: String
    public var presentation: ContextPresentation
    public var events: [CalendarEventSnapshot]
    public var aiActivities: [AIActivitySnapshot]
    public var aiRecentActivities: [AIActivitySnapshot]
    public var focusTimer: FocusTimerSnapshot?
    public var voiceNote: VoiceNoteSnapshot?
    /// Battery for the accessory this card is about, when the system reports
    /// one. Nil means "not stated", never "empty".
    public var accessory: AccessoryBattery?
    public var createdAt: Date
    public var expiresAt: Date?
    public var mayInterruptMedia: Bool

    public init(
        kind: ContextKind,
        title: String,
        subtitle: String? = nil,
        metric: String? = nil,
        accentHex: String = "#30D158",
        presentation: ContextPresentation = .compact,
        events: [CalendarEventSnapshot] = [],
        aiActivities: [AIActivitySnapshot] = [],
        aiRecentActivities: [AIActivitySnapshot] = [],
        focusTimer: FocusTimerSnapshot? = nil,
        voiceNote: VoiceNoteSnapshot? = nil,
        accessory: AccessoryBattery? = nil,
        createdAt: Date = Date(),
        expiresAt: Date? = nil,
        mayInterruptMedia: Bool = false
    ) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.metric = metric
        self.accentHex = accentHex
        self.presentation = presentation
        self.events = events
        self.aiActivities = aiActivities
        self.aiRecentActivities = aiRecentActivities
        self.focusTimer = focusTimer
        self.voiceNote = voiceNote
        self.accessory = accessory
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.mayInterruptMedia = mayInterruptMedia
    }

    public var isExpired: Bool { expiresAt.map { $0 <= Date() } ?? false }
}

public struct CalendarDescriptor: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var colorHex: String

    public init(id: String, title: String, colorHex: String) {
        self.id = id
        self.title = title
        self.colorHex = colorHex
    }
}
