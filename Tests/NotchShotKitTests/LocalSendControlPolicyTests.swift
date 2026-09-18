import Foundation
import Testing
@testable import NotchShotKit

/// The trusted retry is a real send. Cancel must follow the task, not the
/// fingerprint branch, and the island may be disabled entirely.
@Suite("LocalSend control state")
struct LocalSendControlPolicyTests {
    @Test("Initial send shows only an enabled send button")
    func initialSend() {
        let state = LocalSendControlState(
            pendingFingerprint: nil,
            isSending: false,
            hasSelection: true
        )
        #expect(state.showsSendButton)
        #expect(!state.showsTrustButton)
        #expect(state.sendEnabled)
        #expect(!state.showsCancelButton)
    }

    @Test("No selection disables the send button")
    func noSelectionDisablesSend() {
        let state = LocalSendControlState(
            pendingFingerprint: nil,
            isSending: false,
            hasSelection: false
        )
        #expect(!state.sendEnabled)
    }

    @Test("A certificate that needs approval shows the trust button")
    func certificateNeedsApproval() {
        let state = LocalSendControlState(
            pendingFingerprint: "ABCD",
            isSending: false,
            hasSelection: true
        )
        #expect(state.showsTrustButton)
        #expect(!state.showsSendButton)
        #expect(state.trustEnabled)
        #expect(!state.showsCancelButton)
    }

    @Test("The approved retry keeps Cancel and disables the trust button")
    func approvedRetryKeepsCancel() {
        let state = LocalSendControlState(
            pendingFingerprint: "ABCD",
            isSending: true,
            hasSelection: true
        )
        #expect(state.showsTrustButton)
        #expect(!state.trustEnabled)
        #expect(state.showsCancelButton, "an active trusted send must remain cancellable")
    }

    @Test("Cancelling returns to the trust branch with no active control")
    func cancellationEndsTheTask() {
        let state = LocalSendControlState(
            pendingFingerprint: "ABCD",
            isSending: false,
            hasSelection: true
        )
        #expect(state.showsTrustButton)
        #expect(!state.showsCancelButton)
    }

    @Test("A successful retry returns to the normal branch and clears Cancel")
    func successfulRetryClearsFingerprint() {
        let state = LocalSendControlState(
            pendingFingerprint: nil,
            isSending: false,
            hasSelection: true
        )
        #expect(state.showsSendButton)
        #expect(!state.showsCancelButton)
    }

    @Test("A failed send returns to the normal branch with no Cancel")
    func failedSendClearsCancel() {
        let state = LocalSendControlState(
            pendingFingerprint: nil,
            isSending: false,
            hasSelection: true
        )
        #expect(state.showsSendButton)
        #expect(state.sendEnabled)
        #expect(!state.showsCancelButton)
    }
}
