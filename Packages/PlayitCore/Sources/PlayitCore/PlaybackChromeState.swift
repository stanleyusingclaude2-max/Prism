/// The visibility and auto-hide deadline for playback controls. All times are
/// monotonic seconds (for example, ProcessInfo.processInfo.systemUptime).
///
/// Time publications call `update`; actual user actions call `interact` or
/// `tapVideo`. Keeping those separate prevents playback progress from keeping
/// the controls on screen indefinitely.
public struct PlaybackChromeState: Equatable, Sendable {
    public struct Context: Equatable, Sendable {
        public let isReady: Bool
        public let isPlaying: Bool
        public let isScrubbing: Bool
        public let isLocked: Bool
        public let isTemporaryFastPlayback: Bool
        public let isSceneActive: Bool
        public let isVoiceOverRunning: Bool
        public let isPresentingOptions: Bool
        public let hasError: Bool

        public init(
            isReady: Bool = false,
            isPlaying: Bool = false,
            isScrubbing: Bool = false,
            isLocked: Bool = false,
            isTemporaryFastPlayback: Bool = false,
            isSceneActive: Bool = true,
            isVoiceOverRunning: Bool = false,
            isPresentingOptions: Bool = false,
            hasError: Bool = false
        ) {
            self.isReady = isReady
            self.isPlaying = isPlaying
            self.isScrubbing = isScrubbing
            self.isLocked = isLocked
            self.isTemporaryFastPlayback = isTemporaryFastPlayback
            self.isSceneActive = isSceneActive
            self.isVoiceOverRunning = isVoiceOverRunning
            self.isPresentingOptions = isPresentingOptions
            self.hasError = hasError
        }
    }

    public private(set) var isVisible: Bool = true
    public private(set) var deadline: Double? = nil
    public private(set) var context: Context

    private let autoHideDelay: Double
    private var lastTime: Double?

    private enum Policy {
        case hidden
        case visible
        case paused
        case preserveVisibility
        case autoHide
    }

    /// Zero is supported for an immediate hide on the next `advance`. Negative
    /// or non-finite delays fall back to the normal three-second interval.
    public init(autoHideDelay: Double = 3) {
        self.autoHideDelay = autoHideDelay.isFinite && autoHideDelay >= 0 ? autoHideDelay : 3
        self.context = Context()
    }

    /// Applies a complete playback snapshot. Ordinary progress publications do
    /// not move an existing deadline; exiting a hold starts a fresh interval.
    public mutating func update(_ context: Context, now: Double) {
        let previousPolicy = policy
        self.context = context
        let time = acceptTime(now)

        switch policy {
        case .hidden:
            isVisible = false
            deadline = nil
        case .visible:
            isVisible = true
            deadline = nil
        case .paused:
            // Pausing reveals controls once. Subsequent paused snapshots retain
            // the viewer's choice to hide them for an unobstructed still frame.
            // Releasing temporary playback also preserves that choice.
            if previousPolicy != .paused && previousPolicy != .preserveVisibility {
                isVisible = true
            }
            deadline = nil
        case .preserveVisibility:
            deadline = nil
        case .autoHide:
            guard isVisible else { deadline = nil; return }
            if previousPolicy != .autoHide || deadline == nil {
                deadline = hideDeadline(after: time)
            }
        }
    }

    /// A control interaction reveals the controls and gives the viewer a full
    /// interval. A held fast-play gesture preserves visibility until release.
    public mutating func interact(now: Double) {
        let time = acceptTime(now)
        switch policy {
        case .hidden:
            isVisible = false
            deadline = nil
        case .visible, .paused:
            isVisible = true
            deadline = nil
        case .preserveVisibility:
            deadline = nil
        case .autoHide:
            isVisible = true
            deadline = hideDeadline(after: time)
        }
    }

    /// Tapping the video toggles controls during ordinary ready playback or
    /// pause. Paused controls never hide automatically. Loading, accessibility
    /// and options retain visible controls; the independent unlock affordance
    /// remains the view's responsibility.
    public mutating func tapVideo(now: Double) {
        let time = acceptTime(now)
        switch policy {
        case .hidden:
            isVisible = false
            deadline = nil
        case .visible:
            isVisible = true
            deadline = nil
        case .paused:
            isVisible.toggle()
            deadline = nil
        case .preserveVisibility:
            deadline = nil
        case .autoHide:
            isVisible.toggle()
            deadline = isVisible ? hideDeadline(after: time) : nil
        }
    }

    /// A timer callback evaluates the *current* deadline, so an older scheduled
    /// callback cannot hide controls whose interval was reset by interaction.
    public mutating func advance(now: Double) {
        let time = acceptTime(now)
        switch policy {
        case .hidden:
            isVisible = false
            deadline = nil
        case .visible:
            isVisible = true
            deadline = nil
        case .preserveVisibility, .paused:
            deadline = nil
        case .autoHide:
            guard isVisible else { deadline = nil; return }
            guard let time else { return }
            guard let deadline else {
                // An earlier non-finite timestamp could not arm a timer. Give
                // the viewer a full interval once a usable clock is available.
                self.deadline = hideDeadline(after: time)
                return
            }
            if time >= deadline {
                isVisible = false
                self.deadline = nil
            }
        }
    }

    private var policy: Policy {
        if context.isLocked { return .hidden }
        if !context.isReady || context.isScrubbing || !context.isSceneActive ||
            context.isVoiceOverRunning || context.isPresentingOptions || context.hasError {
            return .visible
        }
        // A temporary 2x gesture may itself publish a playing/paused change.
        // Preserve the visibility from before the gesture rather than letting
        // that transient change open or close the controls.
        if context.isTemporaryFastPlayback { return .preserveVisibility }
        if !context.isPlaying { return .paused }
        return .autoHide
    }

    private mutating func acceptTime(_ now: Double) -> Double? {
        guard now.isFinite else { return nil }
        let time = max(lastTime ?? now, now)
        lastTime = time
        return time
    }

    private func hideDeadline(after time: Double?) -> Double? {
        guard let time else { return nil }
        let candidate = time + autoHideDelay
        return candidate.isFinite ? candidate : nil
    }
}
