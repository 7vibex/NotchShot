import Foundation
import Testing
@testable import NotchShotKit

@Suite("VPN and Wi-Fi bursts")
struct NetworkEventPolicyTests {
    private let wifi = NetworkReachability(isOnline: true, link: .wifi, wifiStrength: 0.67)
    private let wired = NetworkReachability(isOnline: true, link: .wired)

    @Test("The state at launch is not news")
    func firstReading() {
        let events = NetworkEventPolicy.events(
            previous: nil,
            current: NetworkReachability(isOnline: true, link: .wifi, isVPNActive: true),
            showsVPN: true,
            showsWiFiJoin: true
        )
        #expect(events.isEmpty)
    }

    @Test("A VPN coming up and going down each get the pill")
    func vpnToggles() throws {
        var on = wired
        on.isVPNActive = true
        let up = NetworkEventPolicy.events(previous: wired, current: on, showsVPN: true, showsWiFiJoin: true)
        let upEvent = try #require(up.first)
        #expect(upEvent.kind == .vpn)
        #expect(upEvent.symbolName == NetworkEventPolicy.vpnOnSymbol)
        #expect(upEvent.title == "VPN On")

        let down = NetworkEventPolicy.events(previous: on, current: wired, showsVPN: true, showsWiFiJoin: true)
        #expect(down.first?.title == "VPN Off")
        #expect(NetworkEventPolicy.events(previous: wired, current: on, showsVPN: false, showsWiFiJoin: true).isEmpty)
    }

    @Test("Moving onto Wi-Fi while online sweeps the bars; coming back online leaves it to the card")
    func wifiJoin() throws {
        let joined = NetworkEventPolicy.events(previous: wired, current: wifi, showsVPN: true, showsWiFiJoin: true)
        let event = try #require(joined.first)
        #expect(event.kind == .wifi)
        #expect(event.level == 0.67)

        let restored = NetworkEventPolicy.events(
            previous: NetworkReachability(isOnline: false),
            current: wifi,
            showsVPN: true,
            showsWiFiJoin: true
        )
        #expect(restored.isEmpty)
        #expect(NetworkEventPolicy.events(previous: wifi, current: wifi, showsVPN: true, showsWiFiJoin: true).isEmpty)
    }

    @Test("Signal strength maps to the menu's bars")
    func strength() {
        #expect(NetworkEventPolicy.strength(rssi: -45) == 1)
        #expect(NetworkEventPolicy.strength(rssi: -60) == 0.67)
        #expect(NetworkEventPolicy.strength(rssi: -82) == 0.34)
        #expect(NetworkEventPolicy.strength(rssi: 0) == nil)
    }

    @Test("Only tunnel scopes count as a VPN")
    func vpnScopes() {
        #expect(!VPNStatusReader.isTunnel(scopes: ["en0", "en1"]))
        #expect(VPNStatusReader.isTunnel(scopes: ["en0", "utun4"]))
        #expect(VPNStatusReader.isTunnel(scopes: ["ipsec0"]))
        #expect(VPNStatusReader.isTunnel(scopes: ["ppp0"]))
    }
}

@Suite("Mouse, keyboard and trackpad battery")
struct PeripheralBatteryPolicyTests {
    @Test("Product names choose the device symbol")
    func kinds() {
        #expect(PeripheralKind(productName: "Magic Mouse") == .mouse)
        #expect(PeripheralKind(productName: "Magic Trackpad") == .trackpad)
        #expect(PeripheralKind(productName: "Magic Keyboard with Touch ID") == .keyboard)
        #expect(PeripheralKind(productName: "MX Master 3S") == .other)
    }

    @Test("Each low threshold fires once on the way down")
    func thresholds() {
        #expect(PeripheralBatteryPolicy.crossedThreshold(previous: 11, current: 10) == 10)
        #expect(PeripheralBatteryPolicy.crossedThreshold(previous: 10, current: 9) == nil)
        #expect(PeripheralBatteryPolicy.crossedThreshold(previous: 7, current: 5) == 5)
        #expect(PeripheralBatteryPolicy.crossedThreshold(previous: 30, current: 4) == 5)
        #expect(PeripheralBatteryPolicy.crossedThreshold(previous: 4, current: 40) == nil)
    }

    @Test("Connecting shows the charge; a low battery warns")
    func events() {
        let mouse = PeripheralBatteryReading(registryID: 7, name: "Magic Mouse", percent: 64)
        let connected = PeripheralBatteryPolicy.connectedEvent(mouse)
        #expect(connected.kind == .accessory)
        #expect(connected.symbolName == "magicmouse.fill")
        #expect(connected.level == 0.64)
        #expect(connected.severity == .informational)

        var low = mouse
        low.percent = 9
        let warning = PeripheralBatteryPolicy.lowEvent(low)
        #expect(warning.severity == .warning)
        #expect(warning.title == "9% Left")
        #expect(warning.coalescingKey == connected.coalescingKey)
    }
}

@Suite("Charging details")
struct PowerChargeDescriptionTests {
    @Test("Time to full and the adapter's watts")
    func charging() {
        let power = PowerSourceReading(
            percentage: 62, isConnectedToPower: true, isCharging: true,
            adapterWatts: 96, minutesToFull: 80
        )
        #expect(PowerChargeDescription.title(power) == "Charging")
        #expect(PowerChargeDescription.detail(power) == "1:20 until full · 96W")

        let soon = PowerSourceReading(percentage: 95, isConnectedToPower: true, isCharging: true, minutesToFull: 12)
        #expect(PowerChargeDescription.detail(soon) == "12 min until full")
    }

