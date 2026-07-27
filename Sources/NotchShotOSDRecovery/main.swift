import AppKit
import Darwin
import Foundation

private let expectedBundleIdentifier = "com.apple.OSDUIHelper"
private let expectedExecutable = URL(
    fileURLWithPath: "/System/Library/CoreServices/OSDUIHelper.app/Contents/MacOS/OSDUIHelper"
).standardizedFileURL.path

guard CommandLine.arguments.count == 4,
      let processID = pid_t(CommandLine.arguments[1]),
      let expectedStartSeconds = UInt64(CommandLine.arguments[2]),
      let expectedStartMicroseconds = UInt64(CommandLine.arguments[3]),
      processID > 1 else {
    exit(64)
}

// The write end is owned only by NotchShot. Normal disarm, crash, force quit,
// or SIGKILL all close it in the kernel; no signal handler in the app is needed.
_ = FileHandle.standardInput.readDataToEndOfFile()

// PIDs can be reused. Resume only the exact Apple helper identity this binary
// exists to recover; resuming any other process would be an ownership bug.
guard let application = NSRunningApplication(processIdentifier: processID),
      application.bundleIdentifier == expectedBundleIdentifier,
      application.executableURL?.standardizedFileURL.path == expectedExecutable else {
    exit(0)
}

var processInfo = proc_bsdinfo()
let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
guard proc_pidinfo(
    processID,
    PROC_PIDTBSDINFO,
    0,
    &processInfo,
    expectedSize
) == expectedSize,
    UInt64(processInfo.pbi_start_tvsec) == expectedStartSeconds,
    UInt64(processInfo.pbi_start_tvusec) == expectedStartMicroseconds
else {
    exit(0)
}

exit(kill(processID, SIGCONT) == 0 ? 0 : 1)
