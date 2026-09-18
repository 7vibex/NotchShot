import Foundation

/// Which LocalSend controls a given transient state shows.
///
/// Cancel belongs to an in-flight task, not to whichever branch last set the
/// message. After the user approves a certificate fingerprint the trusted
/// retry is a real send, so Cancel must stay on screen until that task ends —
/// the multi-activity island may be disabled entirely, so it is not a
/// substitute for the view's own control.
public struct LocalSendControlState: Sendable, Equatable {
    public var showsTrustButton: Bool
    public var showsSendButton: Bool
    public var trustEnabled: Bool
    public var sendEnabled: Bool
    public var showsCancelButton: Bool

    public init(pendingFingerprint: String?, isSending: Bool, hasSelection: Bool) {
        showsTrustButton = pendingFingerprint != nil
        showsSendButton = pendingFingerprint == nil
        trustEnabled = !isSending
        sendEnabled = !isSending && hasSelection
        showsCancelButton = isSending
    }
}
