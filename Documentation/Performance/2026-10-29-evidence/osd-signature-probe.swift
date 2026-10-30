// Times the OSD recovery helper's strict signature check against the stamp
// check that now gates it (`SignatureVerdictCache` in SystemOSDSuppressor.swift).
// The stamp code is copied from BundleFileStamps; the check matches
// `hasMatchingValidSignature`. Only reads the bundle.
//
//   swiftc -O osd-signature-probe.swift -o osd-signature-probe
//   ./osd-signature-probe <path to NotchShot.app> <rounds>

import Foundation
import Security

struct Stamp: Equatable {
    var inode: UInt64, size: Int64, mode: UInt16
    var modifiedSeconds: Int, modifiedNanoseconds: Int, changedSeconds: Int, changedNanoseconds: Int
}

func stamps(_ bundle: URL) -> [String: Stamp]? {
    let root = bundle.standardizedFileURL.path
    guard let enumerator = FileManager.default.enumerator(atPath: root) else { return nil }
    var entries: [String: Stamp] = [:]
    for relative in [""] + enumerator.compactMap({ $0 as? String }) {
        var information = stat()
        let path = relative.isEmpty ? root : root + "/" + relative
        guard lstat(path, &information) == 0 else { return nil }
        entries[relative] = Stamp(
            inode: UInt64(information.st_ino), size: Int64(information.st_size), mode: UInt16(information.st_mode),
            modifiedSeconds: Int(information.st_mtimespec.tv_sec), modifiedNanoseconds: Int(information.st_mtimespec.tv_nsec),
            changedSeconds: Int(information.st_ctimespec.tv_sec), changedNanoseconds: Int(information.st_ctimespec.tv_nsec)
        )
    }
    return entries
}

func strictCheck(app: URL, helper: URL) -> Bool {
    var appCode: SecStaticCode?, helperCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(app as CFURL, [], &appCode) == errSecSuccess,
          SecStaticCodeCreateWithPath(helper as CFURL, [], &helperCode) == errSecSuccess,
          let appCode, let helperCode else { return false }
    let strict = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
    let appFlags = SecCSFlags(rawValue: strict.rawValue | kSecCSCheckNestedCode)
    return SecStaticCodeCheckValidity(appCode, appFlags, nil) == errSecSuccess
        && SecStaticCodeCheckValidity(helperCode, strict, nil) == errSecSuccess
}

func milliseconds(_ body: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
}

let app = URL(fileURLWithPath: CommandLine.arguments[1])
let rounds = Int(CommandLine.arguments[2]) ?? 5
let helper = app.appendingPathComponent("Contents/MacOS/NotchShotOSDRecovery")
var valid = false
let checkTimes = (0 ..< rounds).map { _ in milliseconds { valid = strictCheck(app: app, helper: helper) } }
var first: [String: Stamp]?
let firstStampTime = milliseconds { first = stamps(app) }
var same = 0
let stampTimes = (0 ..< rounds * 4).map { _ in milliseconds { if stamps(app) == first { same += 1 } } }
let sorted = { (values: [Double]) in values.sorted() }
let result: [String: Any] = [
    "bundle": app.path, "entries": first?.count ?? 0, "valid": valid,
    "strictCheckMs": sorted(checkTimes), "firstStampMs": firstStampTime,
    "stampMs": sorted(stampTimes), "stampsUnchanged": "\(same)/\(rounds * 4)",
]
print(String(data: try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
