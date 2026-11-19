import AVFoundation
import Combine
import Foundation
import PlayitCore
import UIKit

/// High-frequency playback time, kept apart from the controller's other state.
/// mpv reports a position for nearly every frame; publishing it on the controller
/// would re-render the whole player 24–60 times a second. Only the time label,
/// timeline and drag preview observe this object.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published fileprivate(set) var time: Double = 0
}

/// UI-facing playback state. All libmpv access is isolated on MPVEngine's serial queue.
@MainActor
final class PlaybackController: ObservableObject {
    let url: URL
    private let fileAccess: PlaybackFileAccess?
    let renderView = MPVRenderView(frame: .zero)
    let clock = PlaybackClock()
    /// The remembered position this session started from, if any.
    let resumedFrom: Double?

    @Published private(set) var duration: Double = 0
    /// The logical position. Views read it through `clock`, never by observing the controller.
    private(set) var currentTime: Double = 0 {
        didSet { publishClock() }
    }
    private(set) var renderedTime: Double = 0
    @Published private(set) var isPlaying = false {
        didSet {
            if oldValue != isPlaying {
                updateAutoLock()
                updateNowPlaying()
            }
        }
    }
    @Published private(set) var isReady = false
    @Published private(set) var isScrubbing = false {
        didSet { if oldValue != isScrubbing { updateAutoLock() } }
    }
    @Published private(set) var isScreenSeeking = false
    @Published private(set) var isScreenSeekTouchActive = false
    @Published private(set) var screenSeekDelta: Double = 0
    @Published private(set) var isBuffering = false
    @Published private(set) var isLooping = false
    @Published private(set) var loopStart: Double?
    @Published private(set) var loopEnd: Double?
    @Published private(set) var loopMessage: String?
    @Published private(set) var isExportingFrame = false
    @Published private(set) var didPresentFrame = false
    @Published var exportedFrameURL: URL?
    @Published private(set) var preventsAutoLock = false
    /// Increments each time a non-looping file reaches its end.
    @Published private(set) var playbackEndCount = 0
    @Published var isLocked = false {
        didSet {
            if isLocked {
                cancelTemporaryFastPlayback()
                if isScrubbing { pause() }
            }
        }
    }
    @Published private(set) var playbackRate: Float = 1
    @Published private(set) var isTemporaryFastPlayback = false
    @Published private(set) var isVideoZoomed = false
    @Published var errorMessage: String?
    @Published private(set) var frameStepAvailable = false
    @Published private(set) var nominalFPS: Double = 0
    @Published private(set) var videoWidth = 0
    @Published private(set) var videoHeight = 0
    @Published private(set) var displayGeometry: VideoDisplayGeometry?
    @Published private(set) var audioTracks: [PlaybackTrack] = []
    @Published private(set) var subtitleTracks: [PlaybackTrack] = []
    @Published private(set) var selectedAudioTrackID: Int?
    @Published private(set) var selectedSubtitleTrackID: Int?

    /// Views showing the time set this while they are on screen. Hidden controls
    /// do not need a position update for every decoded frame.
    var clockIsLive = true {
        didSet { if clockIsLive && !oldValue { clock.time = currentTime } }
    }
    /// Set by the player view when a list is available: +1 next, -1 previous.
    var onRemoteTrackChange: (@MainActor (Int) -> Void)?

    private lazy var engine = MPVEngine { [weak self] event in
        // Preserve the decoder's event order (in particular final seek -> pause -> time).
        DispatchQueue.main.async { [weak self] in self?.receive(event) }
    }
    private let nowPlaying = NowPlayingSession()
    private var loadRequested = false
    private var engineStarted = false
    private var stopped = false
    private var wasPlayingBeforeScrub = false
    private var scrubSession: UUID?
    private var scrubAtEdge = false
    private var screenSeek: ScreenSeekState?
    private var screenSeekSession = ScreenSeekSessionState()
    private var notificationTokens: [NSObjectProtocol] = []
    private var resumeAfterInterruption = false
    private var temporaryPlayback = TemporaryPlaybackState()
    private var reachedEnd = false
    private var isAudioInterrupted = false
    private var idleGrace: Task<Void, Never>?
    private var isInBackground = false
    private var zoom = VideoZoomState()

