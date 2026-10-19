import AppKit
@preconcurrency import ApplicationServices
import Foundation
import Observation

public struct SystemNotificationSnapshot: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sourceName: String
    public let title: String
    public let body: String
    public let receivedAt: Date
    /// How many banners from this sender the row stands for. A second message
    /// from the same person bumps the badge instead of adding a row.
    public var groupCount: Int = 1
    /// Other senders shown under this one, newest first. Empty for a single
    /// banner, which is the card every notification used to be.
    public var earlier: [SystemNotificationSnapshot] = []
    /// Senders that arrived in the same burst but did not fit the stack.
    public var overflowCount: Int = 0
    /// Set when the banner macOS is showing offers its own Reply action, so
    /// the notch can open that reply field. Nil for banners without one.
    public var replyKey: String?

    /// Every row the stack draws, this one first.
    public var rows: [SystemNotificationSnapshot] {
        var head = self
        head.earlier = []
        return [head] + earlier
    }

    /// Groups banners by source and sender, so a thread reads as one row.
    public var groupKey: String {
        [sourceName, title]
            .map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
            .joined(separator: "\u{001F}")
    }

    public init(
        id: UUID = UUID(),
        sourceName: String,
        title: String,
        body: String,
        receivedAt: Date = Date()
    ) {
        let boundedSource = String(sourceName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let resolvedSource = boundedSource.isEmpty ? "Notification" : boundedSource
        let boundedTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        self.id = id
        self.sourceName = resolvedSource
        self.title = boundedTitle.isEmpty ? resolvedSource : boundedTitle
        self.body = String(body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        self.receivedAt = receivedAt
    }
}

struct SystemNotificationBannerContent: Sendable, Equatable {
    var sourceName: String
    var title: String
    var body: String

    var fingerprint: String {
        [sourceName, title, body]
            .map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
            .joined(separator: "\u{001F}")
    }
}

struct SystemNotificationQueue: Sendable, Equatable {
    private(set) var current: SystemNotificationSnapshot?
    private(set) var pending: [SystemNotificationSnapshot] = []
    let pendingLimit: Int

    init(pendingLimit: Int = 20) {
        self.pendingLimit = max(1, pendingLimit)
    }

    @discardableResult
    mutating func enqueue(_ snapshot: SystemNotificationSnapshot) -> Bool {
        guard !containsEquivalent(snapshot) else { return false }
        guard current != nil else {
            current = snapshot
            return true
        }
        pending.append(snapshot)
        if pending.count > pendingLimit {
            pending.removeFirst(pending.count - pendingLimit)
        }
        return true
    }

    mutating func advance() {
        current = pending.isEmpty ? nil : pending.removeFirst()
    }

    mutating func removeAll() {
        current = nil
        pending.removeAll(keepingCapacity: false)
    }

    /// Everything waiting, shown at once the way the Dynamic Island stacks
    /// messages: one row per sender, newest sender on top, with a count when
    /// a sender sent more than one. `nil` when nothing is queued.
    func presented(rowLimit: Int = 3) -> SystemNotificationSnapshot? {
        let all = ([current].compactMap { $0 } + pending).sorted { $0.receivedAt > $1.receivedAt }
        var order: [String] = []
        var groups: [String: SystemNotificationSnapshot] = [:]
        for snapshot in all {
            let key = snapshot.groupKey
            if var group = groups[key] {
                group.groupCount += 1
                groups[key] = group
            } else {
                order.append(key)
                groups[key] = snapshot
            }
        }
        let rows = order.compactMap { groups[$0] }
        guard var head = rows.first else { return nil }
        let limit = max(1, rowLimit)
        head.earlier = Array(rows.dropFirst().prefix(limit - 1))
        head.overflowCount = max(0, rows.count - limit)
        return head
    }

    /// Drops every banner from one sender, after the user opened that row.
    mutating func removeGroup(_ key: String) {
        let remaining = ([current].compactMap { $0 } + pending).filter { $0.groupKey != key }
        current = remaining.first
        pending = Array(remaining.dropFirst())
    }

    private func containsEquivalent(_ snapshot: SystemNotificationSnapshot) -> Bool {
        current.map { Self.sameContent($0, snapshot) } == true
            || pending.contains { Self.sameContent($0, snapshot) }
    }

    private static func sameContent(
        _ lhs: SystemNotificationSnapshot,
        _ rhs: SystemNotificationSnapshot
    ) -> Bool {
        lhs.sourceName == rhs.sourceName && lhs.title == rhs.title && lhs.body == rhs.body
    }
}

/// Converts Notification Center's bounded Accessibility text into the payload
/// the notch may show. The parser is deliberately independent of AX so the
/// privacy and truncation behavior remains deterministic in tests.
enum SystemNotificationBannerParser {
    static func parse(description: String?, staticTexts: [String]) -> SystemNotificationBannerContent? {
        let texts = uniqueBounded(staticTexts, limit: 12, length: 500)
        guard let first = texts.first else { return nil }

        let source = sourceName(from: description, firstVisibleText: first)
        let title = String(first.prefix(160))
        let body = String(texts.dropFirst().joined(separator: " — ").prefix(500))
        return SystemNotificationBannerContent(
            sourceName: source.isEmpty ? "Notification" : String(source.prefix(80)),
            title: title,
            body: body
        )
    }

    private static func uniqueBounded(_ values: [String], limit: Int, length: Int) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for raw in values {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let bounded = String(value.prefix(length))
            guard seen.insert(bounded).inserted else { continue }
            result.append(bounded)
            if result.count == limit { break }
        }
        return result
    }

    private static func sourceName(from description: String?, firstVisibleText: String) -> String {
        guard let description else { return "" }
        let cleaned = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = cleaned.range(of: firstVisibleText) else { return "" }
        return cleaned[..<range.lowerBound]
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }
}

