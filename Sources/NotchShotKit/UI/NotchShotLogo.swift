import AppKit
import SwiftUI

/// The capture buddy from the app icon, reduced to a single-colour screen,
/// top notch and friendly face. Cutouts keep it legible on either menu-bar tint.
enum NotchShotLogo {
    static let designSize = CGSize(width: 24, height: 22)

    /// Coordinates point down, like SwiftUI and the flipped menu-bar image.
    static func bodyPath() -> CGMutablePath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 7, y: 4))
        path.addLine(to: CGPoint(x: 9, y: 4))
        path.addLine(to: CGPoint(x: 9.3, y: 5.9))
        path.addQuadCurve(to: CGPoint(x: 10.8, y: 7.2), control: CGPoint(x: 9.5, y: 7.2))
        path.addLine(to: CGPoint(x: 13.2, y: 7.2))
        path.addQuadCurve(to: CGPoint(x: 14.7, y: 5.9), control: CGPoint(x: 14.5, y: 7.2))
        path.addLine(to: CGPoint(x: 15, y: 4))
        path.addLine(to: CGPoint(x: 17, y: 4))
        path.addQuadCurve(to: CGPoint(x: 22, y: 9), control: CGPoint(x: 22, y: 4))
        path.addLine(to: CGPoint(x: 22, y: 15))
        path.addQuadCurve(to: CGPoint(x: 17, y: 20), control: CGPoint(x: 22, y: 20))
        path.addLine(to: CGPoint(x: 7, y: 20))
        path.addQuadCurve(to: CGPoint(x: 2, y: 15), control: CGPoint(x: 2, y: 20))
        path.addLine(to: CGPoint(x: 2, y: 9))
        path.addQuadCurve(to: CGPoint(x: 7, y: 4), control: CGPoint(x: 2, y: 4))
        path.closeSubpath()
        return path
    }

    static func smilePath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 10.1, y: 14.5))
        path.addCurve(
            to: CGPoint(x: 13.9, y: 14.5),
            control1: CGPoint(x: 10.9, y: 15.8),
            control2: CGPoint(x: 13.1, y: 15.8)
        )
        return path.copy(strokingWithWidth: 1.1, lineCap: .round, lineJoin: .round, miterLimit: 1)
    }

    /// Fill even-odd: the two eyes and smile are transparent cutouts.
    static func glyphPath() -> CGPath {
        let path = bodyPath()
        for x in [CGFloat(7.2), 15] {
            path.addRoundedRect(
                in: CGRect(x: x, y: 11, width: 1.8, height: 2.5),
                cornerWidth: 0.9, cornerHeight: 1.25
            )
        }
        path.addPath(smilePath())
        return path
    }

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

    /// AppKit supplies the correct tint for light, dark and pressed states.
    static func menuBarImage() -> NSImage {
        let size = CGSize(width: 22, height: 18)
        let image = NSImage(size: size, flipped: true) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(glyphPath(fitting: bounds))
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath(using: .evenOdd)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "NotchShot"
        return image
    }
}

/// Fill with `FillStyle(eoFill: true)` to preserve the face cutouts.
struct NotchShotLogoShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(NotchShotLogo.glyphPath(fitting: rect))
    }
}
