import SwiftUI

/// Presentation rules for the Claude-specific surface. Keeping these outside
/// the view makes the Vibe Notch ordering deterministic and easy to exercise
/// without launching the menu-bar app.
enum ClaudeVibeSessionPresentation {
    static func statusText(for session: ClaudeCodeSession) -> String {
        if session.permission != nil { return "Waiting for approval" }
        return switch session.phase {
        case .working: "Processing"
        case .waiting: "Ready"
        case .finished: "Ended"
        case .failed: "Failed"
        }
    }

    static func sorted(_ sessions: [ClaudeCodeSession]) -> [ClaudeCodeSession] {
        sessions.sorted { lhs, rhs in
            let lhsNeedsAttention = lhs.permission != nil || lhs.phase == .failed
            let rhsNeedsAttention = rhs.permission != nil || rhs.phase == .failed
            if lhsNeedsAttention != rhsNeedsAttention {
                return lhsNeedsAttention
            }
            if lhs.phase.isTerminal != rhs.phase.isTerminal {
                return !lhs.phase.isTerminal
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }
}

/// The small Claude mark used by Vibe Notch. It stays drawn rather than
/// depending on a separately-installed Claude app icon, so the surface remains
/// recognizable on every Mac where Claude Code runs.
struct ClaudeVibeCrabIcon: View {
    let size: CGFloat
    private let accent = Color(red: 0.85, green: 0.47, blue: 0.34)

    var body: some View {
        Canvas { context, canvasSize in
            let scale = size / 52
            let xOffset = (canvasSize.width - 66 * scale) / 2

            func rect(_ source: CGRect) -> CGRect {
                CGRect(
                    x: xOffset + source.minX * scale,
                    y: source.minY * scale,
                    width: source.width * scale,
                    height: source.height * scale
                )
            }

            func fill(_ source: CGRect, color: Color) {
                context.fill(Path(rect(source)), with: .color(color))
            }

            // Antennae and legs preserve the pixel-art silhouette from the
            // reference app at the small sizes used in the notch.
            fill(CGRect(x: 0, y: 13, width: 6, height: 13), color: accent)
            fill(CGRect(x: 60, y: 13, width: 6, height: 13), color: accent)
            for x in [CGFloat(6), 18, 42, 54] {
                fill(CGRect(x: x, y: 39, width: 6, height: 13), color: accent)
            }
            fill(CGRect(x: 6, y: 0, width: 54, height: 39), color: accent)
            fill(CGRect(x: 12, y: 13, width: 6, height: 6.5), color: .black)
            fill(CGRect(x: 48, y: 13, width: 6, height: 6.5), color: .black)
        }
        .frame(width: size * (66 / 52), height: size)
        .accessibilityHidden(true)
    }
}
