import Foundation

/// Maps a fixed square decoder target into a changing view without resizing
/// the decoder's swapchain or nonuniformly stretching its cached video image.
public struct VideoSurfaceLayout: Equatable, Sendable {
    public struct Rectangle: Equatable, Sendable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public var maxX: Double { x + width }
        public var maxY: Double { y + height }
    }

    /// How far a magnified image's centre may move from the viewport centre.
    public struct PanLimits: Equatable, Sendable {
        public let x: Double
        public let y: Double
    }

    /// A square layer centered on the image. At zoom 1 only generated black
    /// margins can lie outside the view; larger zooms deliberately crop the image.
    public let layerFrame: Rectangle
    /// The complete image rectangle after uniform scaling, before viewport clipping.
    public let videoFrame: Rectangle?

    /// MoltenVK compares the drawable extent with bounds × contentsScale.
    /// Keep both fixed, avoiding a suboptimal-swapchain recreation loop.
    public func contentsScale(forDrawableSide side: Double) -> Double? {
        guard side.isFinite, side > 0 else { return nil }
        let scale = (side / layerFrame.width).nextUp
        return scale.isFinite && scale > 0 ? scale : nil
    }

    /// Playback/paused state is deliberately not an input. The same frame is
    /// composed in exactly the same place regardless of decoder activity.
    /// `offsetX`/`offsetY` move a magnified image's centre away from the
    /// viewport centre; they are clamped so the image never uncovers an edge
    /// it already covered, and they have no effect at zoom 1.
    public init?(viewportWidth: Double, viewportHeight: Double,
                 geometry: VideoDisplayGeometry?, zoomScale: Double = 1,
                 offsetX: Double = 0, offsetY: Double = 0) {
        guard viewportWidth.isFinite, viewportHeight.isFinite,
              viewportWidth > 0, viewportHeight > 0,
              zoomScale.isFinite, zoomScale >= 1 else { return nil }
        let videoWidth: Double
        let videoHeight: Double
        var centerX = viewportWidth / 2
        var centerY = viewportHeight / 2
        if let geometry {
            let scale = min(viewportWidth / geometry.width, viewportHeight / geometry.height) * zoomScale
            videoWidth = geometry.width * scale
            videoHeight = geometry.height * scale
            guard videoWidth.isFinite, videoHeight.isFinite,
                  videoWidth > 0, videoHeight > 0 else { return nil }
            let limitX = max(0, (videoWidth - viewportWidth) / 2)
            let limitY = max(0, (videoHeight - viewportHeight) / 2)
            centerX += Self.clamp(offsetX, limit: limitX)
            centerY += Self.clamp(offsetY, limit: limitY)
            videoFrame = Rectangle(x: centerX - videoWidth / 2,
                                   y: centerY - videoHeight / 2,
                                   width: videoWidth, height: videoHeight)
        } else {
            // Before metadata arrives, a contained square never clips unknown content.
            videoWidth = min(viewportWidth, viewportHeight)
            videoHeight = videoWidth
            videoFrame = nil
        }
        let side = max(videoWidth, videoHeight)
        layerFrame = Rectangle(x: centerX - side / 2,
                               y: centerY - side / 2,
                               width: side, height: side)
    }

    /// The pan range of a magnified image. Unknown geometry or invalid input cannot pan.
    public static func panLimits(viewportWidth: Double, viewportHeight: Double,
                                 geometry: VideoDisplayGeometry?, zoomScale: Double) -> PanLimits {
        guard let geometry, viewportWidth.isFinite, viewportHeight.isFinite,
              viewportWidth > 0, viewportHeight > 0, zoomScale.isFinite, zoomScale >= 1 else {
            return PanLimits(x: 0, y: 0)
        }
        let scale = min(viewportWidth / geometry.width, viewportHeight / geometry.height) * zoomScale
        let width = geometry.width * scale
        let height = geometry.height * scale
        guard width.isFinite, height.isFinite else { return PanLimits(x: 0, y: 0) }
        return PanLimits(x: max(0, (width - viewportWidth) / 2), y: max(0, (height - viewportHeight) / 2))
    }

    private static func clamp(_ value: Double, limit: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, -limit), limit)
    }
}

/// Pinch-to-zoom state for the video surface: a magnification and the offset
/// of the image centre from the viewport centre. Gestures are applied as
/// increments so the content under the fingers stays under the fingers.
public struct VideoZoomState: Equatable, Sendable {
    public static let maximumScale: Double = 4
    /// A pinch released below this magnification returns to the complete image.
    public static let snapScale: Double = 1.08

    public private(set) var scale: Double = 1
    public private(set) var offsetX: Double = 0
    public private(set) var offsetY: Double = 0

    public init() {}

    public var isZoomed: Bool { scale > 1.000_001 }

    /// Scales by `factor` around an anchor measured from the viewport centre,
    /// after first following the fingers' movement by `panX`/`panY`.
    public mutating func pinch(by factor: Double, anchorX: Double, anchorY: Double,
                               panX: Double = 0, panY: Double = 0,
                               viewportWidth: Double, viewportHeight: Double,
                               geometry: VideoDisplayGeometry?) {
        guard factor.isFinite, factor > 0, anchorX.isFinite, anchorY.isFinite else { return }
        if panX.isFinite { offsetX += panX }
        if panY.isFinite { offsetY += panY }
        let target = min(max(scale * factor, 1), Self.maximumScale)
        let ratio = target / scale
        // Keep the image point under the anchor fixed: d = offset' + u * scale'.
        offsetX = anchorX - (anchorX - offsetX) * ratio
        offsetY = anchorY - (anchorY - offsetY) * ratio
        scale = target
        clamp(viewportWidth: viewportWidth, viewportHeight: viewportHeight, geometry: geometry)
    }

    /// Moves a magnified image. The complete image (scale 1) cannot move.
    public mutating func pan(byX dx: Double, y dy: Double,
                             viewportWidth: Double, viewportHeight: Double,
                             geometry: VideoDisplayGeometry?) {
        guard isZoomed, dx.isFinite, dy.isFinite else { return }
        offsetX += dx
        offsetY += dy
        clamp(viewportWidth: viewportWidth, viewportHeight: viewportHeight, geometry: geometry)
    }

    /// Ends a pinch: a barely magnified image returns to the complete image.
    public mutating func settle(viewportWidth: Double, viewportHeight: Double,
                                geometry: VideoDisplayGeometry?) {
        if scale < Self.snapScale {
            reset()
        } else {
            clamp(viewportWidth: viewportWidth, viewportHeight: viewportHeight, geometry: geometry)
        }
    }

    /// A centred magnification, used by the accessibility zoom action.
    public mutating func setCentered(scale value: Double) {
        guard value.isFinite else { return }
        scale = min(max(value, 1), Self.maximumScale)
        offsetX = 0
        offsetY = 0
    }

    public mutating func reset() {
        scale = 1
        offsetX = 0
        offsetY = 0
    }

    /// Keeps the offset inside the pan range, e.g. after rotation changes the viewport.
    public mutating func clamp(viewportWidth: Double, viewportHeight: Double,
                               geometry: VideoDisplayGeometry?) {
        let limits = VideoSurfaceLayout.panLimits(viewportWidth: viewportWidth, viewportHeight: viewportHeight,
                                                  geometry: geometry, zoomScale: scale)
        offsetX = offsetX.isFinite ? min(max(offsetX, -limits.x), limits.x) : 0
        offsetY = offsetY.isFinite ? min(max(offsetY, -limits.y), limits.y) : 0
    }
}
