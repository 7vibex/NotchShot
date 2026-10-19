import Foundation
import Security

/// The scoped device token NotchShot received when it paired with Crewline.
/// Crewline's root token is never kept; this token can read the workspace,
/// answer runs and upload attachments, and the user can revoke it from
/// Crewline's device list at any time.
public struct CrewlineCredential: Codable, Equatable, Sendable {
    public var deviceID: String
    public var token: String
    public var scopes: [String]
    public var pairedAt: Date
}

enum CrewlineCredentialStore {
    private static let service = "com.notchshot.crewline"
    private static let account = "device"

    static func load() -> CrewlineCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(CrewlineCredential.self, from: data)
    }

    @discardableResult
    static func save(_ credential: CrewlineCredential) -> Bool {
        guard let data = try? JSONEncoder().encode(credential) else { return false }
        delete()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            kSecAttrLabel as String: "NotchShot Crewline pairing",
        ]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
