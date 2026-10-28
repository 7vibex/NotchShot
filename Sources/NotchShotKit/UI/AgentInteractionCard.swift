import SwiftUI

/// What an agent is waiting on, drawn under its row in the agent list.
///
/// It follows the notification stack rather than a form: no boxes or
/// coloured outlines, just the request in plain text and quiet capsules,
/// with white for the one action that says yes. Choices are reply chips, as
/// in Messages, so a single question is answered with one click.
struct AgentInteractionCard: View {
    let interaction: AgentInteraction
    let onRespond: (AgentInteractionResponse) -> Void

    var body: some View {
        switch interaction.kind {
        case .approval(let request):
            AgentApprovalCard(request: request, source: interaction.source, onRespond: onRespond)
        case .question(let form):
            AgentQuestionCard(
                form: form,
                source: interaction.source,
                onSubmit: { onRespond(.answer($0)) },
                onAnswerElsewhere: { onRespond(.answerElsewhere) }
            )
            // A new question from the same run must start with a clean slate.
            .id(interaction.id)
        }
    }
}

private struct AgentApprovalCard: View {
    let request: AgentApprovalRequest
    let source: AISource
    let onRespond: (AgentInteractionResponse) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NotchIsland.Spacing.element) {
            if let summary = request.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Color.islandInk(0.82))
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .padding(.horizontal, NotchIsland.Spacing.row)
                    .padding(.vertical, NotchIsland.Spacing.snug + 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color.islandInk(NotchIsland.Ink.fill * 0.75),
                        in: RoundedRectangle(cornerRadius: NotchIsland.Radius.control, style: .continuous)
                    )
                    .textSelection(.enabled)
            }

            HStack(spacing: NotchIsland.Spacing.snug) {
                Spacer(minLength: 0)
                AgentCapsuleButton(title: "Deny") { onRespond(.deny) }
                    .accessibilityLabel("Deny \(request.tool)")
                if request.offersSessionApproval {
                    AgentCapsuleButton(title: "Allow for This Run") { onRespond(.allowForSession) }
                        .help("Allow \(request.tool) for the rest of this run")
                }
                AgentCapsuleButton(title: "Allow", isPrimary: true) { onRespond(.allowOnce) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Allow \(request.tool) once")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(source.title) needs approval for \(request.tool)")
    }
}

private struct AgentQuestionCard: View {
    let form: AgentQuestionForm
    let source: AISource
    let onSubmit: (AgentQuestionAnswers) -> Void
    let onAnswerElsewhere: () -> Void

    @State private var answers = AgentQuestionAnswers()
    @FocusState private var focusedField: Int?

    private var elsewhereTitle: String {
        source == .crewline ? "Open in Crewline" : "Answer in Terminal"
    }

