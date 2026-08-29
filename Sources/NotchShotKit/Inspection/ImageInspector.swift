import AppKit
import CoreGraphics
import Foundation
import Observation
import SwiftUI

public struct InspectedColor: Sendable, Equatable {
    public var red: CGFloat
    public var green: CGFloat
    public var blue: CGFloat

    public var hex: String {
        String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }

    public var rgbDescription: String {
        "rgb(\(Int((red * 255).rounded())), \(Int((green * 255).rounded())), \(Int((blue * 255).rounded())))"
    }

    public var hslDescription: String {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let lightness = (maximum + minimum) / 2
        let delta = maximum - minimum
        let saturation = delta == 0 ? 0 : delta / (1 - abs(2 * lightness - 1))
        var hue: CGFloat = 0
        if delta != 0 {
            if maximum == red {
                hue = 60 * ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maximum == green {
                hue = 60 * ((blue - red) / delta + 2)
            } else {
                hue = 60 * ((red - green) / delta + 4)
            }
            if hue < 0 { hue += 360 }
        }
        return "hsl(\(Int(hue.rounded())), \(Int((saturation * 100).rounded()))%, \(Int((lightness * 100).rounded()))%)"
    }

    public var color: Color { Color(red: red, green: green, blue: blue) }

    fileprivate var relativeLuminance: CGFloat {
        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }
}

public struct PixelSample: Sendable, Equatable {
    public var point: CGPoint
    public var color: InspectedColor
}

public enum ImagePixelInspector {
    public static func sample(_ image: CGImage, at point: CGPoint) -> PixelSample? {
        ImagePixelSampler()?.sample(image, at: point)
    }

    public static func contrast(_ first: InspectedColor, _ second: InspectedColor) -> Double {
        let brighter = max(first.relativeLuminance, second.relativeLuminance)
        let darker = min(first.relativeLuminance, second.relativeLuminance)
        return Double((brighter + 0.05) / (darker + 0.05))
    }
}

/// Reuses the tiny destination bitmap while the pointer moves. Creating a new
/// color space, context, and backing store for every mouse event was avoidable
/// allocator pressure in the inspector's hottest interaction path.
private final class ImagePixelSampler {
    private let context: CGContext

    init?() {
        guard let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        self.context = context
    }

    func sample(_ image: CGImage, at point: CGPoint) -> PixelSample? {
        let x = Int(point.x.rounded(.down))
        let y = Int(point.y.rounded(.down))
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }

        context.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
        context.saveGState()
        context.translateBy(x: -CGFloat(x), y: -CGFloat(image.height - y - 1))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.restoreGState()
        guard let data = context.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        return PixelSample(
            point: CGPoint(x: x, y: y),
            color: InspectedColor(
                red: CGFloat(bytes[0]) / 255,
                green: CGFloat(bytes[1]) / 255,
                blue: CGFloat(bytes[2]) / 255
            )
        )
    }
}

@MainActor
@Observable
public final class ImageInspectionSession {
    public let asset: CaptureAsset
    public let image: CGImage
    public var hoverSample: PixelSample?
    public var firstContrastColor: InspectedColor?
    public var secondContrastColor: InspectedColor?
    public var measurementStart: CGPoint?
    public var measurementEnd: CGPoint?
    @ObservationIgnored private let pixelSampler = ImagePixelSampler()

    public init(asset: CaptureAsset) throws {
        guard asset.kind.isImage, let image = SafeImageFile.cgImage(for: asset) else {
            throw NotchShotError.exportFailed("That image could not be read safely")
        }
        self.asset = asset
        self.image = image
    }

    public var contrastDescription: String {
        guard let firstContrastColor, let secondContrastColor else { return "Choose two colors" }
        return String(format: "%.2f:1", ImagePixelInspector.contrast(firstContrastColor, secondContrastColor))
    }

    public var measurementDescription: String? {
        guard let measurementStart, let measurementEnd else { return nil }
        let dx = abs(measurementEnd.x - measurementStart.x)
        let dy = abs(measurementEnd.y - measurementStart.y)
        let distance = hypot(dx, dy)
        return "Δx \(Int(dx.rounded())) · Δy \(Int(dy.rounded())) · \(Int(distance.rounded())) px"
    }

    public func updateHover(at imagePoint: CGPoint) {
        let pixelPoint = CGPoint(
            x: imagePoint.x.rounded(.down),
            y: imagePoint.y.rounded(.down)
        )
        guard hoverSample?.point != pixelPoint else { return }
        hoverSample = pixelSampler?.sample(image, at: pixelPoint)
    }

    public func copyCurrentColor() {
        guard let hoverSample else { return }
        ImageExport.copyToPasteboard(text: hoverSample.color.hex)
    }

    public func sampleCenter() {
        updateHover(at: CGPoint(
            x: CGFloat(image.width - 1) / 2,
            y: CGFloat(image.height - 1) / 2
        ))
    }

    public func moveSample(dx: CGFloat, dy: CGFloat) {
        let start = hoverSample?.point ?? CGPoint(
            x: CGFloat(image.width - 1) / 2,
            y: CGFloat(image.height - 1) / 2
        )
        updateHover(at: CGPoint(
            x: min(max(start.x + dx, 0), CGFloat(image.width - 1)),
            y: min(max(start.y + dy, 0), CGFloat(image.height - 1))
        ))
    }
}

