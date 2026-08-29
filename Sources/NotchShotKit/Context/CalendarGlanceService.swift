import AppKit
import EventKit
import Foundation
import Observation

public enum CalendarAccessState: String, Sendable, Equatable {
    case notDetermined
    case granted
    case denied
    case restricted
    case writeOnly

    public var title: String {
        switch self {
        case .notDetermined: "Not requested"
        case .granted: "Granted"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .writeOnly: "Write-only access is insufficient"
        }
    }
}

/// Which calendars the glance follows.
///
/// An empty stored list is ambiguous on its own — it is both the shipped
/// default and the result of switching everything off — so the decision is
/// paired with an explicit "the user has chosen" flag and kept pure.
enum CalendarSelectionPolicy {
    /// Whether a calendar's toggle reads as on.
    static func isSelected(
        _ identifier: String,
        current: [String],
        hasCustomSelection: Bool
    ) -> Bool {
        hasCustomSelection ? current.contains(identifier) : true
    }

    /// The stored list after one toggle. The first edit materialises the
    /// implicit "everything" default into a real list, so removing the last
    /// entry can mean none rather than silently meaning all.
    static func updating(
        current: [String],
        hasCustomSelection: Bool,
        allIdentifiers: [String],
        setting identifier: String,
        to selected: Bool
    ) -> [String] {
        var identifiers = hasCustomSelection ? Set(current) : Set(allIdentifiers)
        if selected { identifiers.insert(identifier) } else { identifiers.remove(identifier) }
        return identifiers.sorted()
    }

    /// The calendars to query, or nil when the user has explicitly chosen none.
    static func resolved<EventCalendar>(
        from calendars: [EventCalendar],
        identifiedBy identifier: (EventCalendar) -> String,
        current: [String],
        hasCustomSelection: Bool
    ) -> [EventCalendar]? {
        guard hasCustomSelection else { return calendars }
        let selected = Set(current)
        let matches = calendars.filter { selected.contains(identifier($0)) }
        return matches.isEmpty ? nil : matches
    }
}

enum CalendarContextPolicy {
    static func snapshot(
        events: [CalendarEventSnapshot],
        now: Date = Date(),
        mayInterruptMedia: Bool
    ) -> ContextSnapshot? {
        let relevant = events
            .filter { $0.endDate > now }
            .sorted { lhs, rhs in
                if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
                return lhs.endDate < rhs.endDate
            }
        // An all-day event starts at midnight, so it sorts ahead of every
        // meeting that day. Headlining it would hide the next real commitment
        // and — because an all-day event is never "imminent" — would also
        // suppress the over-media alert for a meeting minutes away. All-day
        // events stay in the agenda; they just don't win the headline.
        guard let next = relevant.first(where: { !$0.isAllDay }) ?? relevant.first else {
            return nil
        }
        let imminent = !next.isAllDay
            && next.startDate > now
            && next.startDate.timeIntervalSince(now) <= 10 * 60
        return ContextSnapshot(
            kind: .calendar,
            title: next.title,
            subtitle: next.durationDescription(),
            metric: next.timingDescription(now: now).replacingOccurrences(of: "In ", with: ""),
            accentHex: next.colorHex,
            events: agenda(from: relevant, including: next),
            mayInterruptMedia: mayInterruptMedia && imminent
        )
    }

    /// The chronological agenda, guaranteed to contain the headline event even
    /// when enough all-day entries would otherwise crowd it past the limit.
    private static func agenda(
        from relevant: [CalendarEventSnapshot],
        including headline: CalendarEventSnapshot,
        limit: Int = 5
    ) -> [CalendarEventSnapshot] {
        var agenda = Array(relevant.prefix(limit))
        guard !agenda.contains(where: { $0.id == headline.id }) else { return agenda }
        agenda.removeLast()
        agenda.append(headline)
        return agenda.sorted { lhs, rhs in
            if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
            return lhs.endDate < rhs.endDate
        }
    }
}

@MainActor
@Observable
public final class CalendarGlanceService {
    public static let shared = CalendarGlanceService()

    public private(set) var accessState: CalendarAccessState = .notDetermined
    public private(set) var calendars: [CalendarDescriptor] = []
    public private(set) var events: [CalendarEventSnapshot] = []
    public var onSnapshotChange: ((ContextSnapshot?) -> Void)?

    private let store = EKEventStore()
    private var observers: [NSObjectProtocol] = []
    private var started = false

    public init() { refreshAccessState() }

    public func start() {
        guard !started else {
            refresh()
            return
        }
        started = true
        installObservers()
        refreshAccessState()
        if accessState == .granted { refresh() }
    }

