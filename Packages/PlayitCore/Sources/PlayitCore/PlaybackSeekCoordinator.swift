import Foundation

/// The seek bookkeeping of a drag, kept apart from libmpv so it can be tested.
/// The engine reports what mpv did and performs the returned actions.
///
/// mpv works on one of these seeks at a time, with at most one newer target
/// waiting, so a fast drag keeps showing finished frames instead of restarting
/// the decoder on every touch event. The exceptions are a slow exact preview,
/// which a newer target replaces at once (mpv abandons the old decode), and a
/// final commit whose exact frame is already being decoded or already on screen.
///
/// A replaced seek can still produce events: its `MPV_EVENT_SEEK` or
/// `MPV_EVENT_PLAYBACK_RESTART` may arrive after the newer command was sent.
/// mpv replies to a seek command when it queues the seek, before that seek
/// starts, so only a seek event that follows the running command's reply
/// belongs to it, and only a restart after that event finishes it.
public struct PlaybackSeekCoordinator: Sendable {
    public struct Seek: Equatable, Sendable {
        public let id: UInt64
        public let target: Double
        public let session: UUID
        public let exact: Bool
        public var commit: Bool
        public var resume: Bool
        public var pauseRevision: UInt64

        public init(id: UInt64, target: Double, session: UUID, exact: Bool,
                    commit: Bool, resume: Bool, pauseRevision: UInt64) {
            self.id = id
            self.target = target
            self.session = session
            self.exact = exact
            self.commit = commit
            self.resume = resume
            self.pauseRevision = pauseRevision
        }
    }

    public enum Action: Equatable, Sendable {
        /// Send this seek to mpv now.
        case send(Seek)
        /// The exact frame on screen already is this commit's target. Finish
        /// the commit without decoding it again.
        case finish(Seek)
    }

    public enum Reply: Equatable, Sendable {
        /// The reply to the running seek's command.
        case running
        /// The reply to a seek that a newer one replaced.
        case replaced
        /// Not a seek of this coordinator.
        case other
    }

    public private(set) var running: Seek?
    public private(set) var waiting: Seek?
    public private(set) var cost = ExactSeekCost()
    private var runningSentAt = 0.0
    private var runningAccepted = false
    private var runningBegan = false
    private var exactFrame: (session: UUID, target: Double)?
    private var replacedIDs: [UInt64] = []

    public init() {}

    public var exactSeeksAreSlow: Bool { cost.isSlow }

    /// Hands over a new seek. An action returned here must be performed now.
    public mutating func submit(_ seek: Seek, now: Double) -> Action? {
        if seek.commit {
            if var current = running, current.exact, !current.commit,
               current.session == seek.session, Self.same(current.target, seek.target) {
                // The exact frame of this commit is already being decoded.
                current.commit = true
                current.resume = seek.resume
                current.pauseRevision = seek.pauseRevision
                running = current
                waiting = nil
                return nil
            }
            if running == nil, waiting == nil, let frame = exactFrame,
               frame.session == seek.session, Self.same(frame.target, seek.target) {
                return .finish(seek)
            }
        }
        if let current = running {
            let elapsed = now - runningSentAt
            if PlaybackSeekPolicy.replacesRunningSeek(runningIsExact: current.exact, runningIsCommit: current.commit,
                                                       runningFor: elapsed, exactSeeksAreSlow: cost.isSlow) {
                cost.record(seconds: elapsed, finished: false)
                replacedIDs.append(current.id)
                if replacedIDs.count > 16 { replacedIDs.removeFirst() }
                running = nil
            }
        }
        waiting = seek
        return dispatch(now: now)
    }

    /// A nearby target made a waiting preview of an older, distant one obsolete.
    public mutating func dropWaitingPreview() {
        if waiting?.commit == false { waiting = nil }
    }

    /// A new drag began or the drag was cancelled: nothing waiting is wanted.
    public mutating func dropWaiting() {
        waiting = nil
    }

    /// Playback, a frame step or a new drag moved the picture away from the
    /// last exact seek.
    public mutating func pictureMoved() {
        exactFrame = nil
    }

    /// mpv replied to a command without an error.
    public mutating func replied(id: UInt64) -> Reply {
        if running?.id == id {
            runningAccepted = true
            return .running
        }
        if let index = replacedIDs.firstIndex(of: id) {
            replacedIDs.remove(at: index)
            return .replaced
        }
        return .other
    }

    /// Whether an error reply with this id belongs to a replaced seek.
    public mutating func isReplaced(id: UInt64) -> Bool {
        guard let index = replacedIDs.firstIndex(of: id) else { return false }
        replacedIDs.remove(at: index)
        return true
    }

    /// `MPV_EVENT_SEEK`.
    public mutating func seekStarted() {
        if running != nil, runningAccepted { runningBegan = true }
    }

    /// `MPV_EVENT_PLAYBACK_RESTART`. Returns the seek this restart finished, if
    /// any, and the waiting seek to send next. When a newer seek is sent, the
    /// finished one has been superseded and must not complete a commit.
    public mutating func playbackRestarted(now: Double) -> (finished: Seek?, next: Action?) {
        guard let done = running, runningBegan else { return (nil, nil) }
        running = nil
        runningAccepted = false
        runningBegan = false
        if done.exact { cost.record(seconds: now - runningSentAt, finished: true) }
        if waiting != nil { return (done, dispatch(now: now)) }
        if done.exact { exactFrame = (done.session, done.target) }
        return (done, nil)
    }

    /// The running seek failed or stalled. Returns the waiting seek to send next.
    public mutating func abandonRunning(now: Double) -> Action? {
        running = nil
        runningAccepted = false
        runningBegan = false
        return dispatch(now: now)
    }

    /// Forget every seek, as after a failure.
    public mutating func reset() {
        running = nil
        waiting = nil
        runningAccepted = false
        runningBegan = false
        exactFrame = nil
    }

    private mutating func dispatch(now: Double) -> Action? {
        guard running == nil, let next = waiting else { return nil }
        waiting = nil
        running = next
        runningSentAt = now
        runningAccepted = false
        runningBegan = false
        exactFrame = nil
        return .send(next)
    }

    private static func same(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) < 0.000_5
    }
}
