import AppKit
import CoreGraphics
import CoreImage
import Foundation

/// Flattens an `AnnotationDocument` onto its source image.
///
/// The order matters and is load-bearing:
///
/// 1. redactions are burned into a *copy of the pixel data* first,
/// 2. then the crop and rotation are applied,
/// 3. then the visible annotations are drawn,
/// 4. then the background is composed underneath.
///
/// Because step 1 rewrites the bitmap rather than drawing an opaque shape over
/// a still-intact layer, nothing downstream — not the PNG, not the pasteboard,
/// not a copy of the exported file — can recover what was hidden.
public enum AnnotationRenderer {

    public struct Options: Sendable {
        /// Skip redaction burn-in. Only ever used by the live editor preview,
        /// never by an export path.
        public var isPreview: Bool
        /// Draw seam markers from a scrolling stitch.
        public var seams: [StitchSeam]

        public init(isPreview: Bool = false, seams: [StitchSeam] = []) {
            self.isPreview = isPreview
            self.seams = seams
        }
    }

    /// Renders the finished, flattened image.
    public static func render(
        document: AnnotationDocument,
        source: CGImage,
        options: Options = Options()
    ) throws -> CGImage {
        let redacted = document.hasRedactions && !options.isPreview
            ? try burnRedactions(document: document, into: source)
            : source

        let cropped = try applyCrop(document: document, to: redacted)
        let rotated = try applyRotation(document.rotation, to: cropped)

        let annotated = try drawAnnotations(
            document: document,
            onto: rotated,
            options: options
        )

        guard document.background.isEnabled else { return annotated }
        return try composeBackground(
            document.background,
            content: annotated,
            scale: document.sourceScale
        )
    }

    // MARK: 1 — Redactions

    /// Rewrites the pixels under every redaction element. Returns a new image;
    /// the source is untouched so the editable project keeps the original.
    static func burnRedactions(document: AnnotationDocument, into source: CGImage) throws -> CGImage {
        let width = source.width
        let height = source.height
        guard let context = makeContext(width: width, height: height) else {
            throw NotchShotError.exportFailed("Could not allocate the redaction canvas")
        }

        // Draw in source space with a top-left origin so element geometry maps
        // straight across without a per-element flip.
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        for element in document.sortedElements where element.kind.isRedaction {
            let rect = element.boundingRect.integral
            guard rect.width >= 1, rect.height >= 1 else { continue }
            let clipped = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { continue }

            switch element.kind {
            case .blackout:
                context.saveGState()
                context.setFillColor(element.style.color.cgColor)
                context.setAlpha(1) // opacity is ignored: a blackout must be opaque
                context.fill(clipped)
                context.restoreGState()

            case .pixelate:
                guard let block = pixelate(
                    region: clipped,
                    of: source,
                    imageHeight: height,
                    blockSize: max(8, element.style.pixelBlockSize)
                ) else { continue }
                context.saveGState()
                context.interpolationQuality = .none
                // The context is flipped so element geometry reads in top-left
                // space, which is right for `fill` but mirrors any *image*
                // drawn into it. A blackout could not show that; a mosaic can,
                // and did — the exported blocks came out upside down relative
                // to both the source and the editor preview. Undo the flip for
                // the duration of this one draw.
                context.translateBy(x: 0, y: clipped.minY + clipped.maxY)
                context.scaleBy(x: 1, y: -1)
                context.draw(block, in: clipped)
                context.restoreGState()

            default:
                continue
            }
        }

        guard let image = context.makeImage() else {
            throw NotchShotError.exportFailed("Could not render redactions")
        }
        return image
    }