public struct ImageInspectorView: View {
    @Bindable var session: ImageInspectionSession

    public init(session: ImageInspectionSession) {
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            inspectorToolbar
            GeometryReader { geometry in
                let fitted = fit(
                    source: CGSize(width: session.image.width, height: session.image.height),
                    into: geometry.size,
                    margin: 28
                )
                ZStack {
                    Color(nsColor: .underPageBackgroundColor)
                    Image(nsImage: NSImage(
                        cgImage: session.image,
                        size: NSSize(width: session.image.width, height: session.image.height)
                    ))
                    .resizable()
                    .interpolation(.none)
                    .frame(width: fitted.width, height: fitted.height)
                    .position(x: fitted.midX, y: fitted.midY)

                    if let start = session.measurementStart,
                       let end = session.measurementEnd {
                        Path { path in
                            path.move(to: viewPoint(start, fitted: fitted))
                            path.addLine(to: viewPoint(end, fitted: fitted))
                        }
                        .stroke(.yellow, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        if let point = imagePoint(location, fitted: fitted) {
                            session.updateHover(at: point)
                        }
                    case .ended:
                        break
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            guard let start = imagePoint(value.startLocation, fitted: fitted),
                                  let end = imagePoint(value.location, fitted: fitted) else { return }
                            session.measurementStart = start
                            session.measurementEnd = end
                        }
                )
                .focusable()
                .onKeyPress(.leftArrow) {
                    session.moveSample(dx: -1, dy: 0)
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    session.moveSample(dx: 1, dy: 0)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    session.moveSample(dx: 0, dy: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    session.moveSample(dx: 0, dy: 1)
                    return .handled
                }
                .accessibilityLabel("Image inspection canvas")
                .accessibilityValue(inspectorAccessibilityValue)
                .accessibilityHint("Move the pointer or use the arrow keys to sample a color. Drag to measure pixel distance.")
                .accessibilityActions {
                    Button("Sample image center") { session.sampleCenter() }
                    Button("Move sample left") { session.moveSample(dx: -1, dy: 0) }
                    Button("Move sample right") { session.moveSample(dx: 1, dy: 0) }
                    Button("Move sample up") { session.moveSample(dx: 0, dy: -1) }
                    Button("Move sample down") { session.moveSample(dx: 0, dy: 1) }
                    Button("Copy sampled color") { session.copyCurrentColor() }
                }
            }
        }
        .frame(minWidth: 820, minHeight: 560)
    }

    private var inspectorToolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label(
                    "\(session.image.width) × \(session.image.height)",
                    systemImage: "aspectratio"
                )

                if let sample = session.hoverSample {
                    Divider().frame(height: 18)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(sample.color.color)
                        .frame(width: 26, height: 22)
                        .overlay { RoundedRectangle(cornerRadius: 4).stroke(.secondary) }
                    Text("\(Int(sample.point.x)), \(Int(sample.point.y))")
                        .monospacedDigit()
                    Text(sample.color.hex)
                        .monospaced()
                        .textSelection(.enabled)
                    Button("Copy") { session.copyCurrentColor() }
                    Menu("Contrast") {
                        Button("Use as color A") { session.firstContrastColor = sample.color }
                        Button("Use as color B") { session.secondContrastColor = sample.color }
                    }
                }

                Spacer(minLength: 8)
                Button("Sample Center") { session.sampleCenter() }
                Label(session.contrastDescription, systemImage: "circle.lefthalf.filled")
                    .help("WCAG contrast ratio")
            }

            if let sample = session.hoverSample {
                HStack(spacing: 14) {
                    Text(sample.color.rgbDescription).monospaced()
                    Text(sample.color.hslDescription).monospaced()
                    Spacer(minLength: 8)
                    if let measurement = session.measurementDescription {
                        Text(measurement).monospacedDigit()
                    }
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .textSelection(.enabled)
            }
        }
        .font(.caption)
        .padding(.horizontal, NotchShotDesignSystem.toolbarHorizontalPadding)
        .padding(.vertical, NotchShotDesignSystem.toolbarVerticalPadding)
        .notchShotToolbarSurface()
    }

    private var inspectorAccessibilityValue: String {
        guard let sample = session.hoverSample else { return "No color sampled" }
        let measurement = session.measurementDescription.map { ". \($0)" } ?? ""
        return "Pixel \(Int(sample.point.x)), \(Int(sample.point.y)); \(sample.color.hex)\(measurement)"
    }

    private func imagePoint(_ point: CGPoint, fitted: CGRect) -> CGPoint? {
        guard fitted.contains(point) else { return nil }
        return CGPoint(
            x: (point.x - fitted.minX) / fitted.width * CGFloat(session.image.width),
            y: (point.y - fitted.minY) / fitted.height * CGFloat(session.image.height)
        )
    }

    private func viewPoint(_ point: CGPoint, fitted: CGRect) -> CGPoint {
        CGPoint(
            x: fitted.minX + point.x / CGFloat(session.image.width) * fitted.width,
            y: fitted.minY + point.y / CGFloat(session.image.height) * fitted.height
        )
    }

    private func fit(source: CGSize, into container: CGSize, margin: CGFloat) -> CGRect {
        let available = CGSize(
            width: max(1, container.width - margin * 2),
            height: max(1, container.height - margin * 2)
        )
        let scale = min(available.width / source.width, available.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}
