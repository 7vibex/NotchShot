import Foundation
import Speech

/// Where a language's on-device model stands right now.
public enum DictationModelAvailability: Sendable, Equatable {
    /// Ready to dictate with.
    case installed
    /// Apple publishes a model for this language; it has not been downloaded.
    case availableToInstall
    /// A download is in flight, 0…1.
    case downloading(progress: Double)
    /// No on-device model exists for this language.
    case unsupported
    /// Speech recognition itself is unavailable on this machine.
    case unavailable

    public var isInstalled: Bool { self == .installed }

    /// Whether offering an Install button makes sense.
    public var isInstallable: Bool {
        switch self {
        case .availableToInstall: true
        case .installed, .downloading, .unsupported, .unavailable: false
        }
    }

    public var title: String {
        switch self {
        case .installed: "Installed"
        case .availableToInstall: "Not installed"
        case .downloading(let p): "Downloading \(Int((p * 100).rounded()))%"
        case .unsupported: "No model for this language"
        case .unavailable: "Speech recognition unavailable"
        }
    }
}

public struct DictationModelStatus: Sendable, Equatable {
    /// The language identifier as stored in Preferences.
    public var requestedIdentifier: String
    /// The locale Speech actually resolved it to, when there is one.
    public var resolvedLocale: Locale?
    public var availability: DictationModelAvailability

    public init(
        requestedIdentifier: String,
        resolvedLocale: Locale? = nil,
        availability: DictationModelAvailability
    ) {
        self.requestedIdentifier = requestedIdentifier
        self.resolvedLocale = resolvedLocale
        self.availability = availability
    }

    public var isInstalled: Bool { availability.isInstalled }

    /// Name to show in the UI, resolved where possible so "System" reads as the
    /// language it actually maps to.
    public var displayName: String {
        DictationModelCatalog.displayName(
            for: resolvedLocale ?? Locale(identifier: requestedIdentifier)
        )
    }
}

public enum DictationModelError: LocalizedError, Equatable {
    /// Every reservation slot is taken and none could be freed.
    case reservationLimitReached(maximum: Int)
    /// The download reported success but the analyzer still cannot use it.
    case unavailableAfterInstall(language: String)

    public var errorDescription: String? {
        switch self {
        case .reservationLimitReached(let maximum):
            "macOS allows \(maximum) dictation languages to be kept ready at once. Remove one in Settings → Dictation, then try again."
        case .unavailableAfterInstall(let language):
            "\(language) downloaded but is still unavailable. Restarting the Mac usually clears this."
        }
    }
}

/// One place that answers "is this language's model installed?" and installs it.
///
/// Settings and the dictation session both go through here so they cannot
/// disagree — Settings reporting "installed" while a session still fails with
/// "language model not installed" is worse than either answer alone.
public enum DictationModelCatalog {

    /// Every language Apple ships an on-device model for, sorted for display.
    public static func supportedLanguages() async -> [Locale] {
        let locales = await SpeechTranscriber.supportedLocales
        return locales.sorted { displayName(for: $0) < displayName(for: $1) }
    }

