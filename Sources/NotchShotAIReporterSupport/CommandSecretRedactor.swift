import Foundation

/// Redacts only the persisted/display copy of a command. The reporter still
/// executes the exact arguments supplied by the user.
public enum CommandSecretRedactor {
    private static let secretOptions: Set<String> = [
        "--token", "--api-key", "--apikey", "--key", "--secret",
        "--password", "--passwd", "--pass", "--auth", "--authorization",
        "--bearer", "--access-token", "--refresh-token", "--client-secret",
        "--private-key", "--user", "--cookie", "-p", "-t", "-u", "-b",
    ]

    private static let sensitiveNames: Set<String> = [
        "authorization", "proxyauthorization", "cookie", "setcookie",
        "xapikey", "apikey", "api_key", "token", "accesstoken",
        "access_token", "refreshtoken", "refresh_token", "password",
        "passwd", "secret", "clientsecret", "client_secret", "privatekey",
        "private_key",
    ]

    public static func redact(_ arguments: [String]) -> [String] {
        var result: [String] = []
        result.reserveCapacity(arguments.count)
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let lowered = argument.lowercased()

            if secretOptions.contains(lowered) {
                result.append(argument)
                if index + 1 < arguments.count {
                    result.append("<redacted>")
                    index += 2
                } else {
                    index += 1
                }
                continue
            }

            if lowered == "-h" || lowered == "--header" {
                result.append(argument)
                if index + 1 < arguments.count {
                    result.append(redactHeader(arguments[index + 1]))
                    index += 2
                } else {
                    index += 1
                }
                continue
            }

            if argument.hasSuffix(":"),
               sensitiveNames.contains(normalizeName(String(argument.dropLast()))) {
                result.append(String(argument.dropLast()) + ": <redacted>")
                if index + 1 < arguments.count,
                   arguments[index + 1].caseInsensitiveCompare("bearer") == .orderedSame,
                   index + 2 < arguments.count {
                    index += 3
                } else {
                    index += min(2, arguments.count - index)
                }
                continue
            }

            if lowered.hasPrefix("-h"), argument.count > 2 {
                result.append(String(argument.prefix(2)) + redactHeader(String(argument.dropFirst(2))))
                index += 1
                continue
            }

            if let separator = argument.firstIndex(of: "=") {
                let name = String(argument[..<separator])
                let value = String(argument[argument.index(after: separator)...])
                let normalized = normalizeName(name)
                if secretOptions.contains(name.lowercased()) || sensitiveNames.contains(normalized) {
                    result.append(name + "=<redacted>")
                    index += 1
                    continue
                }
                if name.lowercased() == "--header" {
                    result.append(name + "=" + redactHeader(value))
                    index += 1
                    continue
                }
            }

            result.append(redactStandalone(argument))
            index += 1
        }
        return result
    }

    /// A bounded activity title/detail can still receive a prompt or explicit
    /// user string rather than a parsed argv. Tokenizing it gives those fields
    /// the same credential suppression without ever touching the source event.
    public static func redactText(_ text: String) -> String {
        redact(text.split(whereSeparator: \Character.isWhitespace).map(String.init))
            .joined(separator: " ")
    }

    private static func redactHeader(_ header: String) -> String {
        guard let separator = header.firstIndex(of: ":") else {
            return looksLikeSecret(header) ? "<redacted>" : header
        }
        let name = String(header[..<separator])
        guard sensitiveNames.contains(normalizeName(name)) else { return header }
        return name + ": <redacted>"
    }

    private static func redactStandalone(_ value: String) -> String {
        if value.contains(":"), redactHeader(value) != value {
            return redactHeader(value)
        }

        if var components = URLComponents(string: value), components.scheme != nil {
            var changed = false
            if components.user != nil {
                components.user = "redacted"
                changed = true
            }
            if components.password != nil {
                components.password = "redacted"
                changed = true
            }
            if let items = components.queryItems {
                components.queryItems = items.map { item in
                    guard sensitiveNames.contains(normalizeName(item.name)) else { return item }
                    changed = true
                    return URLQueryItem(name: item.name, value: "redacted")
                }
            }
            if changed, let redacted = components.string { return redacted }
        }

        return looksLikeSecret(value) ? "<redacted>" : value
    }

    private static func normalizeName(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0 == "_" }
    }

    private static func looksLikeSecret(_ value: String) -> Bool {
        let lowered = value.lowercased()
        for prefix in [
            "sk-", "sk_", "pk_", "ghp_", "gho_", "github_pat_", "xoxb-",
            "xoxp-", "akia", "asia", "bearer ",
        ] where lowered.hasPrefix(prefix) {
            return true
        }
        guard value.count >= 24, !value.hasPrefix("/") else { return false }
        let allowed = value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
                || "-_=+/.".unicodeScalars.contains($0)
        }
        return allowed
            && value.contains(where: \Character.isNumber)
            && value.contains(where: \Character.isLetter)
    }
}
