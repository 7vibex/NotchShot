import AppKit
import Foundation

/// One front door for agents waiting on the user, so the island's card does
/// not need to know which bridge asked.
extension AppCoordinator {
    /// A compact card cannot show a complete shell action. Its Review button
    /// opens this inspection before an exact, still-current request can run.
    func reviewClaudePermission(sessionID: String, requestID: String?) {
        guard let permission = context.claude.session(for: sessionID)?.permission,
              requestID == nil || permission.id == requestID else { return }
        guard permission.canApproveInline, let action = permission.actionDescription else {
            reviewClaudePermissionInTerminal(sessionID: sessionID, requestID: permission.id)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Review \(permission.toolName) action"
        alert.informativeText = "Allow Once approves the complete action below."
        alert.addButton(withTitle: "Review in Terminal")
        alert.addButton(withTitle: "Allow Once")
        alert.addButton(withTitle: "Deny")
        // Return chooses the terminal fallback; approval always needs its own
        // explicit activation after the full text is available for inspection.
        alert.buttons[1].keyEquivalent = ""
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 240))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.string = action
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.isEditable = false
        text.isSelectable = true
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.width]
        text.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.setAccessibilityLabel("Complete action requested by Claude Code")
        scroll.documentView = text
        alert.accessoryView = scroll
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            context.claude.approve(sessionID: sessionID, requestID: permission.id)
        case .alertThirdButtonReturn:
            context.claude.deny(sessionID: sessionID, requestID: permission.id)
        default:
            reviewClaudePermissionInTerminal(sessionID: sessionID, requestID: permission.id)
        }
    }

    private func reviewClaudePermissionInTerminal(sessionID: String, requestID: String) {
        context.claude.answerInTerminal(sessionID: sessionID, requestID: requestID)
        if let session = context.claude.session(for: sessionID) {
            _ = AgentTerminalJumper.jump(pid: session.pid, tty: session.tty)
            collapseAfterAgentJump()
        }
    }

    /// Every open approval and question, oldest first.
    public var agentInteractions: [AgentInteraction] {
        let claude = context.claude.sessions.flatMap(Self.interactions(for:))
        return (claude + context.crewline.interactions).sorted { $0.receivedAt < $1.receivedAt }
    }

    static func interactions(for session: ClaudeCodeSession) -> [AgentInteraction] {
        var result: [AgentInteraction] = []
        let key = AISource.claude.rawValue + ":" + session.id
        if let permission = session.permission {
            result.append(AgentInteraction(
                id: permission.id,
                activityKey: key,
                source: .claude,
                kind: .approval(AgentApprovalRequest(
                    tool: permission.toolName, summary: permission.detail, reviewActionTitle: permission.reviewActionTitle
                )),
                receivedAt: permission.receivedAt
            ))
        }
        if let question = session.question {
            result.append(AgentInteraction(
                id: question.id,
                activityKey: key,
                source: .claude,
                kind: .question(question.form),
                receivedAt: question.receivedAt
            ))
        }
        return result
    }

    /// Usage rings for the Agents page and the compact AI bubble.
    public var agentUsageGroups: [AgentUsageGroup] {
        AgentUsagePolicy.merged(
            claude: context.claudeUsage.group,
            crewline: AgentUsagePolicy.crewlineGroups(from: context.crewline.usageAccounts)
        )
    }

    public func respondToAgent(_ interaction: AgentInteraction, with response: AgentInteractionResponse) {
        switch interaction.source {
        case .crewline:
            if response == .answerElsewhere {
                let runID = String(interaction.activityKey.dropFirst(AISource.crewline.rawValue.count + 1))
                context.crewline.openRun(runID)
                collapseAfterAgentJump()
                return
            }
            context.crewline.respond(to: interaction, with: response)
        case .claude:
            let sessionID = String(interaction.activityKey.dropFirst(AISource.claude.rawValue.count + 1))
            switch (interaction.kind, response) {
            case (.approval, .allowOnce), (.approval, .allowForSession):
                approveClaudePermission(sessionID: sessionID, requestID: interaction.id)
            case (.approval, .deny):
                context.claude.deny(sessionID: sessionID, requestID: interaction.id)
            case (.question(let form), .answer(let answers)):
                context.claude.answer(sessionID: sessionID, questionID: interaction.id, form: form, answers: answers)
            case (.question, .answerElsewhere), (.approval, .answerElsewhere):
                context.claude.answerInTerminal(sessionID: sessionID, requestID: interaction.id)
                if let session = context.claude.session(for: sessionID) {
                    _ = AgentTerminalJumper.jump(pid: session.pid, tty: session.tty)
                    collapseAfterAgentJump()
                }
            default:
                break
            }
        case .codex, .cursor, .terminal:
            break
        }
    }

    /// Which of Pause, Resume and Stop the run card offers for a run.
    public func runControls(for activity: AIActivitySnapshot) -> AgentRunControls {
        switch activity.source {
        case .claude:
            guard let session = context.claude.session(for: activity.id) else { return .none }
            let asking = session.permission != nil || session.question != nil
            let live = !asking && (session.phase == .working || session.control != nil)
            return AgentRunControls(canPause: live, canStop: live, state: session.control)
        case .crewline:
            guard let run = context.crewline.workspace.run(activity.id) else { return .none }
            var state: AgentRunControlState? = run.status == .paused ? .paused(before: nil) : nil
            switch context.crewline.pendingControls[run.id] {
            case .pause: state = .pausing
            case .stop: state = .stopping
            case .resume, nil: break
            }
            return AgentRunControls(
                canPause: run.status == .running || run.status == .starting,
                canStop: run.status.isActive,
                state: state
            )
        case .codex, .cursor, .terminal:
            return .none
        }
    }

    public func controlAgentRun(_ activity: AIActivitySnapshot, _ command: AgentRunCommand) {
        switch activity.source {
        case .claude:
            switch command {
            case .pause: context.claude.pauseRun(sessionID: activity.id)
            case .resume: context.claude.resumeRun(sessionID: activity.id)
            case .stop: context.claude.stopRun(sessionID: activity.id)
            }
        case .crewline:
            context.crewline.control(runID: activity.id, command)
        case .codex, .cursor, .terminal:
            break
        }
    }

    /// The model behind a run, in people's words, when anything names it.
    public func runModelName(for activity: AIActivitySnapshot) -> String? {
        switch activity.source {
        case .claude:
            let raw = context.claudeUsage.modelBySession[activity.id]
                ?? context.claude.session(for: activity.id)?.model
            return raw.map(AgentModelName.display)
        case .crewline:
            return activity.agentLabel
        case .codex, .cursor, .terminal:
            return activity.agentLabel
        }
    }

    /// Goes to where the agent runs: the Claude session's own terminal tab,
    /// the run inside Crewline, or the agent's app for the rest.
    public func jumpToAgent(_ activity: AIActivitySnapshot) {
        switch activity.source {
        case .crewline:
            context.crewline.openRun(activity.id)
        case .claude:
            if let session = context.claude.session(for: activity.id),
               AgentTerminalJumper.jump(pid: session.pid, tty: session.tty) {
                return
            }
            AgentIconCatalog.activate(.claude)
        case .codex, .cursor, .terminal:
            AgentIconCatalog.activate(activity.source)
        }
        collapseAfterAgentJump()
    }

    /// Where a capture can go: Crewline runs (queued as the run's next turn,
    /// with the image attached) and live Claude Code sessions (copied, then
    /// the session's terminal is brought forward to paste into).
    var agentSendTargets: [AgentSendTarget] {
        AgentSendTarget.targets(
            crewline: context.crewline.state == .connected ? context.crewline.workspace : nil,
            claudeSessions: context.claude.sessions
        )
    }

    public func sendToAgent(_ asset: CaptureAsset) {
        guard let identity = SafeAssetFile.selectionIdentity(of: asset) else {
            present(error: NotchShotError.exportFailed("That file changed or is no longer safely readable"))
            return
        }
        sendToAgent(.file(AgentAttachment(url: asset.url, identity: identity)))
    }

    /// Text clippings go as the message itself; image clippings as an
    /// attachment.
    public func sendClipboardEntryToAgent(_ entry: ClipboardEntry) {
        switch entry.kind {
        case .image:
            guard let url = entry.imageURL else { return }
            guard let identity = SafeAssetFile.identity(at: url, maximumBytes: SafeAssetFile.maximumOwnedBytes) else {
                present(error: NotchShotError.exportFailed("That clipping's image is no longer safely readable"))
                return
            }
            sendToAgent(.file(AgentAttachment(url: url, identity: identity)))
        case .text, .link, .color:
            guard let text = entry.text, !text.isEmpty else { return }
            sendToAgent(.text(text))
        case .files:
            break
        }
    }

    func sendToAgent(_ payload: AgentSendPayload) {
        let targets = agentSendTargets
        guard !targets.isEmpty else {
            present(error: NotchShotError.exportFailed(
                "No agent to send to. Start a Claude Code session, or connect Crewline in Settings → Activities."
            ))
            return
        }

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 30, width: 320, height: 26), pullsDown: false)
        for target in targets { popup.addItem(withTitle: target.menuTitle) }
        popup.setAccessibilityLabel("Agent")
        let note = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        note.placeholderString = "Add a note for the agent (optional)"
        note.setAccessibilityLabel("Note")
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 58))
        accessory.addSubview(popup)
        accessory.addSubview(note)

        let alert = NSAlert()
        alert.messageText = payload.alertTitle
        alert.informativeText = payload.alertDetail
        alert.alertStyle = .informational
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = note
        guard alert.runModal() == .alertFirstButtonReturn,
              targets.indices.contains(popup.indexOfSelectedItem) else { return }
        let target = targets[popup.indexOfSelectedItem]
        let message = note.stringValue

        switch target {
        case .claude(let sessionID, _):
            switch payload {
            case .file(let attachment):
                // Only a reference goes on the clipboard, so check that it
                // still names the file chosen before the dialog.
                guard SafeAssetFile.identity(
                    at: attachment.url,
                    maximumBytes: SafeAssetFile.maximumOwnedBytes
                ) == attachment.identity else {
                    present(error: NotchShotError.exportFailed(
                        "That file changed after you chose it. Nothing was copied."
                    ))
                    return
                }
                ImageExport.copyToPasteboard(fileURL: attachment.url)
            case .text(let text):
                let combined = message.isEmpty ? text : message + "\n\n" + text
                clipboardMonitor.copyDerivedTextToPasteboard(combined)
            }
            let session = context.claude.session(for: sessionID)
            if !AgentTerminalJumper.jump(pid: session?.pid, tty: session?.tty) {
                AgentIconCatalog.activate(.claude)
            }
            presentIslandEvent(IslandTransientEvent(
                kind: .notice,
                severity: .success,
                coalescingKey: "sendToAgent",
                symbolName: "doc.on.clipboard",
                title: "Copied for Claude",
                detail: payload.pasteHint
            ))

        case .crewline(let runID, let title):
            let processingLabel = beginProcessing("Sending to Crewline…")
            Task { [weak self] in
                guard let self else { return }
                defer { self.endProcessing(processingLabel) }
                do {
                    switch payload {
                    case .file(let attachment):
                        try await self.context.crewline.sendFollowUp(runID: runID, note: message, files: [attachment])
                    case .text(let text):
                        let combined = message.isEmpty ? text : message + "\n\n" + text
                        try await self.context.crewline.sendFollowUp(runID: runID, note: combined, files: [])
                    }
                    self.presentIslandEvent(IslandTransientEvent(
                        kind: .notice,
                        severity: .success,
                        coalescingKey: "sendToAgent",
                        symbolName: "paperplane.fill",
                        title: "Sent to Crewline",
                        detail: title
                    ))
                } catch {
                    self.present(error: error)
                }
            }
        }
    }

    private func collapseAfterAgentJump() {
        // The user is leaving for another app; keep the island out of the way.
        collapseIsland()
        collapse()
    }
}

