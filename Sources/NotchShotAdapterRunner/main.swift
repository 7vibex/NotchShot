import Darwin
import Foundation

// The runner is intentionally tiny: group creation must happen in the child
// before exec, because a parent-side setpgid call races the child's exec on
// macOS and can leave grandchildren outside NotchShot's cleanup boundary.
guard CommandLine.arguments.count >= 7 else { exit(64) }
if getpgrp() != getpid() {
    guard setpgid(0, 0) == 0 else { exit(71) }
}

guard let expectedDevice = UInt64(CommandLine.arguments[1]),
      let expectedInode = UInt64(CommandLine.arguments[2]),
      let expectedSize = Int64(CommandLine.arguments[3]),
      let expectedModifiedSeconds = Int64(CommandLine.arguments[4]),
      let expectedModifiedNanoseconds = Int64(CommandLine.arguments[5]) else {
    exit(64)
}

// Validation is by path, and exec is by the same path, so a replacement landing
// between the two would run unvalidated. That window is deliberate, not
// overlooked: macOS ships no `fexecve`, and the usual substitute — holding the
// validated descriptor and exec'ing `/dev/fd/N` — does not work here either.
// It fails EBADF when the descriptor is O_CLOEXEC and EACCES when it is not,
// because fdescfs will not honour an exec through a read-only descriptor. There
// is no descriptor-pinned exec on this platform to switch to.
//
// The exposure is bounded by what it already takes to reach it: write access to
// the directory holding the executable the user explicitly approved, which is
// write access to that executable.
let target = CommandLine.arguments[6]
var information = stat()
guard lstat(target, &information) == 0,
      information.st_mode & S_IFMT == S_IFREG,
      UInt64(information.st_dev) == expectedDevice,
      UInt64(information.st_ino) == expectedInode,
      information.st_size == expectedSize,
      Int64(information.st_mtimespec.tv_sec) == expectedModifiedSeconds,
      Int64(information.st_mtimespec.tv_nsec) == expectedModifiedNanoseconds,
      access(target, X_OK) == 0 else {
    exit(77)
}

let arguments = [target] + Array(CommandLine.arguments.dropFirst(7))
var pointers = arguments.map { strdup($0) }
pointers.append(nil)
defer {
    for pointer in pointers where pointer != nil { free(pointer) }
}

_ = target.withCString { path in
    execv(path, &pointers)
}
exit(126)
