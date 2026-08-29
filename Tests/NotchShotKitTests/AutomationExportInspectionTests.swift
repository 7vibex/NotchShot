import Foundation
import Testing

@testable import NotchShotKit

@Suite("Automation export inspection")
struct AutomationExportInspectionTests {
    @Test("All six user-facing shortcuts remain exported")
    func shortcutCount() {
        #expect(NotchShotAppShortcuts.appShortcuts.count == 6)
        _ = NotchShotKitAppIntentsPackage()
    }

    @Test("Packaging uses the current SwiftPM bin directory and requires intent metadata")
    func packagingContract() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(
            contentsOf: root.appending(path: "Scripts/build_app.sh"),
            encoding: .utf8
        )
        #expect(script.contains("SPARKLE_FRAMEWORK=\"$BIN_DIR/Sparkle.framework\""))
        #expect(!script.contains("find \"$ROOT/.build\""))
        #expect(script.contains("appintentsmetadataprocessor"))
        #expect(script.contains("Metadata.appintents"))
    }
}
