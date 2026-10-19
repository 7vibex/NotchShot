import Foundation

/// How lively the island's motion is. Every named curve in `NotchMotion` is
/// tuned per style, so switching it changes the whole island at once instead
/// of one animation at a time.
public enum IslandAnimationStyle: String, CaseIterable, Identifiable, Sendable {
    /// Critically damped everywhere: shapes arrive and stop, nothing overshoots.
    case subtle
    /// The default. A small overshoot on the way open, none on the way closed.
    case iPhone
    /// More travel and a visible settle, for people who like the island to feel
    /// springy.
    case bouncy

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .subtle: "Subtle"
        case .iPhone: "iPhone-like"
        case .bouncy: "Bouncy"
        }
    }
}
