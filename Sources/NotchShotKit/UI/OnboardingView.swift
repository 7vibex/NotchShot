import SwiftUI

public enum FirstCaptureOutcome: String, CaseIterable, Identifiable {
    case copyAndSave
    case copyOnly
    case saveOnly

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .copyAndSave: "Copy and Save"
        case .copyOnly: "Copy Only"
        case .saveOnly: "Save Only"
        }
    }

    public var detail: String {
        switch self {
        case .copyAndSave: "Ready to paste, with a file saved to your output folder."
        case .copyOnly: "Fastest for messages and documents; History still keeps a local result."
        case .saveOnly: "Creates a file without changing the clipboard."
        }
    }
}

/// A task-first first run: choose the default outcome, learn the three entry
/// points, then complete a real capture through the normal product workflow.
public struct OnboardingView: View {
    @State private var outcome: FirstCaptureOutcome = .copyAndSave
    let onTakeFirstCapture: (FirstCaptureOutcome) -> Void
    let onFinishLater: () -> Void

    public init(
        onTakeFirstCapture: @escaping (FirstCaptureOutcome) -> Void,
        onFinishLater: @escaping () -> Void
    ) {
        self.onTakeFirstCapture = onTakeFirstCapture
        self.onFinishLater = onFinishLater
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 7) {
                Label("Welcome to NotchShot", systemImage: "camera.viewfinder")
                    .font(.largeTitle.weight(.semibold))
                Text("Capture, explain, and share from your Mac — with OCR and privacy checks performed locally.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            GroupBox("After a capture") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Default outcome", selection: $outcome) {
                        ForEach(FirstCaptureOutcome.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    Text(outcome.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("Use the notch, the menu-bar camera, or ⇧⌘4.", systemImage: "command")
                Label(
                    "macOS asks for Screen Recording access when you take the first capture.",
                    systemImage: "lock.shield"
                )
                Label("If macOS requires a relaunch, NotchShot resumes this capture afterward.", systemImage: "arrow.clockwise")
            }
            .font(.callout)

            Spacer(minLength: 0)

            HStack {
                Button("Finish Later", action: onFinishLater)
                Spacer()
                Button("Take First Capture") { onTakeFirstCapture(outcome) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(minWidth: 620, minHeight: 440)
    }
}
