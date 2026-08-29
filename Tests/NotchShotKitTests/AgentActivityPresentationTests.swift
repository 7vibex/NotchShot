import AppKit
import SwiftUI
import Testing
@testable import NotchShotKit

@Suite("Agent activity presentation")
struct AgentActivityPresentationTests {

    private let accent = Color.blue

    @Test("Every state a user must act on is tinted apart from working")
    func attentionStatesAreDistinct() {
        // The previous panel tinted everything except `failed` with the source
        // accent, which made "Needs attention" — the one state that exists to
        // pull the eye — render identically to "Working".
        let working = AIActivityState.working.tint(sourceAccent: accent)
        for state in [AIActivityState.waiting, .finished, .failed] {
            #expect(state.tint(sourceAccent: accent) != working)
        }
        #expect(AIActivityState.waiting.tint(sourceAccent: accent)
            != AIActivityState.failed.tint(sourceAccent: accent))
    }

    @Test("Only waiting and failed ask for attention")
    func attentionFlag() {
        #expect(AIActivityState.waiting.isAttention)
        #expect(AIActivityState.failed.isAttention)
        #expect(!AIActivityState.working.isAttention)
        #expect(!AIActivityState.finished.isAttention)
    }

    @Test("The collapsed strip's label stays inside a notch wing")
    func compactTitlesAreShort() {
        for state in AIActivityState.allCases {
            #expect(!state.compactTitle.isEmpty)
            // The closed island's wing fits roughly one word; "Needs attention"
            // does not, which is why `title` is not reused here.
            #expect(!state.compactTitle.contains(" "))
            #expect(state.compactTitle.count <= 10)
        }
    }

    @Test("A home-relative workspace is abbreviated, and others are not")
    func workspaceAbbreviation() {
        let home = "/Users/example"
        #expect(AgentWorkspaceFormatter.display("/Users/example/Documents/NOTCH", home: home)
            == "~/Documents/NOTCH")
        #expect(AgentWorkspaceFormatter.display(home, home: home) == "~")
        #expect(AgentWorkspaceFormatter.display("/Volumes/Work/repo", home: home)
            == "/Volumes/Work/repo")
    }

    @Test("A sibling directory sharing the home prefix is left alone")
    func workspacePrefixIsNotASubstringMatch() {
        // "/Users/example2" starts with "/Users/example" but is a different
        // account's directory; abbreviating it would claim it as this user's.
        #expect(AgentWorkspaceFormatter.display("/Users/example2/src", home: "/Users/example")
            == "/Users/example2/src")
    }

    @MainActor
    @Test("Every source declares at least one application to look for")
    func everySourceHasCandidates() {
        for source in AISource.allCases {
            #expect(!AgentIconCatalog.bundleIdentifiers(for: source).isEmpty)
        }
    }

    @MainActor
    @Test("Icon resolution agrees with application resolution and is cached")
    func iconResolutionIsConsistent() {
        for source in AISource.allCases {
            let url = AgentIconCatalog.applicationURL(for: source)
            let icon = AgentIconCatalog.icon(for: source)
            // An icon exists exactly when the application does; a source with no
            // installed app must fall through to the drawn mark, never to a
            // blank image.
            #expect((url == nil) == (icon == nil))
            // A SwiftUI body re-runs on every progress tick, so a second call
            // must come from the cache rather than from LaunchServices.
            #expect(AgentIconCatalog.applicationURL(for: source) == url)
        }
    }
}

/// A physical notch is a hole, not a dark pixel: content drawn behind it is
/// gone, not dimmed, and nothing about the running app reveals the mistake —
/// it simply looks like the label was never there. These pin the geometry the
/// agent strip depends on.
@Suite("Notch cutout safety")
struct NotchCutoutSafetyTests {

    private func metrics(notch: CGSize) -> NotchMetrics {
        NotchMetrics(
            screenFrame: CGRect(x: 0, y: 0, width: 1470, height: 956),
            hasPhysicalNotch: true,
            notchSize: notch,
            menuBarHeight: notch.height
        )
    }

