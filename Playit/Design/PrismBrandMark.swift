import SwiftUI

/// Prism's mark: the glass prism of the app icon, without its background, drawn
/// from `Design/PrismMark.svg`. It follows the phone's tilt: the spectrum swings
/// around the point where the light enters, a reflection travels across the
/// glass, the bright edge of the rim turns towards the light and the mark leans
/// a little. Held still, it settles back into the drawing of the icon. With
/// Reduce Motion it stays still.
struct PrismBrandMark: View {
    var height: CGFloat = 28
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var tilt = PrismTilt.shared

    var body: some View {
        let current = reduceMotion ? .zero : tilt.value
        Canvas { context, size in
            PrismMarkDrawing.draw(in: &context, size: size, tilt: current)
        }
        .frame(width: height * PrismMarkDrawing.aspectRatio, height: height)
        .rotation3DEffect(.degrees(Double(current.dy) * 10), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
        .rotation3DEffect(.degrees(Double(current.dx) * 10), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        .accessibilityHidden(true)
        .task(id: reduceMotion) {
            guard !reduceMotion else { return }
            tilt.attach()
            // Motion updates last as long as the mark is on screen.
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(60)) }
            tilt.detach()
        }
    }
}

/// The SVG's shapes in its own units, mapped into the view. Paths and gradient
/// points are transformed instead of the context, so blur radii stay in points.
enum PrismMarkDrawing {
    static let viewBox = CGRect(x: 321, y: 269, width: 432, height: 486)
    static var aspectRatio: CGFloat { viewBox.width / viewBox.height }