/// A file chosen for an agent, with the identity it had when chosen. It is
/// read only after the send dialog closes, and only if it is still that file.
public struct AgentAttachment: Equatable, Sendable {
    public var url: URL
    public var identity: ExternalFileIdentity
}

enum AgentSendPayload: Equatable {
    case file(AgentAttachment)
    case text(String)

    var alertTitle: String {
        switch self {
        case .file(let attachment): "Send \(attachment.url.lastPathComponent) to an agent"
        case .text: "Send this clipping to an agent"
        }
    }

    var alertDetail: String {
        switch self {
        case .file:
            "A Crewline run gets the image as its next message. For a Claude Code session the image is copied and its terminal comes forward, ready to paste with ⌃V."
        case .text:
            "A Crewline run gets the text as its next message. For a Claude Code session the text is copied and its terminal comes forward, ready to paste."
        }
    }

    var pasteHint: String {
        switch self {
        case .file: "Paste with ⌃V"
        case .text: "Paste with ⌘V"
        }
    }
}

public enum AgentSendTarget: Equatable, Sendable {
    case crewline(runID: String, title: String)
    case claude(sessionID: String, title: String)

    public var menuTitle: String {
        switch self {
        case .crewline(_, let title): "Crewline · " + title
        case .claude(_, let title): "Claude Code · " + title
        }
    }

    /// Live work first: active Crewline runs, then live Claude sessions, then
    /// a few recently finished runs that can still take a follow-up.
    static func targets(
        crewline workspace: CrewlineWorkspace?,
        claudeSessions: [ClaudeCodeSession],
        limit: Int = 10
    ) -> [AgentSendTarget] {
        var targets: [AgentSendTarget] = []
        let runs = workspace?.followUpCandidates ?? []
        func runTarget(_ run: CrewlineRun) -> AgentSendTarget {
            let agent = workspace?.agentName(for: run).map { " (\($0))" } ?? ""
            return .crewline(runID: run.id, title: String((workspace?.title(for: run) ?? "Run").prefix(60)) + agent)
        }
        targets += runs.filter(\.status.isActive).map(runTarget)
        targets += claudeSessions.filter { !$0.phase.isTerminal }.map {
            .claude(sessionID: $0.id, title: String($0.title.prefix(60)) + " — " + $0.workspaceName)
        }
        targets += runs.filter { !$0.status.isActive }.prefix(4).map(runTarget)
        return Array(targets.prefix(limit))
    }
}
