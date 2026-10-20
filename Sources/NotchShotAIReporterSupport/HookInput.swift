import Foundation

/// Reads the one JSON object a hook runner writes to standard input.
///
/// The read is bounded so a malformed or hostile runner cannot make the
/// short-lived reporter allocate without limit. Input past the bound is not
/// cut short and parsed: the front of a PostToolUse event carrying a
/// screenshot is not JSON, and reading it as an empty event used to record
/// activity for a session named "current". It is read to the end and
/// dropped instead, so the runner's write still completes.
public enum HookInput {
    public enum Result: Equatable, Sendable {
        case complete(Data)
        case oversized
    }

    public static func read(from handle: FileHandle, maximumBytes: Int) -> Result {
        var data = Data()
        while let chunk = try? handle.read(upToCount: chunkBytes), !chunk.isEmpty {
            guard data.count + chunk.count <= maximumBytes else {
                while let rest = try? handle.read(upToCount: chunkBytes), !rest.isEmpty {}
                return .oversized
            }
            data.append(chunk)
        }
        return .complete(data)
    }

    private static let chunkBytes = 64 * 1_024
}
