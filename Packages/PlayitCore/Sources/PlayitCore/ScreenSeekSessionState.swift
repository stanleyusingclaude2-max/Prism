import Foundation

/// Keeps a chain of consecutive screen drags separate from decoder completion.
/// Lifting a finger opens the next drag immediately; only the newest session can
/// finish the chain, and its original playing/paused intent survives re-entry.
public struct ScreenSeekSessionState: Equatable, Sendable {
    public private(set) var sessionID: UUID?
    public private(set) var isTouchActive = false
    public private(set) var resumePlayback = false

    public init() {}

    public var isActive: Bool { sessionID != nil }

    @discardableResult
    public mutating func begin(wasPlaying: Bool) -> UUID? {
        guard !isTouchActive else { return nil }
        if !isActive { resumePlayback = wasPlaying }
        let id = UUID()
        sessionID = id
        isTouchActive = true
        return id
    }

    @discardableResult
    public mutating func endTouch() -> UUID? {
        guard isTouchActive else { return nil }
        isTouchActive = false
        return sessionID
    }

    /// A stale decoder callback cannot end a newer drag, including one that has
    /// already lifted its finger and is waiting for its own final frame.
    @discardableResult
    public mutating func complete(session id: UUID) -> Bool {
        guard id == sessionID, !isTouchActive else { return false }
        cancel()
        return true
    }

    public mutating func cancel() {
        sessionID = nil
        isTouchActive = false
        resumePlayback = false
    }
}
