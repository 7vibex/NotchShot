import Foundation
import Testing
@testable import NotchShotKit

/// The host policy must parse the whole string as an address. Discarding the
/// non-numeric parts accepted public-looking names that merely contained four
/// numeric pieces.
@Suite("LocalSend private host policy")
struct LocalSendHostPolicyTests {
    @Test("Local names and addresses are accepted", arguments: [
        "10.0.0.1",
        "172.16.0.1",
        "172.31.255.255",
        "192.168.1.2",
        "169.254.10.20",
        "127.0.0.1",
        "localhost",
        "macbook.local",
        "::1",
        "fe80::1",
        "FE80::1",
        "fc00::1",
        "fd12:3456:789a::1",
    ])
    func acceptsLocalHosts(host: String) {
        #expect(LocalNetworkHostPolicy.isAllowed(host), "\(host) should be allowed")
    }

    @Test("Malformed private-looking names are rejected", arguments: [
        "10.1.2.3.example.com",
        "foo.10.1.2.3",
        "10.foo.1.2.3",
        "10.1.2.3.",
        "10.1.2",
        "10.1.2.3.4",
        "999.1.1.1",
        "10.0.0.01",
        "10..0.1",
    ])
    func rejectsMalformedHosts(host: String) {
        #expect(!LocalNetworkHostPolicy.isAllowed(host), "\(host) should be rejected")
    }

    @Test("Public destinations are rejected", arguments: [
        "8.8.8.8",
        "1.1.1.1",
        "172.32.0.1",
        "192.169.1.1",
        "169.255.0.1",
        "example.com",
        "10.1.2.3/path",
        "user@10.1.2.3",
        "2001:4860:4860::8888",
        "2606:4700:4700::1111",
    ])
    func rejectsPublicDestinations(host: String) {
        #expect(!LocalNetworkHostPolicy.isAllowed(host), "\(host) should be rejected")
    }

    @Test("Malformed IPv6 is rejected rather than prefix-matched", arguments: [
        "fe80::1::2",
        "fe80:::1",
        "gggg::1",
        "fe80::1%en0",
        "fe80",
        "fc",
        "::ffff:10.0.0.1",
    ])
    func rejectsMalformedIPv6(host: String) {
        #expect(!LocalNetworkHostPolicy.isAllowed(host), "\(host) should be rejected")
    }
}
