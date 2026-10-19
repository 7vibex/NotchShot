import AppKit
import Foundation
import Observation

/// An application bundle dropped on the notch.
public struct UninstallableApp: Sendable, Equatable, Identifiable {
    public var url: URL
    public var name: String
    public var bundleIdentifier: String
    public var version: String?

    public var id: URL { url }
}

/// One file or folder an app left in the user's Library.
public struct AppLeftover: Sendable, Equatable, Identifiable {
    public enum Confidence: Sendable, Equatable {
        /// Named after the bundle identifier: certainly this app's.
        case exact
        /// Named after the app's display name, or a shared container that
        /// mentions its identifier: probably this app's, possibly shared.
        case likely
    }

    public var url: URL
    public var category: String
    public var confidence: Confidence
    /// Unknown for other apps' sandbox containers, which macOS guards: sizing
    /// one would raise an "access data from other apps" prompt.
    public var byteCount: Int64?
    public var appURL: URL

    public var id: URL { url }
}

public enum AppUninstallMode: Sendable, Equatable {
    /// The app and its leftovers.
    case uninstall
    /// Only the leftovers: the app starts over as if newly installed.
    case reset

    public var title: String {
        switch self {
        case .uninstall: "Uninstall"
        case .reset: "Reset"
        }
    }
}

/// Why an app can't be removed from the notch.
public enum AppUninstallRefusal: LocalizedError, Equatable {
    case notAnApp(String)
    case appleApp(String)
    case notchShot

    public var errorDescription: String? {
        switch self {
        case .notAnApp(let name): "\(name) isn't an app"
        case .appleApp(let name): "\(name) is part of macOS and can't be removed"
        case .notchShot: "NotchShot can't uninstall itself. Quit it and drag it to the Trash."
        }
    }
}

