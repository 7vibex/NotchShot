import Foundation
import Network

/// Watches internet reachability and emits a card when it changes.
///
/// `NWPathMonitor` reports the system's own routing verdict, so this needs no
/// probe traffic, no host to ping and no entitlement — nothing leaves the Mac.
@MainActor
final class NetworkReachabilityMonitor {
    var onTransition: ((ContextSnapshot) -> Void)?

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
            let reading = NetworkReachability(path: path)
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
