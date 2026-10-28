import AppKit
import Foundation

/// Which link the Mac is currently reaching the internet over.
///
/// Only the coarse kind is kept. The SSID, the interface name and the address
/// are all identifying, none of them change what the card says, and a passive
/// status card is the wrong place to start collecting them.
public enum NetworkLinkKind: String, Sendable, Codable, Equatable {
    case wifi
    case wired
    case cellular
    case other

    var displayName: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .wired: "Ethernet"
        case .cellular: "Personal Hotspot"
        case .other: "the network"
        }
    }
}

/// One reachability reading, free of `Network` types so the transition rules
/// can be exercised without a live interface.
public struct NetworkReachability: Sendable, Equatable {
    public var isOnline: Bool
    public var link: NetworkLinkKind?
    /// A VPN tunnel is carrying traffic. Only whether one is up is kept, never
    /// its name or server.
    public var isVPNActive: Bool
    /// Wi-Fi signal as 0...1, for how many bars the join burst fills. Nil when
    /// not on Wi-Fi or when the radio does not report it.
    public var wifiStrength: Double?

    public init(
        isOnline: Bool,
        link: NetworkLinkKind? = nil,
        isVPNActive: Bool = false,
        wifiStrength: Double? = nil
    ) {
        self.isOnline = isOnline
        self.link = link
        self.isVPNActive = isVPNActive
        self.wifiStrength = wifiStrength
    }
}

/// Presentation and routing rules for the connectivity card.
///
/// Reachability is observable but not actionable: joining a network belongs to
/// System Settings and the Wi-Fi menu. The card states the fact and hands off,
/// the same way the low-battery alert does with Low Power Mode.
enum NetworkContextPolicy {
    static let offlineTitle = "No Internet Connection"
    static let restoredTitle = "Back Online"
    static let offlineSubtitle = "Connect to Wi-Fi, Ethernet, or Personal Hotspot to continue."

    /// Green, following the system's own no-connection alert: the glyph reads
    /// as "the network" rather than as a severity level, and the card's call to
    /// action carries the emphasis instead.
    static let offlineAccentHex = "#30D158"
    static let restoredAccentHex = "#30D158"

    static let offlineDuration: TimeInterval = 8
    static let restoredDuration: TimeInterval = 4

    static var networkSettingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")
    }

    static func isOfflineAlert(_ snapshot: ContextSnapshot) -> Bool {
        snapshot.kind == .network && snapshot.title == offlineTitle
    }

    static func isNetworkCard(_ snapshot: ContextSnapshot) -> Bool {
        snapshot.kind == .network
    }

    static func restoredSubtitle(link: NetworkLinkKind?) -> String {
        guard let link else { return "The internet connection is back." }
        return "Connected over \(link.displayName)."
    }

    /// A card for a *change* in reachability, or nil when nothing worth
    /// interrupting for happened.
    ///
    /// The first reading after start never produces one. Reporting the state
    /// the Mac was already in would announce an outage on every launch and on
    /// every toggle of the preference, which is noise rather than news.
    static func snapshot(
        previous: NetworkReachability?,
        current: NetworkReachability,
        now: Date = Date()
    ) -> ContextSnapshot? {
        guard let previous else { return nil }
        guard previous.isOnline != current.isOnline else { return nil }

        if current.isOnline {
            return ContextSnapshot(
                kind: .network,
                title: restoredTitle,
                subtitle: restoredSubtitle(link: current.link),
                metric: current.link?.displayName,
                accentHex: restoredAccentHex,
                createdAt: now,
                expiresAt: now.addingTimeInterval(restoredDuration),
                mayInterruptMedia: false
            )
        }

        return ContextSnapshot(
            kind: .network,
            title: offlineTitle,
            subtitle: offlineSubtitle,
            accentHex: offlineAccentHex,
            createdAt: now,
            expiresAt: now.addingTimeInterval(offlineDuration),
            // Losing the connection outranks a track change: it explains why
            // the stream that is playing is about to stop.
            mayInterruptMedia: true
        )
    }
}

/// Short bursts for changes that are news but not worth a card: a VPN coming
/// up or going down, and joining Wi-Fi while already online over something
/// else. Reaching the internet again keeps its card above.
enum NetworkEventPolicy {
    static let vpnOnSymbol = "lock.shield.fill"
    static let vpnOffSymbol = "lock.shield"
    static let wifiSymbol = "wifi"

    static func events(
        previous: NetworkReachability?,
        current: NetworkReachability,
        showsVPN: Bool,
        showsWiFiJoin: Bool,
        now: Date = Date()
    ) -> [IslandTransientEvent] {
        // Same rule as the card: the state at launch is not news.
        guard let previous else { return [] }
        var events: [IslandTransientEvent] = []
        if showsVPN, previous.isVPNActive != current.isVPNActive {
            events.append(IslandTransientEvent(
                kind: .vpn,
                severity: current.isVPNActive ? .success : .informational,
                coalescingKey: "vpn",
                symbolName: current.isVPNActive ? vpnOnSymbol : vpnOffSymbol,
                title: current.isVPNActive ? "VPN On" : "VPN Off",
                createdAt: now,
                holdDuration: 1.8
            ))
        }
        // Coming back online already has the card; this is only for moving
        // onto Wi-Fi from Ethernet or a hotspot while still connected.
        if showsWiFiJoin, previous.isOnline, current.isOnline,
           previous.link != .wifi, current.link == .wifi {
            events.append(wifiJoinEvent(strength: current.wifiStrength, now: now))
        }
        return events
    }

    static func wifiJoinEvent(strength: Double?, now: Date = Date()) -> IslandTransientEvent {
        IslandTransientEvent(
            kind: .wifi,
            severity: .success,
            coalescingKey: "wifi",
            symbolName: wifiSymbol,
            // The bars already say Wi-Fi; a longer title is cut off beside
            // the camera.
            title: "Connected",
            detail: "Wi-Fi",
            level: strength,
            createdAt: now,
            holdDuration: 2.2
        )
    }

    /// RSSI in dBm to bars, using the thresholds the Wi-Fi menu's three bars
    /// roughly follow: -50 and stronger is full, -80 and weaker is one bar.
    static func strength(rssi: Int) -> Double? {
        guard rssi < 0 else { return nil }
        if rssi >= -55 { return 1 }
        if rssi >= -67 { return 0.67 }
        return 0.34
    }
}

@MainActor
enum NetworkSettingsService {
    @discardableResult
    static func open() -> Bool {
        guard let url = NetworkContextPolicy.networkSettingsURL else { return false }
        return NSWorkspace.shared.open(url)
    }
}