public enum SystemNotificationMirrorStatus: Sendable, Equatable {
    case disabled
    case accessibilityRequired
    case pausedWhileLocked
    case waitingForNotificationCenter
    case monitoring

    public var title: String {
        switch self {
        case .disabled: "Off"
        case .accessibilityRequired: "Accessibility required"
        case .pausedWhileLocked: "Paused while locked"
        case .waitingForNotificationCenter: "Waiting for Notification Center"
        case .monitoring: "Mirroring visible banners"
        }
    }

    public var needsAccessibility: Bool { self == .accessibilityRequired }
}

/// Best-effort, opt-in mirror for banners macOS is visibly presenting.
///
/// `UNUserNotificationCenter` is scoped to this app, so cross-app banners are
/// available only through Notification Center's Accessibility hierarchy. The
/// text is never persisted or logged, and monitoring stops before the session
/// locks. Focus-suppressed notifications and hidden history are intentionally
/// outside this contract because macOS never presents them to Accessibility.
@MainActor
@Observable
public final class SystemNotificationMirror {
    public static let shared = SystemNotificationMirror()

    public private(set) var status: SystemNotificationMirrorStatus = .disabled
    public var onNotification: ((SystemNotificationSnapshot) -> Void)?

    private static let notificationCenterBundleID = "com.apple.notificationcenterui"
    private nonisolated static let notificationBannerSubrole = "AXNotificationCenterBanner"
    private static let scanInterval: TimeInterval = 0.45
    private nonisolated static let maximumAXElements = 240

    private var isEnabled = false
    private var isSessionActive = true
    private var applicationElement: AXUIElement?
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var scanTimer: Timer?
    private var visibleFingerprints: Set<String> = []
    /// Banners on screen that offer Reply, by fingerprint, with the AX
    /// action's exact name. Rebuilt on every scan, so a banner that has gone
    /// can never be acted on.
    private var replyTargets: [String: (element: AXElementBox, action: String)] = [:]
    /// Walking Notification Center's hierarchy is hundreds of cross-process
    /// Accessibility calls. On the main thread that cost the island frames
    /// every scan, and a busy Notification Center could stall the whole
    /// interface for the length of the AX timeout, so the walk runs here.
    private let scanQueue = DispatchQueue(label: "NotchShot.NotificationMirror", qos: .utility)
    private var isScanning = false
    private var needsRescan = false
    /// Bumped whenever monitoring stops, so a walk already in flight cannot
    /// report banners into a session that has since ended.
    private var scanGeneration = 0
    /// Per-call ceiling on Notification Center's answers. The default is
    /// six seconds; a banner that cannot be read in this long is skipped
    /// and picked up by a later scan.
    private static let messagingTimeout: Float = 0.5

    private init() {}

