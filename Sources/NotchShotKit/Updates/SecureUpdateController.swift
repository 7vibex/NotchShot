import Foundation
import Sparkle

/// Keeps updater startup fail-closed in local builds. Release builds become
/// update-capable only after the HTTPS appcast and EdDSA public key have been
/// injected into the assembled bundle by `build_app.sh`.
@MainActor
public final class SecureUpdateController: NSObject, SPUUpdaterDelegate {
    public private(set) var updaterController: SPUStandardUpdaterController?

    public init(bundle: Bundle = .main) {
        super.init()
        guard Self.configurationIsValid(in: bundle) else {
            updaterController = nil
            return
        }
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    public var isConfigured: Bool { updaterController != nil }

    public func checkForUpdates(_ sender: Any?) {
        updaterController?.checkForUpdates(sender)
    }

    public func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        Self.allowedChannels(for: Preferences.shared.updateChannel)
    }

    public static func allowedChannels(for channel: UpdateChannel) -> Set<String> {
        channel == .beta ? ["beta"] : []
    }

    public static func configurationIsValid(in bundle: Bundle) -> Bool {
        guard let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              let decoded = Data(base64Encoded: key), decoded.count == 32 else {
            return false
        }
        return true
    }
}
