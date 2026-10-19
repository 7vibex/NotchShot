import AppKit
import Foundation
@main struct PrivacyBaselineProbe {
    @MainActor static func main() {
        _ = NSApplication.shared
        let monitor = PrivacyIndicatorMonitor()
        let began = ContinuousClock.now
        monitor.start()
        let elapsed = began.duration(to: .now)
        print("baseline main-actor start and initial snapshot: \(elapsed); client count: \(monitor.microphoneClients.count)")
        monitor.stop()
    }
}