    public func setEnabled(_ enabled: Bool, requestAccessibility: Bool = false) {
        isEnabled = enabled
        if enabled, requestAccessibility, !AXIsProcessTrusted() {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        reconcile()
    }

    public func setSessionActive(_ active: Bool) {
        guard isSessionActive != active else { return }
        isSessionActive = active
        reconcile()
    }

    public func refreshPermission() {
        guard isEnabled else { return }
        reconcile()
    }

    fileprivate func scanNow() {
        guard isEnabled, isSessionActive else { return }
        guard AXIsProcessTrusted() else {
            stopMonitoring()
            status = .accessibilityRequired
            return
        }
        attachIfNeeded()
        guard let applicationElement else { return }
        guard !isScanning else {
            needsRescan = true
            return
        }
        isScanning = true
        let generation = scanGeneration
        let application = AXElementBox(element: applicationElement)
        scanQueue.async { [weak self] in
            let banners = Self.readBanners(in: application.element)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishScan(banners, generation: generation) }
            }
        }
    }

    private func finishScan(_ banners: [ScannedBanner], generation: Int) {
        isScanning = false
        // A request that arrived mid-walk runs now, even when this walk's
        // result is stale because monitoring restarted underneath it.
        defer {
            if needsRescan {
                needsRescan = false
                scanNow()
            }
        }
        guard generation == scanGeneration, isEnabled, isSessionActive else { return }
        var currentFingerprints: Set<String> = []
        replyTargets.removeAll()
        for banner in banners {
            let content = banner.content
            currentFingerprints.insert(content.fingerprint)
            if let action = banner.replyAction {
                replyTargets[content.fingerprint] = (banner.element, action)
            }
            guard !visibleFingerprints.contains(content.fingerprint), shouldMirror(content) else { continue }
            var snapshot = SystemNotificationSnapshot(
                sourceName: content.sourceName,
                title: content.title,
                body: content.body
            )
            snapshot.replyKey = banner.replyAction == nil ? nil : content.fingerprint
            onNotification?(snapshot)
        }
        visibleFingerprints = currentFingerprints
    }

    /// The Accessibility walk itself. Runs on `scanQueue`, never the main
    /// thread; touches nothing but its argument.
    /// Opens the reply field macOS itself attaches to a banner — the same as
    /// hovering the banner and choosing Reply — so the message is typed and
    /// routed by the posting app, never guessed at by NotchShot. False when
    /// the banner has already gone.
    public func performReply(for snapshot: SystemNotificationSnapshot) async -> Bool {
        guard let key = snapshot.replyKey, let target = replyTargets[key] else { return false }
        let element = target.element
        let action = target.action
        return await withCheckedContinuation { continuation in
            scanQueue.async {
                let result = AXUIElementPerformAction(element.element, action as CFString)
                continuation.resume(returning: result == .success)
            }
        }
    }

    /// A banner's AX action that replies. Notification Center publishes
    /// custom actions as "Name:Reply\nTarget:…"; the localized name is
    /// matched loosely, and the raw action string is what gets performed.
    nonisolated static func replyAction(in actionNames: [String]) -> String? {
        let replyWords = ["reply", "antworten", "répondre", "responder", "rispondi", "返信", "回复", "回覆", "답장"]
        return actionNames.first { name in
            let label = name
                .components(separatedBy: "\n")
                .first { $0.hasPrefix("Name:") }
                .map { String($0.dropFirst("Name:".count)) } ?? name
            let folded = label.lowercased()
            return replyWords.contains { folded.contains($0) }
        }
    }

    private nonisolated static func readBanners(in application: AXUIElement) -> [ScannedBanner] {
        let windows = elements(application, attribute: kAXWindowsAttribute as CFString)
        var budget = maximumAXElements
        var banners: [AXUIElement] = []
        for window in windows {
            collectBanners(from: window, budget: &budget, into: &banners)
            if budget == 0 { break }
        }
        return banners.compactMap { banner in
            // Banner discovery and banner parsing use separate bounds. A large
            // Notification Center hierarchy must not consume the text budget
            // before a discovered banner can be read.
            var textBudget = maximumAXElements
            let texts = staticTexts(from: banner, budget: &textBudget)
            let description = string(banner, attribute: kAXDescriptionAttribute as CFString)
            guard let content = SystemNotificationBannerParser.parse(description: description, staticTexts: texts) else {
                return nil
            }
            var names: CFArray?
            let actions = AXUIElementCopyActionNames(banner, &names) == .success ? (names as? [String] ?? []) : []
            return ScannedBanner(content: content, replyAction: replyAction(in: actions), element: AXElementBox(element: banner))
        }
    }

    private func reconcile() {
        stopMonitoring()
        guard isEnabled else {
            status = .disabled
            return
        }
        guard isSessionActive else {
            status = .pausedWhileLocked
            return
        }
        guard AXIsProcessTrusted() else {
            status = .accessibilityRequired
            return
        }
        startScanTimer()
        attachIfNeeded()
        scanNow()
    }

    private func startScanTimer() {
        let timer = Timer(timeInterval: Self.scanInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scanNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        scanTimer = timer
    }

    private func attachIfNeeded() {
        let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.notificationCenterBundleID
        ).first
        guard let app else {
            // Notification Center quit: remove the observer's run-loop source
            // before dropping it, or the source stays attached to a dead PID.
            detachObserver()
            status = .waitingForNotificationCenter
            return
        }
        guard observedPID != app.processIdentifier else {
            status = .monitoring
            return
        }

        detachObserver()
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        var newObserver: AXObserver?
        guard AXObserverCreate(
            app.processIdentifier,
            systemNotificationObserverCallback,
            &newObserver
        ) == .success, let newObserver else {
            applicationElement = element
            observedPID = app.processIdentifier
            status = .monitoring
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in [kAXWindowCreatedNotification, kAXCreatedNotification] {
            _ = AXObserverAddNotification(
                newObserver,
                element,
                notification as CFString,
                refcon
            )
        }
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(newObserver),
            .commonModes
        )
        applicationElement = element
        observer = newObserver
        observedPID = app.processIdentifier
        status = .monitoring
    }

    private func shouldMirror(_ content: SystemNotificationBannerContent) -> Bool {
        let ownName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "NotchShot"
        return content.sourceName.localizedCaseInsensitiveCompare(ownName) != .orderedSame
    }

    private func stopMonitoring() {
        scanTimer?.invalidate()
        scanTimer = nil
        scanGeneration += 1
        needsRescan = false
        detachObserver()
        visibleFingerprints.removeAll()
    }

    private func detachObserver() {
        if let observer {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }
        observer = nil
        applicationElement = nil
        observedPID = nil
    }

    private nonisolated static func collectBanners(
        from element: AXUIElement,
        budget: inout Int,
        into result: inout [AXUIElement]
    ) {
        guard budget > 0 else { return }
        budget -= 1
        if string(element, attribute: kAXSubroleAttribute as CFString) == notificationBannerSubrole {
            result.append(element)
            return
        }
        for child in elements(element, attribute: kAXChildrenAttribute as CFString) {
            collectBanners(from: child, budget: &budget, into: &result)
            if budget == 0 { return }
        }
    }

    private nonisolated static func staticTexts(from element: AXUIElement, budget: inout Int) -> [String] {
        guard budget > 0 else { return [] }
        budget -= 1
        var result: [String] = []
        if string(element, attribute: kAXRoleAttribute as CFString) == kAXStaticTextRole as String,
           let value = string(element, attribute: kAXValueAttribute as CFString) {
            result.append(value)
        }
        for child in elements(element, attribute: kAXChildrenAttribute as CFString) {
            result.append(contentsOf: staticTexts(from: child, budget: &budget))
            if budget == 0 { break }
        }
        return result
    }

    private nonisolated static func elements(_ element: AXUIElement, attribute: CFString) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private nonisolated static func string(_ element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }
}

/// One banner read by a scan: its text, and how to reply to it if it can.
private struct ScannedBanner: @unchecked Sendable {
    var content: SystemNotificationBannerContent
    var replyAction: String?
    var element: AXElementBox
}

/// Carries an `AXUIElement` to the scan queue. The element is an immutable
/// reference to another process's UI, and the Accessibility API may be called
/// from any thread.
private struct AXElementBox: @unchecked Sendable {
    let element: AXUIElement
}

private func systemNotificationObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let mirror = Unmanaged<SystemNotificationMirror>.fromOpaque(refcon).takeUnretainedValue()
    DispatchQueue.main.async {
        MainActor.assumeIsolated { mirror.scanNow() }
    }
}