    /// A lone free-text question sends from its own field.
    private var sendsFromField: Bool {
        form.questions.count == 1 && form.questions.first?.kind == .text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NotchIsland.Spacing.element) {
            ForEach(Array(form.questions.enumerated()), id: \.offset) { index, question in
                if form.sendsOnFirstChoice {
                    // One closed question: the choices and the way out share
                    // a line when they fit, as a notification's actions do.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: NotchIsland.Spacing.element) {
                            HStack(spacing: NotchIsland.Spacing.snug) { chips(for: question, at: index) }
                                .fixedSize()
                            Spacer(minLength: NotchIsland.Spacing.element)
                            elsewhereButton
                        }
                        VStack(alignment: .leading, spacing: NotchIsland.Spacing.tight) {
                            questionView(question, index: index)
                            elsewhereButton
                        }
                    }
                } else {
                    questionView(question, index: index)
                }
            }

            if !form.sendsOnFirstChoice {
                HStack(spacing: NotchIsland.Spacing.snug) {
                    elsewhereButton
                    Spacer(minLength: 0)
                    if !sendsFromField {
                        AgentCapsuleButton(title: "Send", isPrimary: true) { onSubmit(answers) }
                            .disabled(!form.isComplete(answers))
                            .opacity(form.isComplete(answers) ? 1 : 0.4)
                            .keyboardShortcut(.defaultAction)
                            .accessibilityLabel("Send answer to \(source.title)")
                            .padding(.vertical, -(NotchIsland.Hit.control - 28) / 2)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(source.title) asked: \(form.questions.first?.prompt ?? form.title)")
    }

    /// A quiet link out to the agent's own prompt. It lays out at the chips'
    /// height so it never opens a gap under them; the full target still
    /// takes clicks around it.
    private var elsewhereButton: some View {
        Button(action: onAnswerElsewhere) {
            HStack(spacing: 3) {
                Text(elsewhereTitle)
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 8.5, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.islandInk(NotchIsland.Ink.tertiary))
            .frame(minHeight: NotchIsland.Hit.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressButtonStyle())
        .padding(.vertical, -(NotchIsland.Hit.control - 28) / 2)
        .fixedSize()
        .help(source == .crewline ? "Answer this in Crewline instead" : "Let Claude ask in its own terminal picker")
    }

    @ViewBuilder
    private func chips(for question: AgentQuestion, at index: Int) -> some View {
        ForEach(question.choices) { option in
            AgentReplyChip(
                title: option.label,
                isSelected: isSelected(option.value, at: index, kind: question.kind),
                showsCheck: question.kind == .multiSelect
            ) {
                choose(option.value, at: index, question: question)
            }
            .help(option.hint ?? "")
        }
    }

    @ViewBuilder
    private func questionView(_ question: AgentQuestion, index: Int) -> some View {
        VStack(alignment: .leading, spacing: NotchIsland.Spacing.snug) {
            // The row already reads out a lone question; more than one need
            // their own prompts.
            if form.questions.count > 1 {
                Text(question.prompt)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch question.kind {
            case .text:
                AgentReplyField(
                    placeholder: question.placeholder ?? "Reply",
                    text: Binding(
                        get: { answers.single[index] ?? "" },
                        set: { answers.single[index] = $0 }
                    ),
                    showsSend: sendsFromField,
                    canSend: form.isComplete(answers),
                    onSend: { if form.isComplete(answers) { onSubmit(answers) } }
                )
                .focused($focusedField, equals: index)
                .onAppear {
                    if index == 0, form.questions.count == 1 { focusedField = 0 }
                }

            case .select, .multiSelect, .confirm:
                AgentChipFlow(spacing: NotchIsland.Spacing.snug) {
                    chips(for: question, at: index)
                }
            }
        }
    }

    private func isSelected(_ value: String, at index: Int, kind: AgentQuestion.Kind) -> Bool {
        kind == .multiSelect
            ? answers.multiple[index]?.contains(value) == true
            : answers.single[index] == value
    }

    private func choose(_ value: String, at index: Int, question: AgentQuestion) {
        if question.kind == .multiSelect {
            var chosen = answers.multiple[index] ?? []
            if chosen.contains(value) { chosen.remove(value) } else { chosen.insert(value) }
            answers.multiple[index] = chosen
            return
        }
        answers.single[index] = value
        if form.sendsOnFirstChoice { onSubmit(answers) }
    }
}

// MARK: - Controls

/// The list's one button shape. Neutral is the island's soft grey capsule
/// (the notification Reply); primary is white with black text, the way the
/// system marks the affirmative choice on a dark surface.
struct AgentCapsuleButton: View {
    let title: String
    var isPrimary = false
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(isPrimary ? Color.black : Color.islandInk(NotchIsland.Ink.primary))
                .padding(.horizontal, NotchIsland.Spacing.group)
                .frame(height: 28)
                .background(fill, in: Capsule(style: .continuous))
                .frame(minHeight: NotchIsland.Hit.control)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchPressButtonStyle())
        .onHover { isHovered = $0 && isEnabled }
        .fixedSize()
    }

    private var fill: Color {
        if isPrimary { return .white.opacity(isHovered ? 0.86 : 1) }
        return Color.islandInk(isHovered ? 0.22 : 0.15)
    }
}

/// A suggested reply. Picking one fills it white, like a selected segment.
private struct AgentReplyChip: View {
    let title: String
    let isSelected: Bool
    let showsCheck: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if showsCheck, isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.black : Color.islandInk(NotchIsland.Ink.primary))
            .padding(.horizontal, NotchIsland.Spacing.group)
            .frame(height: 28)
            .background(
                isSelected ? Color.white : Color.islandInk(isHovered ? 0.22 : 0.15),
                in: Capsule(style: .continuous)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(NotchPressButtonStyle())
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A reply field shaped like the chips beside it, with its own send arrow
/// when it is the whole answer.
private struct AgentReplyField: View {
    let placeholder: String
    @Binding var text: String
    let showsSend: Bool
    let canSend: Bool
    let onSend: () -> Void

    var body: some View {
        HStack(spacing: NotchIsland.Spacing.snug) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.islandInk(NotchIsland.Ink.primary))
                .onSubmit(onSend)
            if showsSend {
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.black, Color.white.opacity(canSend ? 1 : 0.3))
                        .frame(width: NotchIsland.Hit.control, height: NotchIsland.Hit.control)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NotchPressButtonStyle())
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
        }
        .padding(.leading, NotchIsland.Spacing.group)
        .padding(.trailing, showsSend ? -NotchIsland.Spacing.tight : NotchIsland.Spacing.group)
        .frame(height: 32)
        .background(Color.islandInk(NotchIsland.Ink.fill), in: Capsule(style: .continuous))
    }
}

/// Lays chips out left to right and wraps them, so short answers sit on one
/// line and long ones still fit.
struct AgentChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = fittedSize(of: subviews[index], within: bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    /// A chip's own size, but never wider than the row: a long label
    /// truncates rather than running past the island's edge.
    private func fittedSize(of subview: LayoutSubview, within width: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        guard width.isFinite, ideal.width > width else { return ideal }
        return subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = fittedSize(of: subviews[index], within: width)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