/// Finds what an app leaves behind. Matching is by name only — nothing is
/// opened or read — and stays inside the user's own Library.
enum AppLeftoverScanner {
    static func app(at url: URL, ownBundleIdentifier: String? = Bundle.main.bundleIdentifier) throws -> UninstallableApp {
        let fallbackName = url.deletingPathExtension().lastPathComponent
        guard url.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: url),
              let identifier = bundle.bundleIdentifier, !identifier.isEmpty else {
            throw AppUninstallRefusal.notAnApp(fallbackName)
        }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? fallbackName
        if identifier == ownBundleIdentifier { throw AppUninstallRefusal.notchShot }
        if isProtected(identifier: identifier, url: url) { throw AppUninstallRefusal.appleApp(name) }
        return UninstallableApp(
            url: url,
            name: name,
            bundleIdentifier: identifier,
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        )
    }

    static func isProtected(identifier: String, url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        return identifier.hasPrefix("com.apple.")
            || path.hasPrefix("/System/")
            || path.hasPrefix("/Library/Apple/")
    }

    /// Names in `~/Library` that belong to `app`.
    ///
    /// `listing` returns the entries of a Library subfolder; tests pass a
    /// fake, production lists the disk.
    static func leftovers(
        for app: UninstallableApp,
        library: URL,
        listing: (URL) -> [String]
    ) -> [AppLeftover] {
        let identifier = app.bundleIdentifier
        let lowerIdentifier = identifier.lowercased()
        let lowerName = app.name.lowercased()
        // A short or generic name ("Code", "Mail") would sweep up other
        // software's folders; those apps are matched by identifier only.
        let matchesName = lowerName.count >= 4 && !genericNames.contains(lowerName)
        var found: [AppLeftover] = []

        func scan(_ folder: String, _ category: String, _ match: (String) -> AppLeftover.Confidence?) {
            let base = library.appendingPathComponent(folder, isDirectory: true)
            for entry in listing(base) {
                guard let confidence = match(entry) else { continue }
                found.append(AppLeftover(
                    url: base.appendingPathComponent(entry),
                    category: category,
                    confidence: confidence,
                    byteCount: nil,
                    appURL: app.url
                ))
            }
        }

        func byIdentifier(_ entry: String, suffixes: [String] = [""]) -> Bool {
            let lower = entry.lowercased()
            return suffixes.contains { lower == lowerIdentifier + $0 }
        }

        scan("Application Support", "Application Support") { entry in
            if byIdentifier(entry) { return .exact }
            return matchesName && entry.lowercased() == lowerName ? .likely : nil
        }
        scan("Caches", "Caches") { entry in
            if byIdentifier(entry) { return .exact }
            return matchesName && entry.lowercased() == lowerName ? .likely : nil
        }
        scan("Logs", "Logs") { entry in
            if byIdentifier(entry) { return .exact }
            return matchesName && entry.lowercased() == lowerName ? .likely : nil
        }
        scan("Preferences", "Preferences") { byIdentifier($0, suffixes: [".plist"]) ? .exact : nil }
        scan("Preferences/ByHost", "Preferences") { entry in
            let lower = entry.lowercased()
            return lower.hasPrefix(lowerIdentifier + ".") && lower.hasSuffix(".plist") ? .exact : nil
        }
        scan("Saved Application State", "Saved window state") { byIdentifier($0, suffixes: [".savedstate"]) ? .exact : nil }
        scan("HTTPStorages", "Web data") { byIdentifier($0, suffixes: ["", ".binarycookies"]) ? .exact : nil }
        scan("WebKit", "Web data") { byIdentifier($0) ? .exact : nil }
        scan("Cookies", "Web data") { byIdentifier($0, suffixes: [".binarycookies"]) ? .exact : nil }
        scan("Containers", "Sandbox container") { entry in
            // The app's own container and its extensions' (`<id>.widget`).
            let lower = entry.lowercased()
            return lower == lowerIdentifier || lower.hasPrefix(lowerIdentifier + ".") ? .exact : nil
        }
        scan("Application Scripts", "App scripts") { entry in
            let lower = entry.lowercased()
            return lower == lowerIdentifier || lower.hasPrefix(lowerIdentifier + ".") ? .exact : nil
        }
        scan("Group Containers", sharedContainerCategory) { entry in
            // Shared between a developer's apps, so never more than likely.
            entry.lowercased().contains(lowerIdentifier) ? .likely : nil
        }
        scan("LaunchAgents", "Login item") { entry in
            let lower = entry.lowercased()
            return lower.hasPrefix(lowerIdentifier) && lower.hasSuffix(".plist") ? .exact : nil
        }
        return found
    }

    static let sharedContainerCategory = "Shared container"

    static let genericNames: Set<String> = [
        "code", "mail", "notes", "music", "photos", "files", "terminal", "editor", "browser",
        "player", "settings", "preferences", "support", "default", "common", "shared", "cache",
        "caches", "logs", "data", "tools", "utilities", "helper", "update", "updater", "google",
        "microsoft", "adobe", "apple", "python", "java", "node",
    ]

    static func diskListing(_ folder: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    }

    /// Allocated size of a file or folder tree. Skips sandbox containers:
    /// see `AppLeftover.byteCount`.
    static func size(of url: URL) -> Int64? {
        let path = url.path
        if path.contains("/Library/Containers/") || path.contains("/Library/Group Containers/") { return nil }
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        guard values.isDirectory == true else { return Int64(values.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        )
        while let item = enumerator?.nextObject() as? URL {
            total += Int64((try? item.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

/// One uninstall or reset, from the notch drop to the Trash.
@MainActor
@Observable
public final class AppUninstallSession: Identifiable {
    public enum Stage: Equatable {
        case scanning
        case ready
        case removing
        case finished(itemCount: Int, byteCount: Int64)
        case failed(String)
    }

    public let id = UUID()
    public let mode: AppUninstallMode
    public let apps: [UninstallableApp]
    public private(set) var leftovers: [AppLeftover] = []
    public private(set) var appSizes: [URL: Int64] = [:]
    public var selection: Set<URL> = []
    public private(set) var stage: Stage = .scanning
    public private(set) var runningApps: [UninstallableApp] = []

    @ObservationIgnored public var onFinish: ((AppUninstallSession) -> Void)?

    public init(apps: [UninstallableApp], mode: AppUninstallMode) {
        self.apps = apps
        self.mode = mode
    }

    public var title: String {
        let subject = apps.count == 1 ? apps[0].name : "\(apps.count) apps"
        return "\(mode.title) \(subject)"
    }

    public var selectedByteCount: Int64 {
        var total: Int64 = 0
        for url in selection {
            if let size = appSizes[url] { total += size }
            if let size = leftovers.first(where: { $0.url == url })?.byteCount { total += size }
        }
        return total
    }

    public func leftovers(for app: UninstallableApp) -> [AppLeftover] {
        leftovers.filter { $0.appURL == app.url }
    }

    public func scan() {
        stage = .scanning
        refreshRunningApps()
        let apps = self.apps
        let mode = self.mode
        Task.detached(priority: .userInitiated) {
            let library = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
            var found: [AppLeftover] = []
            var sizes: [URL: Int64] = [:]
            for app in apps {
                for var leftover in AppLeftoverScanner.leftovers(for: app, library: library, listing: AppLeftoverScanner.diskListing) {
                    leftover.byteCount = AppLeftoverScanner.size(of: leftover.url)
                    found.append(leftover)
                }
                if mode == .uninstall {
                    sizes[app.url] = AppLeftoverScanner.size(of: app.url)
                }
            }
            await MainActor.run { [found, sizes] in
                self.leftovers = found
                self.appSizes = sizes
                // Shared containers stay unticked: a developer's other apps
                // read them too. Name matches are ticked; the generic-name
                // guard keeps those to folders that are plainly the app's.
                var selection = Set(found.filter { $0.category != AppLeftoverScanner.sharedContainerCategory }.map(\.url))
                if mode == .uninstall { selection.formUnion(apps.map(\.url)) }
                self.selection = selection
                self.stage = .ready
            }
        }
    }

    public func refreshRunningApps() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        runningApps = apps.filter { running.contains($0.bundleIdentifier) }
    }

    /// Asks running apps to quit, the same request as Quit in their menu, so
    /// they can save first.
    public func quitRunningApps() async {
        for app in runningApps {
            for running in NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier) {
                running.terminate()
            }
        }
        for _ in 0 ..< 40 {
            refreshRunningApps()
            if runningApps.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// Moves the selection to the Trash. Nothing is deleted outright, so a
    /// mistake is one "Put Back" away.
    public func perform() async {
        refreshRunningApps()
        guard runningApps.isEmpty else {
            stage = .failed("Quit \(runningApps.map(\.name).joined(separator: ", ")) first.")
            return
        }
        // Leftovers first: if the app itself needs a password the user can
        // cancel, and the data is gone either way, matching their request.
        let order = leftovers.map(\.url).filter { selection.contains($0) } + apps.map(\.url).filter { selection.contains($0) }
        guard !order.isEmpty else { return }
        stage = .removing
        let bytes = selectedByteCount
        var moved = 0
        var failures: [String] = []
        for url in order {
            do {
                _ = try await NSWorkspace.shared.recycle([url])
                moved += 1
            } catch {
                failures.append(url.lastPathComponent)
            }
        }
        if failures.isEmpty {
            stage = .finished(itemCount: moved, byteCount: bytes)
            onFinish?(self)
        } else {
            stage = .failed("Couldn't move \(failures.prefix(3).joined(separator: ", "))\(failures.count > 3 ? " and \(failures.count - 3) more" : "") to the Trash. Try those in Finder, which can ask for your password.")
        }
    }
}