    private func contextSnapshot(_ presentation: ContextPresentation) -> ContextSnapshot {
        var snapshot = ContextSnapshot(kind: .ai, title: "Claude · Working", metric: "62%")
        snapshot.presentation = presentation
        return snapshot
    }

    @Test("The collapsed strip reserves the cutout and a wing on each side")
    func collapsedStripReservesTheCutout() {
        for width in [CGFloat(178), 200, 250] {
            let notch = CGSize(width: width, height: 32)
            let layout = NotchLayout.layout(
                for: .context(contextSnapshot(.compact)),
                metrics: metrics(notch: notch),
                isPeeking: false,
                resultCount: 0
            )
            let wing = (layout.size.width - width) / 2
            #expect(wing == NotchLayout.compactContextWing)
            // The wing has to hold a 24pt ring glyph plus padding on one side
            // and a percentage on the other. Anything under ~60pt puts one of
            // them under the camera.
            #expect(wing >= 60)
        }
    }

    @Test("Peek and expanded content starts below the cutout")
    func revealedContentClearsTheCutout() {
        let notch = CGSize(width: 178, height: 32)
        let peek = NotchLayout.layout(
            for: .context(contextSnapshot(.compact)),
            metrics: metrics(notch: notch),
            isPeeking: true,
            resultCount: 0
        )
        let expanded = NotchLayout.layout(
            for: .context(contextSnapshot(.expanded)),
            metrics: metrics(notch: notch),
            isPeeking: false,
            resultCount: 0
        )
        for layout in [peek, expanded] {
            #expect(layout.contentTopInset >= notch.height)
        }
    }

    @Test("A synthetic island reserves nothing, because it hides nothing")
    func syntheticIslandKeepsItsFullWidth() {
        let synthetic = NotchMetrics(
            screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            hasPhysicalNotch: false,
            notchSize: NotchMetrics.syntheticIslandSize,
            menuBarHeight: 24
        )
        let layout = NotchLayout.layout(
            for: .context(contextSnapshot(.expanded)),
            metrics: synthetic,
            isPeeking: false,
            resultCount: 0
        )
        #expect(layout.contentTopInset == 0)
    }
}

@Suite("Agent strip signal")
struct AgentStripSignalTests {

    private func activity(
        _ state: AIActivityState,
        progress: Double? = nil
    ) -> AIActivitySnapshot {
        AIActivitySnapshot(
            id: "x", source: .claude, state: state,
            title: "t", progress: progress, steps: [],
            startedAt: Date(), updatedAt: Date()
        )
    }

    @Test("A run that needs the user outranks its own progress")
    func attentionOutranksProgress() {
        // A run blocked on approval at 90% needs the person, not a percentage:
        // the number would read as "nearly done, ignore me".
        for state in [AIActivityState.waiting, .failed] {
            let signal = AgentStripSignal.signal(for: activity(state, progress: 0.9))
            guard case .attention = signal else {
                Issue.record("\(state) with progress should signal attention, got \(signal)")
                continue
            }
        }
    }

    @Test("Progress wins when nothing is blocked")
    func progressWhenUnblocked() {
        #expect(AgentStripSignal.signal(for: activity(.working, progress: 0.62))
            == .percent(62))
        #expect(AgentStripSignal.signal(for: activity(.finished, progress: 1))
            == .percent(100))
    }

    @Test("Out-of-range progress is clamped rather than rendered raw")
    func progressIsClamped() {
        #expect(AgentStripSignal.signal(for: activity(.working, progress: 1.8))
            == .percent(100))
        #expect(AgentStripSignal.signal(for: activity(.working, progress: -0.5))
            == .percent(0))
    }

    @Test("Without progress the state supplies a glyph")
    func glyphFallback() {
        #expect(AgentStripSignal.signal(for: activity(.working))
            == .glyph(symbol: AIActivityState.working.stripSymbol))
    }

    @Test("Every state has a single-glyph form for the wing")
    func everyStateHasAStripSymbol() {
        for state in AIActivityState.allCases {
            #expect(!state.stripSymbol.isEmpty)
        }
    }
}
