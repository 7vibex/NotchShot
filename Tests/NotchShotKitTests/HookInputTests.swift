import Darwin
import Foundation
import Testing

import NotchShotAIReporterSupport

@Suite("AI reporter hook input")
struct HookInputTests {
    @Test("Input within the bound arrives whole")
    func completeInput() {
        let event = Data(#"{"session_id":"abc","hook_event_name":"PostToolUse"}"#.utf8)
        #expect(Self.read(event, maximumBytes: 1_024) == (.complete(event), true))
        // Many pipe-sized chunks, ending exactly at the bound.
        let exact = Data(repeating: 0x20, count: 200_000)
        #expect(Self.read(exact, maximumBytes: 200_000) == (.complete(exact), true))
        #expect(Self.read(Data(), maximumBytes: 10) == (.complete(Data()), true))
    }

    @Test("Oversized input is read to the end and dropped, never cut to a prefix")
    func oversizedInput() {
        // A PostToolUse carrying a screenshot. Its session id comes first, so
        // a prefix looks like an event yet parses as nothing.
        var event = Data(#"{"session_id":"abc","tool_response":""#.utf8)
        event.append(Data(repeating: UInt8(ascii: "A"), count: 600 * 1_024))
        event.append(Data(#""}"#.utf8))
        #expect(Self.read(event, maximumBytes: 512 * 1_024) == (.oversized, true))
        #expect(Self.read(Data(repeating: 0x20, count: 11), maximumBytes: 10) == (.oversized, true))
    }

    /// Feeds `data` through a pipe from another thread, as a hook runner
    /// does. The second value says whether the writer got to finish, which it
    /// can only do once the reader has taken everything.
    private static func read(_ data: Data, maximumBytes: Int) -> (HookInput.Result, Bool) {
        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        // A writer stranded by a regression gets EPIPE, not a fatal signal,
        // when the read end closes below.
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? writer.write(contentsOf: data)
            try? writer.close()
            finished.signal()
        }
        let result = HookInput.read(from: pipe.fileHandleForReading, maximumBytes: maximumBytes)
        let drained = finished.wait(timeout: .now() + 5) == .success
        try? pipe.fileHandleForReading.close()
        if !drained { finished.wait() }
        return (result, drained)
    }
}