    public func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        started = false
        calendars = []
        events = []
        onSnapshotChange?(nil)
    }

    @discardableResult
    public func requestAccess() async -> Bool {
        do {
            let granted = try await store.requestFullAccessToEvents()
            refreshAccessState()
            if granted {
                start()
                refresh()
            }
            return granted
        } catch {
            refreshAccessState()
            return false
        }
    }

    public func refresh() {
        refreshAccessState()
        guard accessState == .granted else {
            calendars = []
            events = []
            onSnapshotChange?(nil)
            return
        }
        let eventCalendars = store.calendars(for: .event)
        calendars = eventCalendars.map { calendar in
            CalendarDescriptor(
                id: calendar.calendarIdentifier,
                title: calendar.title,
                colorHex: Self.colorHex(calendar.cgColor)
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        // EventKit reads a nil calendar list as "all calendars", so an
        // explicitly empty selection is answered here rather than handed over.
        guard let selected = CalendarSelectionPolicy.resolved(
            from: eventCalendars,
            identifiedBy: \.calendarIdentifier,
            current: Preferences.shared.selectedCalendarIdentifiers,
            hasCustomSelection: Preferences.shared.hasCustomCalendarSelection
        ) else {
            events = []
            onSnapshotChange?(nil)
            return
        }
        let now = Date()
        let end = Calendar.autoupdatingCurrent.date(byAdding: .day, value: 31, to: now)
            ?? now.addingTimeInterval(31 * 86_400)
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: selected)
        let hiddenIDs = Set(Preferences.shared.hiddenTitleCalendarIdentifiers)
        events = store.events(matching: predicate).map { event in
            let showsTitle = Preferences.shared.showsCalendarEventTitles
                && !hiddenIDs.contains(event.calendar.calendarIdentifier)
            return CalendarEventSnapshot(
                id: (event.eventIdentifier ?? event.calendarItemIdentifier)
                    + "-" + String(event.startDate.timeIntervalSinceReferenceDate),
                calendarIdentifier: event.calendar.calendarIdentifier,
                title: showsTitle ? (event.title ?? "Untitled Event") : "Busy",
                startDate: event.startDate,
                endDate: event.endDate,
                isAllDay: event.isAllDay,
                colorHex: Self.colorHex(event.calendar.cgColor),
                eventURL: event.url
            )
        }
        .sorted { lhs, rhs in lhs.startDate == rhs.startDate ? lhs.endDate < rhs.endDate : lhs.startDate < rhs.startDate }
        onSnapshotChange?(CalendarContextPolicy.snapshot(
            events: events,
            mayInterruptMedia: Preferences.shared.showsImminentEventsOverMedia
        ))
    }

    public func setCalendarSelected(_ identifier: String, selected: Bool) {
        Preferences.shared.selectedCalendarIdentifiers = CalendarSelectionPolicy.updating(
            current: Preferences.shared.selectedCalendarIdentifiers,
            hasCustomSelection: Preferences.shared.hasCustomCalendarSelection,
            allIdentifiers: calendars.map(\.id),
            setting: identifier,
            to: selected
        )
        Preferences.shared.hasCustomCalendarSelection = true
        refresh()
    }

    /// Restores the default of following every calendar.
    public func selectAllCalendars() {
        Preferences.shared.selectedCalendarIdentifiers = []
        Preferences.shared.hasCustomCalendarSelection = false
        refresh()
    }

    public func setCalendarTitleHidden(_ identifier: String, hidden: Bool) {
        var identifiers = Set(Preferences.shared.hiddenTitleCalendarIdentifiers)
        if hidden { identifiers.insert(identifier) } else { identifiers.remove(identifier) }
        Preferences.shared.hiddenTitleCalendarIdentifiers = identifiers.sorted()
        refresh()
    }

    public func open(_ event: CalendarEventSnapshot) {
        if let url = event.eventURL, NSWorkspace.shared.open(url) { return }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else { return }
        NSWorkspace.shared.openApplication(at: appURL, configuration: .init())
    }

    private func refreshAccessState() {
        accessState = switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .denied: .denied
        case .restricted: .restricted
        case .writeOnly: .writeOnly
        case .notDetermined: .notDetermined
        @unknown default: .restricted
        }
    }

    private func installObservers() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .EKEventStoreChanged,
            .NSCalendarDayChanged,
            .NSSystemTimeZoneDidChange,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
    }

    private static func colorHex(_ cgColor: CGColor) -> String {
        (NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB) ?? .systemBlue).hexString
    }
}
