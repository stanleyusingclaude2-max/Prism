import Darwin
import Foundation
import Libmpv
import os
import PlayitCore
import QuartzCore

/// libmpv is touched only on this queue. No decoder, seek, or file IO runs on the UI thread.
final class MPVEngine {
    struct Metadata: Sendable {
        let duration: Double
        let fps: Double
        let width: Int
        let height: Int
        let displayGeometry: VideoDisplayGeometry?
        let canStepFrames: Bool
    }

    enum Event: Sendable {
        case loaded(Metadata)
        case time(Double)
        case firstFrameReady
        case duration(Double)
        case paused(Bool)
        case playbackEnded
        case buffering(Bool)
        case tracks([PlaybackTrack], [PlaybackTrack], Int?, Int?)
        case seekCommitted(UUID, Double, Bool)
        case frameExported(URL)
        case frameExportFailed(String)
        case error(String)
        case failed(String)
    }

    private typealias Seek = PlaybackSeekCoordinator.Seek

    private final class WakeupContext {
        weak var engine: MPVEngine?
        init(engine: MPVEngine) { self.engine = engine }
    }

    private let queue = DispatchQueue(label: "app.playit.mpv", qos: .userInteractive)
    private let onEvent: @Sendable (Event) -> Void
    private var handle: OpaquePointer?
    private var retainedWakeupContext: UnsafeMutableRawPointer?
    private var retainedLayer: CAMetalLayer?
    private var fileAccess: PlaybackFileAccess?
    private var loaded = false
    private var stopping = false
    /// Which seek mpv is working on, which one waits, and how slow exact seeks are.
    private var seeks = PlaybackSeekCoordinator()
    private var seekSentAt: (id: UInt64, time: TimeInterval)?
    private var scrubSession: UUID?
    private var commandID: UInt64 = 100
    private var pauseRevision: UInt64 = 0
    private var stepping = false
    private var suspendedVideoID: Int?
    private var desiredRate: Double = 1
    private var desiredLooping = false
    private var desiredSubtitleScale: Double = 1
    private var refinePreview: DispatchWorkItem?
    private var frameExports: [UInt64: URL] = [:]
    private var startupTime: TimeInterval?
    private var latestPosition = Double.nan
    private let metrics = Logger(subsystem: "com.playit.app", category: "PlaybackTiming")

    init(onEvent: @escaping @Sendable (Event) -> Void) {
        self.onEvent = onEvent
    }

    deinit { shutdown() }

