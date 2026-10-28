import CoreWLAN
import Foundation
import Network
import SystemConfiguration

/// Watches internet reachability and emits a card when it changes.
///
/// `NWPathMonitor` reports the system's own routing verdict, so this needs no
/// probe traffic, no host to ping and no entitlement — nothing leaves the Mac.
@MainActor
final class NetworkReachabilityMonitor {
    var onTransition: ((ContextSnapshot) -> Void)?
    /// VPN and Wi-Fi join bursts.
    var onEvent: ((IslandTransientEvent) -> Void)?

    /// How long a path change has to hold before it counts.
    ///
    /// Paths flap: roaming between access points, waking the radio after sleep
    /// and switching from Wi-Fi to Ethernet all pass through an unsatisfied
    /// state for well under a second. Announcing those would mean an outage
    /// card every time the user walks between rooms.
    static let settleInterval: Duration = .seconds(2)

    private var monitor: NWPathMonitor?
    private var previous: NetworkReachability?
    private var settleTask: Task<Void, Never>?

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            var reading = NetworkReachability(path: path)
            // Both reads are cheap, local, and happen only on a path change.
            reading.isVPNActive = VPNStatusReader.isActive()
            if reading.link == .wifi {
                reading.wifiStrength = CWWiFiClient.shared().interface()
                    .flatMap { NetworkEventPolicy.strength(rssi: $0.rssiValue()) }
            }
            Task { @MainActor in self?.schedule(reading) }
        }
        monitor.start(queue: DispatchQueue(label: "com.notchshot.network-path", qos: .utility))
    }

    func stop() {
        settleTask?.cancel()
        settleTask = nil
        monitor?.cancel()
        monitor = nil
        previous = nil
    }

    private func schedule(_ reading: NetworkReachability) {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.settleInterval)
            guard !Task.isCancelled, let self else { return }
            let old = self.previous
            self.previous = reading
            let extras = ExtrasPreferences.shared
            for event in NetworkEventPolicy.events(
                previous: old,
                current: reading,
                showsVPN: extras.showsVPNStatus,
                showsWiFiJoin: extras.showsWiFiJoin
            ) {
                self.onEvent?(event)
            }
            guard let snapshot = NetworkContextPolicy.snapshot(previous: old, current: reading) else {
                return
            }
            self.onTransition?(snapshot)
        }
    }
}

extension NetworkReachability {
    init(path: NWPath) {
        let online = path.status == .satisfied
        let link: NetworkLinkKind?
        if !online {
            link = nil
        } else if path.usesInterfaceType(.wiredEthernet) {
            link = .wired
        } else if path.usesInterfaceType(.wifi) {
            link = .wifi
        } else if path.usesInterfaceType(.cellular) {
            link = .cellular
        } else {
            link = .other
        }
        self.init(isOnline: online, link: link)
    }
}

/// Whether a VPN tunnel is up, from the system's scoped proxy table.
///
/// Every interface the system routes through gets a scope there, and VPN
/// clients add theirs (`utun`, `ipsec`, `ppp`, `tun`, `tap`) while connected.
/// The always-present `utun` interfaces that macOS keeps for its own services
/// carry no scope, so they don't count. No VPN configuration is read.
enum VPNStatusReader {
    static let tunnelPrefixes = ["utun", "ipsec", "ppp", "tun", "tap"]

    static func isActive() -> Bool {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
              let scoped = settings["__SCOPED__"] as? [String: Any] else { return false }
        return isTunnel(scopes: Array(scoped.keys))
    }

    static func isTunnel(scopes: [String]) -> Bool {
        scopes.contains { name in tunnelPrefixes.contains { name.hasPrefix($0) } }
    }
}
