import Foundation

/// Keeps a temporary speed gesture separate from the user's persistent speed.
/// A cancelled gesture restores the speed but never starts playback by itself.
public struct TemporaryPlaybackState: Sendable {
    public struct Snapshot: Equatable, Sendable {
        public let rate: Float
        public let isPlaying: Bool

        public init(rate: Float, isPlaying: Bool) {
            self.rate = rate
            self.isPlaying = isPlaying
        }
    }

    private var original: Snapshot?
    public var isActive: Bool { original != nil }

    public init() {}

    public mutating func begin(originalRate: Float, wasPlaying: Bool) -> Snapshot? {
        guard original == nil, originalRate.isFinite, originalRate > 0 else { return nil }
        original = Snapshot(rate: originalRate, isPlaying: wasPlaying)
        return Snapshot(rate: 2, isPlaying: true)
    }

    public mutating func end(reachedEnd: Bool = false) -> Snapshot? {
        guard let saved = original else { return nil }
        original = nil
        return Snapshot(rate: saved.rate, isPlaying: reachedEnd ? false : saved.isPlaying)
    }

    public mutating func cancel() -> Snapshot? {
        guard let saved = original else { return nil }
        original = nil
        return Snapshot(rate: saved.rate, isPlaying: false)
    }
}
