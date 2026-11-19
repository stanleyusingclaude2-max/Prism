import Foundation

/// A touch session keeps its original time and viewport width. Decoder progress
/// and pointer reversals must not shift that anchor while previewing a frame.
public struct ScreenSeekState: Equatable, Sendable {
    public let startTime: Double
    public let duration: Double
    public let viewportWidth: Double
    public let secondsPerViewport: Double

    public init?(startTime: Double, duration: Double, viewportWidth: Double) {
        guard startTime.isFinite, duration.isFinite, viewportWidth.isFinite,
              duration > 0, viewportWidth > 0 else { return nil }
        self.startTime = min(max(startTime, 0), duration)
        self.duration = duration
        self.viewportWidth = viewportWidth
        secondsPerViewport = min(duration, 60)
    }

    public func target(horizontalTranslation: Double) -> Double? {
        guard horizontalTranslation.isFinite else { return nil }
        let fraction = horizontalTranslation / viewportWidth
        // Bound before multiplying, avoiding overflow for abnormal pointer data.
        if fraction >= duration / secondsPerViewport { return duration }
        if fraction <= -duration / secondsPerViewport { return 0 }
        return min(max(startTime + fraction * secondsPerViewport, 0), duration)
    }

    /// A small, mainly horizontal movement is enough to start seeking. This is
    /// a recognition threshold, not a one-shot reason to reject the whole touch.
    public static func shouldBegin(horizontal: Double, vertical: Double) -> Bool {
        guard horizontal.isFinite, vertical.isFinite else { return false }
        return abs(horizontal) >= 6 && abs(horizontal) >= abs(vertical)
    }
}

/// Keep an ambiguous start pending until the finger establishes its direction.
/// A UIKit pan delegate's single shouldBegin decision cannot do this: returning
/// false there rejects the entire touch, even if the next movement is horizontal.
public struct ScreenSeekDirectionLock: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        case pending, horizontal, vertical
    }

    public private(set) var decision: Decision = .pending

    public init() {}

    @discardableResult
    public mutating func update(horizontal: Double, vertical: Double) -> Decision {
        guard decision == .pending, horizontal.isFinite, vertical.isFinite else { return decision }
        if ScreenSeekState.shouldBegin(horizontal: horizontal, vertical: vertical) {
            decision = .horizontal
        } else if abs(vertical) >= 12 && abs(vertical) > abs(horizontal) * 1.5 {
            decision = .vertical
        }
        return decision
    }
}
