import Foundation

/// Defaults suites for tests. Each test gets its own uniquely named suite, but
/// a suite named like a domain keeps a plist in `~/Library/Preferences`, and
/// removing the domain doesn't help: cfprefsd writes an empty plist again 5 to
/// 10 seconds after the process exits, even after the file was deleted. Runs
/// had left about 11,800 of them. A suite named by an absolute path keeps its
/// plist at that path instead, so every suite here lives in one temporary
/// folder per test process, removed when the process exits.
enum TestDefaults {
    private static let folder: URL = {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchShotTests-defaults-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        atexit { try? FileManager.default.removeItem(at: TestDefaults.folder) }
        return folder
    }()

    static func suite(_ name: String) -> UserDefaults {
        UserDefaults(suiteName: folder.appendingPathComponent(name).path)!
    }
}
