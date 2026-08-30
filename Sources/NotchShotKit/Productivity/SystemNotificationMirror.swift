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
    private static let notificationBannerSubrole = "AXNotificationCenterBanner"
    private static let scanInterval: TimeInterval = 0.45
    private static let maximumAXElements = 240

    private var isEnabled = false
    private var isSessionActive = true
    private var applicationElement: AXUIElement?
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var scanTimer: Timer?
    private var visibleFingerprints: Set<String> = []

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

        let windows = Self.elements(applicationElement, attribute: kAXWindowsAttribute as CFString)
        var budget = Self.maximumAXElements
        var banners: [AXUIElement] = []
        for window in windows {
            Self.collectBanners(from: window, budget: &budget, into: &banners)
            if budget == 0 { break }
        }

        var currentFingerprints: Set<String> = []
        for banner in banners {
            // Banner discovery and banner parsing use separate bounds. A large
            // Notification Center hierarchy must not consume the text budget
            // before a discovered banner can be read.
            var textBudget = Self.maximumAXElements
            let texts = Self.staticTexts(from: banner, budget: &textBudget)
            let description = Self.string(banner, attribute: kAXDescriptionAttribute as CFString)
            guard let content = SystemNotificationBannerParser.parse(
                description: description,
                staticTexts: texts
            ) else { continue }
            currentFingerprints.insert(content.fingerprint)
            guard !visibleFingerprints.contains(content.fingerprint), shouldMirror(content) else { continue }
            onNotification?(SystemNotificationSnapshot(
                sourceName: content.sourceName,
                title: content.title,
                body: content.body
            ))
        }
        visibleFingerprints = currentFingerprints
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
            applicationElement = nil
            observer = nil
            observedPID = nil
            status = .waitingForNotificationCenter
            return
        }
        guard observedPID != app.processIdentifier else {
            status = .monitoring
            return
        }

        detachObserver()
        let element = AXUIElementCreateApplication(app.processIdentifier)
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

    private static func collectBanners(
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

    private static func staticTexts(from element: AXUIElement, budget: inout Int) -> [String] {
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

    private static func elements(_ element: AXUIElement, attribute: CFString) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }
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
