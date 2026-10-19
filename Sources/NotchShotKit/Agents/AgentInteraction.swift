import Foundation

/// Something an agent is blocked on until the user answers: a tool approval or
/// a question. Each source adapter (the Claude hook bridge, Crewline) turns its
/// own wire format into this shape, so the island draws one card for both and
/// hands the answer back to the adapter that asked.
public struct AgentInteraction: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        case approval(AgentApprovalRequest)
        case question(AgentQuestionForm)
    }

    /// The adapter's request identifier: an approval or input request ID.
    public var id: String
    /// `AIActivitySnapshot.displayIdentifier` of the run that asked.
    public var activityKey: String
    public var source: AISource
    public var kind: Kind
    public var receivedAt: Date

    public init(
        id: String,
        activityKey: String,
        source: AISource,
        kind: Kind,
        receivedAt: Date = Date()
    ) {
        self.id = id
        self.activityKey = activityKey
        self.source = source
        self.kind = kind
        self.receivedAt = receivedAt
    }

    public var isQuestion: Bool {
        if case .question = kind { return true }
        return false
    }

    /// One line for compact surfaces, such as the left-wing bubble.
    public var headline: String {
        switch kind {
        case .approval(let request):
            "\(request.tool) needs approval"
        case .question(let form):
            form.questions.first?.prompt ?? form.title
        }
    }
}

public struct AgentApprovalRequest: Equatable, Sendable {
    public var tool: String
    public var summary: String?
    /// Whether the source can remember the approval for the rest of the run.
    public var offersSessionApproval: Bool

    public init(tool: String, summary: String? = nil, offersSessionApproval: Bool = false) {
        self.tool = tool
        self.summary = summary
        self.offersSessionApproval = offersSessionApproval
    }
}

public struct AgentQuestionOption: Equatable, Identifiable, Sendable {
    /// What the source expects back. Crewline checks it against what it
    /// offered; Claude's `AskUserQuestion` answers with the label itself.
    public var value: String
    public var label: String
    public var hint: String?

    public var id: String { value }

    public init(value: String, label: String, hint: String? = nil) {
        self.value = value
        self.label = label
        self.hint = hint
    }
}

public struct AgentQuestion: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case select
        case multiSelect
        case confirm
        case text
    }

    public var header: String
    public var prompt: String
    public var kind: Kind
    public var options: [AgentQuestionOption]
    public var placeholder: String?

    public init(
        header: String = "",
        prompt: String,
        kind: Kind,
        options: [AgentQuestionOption] = [],
        placeholder: String? = nil
    ) {
        self.header = header
        self.prompt = prompt
        self.kind = kind
        self.options = options
        self.placeholder = placeholder
    }

    /// What the card offers; a confirm question offers Yes and No.
    public var choices: [AgentQuestionOption] {
        kind == .confirm
            ? [AgentQuestionOption(value: "yes", label: "Yes"), AgentQuestionOption(value: "no", label: "No")]
            : options
    }
}

public struct AgentQuestionForm: Equatable, Sendable {
    public enum Encoding: Equatable, Sendable {
        /// Crewline's normalized single question: `{"answer": value}`, with a
        /// confirm answered as a Boolean.
        case crewlineNormalized
        /// Crewline's native form: `{"0": value, "1": [values]}`.
        case crewlineIndexed
        /// Claude's `AskUserQuestion`, answered by option index: `{"0":
        /// ["1"], "1": ["0", "2"]}`. The hook maps indices back onto Claude's
        /// own wording, so labels redacted on the way out never round-trip.
        case claudeIndexed
    }

    public var title: String
    public var questions: [AgentQuestion]
    public var encoding: Encoding

    public init(title: String, questions: [AgentQuestion], encoding: Encoding) {
        self.title = title
        self.questions = questions
        self.encoding = encoding
    }

    /// True when every question has a usable answer.
    public func isComplete(_ answers: AgentQuestionAnswers) -> Bool {
        questions.indices.allSatisfy { answers.isAnswered($0, kind: questions[$0].kind) }
    }

    /// A single closed question can be sent the moment an option is tapped;
    /// everything else needs an explicit Send.
    public var sendsOnFirstChoice: Bool {
        guard questions.count == 1, let only = questions.first else { return false }
        return only.kind == .select || only.kind == .confirm
    }
}

/// The user's in-progress answers, keyed by question index.
public struct AgentQuestionAnswers: Equatable, Sendable {
    public var single: [Int: String] = [:]
    public var multiple: [Int: Set<String>] = [:]

    public init(single: [Int: String] = [:], multiple: [Int: Set<String>] = [:]) {
        self.single = single
        self.multiple = multiple
    }

    func isAnswered(_ index: Int, kind: AgentQuestion.Kind) -> Bool {
        if kind == .multiSelect { return !(multiple[index] ?? []).isEmpty }
        return !(single[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum AgentInteractionResponse: Equatable, Sendable {
    case allowOnce
    case allowForSession
    case deny
    case answer(AgentQuestionAnswers)
    /// Hand the request back to the agent's own UI: Claude's terminal
    /// picker, or the run in Crewline.
    case answerElsewhere
}

/// A JSON value small enough to compare in tests and hand to
/// `JSONSerialization` on the wire.
public enum AgentAnswerValue: Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case strings([String])

    var jsonObject: Any {
        switch self {
        case .string(let value): value
        case .bool(let value): value
        case .strings(let values): values
        }
    }
}

public enum AgentAnswerEncoder {
    /// The answers payload for the form's source, or nil while any question
    /// is unanswered.
    public static func encode(
        _ answers: AgentQuestionAnswers,
        for form: AgentQuestionForm
    ) -> [String: AgentAnswerValue]? {
        guard form.isComplete(answers) else { return nil }

        func trimmed(_ index: Int) -> String {
            (answers.single[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func chosenValues(_ index: Int) -> [String] {
            let chosen = answers.multiple[index] ?? []
            // Keep the order the agent offered them in, not set order.
            let offered = form.questions[index].options.map(\.value).filter(chosen.contains)
            let extra = chosen.subtracting(offered).sorted()
            return offered + extra
        }

        switch form.encoding {
        case .crewlineNormalized:
            guard let question = form.questions.first else { return nil }
            let value: AgentAnswerValue = switch question.kind {
            case .multiSelect: .strings(chosenValues(0))
            case .confirm: .bool(trimmed(0) == "yes")
            case .select, .text: .string(trimmed(0))
            }
            return ["answer": value]

        case .crewlineIndexed:
            var payload: [String: AgentAnswerValue] = [:]
            for (index, question) in form.questions.enumerated() {
                payload[String(index)] = question.kind == .multiSelect
                    ? .strings(chosenValues(index))
                    : .string(trimmed(index))
            }
            return payload

        case .claudeIndexed:
            var payload: [String: AgentAnswerValue] = [:]
            for (index, question) in form.questions.enumerated() {
                payload[String(index)] = .strings(
                    question.kind == .multiSelect ? chosenValues(index) : [trimmed(index)]
                )
            }
            return payload
        }
    }

    static func jsonObject(_ payload: [String: AgentAnswerValue]) -> [String: Any] {
        payload.mapValues(\.jsonObject)
    }
}