    /// - Parameter startPosition: a remembered position. mpv's `start` option seeks
    ///   before the first frame is shown, so a resumed video never flashes frame 0.
    ///   Looping still returns to the file's real start.
    func start(url: URL, layer: CAMetalLayer, fileAccess: PlaybackFileAccess? = nil, startPosition: Double? = nil) {
        queue.async { [self] in
            guard handle == nil, !stopping else { return }
            retainedLayer = layer
            self.fileAccess = fileAccess
            startupTime = ProcessInfo.processInfo.systemUptime
            guard let context = mpv_create() else {
                onEvent(.failed("无法创建视频解码器。"))
                return
            }
            handle = context
            do {
                // The official MPVKit moltenvk patch bridges wid to a CAMetalLayer pointer.
                var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
                try check(mpv_set_option(context, "wid", MPV_FORMAT_INT64, &wid))
                for (name, value) in [
                    ("vo", "gpu-next"), ("gpu-api", "vulkan"), ("gpu-context", "moltenvk"),
                    ("hwdec", "videotoolbox,videotoolbox-copy"), ("config", "no"), ("terminal", "no"),
                    ("keep-open", "yes"), ("keep-open-pause", "yes"), ("pause", "no"),
                    ("hr-seek", "always"), ("input-default-bindings", "no"),
                    ("keepaspect", "yes"), ("panscan", "0"), ("video-zoom", "0"),
                    ("video-align-x", "0"), ("video-align-y", "0"), ("sub-use-margins", "no"),
                    ("sub-scale-with-window", "no"),
                    ("input-vo-keyboard", "no"), ("load-scripts", "no"),
                    ("subs-match-os-language", "yes"), ("subs-fallback", "yes"),
                    ("access-references", "no"), ("target-prim", "bt.709"), ("target-trc", "srgb"),
                    ("tone-mapping", "bt.2390"), ("screenshot-png-compression", "3")
                ] {
                    try check(mpv_set_option_string(context, name, value))
                }
                if let startPosition, startPosition.isFinite, startPosition > 0 {
                    // Optional: a rejected value simply starts at the beginning.
                    let value = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), startPosition)
                    _ = mpv_set_option_string(context, "start", value)
                }
                try check(mpv_initialize(context))
                setDouble("speed", desiredRate)
                setString("loop-file", desiredLooping ? "inf" : "no")
                setDouble("sub-scale", desiredSubtitleScale)
                mpv_request_log_messages(context, "error")
                let observations: [(String, mpv_format)] = [
                    ("time-pos", MPV_FORMAT_DOUBLE), ("duration", MPV_FORMAT_DOUBLE),
                    ("pause", MPV_FORMAT_FLAG), ("paused-for-cache", MPV_FORMAT_FLAG),
                    ("eof-reached", MPV_FORMAT_FLAG), ("track-list", MPV_FORMAT_NONE),
                    ("dwidth", MPV_FORMAT_INT64), ("dheight", MPV_FORMAT_INT64),
                    ("video-out-params/rotate", MPV_FORMAT_INT64),
                    ("video-params/rotate", MPV_FORMAT_INT64),
                    ("aid", MPV_FORMAT_NONE), ("sid", MPV_FORMAT_NONE)
                ]
                for (index, observation) in observations.enumerated() {
                    mpv_observe_property(context, UInt64(index + 1), observation.0, observation.1)
                }
                let callbackContext = Unmanaged.passRetained(WakeupContext(engine: self)).toOpaque()
                retainedWakeupContext = callbackContext
                mpv_set_wakeup_callback(context, { raw in
                    guard let raw else { return }
                    let context = Unmanaged<WakeupContext>.fromOpaque(raw).takeUnretainedValue()
                    context.engine?.scheduleEventDrain()
                }, callbackContext)
                let result = command(["loadfile", url.path, "replace"])
                if result < 0 { throw MPVFailure(code: result) }
                drainEvents()
            } catch {
                onEvent(.failed("无法初始化播放：\(error.localizedDescription)"))
                shutdown()
            }
        }
    }

    func setPaused(_ paused: Bool) {
        queue.async { [self] in
            if paused { pauseRevision &+= 1 }
            stepping = false
            seeks.pictureMoved()
            if !paused, flag("eof-reached") {
                command(["seek", "0", "absolute+exact"])
            }
            setFlag("pause", paused)
        }
    }

    func beginScrubbing(session: UUID) {
        queue.async { [self] in
            cancelPreviewRefinement()
            scrubSession = session
            // A seek mpv is already working on stays; its completion is drained.
            seeks.dropWaiting()
            seeks.pictureMoved()
            stepping = false
            setFlag("pause", true)
        }
    }

    func cancelScrubbing() {
        queue.async { [self] in
            cancelPreviewRefinement()
            scrubSession = nil
            seeks.dropWaiting()
            // Drain any command already sent to mpv before issuing a newer one.
        }
    }

    func seek(to target: Double, session: UUID, commit: Bool, resume: Bool, precisePreview: Bool = true) {
        queue.async { [self] in
            guard loaded, target.isFinite, session == scrubSession, !stopping else { return }
            cancelPreviewRefinement()
            if commit {
                submit(makeSeek(target: target, session: session, exact: true, commit: true, resume: resume))
                return
            }
            // Files whose exact frames decode slowly (long GOPs, usually long
            // videos) preview with keyframes; the rest keep exact previews.
            switch PlaybackSeekPolicy.preview(precise: precisePreview, exactSeeksAreSlow: seeks.exactSeeksAreSlow,
                                              target: target, renderedTime: latestPosition) {
            case .exact:
                submit(makeSeek(target: target, session: session, exact: true))
            case .keyframe:
                submit(makeSeek(target: target, session: session, exact: false))
                scheduleRefinement(target: target, session: session)
            case .waitForRest:
                seeks.dropWaitingPreview()
                scheduleRefinement(target: target, session: session)
            }
        }
    }

    /// Once the pointer rests, the preview becomes the exact frame.
    private func scheduleRefinement(target: Double, session: UUID) {
        let refine = DispatchWorkItem { [weak self] in
            guard let self, self.scrubSession == session else { return }
            self.refinePreview = nil
            self.submit(self.makeSeek(target: target, session: session, exact: true))
        }
        refinePreview = refine
        queue.asyncAfter(deadline: .now() + PlaybackSeekPolicy.refinementDelay, execute: refine)
    }

    private func makeSeek(target: Double, session: UUID, exact: Bool, commit: Bool = false, resume: Bool = false) -> Seek {
        commandID &+= 1
        return Seek(id: commandID, target: max(0, target), session: session, exact: exact,
                    commit: commit, resume: resume, pauseRevision: pauseRevision)
    }

    private func cancelPreviewRefinement() {
        refinePreview?.cancel()
        refinePreview = nil
    }

    private func submit(_ seek: Seek) {
        let previous = seeks.running
        let action = seeks.submit(seek, now: ProcessInfo.processInfo.systemUptime)
        if case .send? = action, let previous, let sent = seekSentAt, sent.id == previous.id {
            let elapsed = (ProcessInfo.processInfo.systemUptime - sent.time) * 1_000
            metrics.debug("Replaced an exact seek still decoding after \(elapsed, format: .fixed(precision: 0)) ms")
        }
        perform(action)
    }

    private func perform(_ action: PlaybackSeekCoordinator.Action?) {
        switch action {
        case .send(let seek)?: send(seek)
        case .finish(let commit)?:
            metrics.debug("Commit reused the exact frame on screen")
            finishCommit(commit)
        case nil: break
        }
    }

    func stepFrame(_ direction: Int) {
        queue.async { [self] in
            guard loaded, seeks.running == nil, !stopping else { return }
            pauseRevision &+= 1
            stepping = true
            seeks.pictureMoved()
            setFlag("pause", true)
            // These commands use decoded video frames / real presentation timestamps,
            // including VFR. There is deliberately no seconds-per-frame approximation.
            let result = command(direction < 0 ? ["frame-back-step"] : ["frame-step"])
            if result < 0 {
                stepping = false
                onEvent(.error("此文件暂时无法逐帧定位：\(errorDescription(result))"))
            }
        }
    }

    func setRate(_ rate: Double) {
        queue.async { [self] in
            desiredRate = rate
            setDouble("speed", rate)
        }
    }

    func setLooping(_ looping: Bool) {
        queue.async { [self] in
            if looping { configureABLoop(start: nil, end: nil) }
            desiredLooping = looping
            setString("loop-file", looping ? "inf" : "no")
        }
    }

    func setABLoop(start: Double?, end: Double?) {
        queue.async { [self] in configureABLoop(start: start, end: end) }
    }

    /// Scales text subtitles (and ASS, through mpv's default `sub-ass-override=scale`).
    func setSubtitleScale(_ scale: Double) {
        queue.async { [self] in
            guard scale.isFinite, scale > 0 else { return }
            desiredSubtitleScale = scale
            setDouble("sub-scale", scale)
        }
    }

    private func configureABLoop(start: Double?, end: Double?) {
        setString("ab-loop-b", "no")
        guard let start, let end, start.isFinite, end.isFinite, start >= 0, end > start else {
            setString("ab-loop-a", "no")
            return
        }
        desiredLooping = false
        setString("loop-file", "no")
        setDouble("ab-loop-a", start)
        setDouble("ab-loop-b", end)
    }

    func exportCurrentFrame(to url: URL) {
        queue.async { [self] in
            guard loaded, !stopping, frameExports.isEmpty else {
                onEvent(.frameExportFailed("当前画面暂时无法保存，请稍后再试。"))
                return
            }
            commandID &+= 1
            let id = commandID
            frameExports[id] = url
            if command(["screenshot-to-file", url.path, "video"], userData: id) < 0 {
                finishFrameExport(id: id, succeeded: false)
            }
        }
    }

    private func finishFrameExport(id: UInt64, succeeded: Bool) {
        guard let url = frameExports.removeValue(forKey: id) else { return }
        let length = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if succeeded, length > 0 { onEvent(.frameExported(url)) }
        else {
            try? FileManager.default.removeItem(at: url)
            onEvent(.frameExportFailed("保存当前帧失败。请先暂停在有画面的位置后重试。"))
        }
    }

    func selectAudioTrack(_ id: Int) {
        queue.async { [self] in setString("aid", String(id)) }
    }

    func selectSubtitleTrack(_ id: Int?) {
        queue.async { [self] in setString("sid", id.map(String.init) ?? "no") }
    }

    func addSubtitle(_ url: URL) {
        queue.async { [self] in
            let result = command(["sub-add", url.path, "select"])
            if result < 0 { onEvent(.error("无法加载字幕：\(errorDescription(result))")) }
        }
    }

    func suspendVideo(_ suspended: Bool) {
        queue.async { [self] in
            if suspended {
                suspendedVideoID = integer("vid").map(Int.init)
                setString("vid", "no")
            } else {
                setString("vid", suspendedVideoID.map(String.init) ?? "auto")
            }
        }
    }

    func stop(onStopped: (@MainActor @Sendable () -> Void)? = nil) {
        queue.async { [self] in
            stopping = true
            shutdown()
            if let onStopped { DispatchQueue.main.async { onStopped() } }
        }
    }

    /// Sending a seek while mpv still decodes an older one makes mpv abandon
    /// the older one; the coordinator only does that for a slow exact preview.
    private func send(_ seek: Seek) {
        guard handle != nil else {
            seeks.reset()
            return
        }
        seekSentAt = (seek.id, ProcessInfo.processInfo.systemUptime)
        let target = String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), seek.target)
        let result = command(["seek", target, seek.exact ? "absolute+exact" : "absolute+keyframes"], userData: seek.id)
        if result < 0 {
            failSeek("无法定位到所选画面：\(errorDescription(result))")
            return
        }
        // A stalled decoder must not leave the UI permanently stuck in a dragging state.
        // This is a failure deadline, not an artificial preview throttle.
        queue.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.seeks.running?.id == seek.id else { return }
            self.failRunningSeek("此位置解码耗时较长，请稍后重试或选择附近画面。")
        }
    }

    private func finishSeek() {
        let now = ProcessInfo.processInfo.systemUptime
        let result = seeks.playbackRestarted(now: now)
        guard let finished = result.finished else { return }
        if let sent = seekSentAt, sent.id == finished.id {
            let elapsed = (now - sent.time) * 1_000
            metrics.debug("Seek frame ready in \(elapsed, format: .fixed(precision: 0)) ms. Exact: \(finished.exact)")
        }
        if let next = result.next {
            // A newer target was waiting; it supersedes the finished seek.
            perform(next)
            return
        }
        if finished.commit { finishCommit(finished) }
    }

    private func finishCommit(_ commit: Seek) {
        guard commit.session == scrubSession else { return }
        let position = double("time-pos") ?? commit.target
        let resume = commit.resume && commit.pauseRevision == pauseRevision
        scrubSession = nil
        setFlag("pause", !resume)
        if resume { seeks.pictureMoved() }
        onEvent(.seekCommitted(commit.session, position, resume))
    }

    private func failRunningSeek(_ message: String) {
        guard let running = seeks.running else { return }
        if running.session != scrubSession || (!running.commit && seeks.waiting != nil) {
            perform(seeks.abandonRunning(now: ProcessInfo.processInfo.systemUptime))
        } else {
            failSeek(message)
        }
    }

    private func failSeek(_ message: String) {
        cancelPreviewRefinement()
        seeks.reset()
        scrubSession = nil
        setFlag("pause", true)
        onEvent(.error(message))
    }

    private func scheduleEventDrain() {
        queue.async { [weak self] in self?.drainEvents() }
    }

    private func drainEvents() {
        guard let context = handle else { return }
        while let pointer = mpv_wait_event(context, 0) {
            let event = pointer.pointee
            if event.event_id == MPV_EVENT_NONE { break }
            // All event memory is copied or consumed before the next mpv_wait_event.
            switch event.event_id {
            case MPV_EVENT_FILE_LOADED:
                loaded = true
                publishMetadata()
                publishTracks()
                onEvent(.paused(flag("pause")))
            case MPV_EVENT_VIDEO_RECONFIG:
                // FILE_LOADED may precede initial decoder/output configuration.
                // Refresh real dimensions and frame-step availability once it is ready.
                if loaded { publishMetadata() }
            case MPV_EVENT_PROPERTY_CHANGE:
                guard let raw = event.data else { continue }
                let property = raw.assumingMemoryBound(to: mpv_event_property.self).pointee
                guard let namePointer = property.name else { continue }
                let name = String(cString: namePointer)
                switch name {
                case "time-pos":
                    if property.format == MPV_FORMAT_DOUBLE, let data = property.data {
                        let value = data.assumingMemoryBound(to: Double.self).pointee
                        if value.isFinite {
                            latestPosition = max(0, value)
                            onEvent(.time(latestPosition))
                        }
                    }
                case "duration":
                    if property.format == MPV_FORMAT_DOUBLE, let data = property.data {
                        let value = data.assumingMemoryBound(to: Double.self).pointee
                        if value.isFinite { onEvent(.duration(max(0, value))) }
                    }
                case "pause":
                    if property.format == MPV_FORMAT_FLAG, let data = property.data {
                        let paused = data.assumingMemoryBound(to: CInt.self).pointee != 0
                        if paused { stepping = false }
                        onEvent(.paused(paused || stepping))
                    }
                case "paused-for-cache":
                    if property.format == MPV_FORMAT_FLAG, let data = property.data {
                        onEvent(.buffering(data.assumingMemoryBound(to: CInt.self).pointee != 0))
                    }
                case "eof-reached":
                    if property.format == MPV_FORMAT_FLAG, let data = property.data,
                       data.assumingMemoryBound(to: CInt.self).pointee != 0 {
                        // Looping naturally crosses EOF; only a real final stop ends a hold.
                        if !desiredLooping { onEvent(.playbackEnded) }
                    }
                case "track-list", "aid", "sid": publishTracks()
                case "dwidth", "dheight", "video-out-params/rotate", "video-params/rotate":
                    if loaded { publishMetadata() }
                default: break
                }
            case MPV_EVENT_SEEK:
                // Counts only after mpv accepted the running seek's command.
                seeks.seekStarted()
            case MPV_EVENT_PLAYBACK_RESTART:
                if let startupTime {
                    let elapsed = (ProcessInfo.processInfo.systemUptime - startupTime) * 1_000
                    metrics.debug("Initial frame ready in \(elapsed, format: .fixed(precision: 0)) ms")
                    self.startupTime = nil
                    onEvent(.firstFrameReady)
                }
                finishSeek()
                if let position = double("time-pos"), position.isFinite {
                    latestPosition = max(0, position)
                    onEvent(.time(latestPosition))
                }
            case MPV_EVENT_COMMAND_REPLY:
                let id = event.reply_userdata
                if frameExports[id] != nil {
                    finishFrameExport(id: id, succeeded: event.error >= 0)
                } else if event.error >= 0 {
                    // mpv has queued this seek; its own seek event follows.
                    _ = seeks.replied(id: id)
                } else if seeks.running?.id == id {
                    failRunningSeek("定位失败：\(errorDescription(event.error))")
                } else if !seeks.isReplaced(id: id) {
                    onEvent(.error("播放操作失败：\(errorDescription(event.error))"))
                }
            case MPV_EVENT_END_FILE:
                if let raw = event.data {
                    let ended = raw.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                    if ended.error < 0 {
                        loaded = false
                        onEvent(.failed("无法播放此文件，文件可能损坏或编码暂不受支持：\(errorDescription(ended.error))"))
                    }
                }
            case MPV_EVENT_SHUTDOWN:
                loaded = false
                return
            default: break
            }
        }
    }

    private func publishMetadata() {
        // dwidth/dheight alias the post-filter dw/dh values. They include aspect
        // correction, but mpv still carries a separate remaining rotation.
        let geometry = VideoDisplayGeometry.resolve(
            outputWidth: integer("dwidth").map(Double.init) ?? integer("video-out-params/dw").map(Double.init),
            outputHeight: integer("dheight").map(Double.init) ?? integer("video-out-params/dh").map(Double.init),
            outputRotation: integer("video-out-params/rotate").map(Double.init),
            sourceWidth: integer("video-params/dw").map(Double.init) ?? integer("video-params/w").map(Double.init),
            sourceHeight: integer("video-params/dh").map(Double.init) ?? integer("video-params/h").map(Double.init),
            sourceRotation: integer("video-params/rotate").map(Double.init),
            sourceDisplayAspect: double("video-params/aspect")
        )
        onEvent(.loaded(Metadata(duration: max(0, double("duration") ?? 0),
                                 fps: double("container-fps") ?? 0,
                                 width: Int(integer("video-params/w") ?? 0),
                                 height: Int(integer("video-params/h") ?? 0),
                                 displayGeometry: geometry,
                                 canStepFrames: flag("seekable") && (integer("vid") ?? 0) > 0)))
    }

    private func publishTracks() {
        let count = min(Int(integer("track-list/count") ?? 0), 256)
        var audio: [PlaybackTrack] = []
        var subtitles: [PlaybackTrack] = []
        if count > 0 {
            for index in 0..<count {
                let prefix = "track-list/\(index)/"
                guard let id = integer(prefix + "id"), let type = string(prefix + "type") else { continue }
                guard type == "audio" || type == "sub" else { continue }
                let name = string(prefix + "title") ?? (type == "audio" ? "音轨 \(audio.count + 1)" : "字幕 \(subtitles.count + 1)")
                let track = PlaybackTrack(id: Int(id), name: name, language: string(prefix + "lang"), codec: string(prefix + "codec"))
                if type == "audio" { audio.append(track) } else { subtitles.append(track) }
            }
        }
        onEvent(.tracks(audio, subtitles, integer("aid").map(Int.init), integer("sid").map(Int.init)))
    }

    @discardableResult
    private func command(_ arguments: [String], userData: UInt64 = 0) -> Int32 {
        guard let handle else { return -1 }
        return sendMPVCommand(handle, arguments, id: userData)
    }

    private func setFlag(_ name: String, _ value: Bool) {
        guard let handle else { return }
        var raw: CInt = value ? 1 : 0
        mpv_set_property(handle, name, MPV_FORMAT_FLAG, &raw)
    }

    private func setDouble(_ name: String, _ value: Double) {
        guard let handle else { return }
        var raw = value
        mpv_set_property(handle, name, MPV_FORMAT_DOUBLE, &raw)
    }

    private func setString(_ name: String, _ value: String) {
        guard let handle else { return }
        mpv_set_property_string(handle, name, value)
    }

    private func double(_ name: String) -> Double? {
        guard let handle else { return nil }
        var raw: Double = 0
        return mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &raw) >= 0 ? raw : nil
    }

    private func integer(_ name: String) -> Int64? {
        guard let handle else { return nil }
        var raw: Int64 = 0
        return mpv_get_property(handle, name, MPV_FORMAT_INT64, &raw) >= 0 ? raw : nil
    }

    private func flag(_ name: String) -> Bool {
        guard let handle else { return false }
        var raw: CInt = 0
        return mpv_get_property(handle, name, MPV_FORMAT_FLAG, &raw) >= 0 && raw != 0
    }

    private func string(_ name: String) -> String? {
        guard let handle, let pointer = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(pointer) }
        return String(cString: pointer)
    }

    private func check(_ code: Int32) throws {
        if code < 0 { throw MPVFailure(code: code) }
    }

    private func errorDescription(_ code: Int32) -> String {
        String(cString: mpv_error_string(code))
    }

    private func shutdown() {
        cancelPreviewRefinement()
        loaded = false
        seeks.reset()
        scrubSession = nil
        if let handle {
            mpv_set_wakeup_callback(handle, nil, nil)
            mpv_terminate_destroy(handle)
            self.handle = nil
        }
        if let pointer = retainedWakeupContext {
            Unmanaged<WakeupContext>.fromOpaque(pointer).release()
            retainedWakeupContext = nil
        }
        retainedLayer = nil
        fileAccess = nil
        for url in frameExports.values { try? FileManager.default.removeItem(at: url) }
        frameExports.removeAll()
    }
}

@discardableResult
func sendMPVCommand(_ player: OpaquePointer, _ arguments: [String], id: UInt64) -> Int32 {
    let owned = arguments.map { strdup($0) }
    defer { owned.forEach { free($0) } }
    guard owned.allSatisfy({ $0 != nil }) else { return -2 } // MPV_ERROR_NOMEM
    var pointers = owned.map { $0.map { UnsafePointer<CChar>($0) } }
    pointers.append(nil)
    return pointers.withUnsafeMutableBufferPointer { mpv_command_async(player, id, $0.baseAddress) }
}

private struct MPVFailure: LocalizedError {
    let code: Int32
    var errorDescription: String? { String(cString: mpv_error_string(code)) }
}