    private static let outline: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 387.99, y: 287))
        path.addLine(to: CGPoint(x: 717.07, y: 477))
        path.addQuadCurve(to: CGPoint(x: 717.07, y: 547), control: CGPoint(x: 777.70, y: 512))
        path.addLine(to: CGPoint(x: 387.99, y: 737))
        path.addQuadCurve(to: CGPoint(x: 327.36, y: 702), control: CGPoint(x: 327.36, y: 772))
        path.addLine(to: CGPoint(x: 327.36, y: 322))
        path.addQuadCurve(to: CGPoint(x: 387.99, y: 287), control: CGPoint(x: 327.36, y: 252))
        path.closeSubpath()
        return path
    }()

    private static let spectrum = Gradient(stops: [
        .init(color: color(0xFF5C8A), location: 0),
        .init(color: color(0xFFB15C), location: 0.2),
        .init(color: color(0xF2EE7A), location: 0.4),
        .init(color: color(0x5FE3A8), location: 0.58),
        .init(color: color(0x4FA8FF), location: 0.78),
        .init(color: color(0x9467FF), location: 1)
    ])
    private static let fade = Gradient(stops: [
        .init(color: .white.opacity(0), location: 0),
        .init(color: .white.opacity(0.75), location: 0.35),
        .init(color: .white, location: 1)
    ])
    private static let ridge = Gradient(colors: [.white.opacity(0), .white.opacity(0.45)])
    private static let rim = Gradient(stops: [
        .init(color: .white.opacity(0.95), location: 0),
        .init(color: .white.opacity(0.35), location: 0.55),
        .init(color: .white.opacity(0.6), location: 1)
    ])

    /// - Parameter tilt: −1…1 on each axis, as published by `PrismTilt`.
    static func draw(in context: inout GraphicsContext, size: CGSize, tilt: CGVector) {
        let scale = size.height / viewBox.height
        let toView = CGAffineTransform(translationX: -viewBox.minX, y: -viewBox.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        func point(_ x: CGFloat, _ y: CGFloat, _ transform: CGAffineTransform? = nil) -> CGPoint {
            CGPoint(x: x, y: y).applying(transform ?? toView)
        }
        let h = tilt.dx, v = tilt.dy
        let everywhere = Path(CGRect(x: -size.width, y: -size.height, width: size.width * 3, height: size.height * 3))

        var glass = context
        glass.clip(to: outline.applying(toView))
        // Facets: more light falls on the upper face as the top tips back.
        glass.fill(polygon([point(327.36, 252), point(777.70, 512), point(327.36, 512)]),
                   with: .color(.white.opacity(0.30 + 0.07 * v)))
        glass.fill(polygon([point(327.36, 512), point(777.70, 512), point(327.36, 772)]),
                   with: .color(.white.opacity(0.17 - 0.05 * v)))

        // Spectrum: swings around its entry point, widens as the top tips back,
        // and its colours slide across the fan.
        let apex = CGPoint(x: 363.4, y: 518)
        let fan = CGAffineTransform(translationX: -apex.x, y: -apex.y)
            .concatenating(CGAffineTransform(scaleX: 1, y: 1 + 0.12 * v))
            .concatenating(CGAffineTransform(rotationAngle: h * 9 * .pi / 180))
            .concatenating(CGAffineTransform(translationX: apex.x, y: apex.y))
            .concatenating(toView)
        let shift = -40 * h
        let fanPath = polygon([point(apex.x, apex.y, fan), point(893.7, 325, fan), point(893.7, 754.1, fan)])
        glass.drawLayer { layer in
            layer.drawLayer { blurred in
                blurred.addFilter(.blur(radius: 18 * scale))
                blurred.fill(fanPath, with: .linearGradient(spectrum, startPoint: point(0, 402 + shift, fan),
                                                            endPoint: point(0, 662 + shift, fan)))
            }
            // Fade the spectrum in from where the light enters.
            layer.blendMode = .destinationIn
            layer.fill(everywhere, with: .linearGradient(fade, startPoint: point(363.36, 0), endPoint: point(777.70, 0)))
        }

        var ridgeLine = Path()
        ridgeLine.move(to: point(327.36, 512))
        ridgeLine.addLine(to: point(777.70, 512))
        glass.stroke(ridgeLine, with: .linearGradient(ridge, startPoint: point(327.36, 0), endPoint: point(777.70, 0)),
                     lineWidth: 2 * scale)

        // A soft reflection that travels across the glass.
        let strength = 0.08 + 0.16 * min(1, (h * h + v * v).squareRoot())
        glass.blendMode = .plusLighter
        glass.fill(everywhere, with: .radialGradient(Gradient(colors: [.white.opacity(strength), .white.opacity(0)]),
                                                     center: point(500 + 150 * h, 430 + 120 * v),
                                                     startRadius: 0, endRadius: 150 * scale))

        // Rim: its bright edge turns towards the light.
        let angle = .pi / 4 + h * 0.6 + v * 0.35
        let center = CGPoint(x: 552.5, y: 512)
        let reach: CGFloat = 320
        context.stroke(outline.applying(toView),
                       with: .linearGradient(rim,
                                             startPoint: point(center.x - cos(angle) * reach, center.y - sin(angle) * reach),
                                             endPoint: point(center.x + cos(angle) * reach, center.y + sin(angle) * reach)),
                       lineWidth: 7 * scale)
    }

    private static func polygon(_ points: [CGPoint]) -> Path {
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        return path
    }

    private static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }
}

extension View {
    /// Shows the mark in the top-left corner of the library's root screen.
    /// Tapping it opens "About Prism", the same page as "+ → 关于与开源许可".
    @ViewBuilder
    func prismBrandToolbar(isVisible: Bool, onTap: @escaping () -> Void) -> some View {
        if isVisible {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                // A logo rather than a control: no Liquid Glass platter behind it.
                self.toolbar {
                    ToolbarItem(placement: .topBarLeading) { PrismBrandButton(action: onTap) }
                        .sharedBackgroundVisibility(.hidden)
                }
            } else {
                self.toolbar {
                    ToolbarItem(placement: .topBarLeading) { PrismBrandButton(action: onTap) }
                }
            }
            #else
            self.toolbar {
                ToolbarItem(placement: .topBarLeading) { PrismBrandButton(action: onTap) }
            }
            #endif
        } else {
            self
        }
    }
}

private struct PrismBrandButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PrismBrandMark()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("关于 Prism")
        .accessibilityIdentifier("library.brand")
    }
}