    public static func displayName(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier)
            ?? locale.identifier
    }

    public static func status(forLanguage identifier: String) async -> DictationModelStatus {
        guard SpeechTranscriber.isAvailable else {
            return DictationModelStatus(requestedIdentifier: identifier, availability: .unavailable)
        }
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: identifier)
        ) else {
            return DictationModelStatus(requestedIdentifier: identifier, availability: .unsupported)
        }

        // `installedLocales` is what `SpeechAnalyzer` itself gates on, so it
        // decides whether dictation can run right now. `AssetInventory.status`
        // answers a different question — it reads `.supported` for a model
        // whose files are already on disk whenever this app holds no
        // reservation for it, which is how a working install got reported as
        // "the current language model is not installed".
        if await isInstalledForAnalyzer(locale) {
            return DictationModelStatus(
                requestedIdentifier: identifier,
                resolvedLocale: locale,
                availability: .installed
            )
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let availability: DictationModelAvailability
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed: availability = .installed
        case .downloading: availability = .downloading(progress: 0)
        case .supported: availability = .availableToInstall
        case .unsupported: availability = .unsupported
        @unknown default: availability = .availableToInstall
        }
        return DictationModelStatus(
            requestedIdentifier: identifier,
            resolvedLocale: locale,
            availability: availability
        )
    }

    /// Downloads and installs the model, reporting progress as it goes.
    ///
    /// Safe to call when the model is already present: it returns immediately.
    public static func install(
        languageIdentifier: String,
        onProgress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw OnDeviceTranscriptionError.unavailable
        }
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: languageIdentifier)
        ) else {
            throw OnDeviceTranscriptionError.unsupportedLocale
        }
        try await install(locale: locale, onProgress: onProgress)
    }

    /// Installs for an already-resolved supported locale.
    public static func install(
        locale: Locale,
        onProgress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)

        // Reserve before inspecting status. A reservation is what keeps the
        // model available to this app, and without one `AssetInventory.status`
        // reports `.supported` even when every file is already on disk — so
        // checking status first sent an already-working language down the
        // download path, where `assetInstallationRequest` correctly returned
        // nil and the whole thing failed as "not installed".
        try await ensureReserved(locale)

        if await isInstalledForAnalyzer(locale) {
            await onProgress(1)
            return
        }

        let initialStatus = await AssetInventory.status(forModules: [transcriber])
        if initialStatus == .installed {
            await onProgress(1)
            return
        }
        guard initialStatus != .unsupported else {
            throw OnDeviceTranscriptionError.unsupportedLocale
        }

        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) else {
            // Nothing left to fetch. Confirm that is because it is already
            // usable rather than reporting a silent success.
            guard await isUsable(locale, transcriber: transcriber) else {
                throw OnDeviceTranscriptionError.languageModelNotInstalled
            }
            await onProgress(1)
            return
        }

        let progressTask = Task {
            while !Task.isCancelled {
                let fraction = request.progress.fractionCompleted
                await onProgress(max(0.02, min(fraction, 0.98)))
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
        defer { progressTask.cancel() }

        try await request.downloadAndInstall()
        try Task.checkCancellation()
        try await ensureReserved(locale)
        guard await isUsable(locale, transcriber: transcriber) else {
            throw DictationModelError.unavailableAfterInstall(language: displayName(for: locale))
        }
        await onProgress(1)
    }

    /// Makes sure the locale holds one of this app's reservation slots.
    ///
    /// A downloaded model is only visible to `SpeechAnalyzer` once reserved,
    /// and the slots are capped. The previous code reserved with `try?` and
    /// discarded the `Bool` result, so hitting the cap left the language
    /// downloaded but permanently unusable — reported forever as "the current
    /// language model is not installed", with no action that could fix it.
    private static func ensureReserved(_ locale: Locale) async throws(DictationModelError) {
        if await isReserved(locale) { return }
        if await reserveSucceeded(locale) { return }

        // Out of slots: free one this session does not need, then retry once.
        let reserved = await AssetInventory.reservedLocales
        let releasable = reserved.first { $0.identifier != locale.identifier }
        guard let releasable else {
            throw DictationModelError.reservationLimitReached(
                maximum: AssetInventory.maximumReservedLocales
            )
        }
        _ = await AssetInventory.release(reservedLocale: releasable)
        guard await reserveSucceeded(locale) else {
            throw DictationModelError.reservationLimitReached(
                maximum: AssetInventory.maximumReservedLocales
            )
        }
    }

    private static func isReserved(_ locale: Locale) async -> Bool {
        let reserved = await AssetInventory.reservedLocales
        return reserved.contains { $0.identifier == locale.identifier }
    }

    /// `reserve` signals failure two ways — a throw and a `false` return — and
    /// both mean the language will not work.
    private static func reserveSucceeded(_ locale: Locale) async -> Bool {
        (try? await AssetInventory.reserve(locale: locale)) == true
    }

    /// Either signal being positive means dictation can run: the analyzer gate
    /// or a fully installed asset set.
    private static func isUsable(_ locale: Locale, transcriber: SpeechTranscriber) async -> Bool {
        if await isInstalledForAnalyzer(locale) { return true }
        return await AssetInventory.status(forModules: [transcriber]) == .installed
    }

    /// The check `SpeechAnalyzerDictationEngine` actually performs before it
    /// will start.
    private static func isInstalledForAnalyzer(_ locale: Locale) async -> Bool {
        let installed = await SpeechTranscriber.installedLocales
        return installed.contains { $0.identifier == locale.identifier }
    }

    /// Languages whose models are on disk and visible to the analyzer.
    public static func installedLanguages() async -> [Locale] {
        await SpeechTranscriber.installedLocales
    }

    /// Languages currently holding a reservation slot, for Settings to show and
    /// let the user free one.
    public static func reservedLanguages() async -> [Locale] {
        await AssetInventory.reservedLocales
    }

    public static var reservationCapacity: Int { AssetInventory.maximumReservedLocales }

    @discardableResult
    public static func release(_ locale: Locale) async -> Bool {
        await AssetInventory.release(reservedLocale: locale)
    }
}