    init(url: URL, fileAccess: PlaybackFileAccess? = nil, resumePosition: Double? = nil, sourceLongSide: Double? = nil) {
        self.url = url
        self.fileAccess = fileAccess
        self.resumedFrom = resumePosition.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        renderView.videoLayer.sourceLongSide = sourceLongSide
        renderView.onDrawableReady = { [weak self] in self?.attachIfReady() }
        renderView.onViewportSizeChange = { [weak self] in self?.cancelScreenSeeking() }
        observeApplication()
    }

    deinit {
        idleGrace?.cancel()
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
    }

    func load() async {
        guard !loadRequested, !stopped else { return }
        guard url.isFileURL else {
            errorMessage = "请选择手机中的本地视频文件。"
            return
        }
        loadRequested = true
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            errorMessage = "无法启用音频播放：\(error.localizedDescription)"
        }
        attachIfReady()
    }

    private func attachIfReady() {
        guard loadRequested, !engineStarted, !stopped,
              renderView.window != nil, renderView.bounds.width > 1, renderView.bounds.height > 1 else { return }
        engineStarted = true
        engine.start(url: url, layer: renderView.videoLayer, fileAccess: fileAccess, startPosition: resumedFrom)
    }

    func recordUserInteraction() {
        guard !stopped, !isInBackground else { return }
        idleGrace?.cancel()
        idleGrace = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(60)) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            self.idleGrace = nil
            self.updateAutoLock()
        }
        updateAutoLock()
    }

    private func updateAutoLock() {
        let keepAwake = !stopped && !isInBackground && (isPlaying || isScrubbing || idleGrace != nil)
        if keepAwake != preventsAutoLock { preventsAutoLock = keepAwake }
    }

    private func publishClock() {
        // A drag preview stays live even when the controls are hidden.
        guard clockIsLive || isScrubbing else { return }
        if clock.time != currentTime { clock.time = currentTime }
    }

    func togglePlayback() {
        guard isReady, !isScrubbing, !isExportingFrame, !stopped, !isAudioInterrupted else { return }
        recordUserInteraction()
        // The button's visible intent wins over the state that existed before the hold.
        let shouldPause = isPlaying
        cancelTemporaryFastPlayback()
        if !shouldPause { reachedEnd = false }
        engine.setPaused(shouldPause)
        isPlaying = !shouldPause
    }

    func pause() {
        cancelTemporaryFastPlayback()
        clearScreenSeeking()
        wasPlayingBeforeScrub = false
        resumeAfterInterruption = false
        if isScrubbing {
            isScrubbing = false
            scrubSession = nil
            currentTime = renderedTime
            engine.cancelScrubbing()
        }
        engine.setPaused(true)
        isPlaying = false
    }

    func beginTemporaryFastPlayback() {
        guard isReady, !isLocked, !isScrubbing, !isExportingFrame, !stopped, !isAudioInterrupted,
              let target = temporaryPlayback.begin(originalRate: playbackRate, wasPlaying: isPlaying) else { return }
        recordUserInteraction()
        reachedEnd = false
        isTemporaryFastPlayback = true
        playbackRate = target.rate
        engine.setRate(Double(target.rate))
        engine.setPaused(!target.isPlaying)
        isPlaying = target.isPlaying
        updateNowPlaying()
    }

    func endTemporaryFastPlayback() {
        guard let restored = temporaryPlayback.end(reachedEnd: reachedEnd) else { return }
        recordUserInteraction()
        isTemporaryFastPlayback = false
        playbackRate = restored.rate
        engine.setRate(Double(restored.rate))
        let shouldPlay = restored.isPlaying && isReady && !isLocked && !isScrubbing && !stopped && !isAudioInterrupted
        engine.setPaused(!shouldPlay)
        isPlaying = shouldPlay
        updateNowPlaying()
    }

    /// Explicit actions and lifecycle changes restore the original rate without
    /// resuming playback; a later finger-up event consequently becomes a no-op.
    private func cancelTemporaryFastPlayback() {
        guard let restored = temporaryPlayback.cancel() else { return }
        isTemporaryFastPlayback = false
        playbackRate = restored.rate
        engine.setRate(Double(restored.rate))
        engine.setPaused(true)
        isPlaying = false
    }

    func beginScrubbing() {
        guard isReady, !stopped, !isScrubbing, !isLocked, !isExportingFrame, !isAudioInterrupted else { return }
        recordUserInteraction()
        cancelTemporaryFastPlayback()
        reachedEnd = false
        let session = UUID()
        scrubSession = session
        scrubAtEdge = false
        wasPlayingBeforeScrub = isPlaying
        isScrubbing = true
        isPlaying = false
        engine.beginScrubbing(session: session)
    }

    func scrub(to seconds: Double) {
        guard isScrubbing, let session = scrubSession, seconds.isFinite else { return }
        let target = clamped(seconds)
        let atEdge = duration > 0 && (target <= 0 || target >= duration)
        if atEdge && !scrubAtEdge { Haptics.edge() }
        scrubAtEdge = atEdge
        currentTime = target
        engine.seek(to: target, session: session, commit: false, resume: false,
                    precisePreview: !wasPlayingBeforeScrub)
    }

    func endScrubbing(at seconds: Double) {
        guard isScrubbing, let session = scrubSession, seconds.isFinite else { return }
        recordUserInteraction()
        let target = clamped(seconds)
        currentTime = target
        // isScrubbing stays true until PLAYBACK_RESTART confirms the selected frame is ready.
        engine.seek(to: target, session: session, commit: true, resume: wasPlayingBeforeScrub)
    }

    /// One exact seek that keeps the current playing/paused state.
    func seek(to seconds: Double) {
        guard seconds.isFinite, isReady, !isScrubbing else { return }
        beginScrubbing()
        endScrubbing(at: seconds)
    }

    /// Starts a resumed video over from its first frame.
    func restartFromBeginning() {
        seek(to: 0)
    }

    var canBeginScreenSeeking: Bool {
        let canEnterScrub = !isScrubbing || (screenSeekSession.isActive && !screenSeekSession.isTouchActive)
        return isReady && !isLocked && !isVideoZoomed && canEnterScrub && !isScreenSeekTouchActive &&
            !isTemporaryFastPlayback && !isExportingFrame && !stopped && !isAudioInterrupted &&
            duration.isFinite && duration > 0
    }

    @discardableResult
    func beginScreenSeeking(viewportWidth: Double) -> Bool {
        guard canBeginScreenSeeking,
              let state = ScreenSeekState(startTime: currentTime, duration: duration,
                                          viewportWidth: viewportWidth),
              let session = screenSeekSession.begin(wasPlaying: isPlaying) else { return false }
        recordUserInteraction()
        screenSeek = state
        screenSeekDelta = 0
        isScreenSeeking = true
        isScreenSeekTouchActive = true
        reachedEnd = false
        scrubSession = session
        scrubAtEdge = false
        // During a pending commit isPlaying is temporarily false. Preserve the
        // intent saved before the first drag instead of capturing that false.
        wasPlayingBeforeScrub = screenSeekSession.resumePlayback
        isScrubbing = true
        isPlaying = false
        // Replace the session/pending target, but leave an in-flight seek alive.
        // Its completion can then be drained without confusing the next seek.
        engine.beginScrubbing(session: session)
        return true
    }

    func updateScreenSeeking(horizontalTranslation: Double) {
        guard isScreenSeekTouchActive, let state = screenSeek,
              let target = state.target(horizontalTranslation: horizontalTranslation) else { return }
        screenSeekDelta = target - state.startTime
        scrub(to: target)
    }

    func endScreenSeeking(horizontalTranslation: Double, cancelled: Bool = false) {
        guard isScreenSeekTouchActive else { return }
        guard !cancelled, let state = screenSeek,
              let target = state.target(horizontalTranslation: horizontalTranslation) else {
            cancelScreenSeeking()
            return
        }
        screenSeekDelta = target - state.startTime
        screenSeekSession.endTouch()
        // A second drag may start while the final exact frame is still decoding.
        // The preview remains visible, but it no longer owns the user's finger.
        isScreenSeekTouchActive = false
        // Keep the preview state until the decoder confirms this final frame.
        endScrubbing(at: target)
    }

    func cancelScreenSeeking() {
        guard isScreenSeeking else { return }
        // Explicit cancellation invalidates the decoder session and its saved
        // resume intent. Finger-up after rotation/backgrounding cannot revive it.
        pause()
    }

    private func clearScreenSeeking() {
        screenSeek = nil
        screenSeekSession.cancel()
        isScreenSeekTouchActive = false
        isScreenSeeking = false
        screenSeekDelta = 0
    }

    func stepFrame(_ direction: Int) {
        guard isReady, frameStepAvailable, !isScrubbing, !isExportingFrame, !stopped else { return }
        recordUserInteraction()
        cancelTemporaryFastPlayback()
        reachedEnd = false
        isPlaying = false
        engine.stepFrame(direction < 0 ? -1 : 1)
    }

    func setRate(_ rate: Float) {
        guard rate.isFinite else { return }
        recordUserInteraction()
        cancelTemporaryFastPlayback()
        playbackRate = min(max(rate, 0.1), 4)
        engine.setRate(Double(playbackRate))
        updateNowPlaying()
    }

    func setLooping(_ looping: Bool) {
        if looping { clearABLoop() }
        isLooping = looping
        engine.setLooping(looping)
    }

    /// Subtitle size relative to mpv's default; 1 is the normal size.
    func setSubtitleScale(_ scale: Double) {
        guard scale.isFinite, scale > 0 else { return }
        engine.setSubtitleScale(scale)
    }

    // MARK: Zoom

    var canZoomVideo: Bool {
        isReady && displayGeometry != nil && !isLocked && !stopped
    }

    /// Applies one pinch increment around an anchor measured from the viewport centre.
    func zoomVideo(by factor: Double, anchorX: Double, anchorY: Double, panX: Double, panY: Double) {
        guard canZoomVideo else { return }
        let viewport = zoomViewport
        zoom.clamp(viewportWidth: viewport.width, viewportHeight: viewport.height, geometry: displayGeometry)
        zoom.pinch(by: factor, anchorX: anchorX, anchorY: anchorY, panX: panX, panY: panY,
                   viewportWidth: viewport.width, viewportHeight: viewport.height, geometry: displayGeometry)
        applyZoom()
    }

    func panVideo(byX dx: Double, y dy: Double) {
        guard zoom.isZoomed, !isLocked, !stopped else { return }
        let viewport = zoomViewport
        zoom.clamp(viewportWidth: viewport.width, viewportHeight: viewport.height, geometry: displayGeometry)
        zoom.pan(byX: dx, y: dy, viewportWidth: viewport.width, viewportHeight: viewport.height,
                 geometry: displayGeometry)
        applyZoom()
    }

    func settleVideoZoom() {
        let viewport = zoomViewport
        zoom.settle(viewportWidth: viewport.width, viewportHeight: viewport.height, geometry: displayGeometry)
        applyZoom()
        recordUserInteraction()
    }

    func resetVideoZoom() {
        guard zoom.isZoomed else { return }
        zoom.reset()
        applyZoom()
        recordUserInteraction()
    }

    /// VoiceOver alternative to pinching: a centred 2× view, or the complete image.
    func toggleAccessibilityZoom() {
        guard canZoomVideo else { return }
        if zoom.isZoomed { zoom.reset() } else { zoom.setCentered(scale: 2) }
        applyZoom()
        recordUserInteraction()
    }

    private var zoomViewport: (width: Double, height: Double) {
        (Double(renderView.bounds.width), Double(renderView.bounds.height))
    }

    private func applyZoom() {
        renderView.zoom = zoom
        renderView.layoutIfNeeded()
        if isVideoZoomed != zoom.isZoomed { isVideoZoomed = zoom.isZoomed }
    }

    // MARK: A–B loop

    var canMarkLoop: Bool {
        isReady && frameStepAvailable && duration > 0 && !isLocked && !isScrubbing && !isExportingFrame && !isAudioInterrupted
    }

    func markLoopStart() {
        guard canMarkLoop else { return }
        recordUserInteraction()
        loopStart = clamped(renderedTime)
        loopEnd = nil
        loopMessage = nil
        engine.setABLoop(start: nil, end: nil)
    }

    func markLoopEnd() {
        guard canMarkLoop, let start = loopStart else { return }
        let end = clamped(renderedTime)
        guard end - start >= 0.01 else {
            loopMessage = "先定位到 A 点之后的画面，再设 B 点。"
            return
        }
        recordUserInteraction()
        loopEnd = end
        loopMessage = nil
        isLooping = false
        engine.setABLoop(start: start, end: end)
        // Start at A so playback and paused inspection both enter the interval.
        beginScrubbing()
        endScrubbing(at: start)
    }

    func clearABLoop() {
        recordUserInteraction()
        loopStart = nil
        loopEnd = nil
        loopMessage = nil
        engine.setABLoop(start: nil, end: nil)
    }

    // MARK: Frames, tracks, subtitles

    var canExportFrame: Bool {
        isReady && didPresentFrame && displayGeometry != nil && !isLocked && !isScrubbing && !isExportingFrame && !stopped
    }

    func captureCurrentFrame() {
        guard canExportFrame else { return }
        recordUserInteraction()
        pause()
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PrismFrames", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            removeExpiredPrismFrames(in: directory)
            let name = "Prism-" + UUID().uuidString.prefix(8) + ".png"
            isExportingFrame = true
            engine.exportCurrentFrame(to: directory.appendingPathComponent(name))
        } catch {
            errorMessage = "无法创建图片文件：\(error.localizedDescription)"
        }
    }

    func selectAudioTrack(_ id: Int) {
        guard audioTracks.contains(where: { $0.id == id }) else { return }
        engine.selectAudioTrack(id)
    }

    func selectSubtitleTrack(_ id: Int?) {
        guard id == nil || subtitleTracks.contains(where: { $0.id == id }) else { return }
        engine.selectSubtitleTrack(id)
    }

    func loadExternalSubtitle(_ url: URL) {
        guard ["srt", "ass", "ssa", "vtt"].contains(url.pathExtension.lowercased()) else {
            errorMessage = "请选择 SRT、ASS、SSA 或 VTT 字幕文件。"
            return
        }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let fm = FileManager.default
            let directory = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SubtitleImports", isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(url.pathExtension)
            try fm.copyItem(at: url, to: destination)
            engine.addSubtitle(destination)
        } catch {
            errorMessage = "无法导入字幕：\(error.localizedDescription)"
        }
    }

    func stop(onStopped: (@MainActor @Sendable () -> Void)? = nil) {
        guard !stopped else { return }
        cancelTemporaryFastPlayback()
        stopped = true
        idleGrace?.cancel()
        idleGrace = nil
        updateAutoLock()
        nowPlaying.deactivate()
        onRemoteTrackChange = nil
        isPlaying = false
        isReady = false
        isScrubbing = false
        clearScreenSeeking()
        scrubSession = nil
        renderView.onDrawableReady = nil
        renderView.onViewportSizeChange = nil
        engine.stop(onStopped: onStopped)
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func clamped(_ seconds: Double) -> Double {
        min(max(0, seconds), max(0, duration))
    }

    // MARK: System playback controls

    private func activateNowPlayingIfNeeded() {
        guard !stopped, !nowPlaying.isActive else { return }
        let title = (url.lastPathComponent as NSString).deletingPathExtension
        var track: (@MainActor (Int) -> Void)?
        if onRemoteTrackChange != nil {
            track = { [weak self] direction in self?.onRemoteTrackChange?(direction) }
        }
        nowPlaying.activate(title: title, handlers: NowPlayingSession.Handlers(
            play: { [weak self] in self?.remotePlay() },
            pause: { [weak self] in self?.remotePause() },
            toggle: { [weak self] in self?.remoteToggle() },
            seek: { [weak self] position in self?.seek(to: position) },
            track: track
        ))
        updateNowPlaying()
    }

    private func updateNowPlaying() {
        guard !stopped, isReady else { return }
        nowPlaying.update(elapsed: currentTime, duration: duration, rate: Double(playbackRate), isPlaying: isPlaying)
    }

    private func remotePlay() {
        guard !isPlaying, !isInBackground else { return }
        togglePlayback()
    }

    private func remotePause() {
        guard isPlaying else { return }
        togglePlayback()
    }

    private func remoteToggle() {
        if isPlaying { remotePause() } else { remotePlay() }
    }

    // MARK: Decoder events

    private func receive(_ event: MPVEngine.Event) {
        guard !stopped else { return }
        switch event {
        case .loaded(let metadata):
            if !isReady { reachedEnd = false }
            duration = metadata.duration
            nominalFPS = metadata.fps
            videoWidth = metadata.width
            videoHeight = metadata.height
            if let geometry = metadata.displayGeometry {
                displayGeometry = geometry
                renderView.displayGeometry = geometry
                // Metadata and bounds may change while the decoder is paused.
                // Relayout the existing drawable without waiting for another video frame.
                renderView.setNeedsLayout()
                renderView.layoutIfNeeded()
            }
            frameStepAvailable = metadata.canStepFrames
            isReady = true
            activateNowPlayingIfNeeded()
        case .time(let seconds):
            guard seconds.isFinite else { return }
            renderedTime = seconds
            if !isScrubbing { currentTime = seconds }
        case .firstFrameReady:
            didPresentFrame = true
        case .duration(let seconds):
            if seconds.isFinite { duration = max(0, seconds) }
        case .paused(let paused):
            isPlaying = !paused && !isScrubbing
        case .playbackEnded:
            reachedEnd = true
            isPlaying = false
            recordUserInteraction()
            endTemporaryFastPlayback()
            playbackEndCount &+= 1
        case .buffering(let buffering):
            isBuffering = buffering
        case .tracks(let audio, let subtitles, let audioID, let subtitleID):
            audioTracks = audio
            subtitleTracks = subtitles
            selectedAudioTrackID = audioID
            selectedSubtitleTrackID = subtitleID
        case .seekCommitted(let session, let position, let resumed):
            guard session == scrubSession else { return }
            if isScreenSeeking, !screenSeekSession.complete(session: session) { return }
            isScrubbing = false
            clearScreenSeeking()
            scrubSession = nil
            currentTime = position
            renderedTime = position
            isPlaying = resumed
            updateNowPlaying()
        case .frameExported(let url):
            isExportingFrame = false
            exportedFrameURL = url
        case .frameExportFailed(let message):
            isExportingFrame = false
            errorMessage = message
        case .error(let message):
            // Invalidate any in-flight commit's saved resume intent too.
            pause()
            errorMessage = message
        case .failed(let message):
            pause()
            errorMessage = message
            isReady = false
            frameStepAvailable = false
        }
    }

    private func observeApplication() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.isInBackground = true
                self.idleGrace?.cancel()
                self.idleGrace = nil
                self.pause()
                self.updateAutoLock()
                self.engine.suspendVideo(true)
            }
        })
        notificationTokens.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.isInBackground = false
                self.engine.suspendVideo(false)
            }
        })
        notificationTokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    let wasTemporarilyPlaying = self.isTemporaryFastPlayback
                    let shouldResume = !wasTemporarilyPlaying && self.isPlaying && !self.isScrubbing
                    self.isAudioInterrupted = true
                    self.pause()
                    self.resumeAfterInterruption = shouldResume
                } else if type == AVAudioSession.InterruptionType.ended.rawValue {
                    self.isAudioInterrupted = false
                    if self.resumeAfterInterruption,
                       AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
                        try? AVAudioSession.sharedInstance().setActive(true)
                        self.engine.setPaused(false)
                    }
                    self.resumeAfterInterruption = false
                }
            }
        })
        notificationTokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.pause()
            }
        })
    }
}

private func removeExpiredPrismFrames(in directory: URL) {
    DispatchQueue.global(qos: .utility).async {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
        for url in urls ?? [] {
            if let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate, created < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
