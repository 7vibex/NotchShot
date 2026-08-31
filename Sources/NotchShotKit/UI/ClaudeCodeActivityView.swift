import SwiftUI

struct ClaudePermissionBar: View {
    let request: ClaudeCodePermissionRequest
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: NotchIsland.Spacing.snug) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 26, height: 26)
                .background {
                    Circle().fill(.orange.opacity(0.14))
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Permission requested")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                Text(request.toolName)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                if let detail = request.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 8))
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: NotchIsland.Spacing.tight)

            Button("Deny", action: onDeny)
                .buttonStyle(NotchPressButtonStyle())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                .frame(minWidth: 48, minHeight: NotchIsland.Hit.control)
                .background {
                    RoundedRectangle(cornerRadius: NotchIsland.Radius.control, style: .continuous)
                        .fill(Color.islandInk(NotchIsland.Ink.fill))
                }
                .accessibilityLabel("Deny Claude Code permission")
                .accessibilityHint("Reject the requested tool call")

            Button("Allow", action: onApprove)
                .buttonStyle(NotchPressButtonStyle())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.black)
                .frame(minWidth: 52, minHeight: NotchIsland.Hit.control)
                .background {
                    RoundedRectangle(cornerRadius: NotchIsland.Radius.control, style: .continuous)
                        .fill(.orange)
                }
                .accessibilityLabel("Allow Claude Code permission")
                .accessibilityHint("Approve the requested tool call")
        }
        .padding(.horizontal, NotchIsland.Spacing.element)
        .padding(.vertical, NotchIsland.Spacing.tight)
        .background {
            RoundedRectangle(cornerRadius: NotchIsland.Radius.control, style: .continuous)
                .fill(.orange.opacity(0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: NotchIsland.Radius.control, style: .continuous)
                .stroke(.orange.opacity(0.32), lineWidth: NotchIsland.Stroke.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Claude Code permission requested for \(request.toolName)")
    }
}

struct ClaudeConversationPanel: View {
    let session: ClaudeCodeSession
    let onBack: () -> Void

    @State private var messages: [ClaudeTranscriptMessage] = []
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: NotchIsland.Spacing.element) {
            header

            if isLoading && messages.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if messages.isEmpty {
                VStack(spacing: NotchIsland.Spacing.tight) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                    Text("No local conversation found")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.secondary))
                    Text("Claude Code has not written a readable session transcript yet.")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: NotchIsland.Spacing.tight) {
                        ForEach(messages) { message in
                            messageRow(message)
                        }
                    }
                    .padding(.trailing, NotchIsland.Spacing.tight)
                }
                .scrollIndicators(.visible)
                .textSelection(.enabled)
            }
        }
        .task(id: session.id) {
            await reload()
        }
        .padding(.horizontal, NotchIsland.Spacing.group)
        .padding(.vertical, NotchIsland.Spacing.element)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Claude Code conversation for \(session.title)")
    }

    private var header: some View {
        HStack(spacing: NotchIsland.Spacing.snug) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 18, height: 18)
                    .frame(width: NotchIsland.Hit.control, height: NotchIsland.Hit.control)
            }
            .buttonStyle(NotchPressButtonStyle())
            .accessibilityLabel("Back to Claude Code sessions")

            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                    .lineLimit(1)
                Text(session.workspaceName)
                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
                    .lineLimit(1)
            }

            Spacer(minLength: NotchIsland.Spacing.tight)

            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: NotchIsland.Hit.control, height: NotchIsland.Hit.control)
            }
            .buttonStyle(NotchPressButtonStyle())
            .disabled(isLoading)
            .accessibilityLabel("Refresh Claude Code conversation")
        }
    }

    @ViewBuilder
    private func messageRow(_ message: ClaudeTranscriptMessage) -> some View {
        HStack(alignment: .top, spacing: NotchIsland.Spacing.tight) {
            Image(systemName: symbol(for: message.role))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(color(for: message.role))
                .frame(width: 20, height: 20)
                .background {
                    Circle().fill(color(for: message.role).opacity(0.14))
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(label(for: message.role))
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(color(for: message.role))
                Text(message.text)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, NotchIsland.Spacing.element)
        .padding(.vertical, NotchIsland.Spacing.tight)
        .background {
            RoundedRectangle(cornerRadius: NotchIsland.Radius.control, style: .continuous)
                .fill(Color.black.opacity(message.role == .user ? 0.34 : 0.22))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label(for: message.role)): \(message.text)")
    }

    private func reload() async {
        isLoading = true
        let session = session
        let loaded = await Task.detached(priority: .userInitiated) {
            ClaudeConversationReader.messages(for: session)
        }.value
        guard !Task.isCancelled else {
            isLoading = false
            return
        }
        messages = loaded
        isLoading = false
    }

    private func symbol(for role: ClaudeTranscriptRole) -> String {
        switch role {
        case .user: "person.fill"
        case .assistant: "sparkles"
        case .tool: "wrench.and.screwdriver.fill"
        }
    }

    private func label(for role: ClaudeTranscriptRole) -> String {
        switch role {
        case .user: "You"
        case .assistant: "Claude"
        case .tool: "Tool"
        }
    }

    private func color(for role: ClaudeTranscriptRole) -> Color {
        switch role {
        case .user: .blue
        case .assistant: .orange
        case .tool: .purple
        }
    }
}
