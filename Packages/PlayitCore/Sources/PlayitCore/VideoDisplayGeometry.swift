import Foundation

/// The aspect-corrected, rotated video rectangle actually presented to the viewer.
/// mpv's dwidth/dheight are aspect-corrected but still require out-params/rotate.
public struct VideoDisplayGeometry: Equatable, Sendable {
    public enum FullscreenOrientation: Equatable, Sendable {
        case portrait
        case landscape
    }

    public let width: Double
    public let height: Double

    public var aspectRatio: Double { width / height }

    /// Square content uses portrait; negligible floating-point differences are ignored.
    public var fullscreenOrientation: FullscreenOrientation {
        width > height * (1 + 0.000_001) ? .landscape : .portrait
    }

    /// Width and height must already include pixel/display aspect correction.
    public init?(width: Double, height: Double, rotationDegrees: Double) {
        guard width.isFinite, height.isFinite, rotationDegrees.isFinite,
              width > 0, height > 0 else { return nil }
        let rotation = (rotationDegrees.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        let normalized = Int(rotation.rounded()) % 360
        if abs(rotation - Double(normalized)) < 0.000_001 || abs(rotation - 360) < 0.000_001 {
            switch normalized {
            case 0, 180: self.width = width; self.height = height
            case 90, 270: self.width = height; self.height = width
            default:
                let radians = rotation * .pi / 180
                self.width = abs(width * cos(radians)) + abs(height * sin(radians))
                self.height = abs(width * sin(radians)) + abs(height * cos(radians))
            }
        } else {
            let radians = rotation * .pi / 180
            self.width = abs(width * cos(radians)) + abs(height * sin(radians))
            self.height = abs(width * sin(radians)) + abs(height * cos(radians))
        }
        guard self.width.isFinite, self.height.isFinite else { return nil }
    }

    /// Prefer post-filter display dimensions and their remaining rotation.
    /// Encoded dimensions alone never determine orientation: a known rotation is required.
    public static func resolve(
        outputWidth: Double?, outputHeight: Double?, outputRotation: Double?,
        sourceWidth: Double? = nil, sourceHeight: Double? = nil,
        sourceRotation: Double? = nil, sourceDisplayAspect: Double? = nil
    ) -> VideoDisplayGeometry? {
        if let width = outputWidth, let height = outputHeight, let rotation = outputRotation,
           let output = VideoDisplayGeometry(width: width, height: height, rotationDegrees: rotation) {
            return output
        }
        guard var width = sourceWidth, let height = sourceHeight, let rotation = sourceRotation else { return nil }
        if let aspect = sourceDisplayAspect, aspect.isFinite, aspect > 0 {
            width = height * aspect
        }
        return VideoDisplayGeometry(width: width, height: height, rotationDegrees: rotation)
    }
}