    /// Downsamples a region to blocks and scales it back up with no
    /// interpolation, which is what makes the result unrecoverable.
    private static func pixelate(
        region: CGRect,
        of source: CGImage,
        imageHeight: Int,
        blockSize: Double
    ) -> CGImage? {
        // The element rect is top-left origin; CGImage.cropping is too.
        let cropRect = CGRect(
            x: region.origin.x,
            y: region.origin.y,
            width: region.width,
            height: region.height
        ).integral
        guard let crop = source.cropping(to: cropRect) else { return nil }

        let smallWidth = max(1, Int((region.width / blockSize).rounded(.up)))
        let smallHeight = max(1, Int((region.height / blockSize).rounded(.up)))

        guard let small = makeContext(width: smallWidth, height: smallHeight) else { return nil }
        small.interpolationQuality = .medium
        small.draw(crop, in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight))
        return small.makeImage()
    }

    // MARK: 2 — Crop

    static func applyCrop(document: AnnotationDocument, to image: CGImage) throws -> CGImage {
        guard let crop = document.cropRect else { return image }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let clipped = ScreenGeometry.clamp(crop, to: bounds) else { return image }
        guard let cropped = image.cropping(to: clipped) else {
            throw NotchShotError.exportFailed("Crop is outside the image")
        }
        return cropped
    }

    // MARK: 3 — Rotation

    static func applyRotation(_ rotation: RotationAngle, to image: CGImage) throws -> CGImage {
        guard rotation != .none else { return image }

        let width = rotation.swapsAxes ? image.height : image.width
        let height = rotation.swapsAxes ? image.width : image.height
        guard let context = makeContext(width: width, height: height) else {
            throw NotchShotError.exportFailed("Could not allocate the rotation canvas")
        }

        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: -rotation.radians)
        context.draw(image, in: CGRect(
            x: -CGFloat(image.width) / 2,
            y: -CGFloat(image.height) / 2,
            width: CGFloat(image.width),
            height: CGFloat(image.height)
        ))

        guard let rotated = context.makeImage() else {
            throw NotchShotError.exportFailed("Could not rotate the image")
        }
        return rotated
    }

    // MARK: 4 — Annotations

    static func drawAnnotations(
        document: AnnotationDocument,
        onto image: CGImage,
        options: Options
    ) throws -> CGImage {
        let visible = document.sortedElements.filter { !$0.kind.isRedaction || options.isPreview }
        guard !visible.isEmpty || !options.seams.isEmpty else { return image }

        guard let context = makeContext(width: image.width, height: image.height) else {
            throw NotchShotError.exportFailed("Could not allocate the annotation canvas")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        // Element geometry is in *uncropped, unrotated* source space; shift and
        // rotate the drawing context so it lines up with the current image.
        context.saveGState()
        applyElementTransform(document: document, image: image, to: context)

        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext

        for element in visible {
            draw(element, in: context, isPreview: options.isPreview)
        }

        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()

        if !options.seams.isEmpty {
            drawSeams(options.seams, in: context, width: image.width, height: image.height)
        }

        guard let annotated = context.makeImage() else {
            throw NotchShotError.exportFailed("Could not draw annotations")
        }
        return annotated
    }

    /// Maps source-space coordinates (top-left origin) into the current
    /// bottom-up context, accounting for crop offset and rotation.
    private static func applyElementTransform(
        document: AnnotationDocument,
        image: CGImage,
        to context: CGContext
    ) {
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)

        if document.rotation != .none {
            let crop = document.effectiveCrop
            context.translateBy(x: CGFloat(image.width) / 2, y: CGFloat(image.height) / 2)
            context.rotate(by: document.rotation.radians)
            context.translateBy(x: -crop.width / 2, y: -crop.height / 2)
            context.translateBy(x: -crop.origin.x, y: -crop.origin.y)
        } else if let crop = document.cropRect {
            context.translateBy(x: -crop.origin.x, y: -crop.origin.y)
        }
    }

    private static func draw(_ element: AnnotationElement, in context: CGContext, isPreview: Bool) {
        let style = element.style
        let color = style.color.withAlphaComponent(style.opacity)

        context.saveGState()
        defer { context.restoreGState() }

        if style.hasShadow {
            context.setShadow(
                offset: CGSize(width: 0, height: 1.5),
                blur: style.lineWidth * 1.2,
                color: NSColor.black.withAlphaComponent(0.35).cgColor
            )
        }

        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        context.setLineWidth(style.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch element.kind {
        case .rectangle:
            let rect = element.boundingRect
            let path = CGPath(
                roundedRect: rect,
                cornerWidth: min(style.cornerRadius, rect.width / 2),
                cornerHeight: min(style.cornerRadius, rect.height / 2),
                transform: nil
            )
            context.addPath(path)
            context.drawPath(using: style.isFilled ? .fill : .stroke)

        case .ellipse:
            context.addEllipse(in: element.boundingRect)
            context.drawPath(using: style.isFilled ? .fill : .stroke)

        case .line:
            guard element.points.count >= 2 else { break }
            context.move(to: element.points[0])
            context.addLine(to: element.points[1])
            context.strokePath()

        case .arrow:
            guard element.points.count >= 2 else { break }
            drawArrow(from: element.points[0], to: element.points[1], style: style, in: context)

        case .pencil, .highlighter:
            guard element.points.count >= 2 else { break }
            if element.kind == .highlighter {
                context.setLineCap(.square)
                context.setBlendMode(.multiply)
            }
            context.move(to: element.points[0])
            // A Catmull-Rom-ish smoothing: midpoints as curve ends with the
            // sampled point as control. Cheap and removes the polyline look.
            for index in 1 ..< element.points.count {
                let previous = element.points[index - 1]
                let current = element.points[index]
                let midpoint = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
                context.addQuadCurve(to: midpoint, control: previous)
            }
            context.addLine(to: element.points[element.points.count - 1])
            context.strokePath()

        case .text:
            guard let anchor = element.points.first, !element.text.isEmpty else { break }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: style.fontSize, weight: .semibold),
                .foregroundColor: color,
            ]
            let attributed = NSAttributedString(string: element.text, attributes: attributes)
            attributed.draw(at: anchor)

        case .counter:
            guard let centre = element.points.first else { break }
            let radius = max(style.fontSize, 16)
            let circle = CGRect(
                x: centre.x - radius,
                y: centre.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.setFillColor(color.cgColor)
            context.fillEllipse(in: circle)

            context.setShadow(offset: .zero, blur: 0, color: nil)
            let label = "\(element.counterValue)"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: radius, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let attributed = NSAttributedString(string: label, attributes: attributes)
            let size = attributed.size()
            attributed.draw(at: CGPoint(
                x: centre.x - size.width / 2,
                y: centre.y - size.height / 2
            ))

        case .blackout, .pixelate:
            // Only reachable in preview mode; the export path burned these in.
            guard isPreview else { break }
            context.setFillColor(NSColor.black.withAlphaComponent(0.85).cgColor)
            context.fill(element.boundingRect)
        }
    }

    private static func drawArrow(
        from start: CGPoint,
        to end: CGPoint,
        style: AnnotationStyle,
        in context: CGContext
    ) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = max(style.lineWidth * 3.6, 14)
        let headWidth = max(style.lineWidth * 2.6, 10)

        // Stop the shaft short of the tip so the head has a clean point.
        let shaftEnd = CGPoint(
            x: end.x - cos(angle) * headLength * 0.72,
            y: end.y - sin(angle) * headLength * 0.72
        )
        context.move(to: start)
        context.addLine(to: shaftEnd)
        context.strokePath()

        let left = CGPoint(
            x: end.x - cos(angle) * headLength + cos(angle + .pi / 2) * headWidth,
            y: end.y - sin(angle) * headLength + sin(angle + .pi / 2) * headWidth
        )
        let right = CGPoint(
            x: end.x - cos(angle) * headLength + cos(angle - .pi / 2) * headWidth,
            y: end.y - sin(angle) * headLength + sin(angle - .pi / 2) * headWidth
        )
        context.move(to: end)
        context.addLine(to: left)
        context.addLine(to: right)
        context.closePath()
        context.fillPath()
    }

    private static func drawSeams(_ seams: [StitchSeam], in context: CGContext, width: Int, height: Int) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineWidth(2)
        context.setLineDash(phase: 0, lengths: [8, 6])
        for seam in seams where seam.isSuspect {
            context.setStrokeColor(NSColor.systemOrange.withAlphaComponent(0.9).cgColor)
            if seam.axis == .horizontal {
                let x = CGFloat(seam.y)
                context.move(to: CGPoint(x: x, y: 0))
                context.addLine(to: CGPoint(x: x, y: CGFloat(height)))
            } else {
                let y = CGFloat(height - seam.y)
                context.move(to: CGPoint(x: 0, y: y))
                context.addLine(to: CGPoint(x: CGFloat(width), y: y))
            }
            context.strokePath()
        }
    }

    // MARK: 5 — Background

    static func composeBackground(
        _ background: BackgroundConfiguration,
        content: CGImage,
        scale: CGFloat
    ) throws -> CGImage {
        let contentSize = CGSize(width: content.width, height: content.height)
        let layout = background.layout(for: contentSize, scale: scale)

        guard let context = makeContext(
            width: Int(layout.canvas.width),
            height: Int(layout.canvas.height)
        ) else {
            throw NotchShotError.exportFailed("Could not allocate the background canvas")
        }

        let canvasRect = CGRect(origin: .zero, size: layout.canvas)
        drawFill(background.fill, in: context, rect: canvasRect, scale: scale)

        // Flip into top-left space so the layout rect means what it says.
        let contentRect = CGRect(
            x: layout.content.origin.x,
            y: layout.canvas.height - layout.content.origin.y - layout.content.height,
            width: layout.content.width,
            height: layout.content.height
        )

        let radius = background.cornerRadius * Double(scale)
        let clipPath = CGPath(
            roundedRect: contentRect,
            cornerWidth: min(radius, contentRect.width / 2),
            cornerHeight: min(radius, contentRect.height / 2),
            transform: nil
        )

        if background.shadowRadius > 0, background.shadowOpacity > 0 {
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -background.shadowRadius * Double(scale) * 0.28),
                blur: background.shadowRadius * Double(scale),
                color: NSColor.black.withAlphaComponent(background.shadowOpacity).cgColor
            )
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(clipPath)
            context.fillPath()
            context.restoreGState()
        }

        context.saveGState()
        context.addPath(clipPath)
        context.clip()
        context.draw(content, in: contentRect)
        context.restoreGState()

        if background.drawsInnerBorder {
            context.saveGState()
            context.addPath(clipPath)
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
            context.setLineWidth(max(1, Double(scale)))
            context.strokePath()
            context.restoreGState()
        }

        guard let image = context.makeImage() else {
            throw NotchShotError.exportFailed("Could not render the background")
        }
        return image
    }

    private static func drawFill(
        _ fill: BackgroundFill,
        in context: CGContext,
        rect: CGRect,
        scale: CGFloat
    ) {
        switch fill {
        case .none:
            break

        case .solid(let hex):
            context.setFillColor((NSColor(hex: hex) ?? .windowBackgroundColor).cgColor)
            context.fill(rect)

        case .gradient(let startHex, let endHex, let angle):
            let start = NSColor(hex: startHex) ?? .systemBlue
            let end = NSColor(hex: endHex) ?? .systemPurple
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: [start.cgColor, end.cgColor] as CFArray,
                locations: [0, 1]
            ) else { break }

            let radians = angle * .pi / 180
            let halfDiagonal = sqrt(rect.width * rect.width + rect.height * rect.height) / 2
            let centre = CGPoint(x: rect.midX, y: rect.midY)
            let startPoint = CGPoint(
                x: centre.x - cos(radians) * halfDiagonal,
                y: centre.y - sin(radians) * halfDiagonal
            )
            let endPoint = CGPoint(
                x: centre.x + cos(radians) * halfDiagonal,
                y: centre.y + sin(radians) * halfDiagonal
            )
            context.drawLinearGradient(
                gradient,
                start: startPoint,
                end: endPoint,
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )

        case .image(let path):
            guard let cgImage = SafeImageFile.cgImage(
                at: URL(fileURLWithPath: path),
                limits: .background
            ) else { break }
            // Aspect-fill so a background photo never letterboxes.
            let imageAspect = CGFloat(cgImage.width) / CGFloat(cgImage.height)
            let rectAspect = rect.width / rect.height
            var drawRect = rect
            if imageAspect > rectAspect {
                let width = rect.height * imageAspect
                drawRect = CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: rect.height)
            } else {
                let height = rect.width / imageAspect
                drawRect = CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
            }
            context.saveGState()
            context.clip(to: rect)
            context.draw(cgImage, in: drawRect)
            context.restoreGState()
        }
    }

    // MARK: Interactive drawing

    /// Draws elements into an arbitrary context for the live editor, mapping
    /// source-image coordinates onto `contentRect`.
    ///
    /// Shares the exact same `draw(_:in:)` routine as the export path, so what
    /// the user arranges on screen is what lands in the file — the classic
    /// annotation-editor bug is having two drawing implementations that drift.
    public static func drawInteractive(
        elements: [AnnotationElement],
        in context: CGContext,
        contentRect: CGRect,
        visibleSourceRect: CGRect,
        isPreview: Bool
    ) {
        guard visibleSourceRect.width > 0, visibleSourceRect.height > 0 else { return }
        let scaleX = contentRect.width / visibleSourceRect.width
        let scaleY = contentRect.height / visibleSourceRect.height

        context.saveGState()
        defer { context.restoreGState() }

        context.translateBy(x: contentRect.origin.x, y: contentRect.origin.y)
        context.scaleBy(x: scaleX, y: scaleY)
        context.translateBy(x: -visibleSourceRect.origin.x, y: -visibleSourceRect.origin.y)

        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        for element in elements.sorted(by: { $0.order < $1.order }) {
            draw(element, in: context, isPreview: isPreview)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Shared

    static func makeContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
    }
}
