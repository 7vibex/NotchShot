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

    /// Request bodies often carry credentials in JSON or form fields, so the
    /// value is suppressed wholesale rather than parsed. Options are compared
    /// lowercased, so curl's `-F` is matched by its exact spelling instead:
    /// lowercase `-f` is everyday (`rm -f`, `tail -f`). Anywhere else on a line
    /// `-F` can still be innocent, as `formFlagIsHarmless` decides.
    private static let bodyOptions: Set<String> = [
        "--data", "--data-raw", "--data-binary", "--data-urlencode",
        "--form", "--json", "-d",
    ]
    private static let multipartFormOption = "-F"

    /// Tools whose `-p -t -u -b -d -F` are never credentials, so `mkdir -p dir`
    /// and `git push -u origin main` can be shown and approved as they are.
    /// Deliberately a list of the harmless: a tool not named here (`sshpass -p`,
    /// `sqlcmd -P`, `zip -P`, anything unknown) keeps the short-option rule.
    /// `ssh` is left out because what follows its host is another command.
    private static let ordinaryShortOptionTools: Set<String> = [
        "awk", "cat", "cd", "chmod", "chown", "clang", "cp", "cut", "date", "df",
        "diff", "du", "file", "find", "git", "grep", "head", "ln", "ls", "lsof",
        "make", "mkdir", "mv", "ps", "pwd", "rg", "rm", "sed", "sort", "stat",
        "swift", "swiftc", "tail", "tar", "touch", "tr", "uniq", "wc", "which",
        "xcodebuild",
    ]

    /// Mentioned anywhere, for example inside a quoted `git -c` alias or an
    /// `awk` `system()`, these put the short-option rule back.
    private static let credentialTools: Set<String> = [
        "curl", "wget", "http", "xh", "sshpass", "mysql", "mysqldump", "mariadb",
        "psql", "pg_dump", "redis-cli", "ftp", "sftp", "mongo", "mongosh", "sqlcmd",
        "docker", "podman", "htpasswd", "zip", "unzip", "7z",
    ]

    /// True only when every command on the line is a listed tool. Anything
    /// that can run something this cannot read, such as a substitution or
    /// `find -exec`, counts as not ordinary, which redacts as before.
    private static func shortOptionsAreOrdinary(in text: String) -> Bool {
        for marker in ["`", "$(", "<(", ">("] where text.contains(marker) { return false }
        // `2>&1` and `&>file` are redirections, not command separators.
        let line = text
            .replacingOccurrences(of: ">&", with: ">")
            .replacingOccurrences(of: "&>", with: ">")
        var sawCommand = false
        for segment in line.split(whereSeparator: { $0.isNewline || ";|&()".contains($0) }) {
            let words = segment.split(whereSeparator: \.isWhitespace)
            // Skips `VAR=value` before the command.
            guard let command = words.first(where: { !$0.contains("=") }) else { continue }
            let tool = String(command.split(separator: "/").last ?? command)
            guard ordinaryShortOptionTools.contains(tool) else { return false }
            if tool == "find", words.contains(where: { ["-exec", "-execdir", "-ok", "-okdir"].contains(String($0)) }) {
                return false
            }
            if tool == "git", words.contains("-c") { return false }
            sawCommand = true
        }
        guard sawCommand else { return false }
        let mentioned = line.split { !($0.isLetter || $0.isNumber || "-_.".contains($0)) }
        return !mentioned.contains { credentialTools.contains(String($0)) }
    }

    /// True when every `-F` on the line belongs to a tool for which it is a flag
    /// or a config file (`grep -F`, `ssh -F`). A substitution, a mention of a tool
    /// that takes credentials, or any other command using `-F` keeps the rule.
    private static func formFlagIsHarmless(in text: String) -> Bool {
        for marker in ["`", "$(", "<(", ">("] where text.contains(marker) { return false }
        let line = text
            .replacingOccurrences(of: ">&", with: ">")
            .replacingOccurrences(of: "&>", with: ">")
        let mentioned = line.split { !($0.isLetter || $0.isNumber || "-_.".contains($0)) }
        if mentioned.contains(where: { credentialTools.contains(String($0)) }) { return false }
        for segment in line.split(whereSeparator: { $0.isNewline || ";|&()".contains($0) }) {
            let words = segment.split(whereSeparator: \.isWhitespace)
            guard words.contains(where: isFormFlag) else { continue }
            // Skips `VAR=value`, and `sudo` when a command follows it directly.
            let command = words.drop { $0.contains("=") || $0 == "sudo" }
            guard let first = command.first else { return false }
            let tool = String(first.split(separator: "/").last ?? first)
            let arguments = command.dropFirst()
            if tool == "ssh" || tool == "scp" {
                // What follows the host is another command, whose `-F` is unknown.
                let leading = arguments.prefix { !isFormFlag($0) }
                guard arguments.filter(isFormFlag).count == 1,
                      leading.allSatisfy({ $0.hasPrefix("-") }) else { return false }
            } else if !(ordinaryShortOptionTools.contains(tool) || tool == "egrep" || tool == "fgrep") {
                return false
            } else if tool == "find", words.contains(where: { ["-exec", "-execdir", "-ok", "-okdir"].contains(String($0)) }) {
                return false
            } else if tool == "git", words.contains("-c") {
                return false
            }
        }
        return true
    }

    private static func isFormFlag(_ word: Substring) -> Bool {
        word.hasPrefix(multipartFormOption)
    }

    private static func takesSecretValue(
        _ argument: String,
        ordinaryShortOptions: Bool,
        harmlessFormFlag: Bool
    ) -> Bool {
        if argument == multipartFormOption { return !ordinaryShortOptions && !harmlessFormFlag }
        let lowered = argument.lowercased()
        guard secretOptions.contains(lowered) || bodyOptions.contains(lowered) else { return false }
        return !ordinaryShortOptions || argument.hasPrefix("--")
    }

    private static let sensitiveNames: Set<String> = [
        "authorization", "proxyauthorization", "cookie", "setcookie",
        "xapikey", "apikey", "api_key", "token", "accesstoken",
        "access_token", "refreshtoken", "refresh_token", "password",
        "passwd", "secret", "clientsecret", "client_secret", "privatekey",
        "private_key",
    ]

    /// Components that make a *compound* name credential-shaped even when the
    /// exact spelling is unknown: `--secret-key`, `--db-password`,
    /// `AWS_SECRET_ACCESS_KEY`. Matching is per `-`/`_`/camelCase-free
    /// component so `--keyboard` is untouched while `--signing-key` is not.
    private static let sensitiveComponents: Set<String> = [
        "password", "passwd", "pass", "secret", "token", "apikey",
        "auth", "authorization", "credential", "privatekey", "cookie",
        "bearer", "session", "signature",
    ]

    /// True for exact credential names and for compound names built from a
    /// sensitive component (`--db-password`) or ending in a compound `key`
    /// (`--signing-key`, `--encryption-key`, `BACKUP_KEY`). A bare `key` is
    /// left to the exact `secretOptions` set.
    private static func isSensitiveName(_ value: String) -> Bool {
        if sensitiveNames.contains(normalizeName(value)) { return true }
        let components = value.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        if components.contains(where: sensitiveComponents.contains) { return true }
        return components.count > 1 && components.last == "key"
    }

    public static func redact(_ arguments: [String]) -> [String] {
        let line = arguments.joined(separator: " ")
        return redact(
            arguments,
            ordinaryShortOptions: shortOptionsAreOrdinary(in: line),
            harmlessFormFlag: formFlagIsHarmless(in: line)
        )
    }

    private static func redact(
        _ arguments: [String],
        ordinaryShortOptions: Bool,
        harmlessFormFlag: Bool
    ) -> [String] {
        var result: [String] = []
        result.reserveCapacity(arguments.count)
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let lowered = argument.lowercased()

            if takesSecretValue(
                argument,
                ordinaryShortOptions: ordinaryShortOptions,
                harmlessFormFlag: harmlessFormFlag
            ) {
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

            // A compound long option (`--secret-key`, `--db-password`) carries
            // its credential in the following token. Options with an attached
            // `=` are handled by the assignment branch below.
            if argument.hasPrefix("--"), !argument.contains("="), isSensitiveName(argument) {
                result.append(argument)
                if index + 1 < arguments.count {
                    result.append("<redacted>")
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

            // Attached short-option values (`-uuser:pass`, `-d{...}`) never
            // reach the split-option branch above.
            if !ordinaryShortOptions, argument.count > 2, argument.hasPrefix("-"), !argument.hasPrefix("--") {
                let spelled = String(argument.prefix(2))
                let short = spelled.lowercased()
                if spelled == multipartFormOption, !harmlessFormFlag {
                    result.append(spelled + " <redacted>")
                    index += 1
                    continue
                }
                if secretOptions.contains(short) || bodyOptions.contains(short) {
                    result.append(short + " <redacted>")
                    index += 1
                    continue
                }
            }

            if let separator = argument.firstIndex(of: "=") {
                let name = String(argument[..<separator])
                let value = String(argument[argument.index(after: separator)...])
                // URL-shaped tokens are handled by `redactStandalone` below:
                // their userinfo and query credentials need per-component
                // redaction, and a whole `=`-split would both leak the prefix
                // and delete harmless parameters.
                let isStructuredURL = name.contains("/") || name.contains("?")
                if secretOptions.contains(name.lowercased())
                    || bodyOptions.contains(name.lowercased())
                    || (!isStructuredURL && isSensitiveName(name)) {
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
        redact(
            text.split(whereSeparator: \Character.isWhitespace).map(String.init),
            ordinaryShortOptions: shortOptionsAreOrdinary(in: text),
            harmlessFormFlag: formFlagIsHarmless(in: text)
        )
        .joined(separator: " ")
    }

    private static func redactHeader(_ header: String) -> String {
        guard let separator = header.firstIndex(of: ":") else {
            return looksLikeSecret(header) ? "<redacted>" : header
        }
        let name = String(header[..<separator])
        guard isSensitiveName(name) else { return header }
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
                    guard isSensitiveName(item.name) else { return item }
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
            "xoxp-", "bearer ",
        ] where lowered.hasPrefix(prefix) {
            return true
        }
        if looksLikeAWSAccessKey(value) { return true }
        guard value.count >= 24, !value.hasPrefix("/"), !looksLikeRelativeFilePath(value) else { return false }
        let allowed = value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
                || "-_=+/.".unicodeScalars.contains($0)
        }
        return allowed
            && value.contains(where: \Character.isNumber)
            && value.contains(where: \Character.isLetter)
    }

    /// `AKIA` or `ASIA` and sixteen more capitals or digits. Matching the bare
    /// prefix redacted the word "Asia".
    private static func looksLikeAWSAccessKey(_ value: String) -> Bool {
        guard value.hasPrefix("AKIA") || value.hasPrefix("ASIA") else { return false }
        let rest = value.dropFirst(4).prefix(16)
        return rest.count == 16 && rest.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    /// `Sources/Foo/Bar/H264Encoder.swift`. Base64 can hold `/`, `+` and `=`
    /// but no dot, so a secret does not end up looking like this.
    private static func looksLikeRelativeFilePath(_ value: String) -> Bool {
        guard value.contains("/"), !value.contains("="), !value.contains("+"),
              let name = value.split(separator: "/").last,
              let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let fileExtension = name[name.index(after: dot)...]
        return (1 ... 8).contains(fileExtension.count)
            && fileExtension.first?.isLetter == true
            && fileExtension.allSatisfy { $0.isLetter || $0.isNumber }
    }
}
