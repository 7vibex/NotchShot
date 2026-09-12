import Darwin
import Foundation
import NotchShotAIReporterSupport
import Testing

@Suite("Claude hook socket")
struct ClaudeHookSocketTests {

    @Test("The socket path is per-user and short enough for sockaddr_un")
    func pathIsPerUserAndBounded() {
        let path = ClaudeHookSocket.path
        #expect(path.contains("notchshot-claude-\(getuid()).sock"))
        #expect(path.utf8.count < 104)
    }

    @Test("A same-user peer is trusted and an invalid descriptor is not")
    func peerCheck() {
        var descriptors: [Int32] = [0, 0]
        let result = descriptors.withUnsafeMutableBufferPointer { buffer in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buffer.baseAddress)
        }
        guard result == 0 else {
            Issue.record("socketpair failed with errno \(errno)")
            return
        }
        defer {
            close(descriptors[0])
            close(descriptors[1])
        }
        #expect(ClaudeHookSocket.isTrustedPeer(descriptors[0]))
        #expect(ClaudeHookSocket.isTrustedPeer(descriptors[1]))
        #expect(!ClaudeHookSocket.isTrustedPeer(-1))
    }
}
