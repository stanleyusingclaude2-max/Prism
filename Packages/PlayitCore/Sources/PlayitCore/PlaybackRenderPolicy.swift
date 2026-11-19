import Foundation

/// Choose the render allocation once, before starting a decoder session. The
/// square extent then stays unchanged through rotation, zoom and paused frames.
public enum PlaybackRenderPolicy {
    /// - Parameter sourceLongSide: the longer side of the video in pixels, when the
    ///   library already knows it. A source no larger than the screen gains nothing
    ///   from supersampling, so the target shrinks to what the screen can show.
    public static func drawableSide(nativeWidth: Double, nativeHeight: Double,
                                    physicalMemory: UInt64, conservingPower: Bool,
                                    sourceLongSide: Double? = nil) -> Int {
        guard nativeWidth.isFinite, nativeHeight.isFinite,
              nativeWidth > 0, nativeHeight > 0 else { return 2048 }
        let gib: UInt64 = 1_024 * 1_024 * 1_024
        let cap = conservingPower || physicalMemory < 3 * gib ? 2048 : physicalMemory < 5 * gib ? 3072 : 4096
        let screenLongSide = max(nativeWidth, nativeHeight)
        // Leave some detail for zoomed inspection while bounding square-swapchain
        // allocation. Smaller screens need not allocate the full tier budget.
        var desired = min(Double(cap), screenLongSide * 1.25)
        if let sourceLongSide, sourceLongSide.isFinite, sourceLongSide > 0 {
            // Keep about 80% of the screen so landscape playback is not visibly
            // upscaled by Core Animation; beyond that, follow the source.
            desired = min(desired, max(sourceLongSide, screenLongSide * 0.8))
        }
        return min(cap, max(1536, Int(ceil(desired / 256)) * 256))
    }
}

/// Large playing scrubs can display a nearby keyframe quickly; a stationary
/// pointer is refined afterwards and every final commit remains frame-exact.
public enum PlaybackSeekPolicy {
    public static let refinementDelay: Double = 0.12

    public static func usesExactSeek(commit: Bool, precisePreview: Bool,
                                     target: Double, renderedTime: Double) -> Bool {
        commit || precisePreview || !target.isFinite || !renderedTime.isFinite || abs(target - renderedTime) < 0.75
    }
}
