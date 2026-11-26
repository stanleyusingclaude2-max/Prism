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
///
/// Long videos usually carry long GOPs. An exact frame there means decoding
/// everything from the previous keyframe, which can take most of a second, so
/// a drag that waits for exact frames stalls. Once exact seeks prove that slow
/// for a file, previews use keyframes, small moves wait for the finger to rest,
/// and a newer target replaces an exact decode that is still running.
public enum PlaybackSeekPolicy {
    public static let refinementDelay: Double = 0.12
    /// Targets closer than this to the frame on screen are small moves.
    public static let smallMove: Double = 0.75
    /// An exact seek slower than this cannot follow a finger.
    public static let slowExactSeek: Double = 0.2

    public enum Preview: Equatable, Sendable {
        /// Decode the exact frame now.
        case exact
        /// Show the nearest keyframe now and refine once the pointer rests.
        case keyframe
        /// Keep the picture and refine once the pointer rests. A keyframe would
        /// jump back up to a whole GOP for a move of a few frames.
        case waitForRest
    }

    public static func usesExactSeek(commit: Bool, precisePreview: Bool,
                                     target: Double, renderedTime: Double) -> Bool {
        commit || precisePreview || !target.isFinite || !renderedTime.isFinite || abs(target - renderedTime) < smallMove
    }

    /// How a preview during a drag reaches its target. Paused inspection keeps
    /// exact previews while exact seeks are fast.
    public static func preview(precise: Bool, exactSeeksAreSlow: Bool,
                               target: Double, renderedTime: Double) -> Preview {
        guard target.isFinite, renderedTime.isFinite else { return .exact }
        let small = abs(target - renderedTime) < smallMove
        if exactSeeksAreSlow { return small ? .waitForRest : .keyframe }
        return precise || small ? .exact : .keyframe
    }

    /// Whether a newer target replaces the seek the decoder is still working on.
    /// Keyframe previews finish quickly and keep the picture moving, and a final
    /// commit must finish, so only a slow exact preview is replaced.
    public static func replacesRunningSeek(runningIsExact: Bool, runningIsCommit: Bool,
                                           runningFor elapsed: Double, exactSeeksAreSlow: Bool) -> Bool {
        runningIsExact && !runningIsCommit && (exactSeeksAreSlow || elapsed >= slowExactSeek)
    }
}

/// Learns from exact seeks whether this file's exact frames are quick enough to
/// preview while dragging. A moving average lets one cold first decode, or one
/// unusually long GOP, wear off again.
public struct ExactSeekCost: Equatable, Sendable {
    public private(set) var isSlow = false
    private var average: Double?

    public init() {}

    /// - Parameter finished: false for a seek replaced while still decoding. It
    ///   proves only a lower bound, so it counts only once it is already slow.
    public mutating func record(seconds: Double, finished: Bool) {
        guard seconds.isFinite, seconds >= 0 else { return }
        if !finished && seconds < PlaybackSeekPolicy.slowExactSeek { return }
        let next = average.map { $0 * 0.6 + seconds * 0.4 } ?? seconds
        average = next
        isSlow = next >= PlaybackSeekPolicy.slowExactSeek
    }
}
