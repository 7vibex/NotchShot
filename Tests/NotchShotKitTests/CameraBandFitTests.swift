import AppKit
import SwiftUI
import Testing

@testable import NotchShotKit

/// What a card puts beside the camera has to fit the strip it is given, or it
/// runs under the cutout where nobody can see it.
@Suite("Camera band fit")
@MainActor
struct CameraBandFitTests {
    private func metrics(notchWidth: CGFloat) -> NotchMetrics {
        NotchMetrics(
            screenFrame: CGRect(x: 0, y: 0, width: 1_470, height: 956),
            hasPhysicalNotch: true,
            notchSize: CGSize(width: notchWidth, height: 32),
            menuBarHeight: 33
        )
    }

    @Test("The hover bar's Area and Record fit right of the camera", arguments: [CGFloat(179), 185, 200])
    func idleShortcutsFitTheWing(notchWidth: CGFloat) {
        let layout = NotchLayout.layout(
            for: .idle,
            metrics: metrics(notchWidth: notchWidth),
            isPeeking: true,
            resultCount: 0
        )
        let wing = (layout.size.width - notchWidth - IslandCameraBand.cameraClearance) / 2
        let pair = NSHostingView(rootView: IdleShortcutPair(onArea: {}, onRecord: {}))
        // The hover bar's header keeps 8 pt from the shell's right edge.
        #expect(pair.fittingSize.width + 8 <= wing, "pair \(pair.fittingSize.width) in a \(wing) pt wing")
    }

    @Test("Open context cards put their title beside the camera and fit their body")
    func contextCardsWrapTheCamera() {
        let metrics = metrics(notchWidth: 185)
        for kind in [ContextKind.calendar, .timer, .voiceNote, .power, .document] {
            let layout = NotchLayout.layout(
                for: .context(ContextSnapshot(kind: kind, title: "Card", presentation: .expanded)),
                metrics: metrics,
                isPeeking: false,
                resultCount: 0
            )
            #expect(layout.wrapsCamera, "\(kind)")
            #expect(layout.contentTopInset == 0, "\(kind)")
            #expect(layout.size.height <= NotchLayout.maximumSize.height, "\(kind)")
        }
        let calendar = NotchLayout.layout(
            for: .context(ContextSnapshot(kind: .calendar, title: "Next event", presentation: .expanded)),
            metrics: metrics,
            isPeeking: false,
            resultCount: 0
        )
        // Five full-height event rows below the band.
        #expect(calendar.size.height - 32 >= 5 * 36 + 4 * 4)
        let timer = NotchLayout.layout(
            for: .context(ContextSnapshot(kind: .timer, title: "Focus", presentation: .expanded)),
            metrics: metrics,
            isPeeking: false,
            resultCount: 0
        )
        #expect(timer.size.height < calendar.size.height / 2, "a timer is not a calendar-sized card")
    }
}
