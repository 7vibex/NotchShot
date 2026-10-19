import Foundation

/// The numbers Claude Code hands its status line command, reduced to what the
/// notch's usage rings draw. Claude sends rate limits only on Pro and Max
/// plans and only after the session's first response, so every field is
/// optional.
public struct ClaudeStatusSnapshot: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        public var usedPercent: Double
        public var resetsAt: Date?

        public init(usedPercent: Double, resetsAt: Date?) {
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
        }
    }

    public var sessionID: String
    public var model: String?
    public var workspace: String?
    public var contextPercent: Double?
    public var costUSD: Double?
    public var fiveHour: Window?
    public var sevenDay: Window?
    public var updatedAt: Date

    public init(
        sessionID: String,
        model: String? = nil,
        workspace: String? = nil,
        contextPercent: Double? = nil,
        costUSD: Double? = nil,
        fiveHour: Window? = nil,
        sevenDay: Window? = nil,
        updatedAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.model = model
        self.workspace = workspace
        self.contextPercent = contextPercent
        self.costUSD = costUSD
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.updatedAt = updatedAt
    }
}

public enum ClaudeStatusLine {
    public static let directoryName = "Claude Status"
    public static let maximumInputBytes = 256 * 1_024

    public static func directory(base: URL) -> URL {
        base.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Reads Claude's status line JSON. Returns nil without a session ID,
    /// since a snapshot nobody can attribute is worse than none.
    public static func snapshot(from json: [String: Any], now: Date = Date()) -> ClaudeStatusSnapshot? {
        guard let rawID = json["session_id"] as? String else { return nil }
        let sessionID = String(rawID.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)
        }.prefix(64))
        guard !sessionID.isEmpty else { return nil }

        let model = (json["model"] as? [String: Any]).flatMap {
            ($0["display_name"] as? String) ?? ($0["id"] as? String)
        }
        let workspace = (json["workspace"] as? [String: Any]).flatMap {
            ($0["current_dir"] as? String) ?? ($0["project_dir"] as? String)
        } ?? (json["cwd"] as? String)
        let context = (json["context_window"] as? [String: Any])?["used_percentage"]
        let cost = (json["cost"] as? [String: Any])?["total_cost_usd"]
        let limits = json["rate_limits"] as? [String: Any]

        return ClaudeStatusSnapshot(
            sessionID: sessionID,
            model: model.map { String($0.prefix(60)) },
            workspace: workspace.map { String($0.prefix(240)) },
            contextPercent: percent(context),
            costUSD: (cost as? NSNumber)?.doubleValue,
            fiveHour: window(limits?["five_hour"]),
            sevenDay: window(limits?["seven_day"]),
            updatedAt: now
        )
    }

    /// A one-line status for Claude's prompt when the user had none of their
    /// own: model, context, and the plan windows when Claude reports them.
    public static func defaultLine(for snapshot: ClaudeStatusSnapshot) -> String {
        var parts: [String] = []
        if let model = snapshot.model { parts.append(model) }
        if let context = snapshot.contextPercent { parts.append("ctx \(Int(context.rounded()))%") }
        if let fiveHour = snapshot.fiveHour { parts.append("5h \(Int(fiveHour.usedPercent.rounded()))%") }
        if let sevenDay = snapshot.sevenDay { parts.append("wk \(Int(sevenDay.usedPercent.rounded()))%") }
        return parts.joined(separator: " · ")
    }

    static func percent(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let raw = number.doubleValue
        guard raw.isFinite else { return nil }
        return min(max(raw, 0), 100)
    }

    static func window(_ value: Any?) -> ClaudeStatusSnapshot.Window? {
        guard let object = value as? [String: Any], let used = percent(object["used_percentage"]) else { return nil }
        let resets: Date? = if let number = object["resets_at"] as? NSNumber {
            Date(timeIntervalSince1970: number.doubleValue > 100_000_000_000 ? number.doubleValue / 1_000 : number.doubleValue)
        } else if let text = object["resets_at"] as? String {
            ISO8601DateFormatter().date(from: text)
        } else {
            nil
        }
        return ClaudeStatusSnapshot.Window(usedPercent: used, resetsAt: resets)
    }
}
