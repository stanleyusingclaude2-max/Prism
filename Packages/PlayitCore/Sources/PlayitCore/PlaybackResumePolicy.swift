import Foundation

/// Decides when a partially watched video reopens where it stopped.
/// Short clips and positions near either end always start from the beginning.
public enum PlaybackResumePolicy {
    /// Clips shorter than this are rewatched from the start.
    public static let minimumDuration: Double = 15
    /// Stopping in the first seconds is not worth remembering.
    public static let minimumPosition: Double = 3

    /// The position to persist when playback stops, or nil to forget it.
    public static func storedPosition(position: Double, duration: Double) -> Double? {
        guard position.isFinite, duration.isFinite,
              duration >= minimumDuration, position >= minimumPosition else { return nil }
        // Treat the closing seconds (credits, a final shot) as finished.
        let tail = max(3, duration * 0.05)
        guard position <= duration - tail else { return nil }
        return position
    }

    /// Validates a stored position before playback starts. When the duration is
    /// not known yet, the stored value is trusted; the decoder clamps it later.
    public static func resumePosition(stored: Double?, duration: Double?) -> Double? {
        guard let stored, stored.isFinite, stored >= minimumPosition else { return nil }
        guard let duration, duration.isFinite, duration > 0 else { return stored }
        return storedPosition(position: stored, duration: duration)
    }
}

/// Picks the frame used as a video's thumbnail. Many clips open on a black
/// fade, so the poster comes from slightly after the start.
public enum MediaPosterPolicy {
    public static func time(duration: Double?) -> Double {
        guard let duration, duration.isFinite, duration > 0 else { return 1 }
        return min(duration * 0.1, 1)
    }
}
