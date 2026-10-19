import AppKit
import Foundation

/// Small system utilities that report through the island: Caps Lock and
/// keyboard-language bursts, browser downloads, external display brightness,
/// and the Extract and Uninstall drop destinations.
extension AppCoordinator {
    /// Re-applies the Extras toggles. Each service runs only while its toggle
    /// is on, so a switched-off feature costs nothing.
    public func refreshUtilities() {
        let extras = ExtrasPreferences.shared
        keyboardState.onCapsLockChange = { [weak self] isOn in self?.capsLockDidChange(isOn) }
        keyboardState.onInputSourceChange = { [weak self] source in
            self?.presentIslandEvent(Self.inputSourceEvent(name: source.shortName, badge: source.badge))
        }
        keyboardState.update(capsLock: extras.showsCapsLock, inputSource: extras.showsInputSource)

        if extras.showsDownloads {
            downloads.start()
        } else {
            downloads.stop()
        }

        if extras.controlsExternalDisplays {
            displayBrightness.start()
        } else {
            // Restores any software dimming, so turning the feature off
            // never strands a monitor dark.
            displayBrightness.stop()
        }
    }

    func stopUtilities() {
        keyboardState.stop()
        downloads.stop()
        displayBrightness.stop()
    }

    // MARK: Keyboard

    private func capsLockDidChange(_ isOn: Bool) {
        presentIslandEvent(Self.capsLockEvent(isOn: isOn))
    }

    /// Shares the Focus burst's Silent/Ring-style pill, in green.
    static func capsLockEvent(isOn: Bool) -> IslandTransientEvent {
        IslandTransientEvent(
            kind: .capsLock,
            coalescingKey: "capsLock",
            symbolName: isOn ? "capslock.fill" : "capslock",
            title: isOn ? "Caps Lock On" : "Caps Lock Off",
            holdDuration: 1.4
        )
    }

    /// The badge rides in `detail`; the burst draws it as the pill.
    static func inputSourceEvent(name: String, badge: String?) -> IslandTransientEvent {
        IslandTransientEvent(
            kind: .inputSource,
            coalescingKey: "inputSource",
            symbolName: "globe",
            title: name,
            detail: badge,
            holdDuration: 1.4
        )
    }

    // MARK: Extract

    func extractArchives(_ urls: [URL]) {
        let archives = urls.filter(ArchiveExtractor.isArchive)
        guard !archives.isEmpty else {
            present(error: NotchShotError.exportFailed("Drop a ZIP, tar, 7z, RAR or gzip archive to extract it"))
            return
        }
        let label = beginProcessing(archives.count == 1 ? "Extracting" : "Extracting \(archives.count)")
        Task { [weak self] in
            // Off the main actor: a large archive is seconds of disk work.
            let outcomes = await Task.detached(priority: .userInitiated) {
                archives.map { archive in
                    Swift.Result { try ArchiveExtractor.extract(archive) }
                }
            }.value
            guard let self else { return }
            self.endProcessing(label)
            let outputs = outcomes.compactMap { try? $0.get().outputURL }
            let failures = outcomes.compactMap { outcome -> Error? in
                if case .failure(let error) = outcome { return error }
                return nil
            }
            if !outputs.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(outputs)
                self.presentIslandEvent(IslandTransientEvent(
                    kind: .notice,
                    severity: .success,
                    coalescingKey: "extract",
                    symbolName: "archivebox.fill",
                    title: outputs.count == 1 ? "Extracted" : "Extracted \(outputs.count) archives",
                    detail: outputs.count == 1 ? outputs[0].lastPathComponent : nil
                ))
            }
            if let failure = failures.first {
                self.present(error: failure)
            }
        }
    }

    // MARK: Uninstall

    func beginAppRemoval(_ urls: [URL], mode: AppUninstallMode) {
        var apps: [UninstallableApp] = []
        var refusals: [Error] = []
        for url in urls {
            do {
                apps.append(try AppLeftoverScanner.app(at: url))
            } catch {
                refusals.append(error)
            }
        }
        if let refusal = refusals.first {
            present(error: refusal)
        }
        guard !apps.isEmpty else { return }
        let session = AppUninstallSession(apps: apps, mode: mode)
        session.onFinish = { [weak self] session in
            guard case .finished(let count, let bytes) = session.stage else { return }
            let size = bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : nil
            self?.presentIslandEvent(IslandTransientEvent(
                kind: .notice,
                severity: .success,
                coalescingKey: "uninstall",
                symbolName: session.mode == .uninstall ? "trash.fill" : "arrow.counterclockwise",
                title: session.mode == .uninstall
                    ? (session.apps.count == 1 ? "\(session.apps[0].name) removed" : "\(session.apps.count) apps removed")
                    : (session.apps.count == 1 ? "\(session.apps[0].name) reset" : "\(session.apps.count) apps reset"),
                detail: [size.map { "\($0) moved to the Trash" }, count == 1 ? nil : "\(count) items"]
                    .compactMap { $0 }.first
            ))
        }
        session.scan()
        onOpenAppUninstall?(session)
    }
}