    @Test("Plugged in but held below full reads as On Hold")
    func onHold() {
        let held = PowerSourceReading(percentage: 80, isConnectedToPower: true, isCharging: false, adapterWatts: 67)
        #expect(held.isChargingOnHold)
        #expect(PowerChargeDescription.title(held) == "Charging On Hold")
        #expect(PowerChargeDescription.detail(held) == "Protecting battery health · 67W")

        let full = PowerSourceReading(percentage: 100, isConnectedToPower: true, isCharging: false)
        #expect(!full.isChargingOnHold)
        #expect(PowerChargeDescription.title(full) == "Charged")
    }

    @Test("Charging alone fills the Lock Screen card's spot when the player is on")
    func lockedCharging() {
        #expect(LockedMediaPresentationPolicy.content(
            mediaOptedIn: true, hasMediaContent: false,
            activityStackOptedIn: false, hasActivityContent: false,
            hasChargingContent: true
        ) == .charging)
        #expect(LockedMediaPresentationPolicy.content(
            mediaOptedIn: true, hasMediaContent: true,
            activityStackOptedIn: false, hasActivityContent: false,
            hasChargingContent: true
        ) == .compactMedia)
        #expect(LockedMediaPresentationPolicy.content(
            mediaOptedIn: false, hasMediaContent: false,
            activityStackOptedIn: true, hasActivityContent: true,
            hasChargingContent: true
        ) == .activityStack)
        #expect(LockedMediaPresentationPolicy.content(
            mediaOptedIn: true, hasMediaContent: false,
            activityStackOptedIn: false, hasActivityContent: false,
            isPrimaryDisplay: false,
            hasChargingContent: true
        ) == .none)
    }
}

@Suite("Lyric line and sweep")
struct LiveLyricLinePolicyTests {
    private let lyrics = Lyrics(
        lines: [
            LyricLine(id: 0, time: 10, text: "First line"),
            LyricLine(id: 1, time: 14, text: ""),
            LyricLine(id: 2, time: 20, text: "Third line"),
        ],
        isSynced: true,
        isInstrumental: false
    )

    @Test("The sung line, with gaps left empty")
    func line() {
        #expect(LiveLyricLinePolicy.line(in: lyrics, at: 5) == nil)
        #expect(LiveLyricLinePolicy.line(in: lyrics, at: 11) == "First line")
        #expect(LiveLyricLinePolicy.line(in: lyrics, at: 15) == nil)
        #expect(LiveLyricLinePolicy.line(in: lyrics, at: 25) == "Third line")
    }

    @Test("The sweep runs from a line's start to the next line's")
    func sweep() throws {
        let first = try #require(LiveLyricLinePolicy.sweep(in: lyrics, index: 0, position: 12, trackDuration: 200))
        #expect(first.duration == 4)
        #expect(first.fraction == 0.5)
        // The last line is capped so a long outro doesn't stretch it.
        let last = try #require(LiveLyricLinePolicy.sweep(in: lyrics, index: 2, position: 20, trackDuration: 200))
        #expect(last.duration == 8)
        #expect(last.fraction == 0)
    }
}

@Suite("Live audio")
struct LiveAudioTests {
    @Test("Helpers and WebKit's GPU process count as the player")
    func processMatching() {
        let running = ["com.spotify.client", "com.spotify.client.helper", "com.apple.WebKit.GPU", "com.google.Chrome.helper"]
        #expect(Set(AudioTapProcessPolicy.matches(for: "com.spotify.client", among: running))
            == ["com.spotify.client", "com.spotify.client.helper"])
        #expect(AudioTapProcessPolicy.matches(for: "com.apple.Safari", among: running) == ["com.apple.WebKit.GPU"])
        #expect(AudioTapProcessPolicy.matches(for: "com.google.Chrome", among: running) == ["com.google.Chrome.helper"])
        #expect(AudioTapProcessPolicy.matches(for: "com.apple.Music", among: running).isEmpty)
    }

    @Test("A bass tone lights the lowest band and leaves the highest dark")
    func bands() throws {
        let analyzer = LevelAnalyzer(bandCount: 4)
        let rate = 48_000.0
        var levels: [Float]?
        var phase = 0.0
        for _ in 0..<40 {
            var block = [Float](repeating: 0, count: 512)
            for index in block.indices {
                block[index] = Float(sin(phase) * 0.6)
                phase += 2 * .pi * 110 / rate
            }
            levels = block.withUnsafeBufferPointer { analyzer.process($0, channels: 1, sampleRate: rate) } ?? levels
        }
        let result = try #require(levels)
        #expect(result.count == 4)
        #expect(result[0] > 0.5)
        #expect(result[0] > result[3])
    }
}

@Suite("Song recognition copy")
struct SongRecognitionPolicyTests {
    @Test("Listening, the answer and a miss share one burst slot")
    func events() {
        let listening = SongRecognitionPolicy.event(for: .listening)
        let match = SongRecognitionPolicy.event(for: .matched(.init(title: "Song", artist: "Artist")))
        let miss = SongRecognitionPolicy.event(for: .noMatch)
        #expect(listening.coalescingKey == match.coalescingKey)
        #expect(miss.coalescingKey == match.coalescingKey)
        #expect(match.title == "Song")
        #expect(match.detail == "Artist")
        #expect(match.severity == .success)
        #expect(listening.kind == .song)
    }
}
