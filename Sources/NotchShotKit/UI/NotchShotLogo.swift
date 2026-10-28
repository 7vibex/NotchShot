import AppKit
import SwiftUI

/// NotchShot's mascot: the notch itself, hanging from the top of the screen,
/// looking out through its camera.
///
/// The camera is the one eye, which is what makes it NotchShot's rather than a
/// generic face. It is one silhouette with holes, filled even-odd, so the same
/// geometry works as a menu-bar template image, a SwiftUI shape, and the base of
/// the app icon (`Scripts/make_app_icon.sh` compiles this file as-is, so it may
/// only depend on AppKit and SwiftUI).
enum NotchShotLogo {
    /// The design grid every coordinate below is written in.
    static let designSize = CGSize(width: 20, height: 14.5)

    /// Where the camera eye sits on the design grid.
    static let eyeCenter = CGPoint(x: 10, y: 6.4)
    static let eyeRadius: CGFloat = 3.5

    /// The notch's outline: a flat top with the two concave shoulders where it
    /// meets the edge of the screen, then soft bottom corners.
    static func bodyPath() -> CGMutablePath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 20, y: 0))
        path.addQuadCurve(to: CGPoint(x: 18, y: 2), control: CGPoint(x: 18, y: 0))
        path.addLine(to: CGPoint(x: 18, y: 8.5))
        path.addArc(tangent1End: CGPoint(x: 18, y: 14.5), tangent2End: CGPoint(x: 12, y: 14.5), radius: 6)
        path.addLine(to: CGPoint(x: 8, y: 14.5))
        path.addArc(tangent1End: CGPoint(x: 2, y: 14.5), tangent2End: CGPoint(x: 2, y: 8.5), radius: 6)
        path.addLine(to: CGPoint(x: 2, y: 2))
        path.addQuadCurve(to: CGPoint(x: 0, y: 0), control: CGPoint(x: 2, y: 0))
        path.closeSubpath()
        return path
    }

    /// A small upturned arc under the eye, as a filled outline.
    static func smilePath(lineWidth: CGFloat = 1) -> CGPath {
        let arc = CGMutablePath()
        // y grows downward, so 30°…150° clockwise-false sweeps through the
        // bottom of the circle: a smile, not a frown.
        arc.addArc(
            center: CGPoint(x: 10, y: 10.5),
            radius: 1.7,
            startAngle: .pi / 6,
            endAngle: .pi * 5 / 6,
            clockwise: false
        )
        return arc.copy(strokingWithWidth: lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 1)
    }

    /// The whole one-colour glyph on the design grid, y pointing down.
    /// Fill it with the even-odd rule: body, lens hole, pupil, glint, smile.
    static func glyphPath() -> CGPath {
        let path = bodyPath()
        path.addEllipse(in: circle(eyeCenter, eyeRadius))
        path.addEllipse(in: circle(eyeCenter, 1.8))
        path.addEllipse(in: circle(CGPoint(x: 10.75, y: 5.65), 0.65))
        path.addPath(smilePath())
        return path
    }

    /// The glyph scaled to fit `rect`, centred, y pointing down.
    static func glyphPath(fitting rect: CGRect) -> CGPath {
        let scale = min(rect.width / designSize.width, rect.height / designSize.height)
        let transform = CGAffineTransform(
            translationX: rect.midX - designSize.width * scale / 2,
            y: rect.midY - designSize.height * scale / 2
        ).scaledBy(x: scale, y: scale)
        let path = CGMutablePath()
        path.addPath(glyphPath(), transform: transform)
        return path
    }

    /// The menu-bar image. A template, so AppKit tints it for light and dark
    /// menu bars and for the pressed state.
    static func menuBarImage() -> NSImage {
        // 18 pt tall like the system's own items; the glyph is wide, so it
        // gets a little more width than height.
        let size = CGSize(width: 20, height: 18)
        let image = NSImage(size: size, flipped: true) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let glyph = glyphPath(fitting: bounds.insetBy(dx: 0.5, dy: 2.25))
            context.addPath(glyph)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath(using: .evenOdd)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "NotchShot"
        return image
    }

    static func circle(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }
}

/// The mascot as a SwiftUI shape. Fill it with `FillStyle(eoFill: true)`.
struct NotchShotLogoShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(NotchShotLogo.glyphPath(fitting: rect))
    }
}
