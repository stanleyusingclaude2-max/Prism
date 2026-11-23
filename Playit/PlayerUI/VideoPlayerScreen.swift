import SwiftUI
import UIKit
import UniformTypeIdentifiers
import PlayitCore

/// What happens when a video reaches its end. Kept as a preference across videos.
enum PlaybackEndAction: String, CaseIterable, Identifiable {
    case stop, loop, next

    var id: String { rawValue }
    var title: String {
        switch self {
        case .stop: return "停在末尾"
        case .loop: return "单条循环"
        case .next: return "播放下一个"
        }
    }
}

/// Subtitle size choices; the value multiplies mpv's default text size.
enum SubtitleSize: CaseIterable, Identifiable {
    case small, standard, large, extraLarge

    var id: Double { scale }
    var scale: Double {
        switch self {
        case .small: return 0.8
        case .standard: return 1
        case .large: return 1.3
        case .extraLarge: return 1.6
        }
    }
    var title: String {
        switch self {
        case .small: return "小"
        case .standard: return "标准"
        case .large: return "大"
        case .extraLarge: return "特大"
        }
    }
}

@MainActor
struct VideoPlayerScreen: View {
    let entry: PlaybackEntry
    let entries: [PlaybackEntry]
    let index: Int
    let onFullscreenChange: (Bool) -> Void
    let onAutoLockChange: (Bool) -> Void
    let onSelect: (Int) -> Void
    let onSaveExternal: () async throws -> Void
    let onMetadata: (Double, Int, Int) -> Void
    let onPlaybackPosition: (Double, Double) -> Void
    private var item: MediaItem { entry.item }
    @StateObject private var controller: PlaybackController
    @Binding private var orientationSession: UUID?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("player.endAction") private var endAction: PlaybackEndAction = .stop
    @AppStorage("player.subtitleScale") private var subtitleScale: Double = 1
    @State private var chrome = PlaybackChromeState(autoHideDelay: 3)
    @State private var autoHideTask: Task<Void, Never>?
    @State private var timerGeneration: UInt64 = 0
    @State private var showsOptions = false
    @State private var showsSubtitleImporter = false
    @State private var pendingSubtitleImport = false
    @State private var showsGestureGuide = false
    @State private var pendingGestureGuide = false
    @State private var pendingABEditor = false
    @State private var pendingVideoSelection: Int?
    @State private var isSwitchingVideo = false
    @State private var waitsForOptionsDismissal = false
    @State private var framePresentation: FramePresentation?
    @State private var externalSaveState: ExternalSaveState = .available
    @State private var loadFailure: String?
    @State private var isFullscreen = false
    @State private var interfaceIsLandscape = false
    @State private var showsABEditor = false
    @State private var showsRatePicker = false
    @State private var showsLoadingIndicator = false
    @State private var showsResumeNotice = false
    @State private var resumeNoticeTask: Task<Void, Never>?
    @State private var notice: String?
    @State private var noticeTask: Task<Void, Never>?
    @State private var showsUnlockButton = true
    @State private var unlockButtonTask: Task<Void, Never>?

    private static let rates: [Float] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2]

    init(entry: PlaybackEntry, entries: [PlaybackEntry], index: Int, startsFullscreen: Bool,
         resumePosition: Double?, orientationSession: Binding<UUID?>,
         onFullscreenChange: @escaping (Bool) -> Void, onAutoLockChange: @escaping (Bool) -> Void,
         onSelect: @escaping (Int) -> Void, onSaveExternal: @escaping () async throws -> Void,
         onMetadata: @escaping (Double, Int, Int) -> Void,
         onPlaybackPosition: @escaping (Double, Double) -> Void) {
        self.entry = entry
        self.entries = entries
        self.index = index
        self.onFullscreenChange = onFullscreenChange
        self.onAutoLockChange = onAutoLockChange
        self.onSelect = onSelect
        self.onSaveExternal = onSaveExternal
        self.onMetadata = onMetadata
        self.onPlaybackPosition = onPlaybackPosition
        _orientationSession = orientationSession
        _isFullscreen = State(initialValue: startsFullscreen)
        let pixels = [entry.item.pixelWidth ?? 0, entry.item.pixelHeight ?? 0].max() ?? 0
        _controller = StateObject(wrappedValue: PlaybackController(
            url: entry.url, fileAccess: entry.fileAccess, resumePosition: resumePosition,
            sourceLongSide: pixels > 0 ? Double(pixels) : nil))
    }

    private var playerLayout: some View {
        NavigationStack {
            GeometryReader { geometry in
                let safeArea = effectiveSafeArea(geometry.safeAreaInsets)
                let landscape = geometry.size.width > geometry.size.height
                videoViewport(safeArea: safeArea, isLandscapeInterface: landscape)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
                    .onChange(of: landscape, initial: true) { _, value in
                        interfaceIsLandscape = value
                        applySubtitleScale()
                    }
            }
            .background(.black)
            // The video always uses the whole screen; only the controls respect
            // the safe area, so showing or hiding them never moves the picture.
            .ignoresSafeArea(.container, edges: .all)
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(Theme.accent)
        .font(AppTypography.body)
        .preferredColorScheme(.dark)
        .statusBarHidden(interfaceIsLandscape || controller.isLocked || !controlsAreVisible)
        .persistentSystemOverlays(controlsAreVisible ? .automatic : .hidden)
    }

    // Split into short modifier chains: each opaque property is a separate
    // type-checking boundary for the compiler.
    private var playerWithTasks: some View {
        playerLayout
        .task { await controller.load() }
        .task(id: needsLoadingIndicator) {
            guard needsLoadingIndicator else {
                showsLoadingIndicator = false
                return
            }
            // Local files usually open within a few hundred milliseconds; an
            // immediate spinner would only flash.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            showsLoadingIndicator = true
        }
        .onAppear {
            controller.recordUserInteraction()
            if entries.count > 1 {
                controller.onRemoteTrackChange = { direction in selectVideo(index + direction) }
            }
            refreshChrome(reveal: true)
        }
        .onChange(of: chromeContext, initial: true) { _, _ in refreshChrome() }
        .onChange(of: controlsAreVisible, initial: true) { _, visible in controller.clockIsLive = visible }
        .onChange(of: controller.preventsAutoLock, initial: true) { _, active in onAutoLockChange(active) }
    }

    private var playerWithLifecycle: some View {
        playerWithTasks
        .onChange(of: controller.isReady) { _, ready in
            guard ready else { return }
            loadFailure = nil
            reportMetadata()
            applyEndAction()
            applySubtitleScale()
            presentResumeNoticeIfNeeded()
        }
        .onChange(of: controller.displayGeometry) { _, geometry in
            reportMetadata()
            applySubtitleScale()
            if isFullscreen, geometry?.fullscreenOrientation == .portrait {
                // Landscape mode carries over only between landscape videos.
                exitFullscreen()
            } else {
                synchronizeFullscreenOrientation()
            }
        }
        .onChange(of: controller.duration) { _, duration in
            if controller.isReady && duration > 0 { reportMetadata() }
        }
        .onChange(of: controller.isLocked) { _, locked in
            if locked {
                showsABEditor = false
                showsRatePicker = false
                revealUnlockButton()
            } else {
                refreshChrome(reveal: true)
            }
        }
        .onChange(of: controller.playbackEndCount) { _, _ in handlePlaybackEnded() }
        .onChange(of: controller.loopEnd) { _, end in
            // Clearing an A–B interval returns to the chosen end-of-video behavior.
            if end == nil { applyEndAction() }
        }
        .onChange(of: endAction) { _, _ in applyEndAction() }
        .onChange(of: subtitleScale) { _, _ in applySubtitleScale() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { savePlaybackPosition() }
            if phase == .active { refreshChrome(reveal: true) }
        }
        .onChange(of: controller.errorMessage) { _, error in
            if let error, !controller.isReady { loadFailure = error }
        }
        .onDisappear {
            cancelAutoHide()
            if isSwitchingVideo {
                // The next video takes over; a landscape session stays with it.
                isSwitchingVideo = false
                return
            }
            // A document picker may cover the player temporarily.
            guard !isPresentingOptions else { return }
            savePlaybackPosition()
            restoreOrientation()
            controller.stop()
            onAutoLockChange(false)
        }
    }

    var body: some View {
        playerWithLifecycle
        .sheet(isPresented: $showsOptions, onDismiss: optionsDidDismiss) {
            PlaybackOptionsSheet(controller: controller, entry: entry, entries: entries, index: index,
                                 endAction: $endAction, subtitleScale: $subtitleScale,
                                 externalSaveState: externalSaveState,
                                 onSaveExternal: saveExternalVideo,
                                 onSelect: { next in
                                     pendingVideoSelection = next
                                     showsOptions = false
                                 },
                                 onCapture: {
                                     waitsForOptionsDismissal = true
                                     controller.captureCurrentFrame()
                                     showsOptions = false
                                 },
                                 onEditABLoop: {
                                     pendingABEditor = true
                                     showsOptions = false
                                 },
                                 onImportSubtitle: {
                                     pendingSubtitleImport = true
                                     showsOptions = false
                                 },
                                 onLock: {
                                     controller.isLocked = true
                                     showNotice("已锁定触控 · 轻点屏幕显示解锁")
                                     showsOptions = false
                                 },
                                 onShowGestureGuide: {
                                     pendingGestureGuide = true
                                     showsOptions = false
                                 })
        }
        .sheet(isPresented: $showsGestureGuide, onDismiss: { refreshChrome(reveal: true) }) {
            PlaybackGestureGuide()
        }
        .sheet(item: $framePresentation, onDismiss: {
            controller.exportedFrameURL = nil
            controller.recordUserInteraction()
            refreshChrome(reveal: true)
        }) { frame in
            FrameExportSheet(url: frame.url)
        }
        .onChange(of: controller.exportedFrameURL) { _, _ in showExportedFrame() }
        .fileImporter(isPresented: $showsSubtitleImporter,
                      allowedContentTypes: subtitleTypes,
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { controller.loadExternalSubtitle(url) }
            case .failure(let error): controller.errorMessage = error.localizedDescription
            }
            refreshChrome(reveal: true)
        }
        .alert("无法完成播放操作", isPresented: Binding(get: { controller.errorMessage != nil }, set: { if !$0 { controller.errorMessage = nil } })) {
            Button("关闭播放器", action: closePlayer)
            Button("知道了", role: .cancel) { controller.errorMessage = nil }
        } message: { Text(controller.errorMessage ?? "") }
        .accessibilityAction(named: Text("显示播放控件")) { refreshChrome(reveal: true) }
        .accessibilityAction(.escape) {
            if isFullscreen { exitFullscreen() } else { closePlayer() }
        }
    }

    private var controlsAreVisible: Bool { chrome.isVisible && !controller.isLocked }
    private var isPresentingOptions: Bool {
        showsOptions || showsSubtitleImporter || pendingSubtitleImport || showsGestureGuide || pendingGestureGuide ||
            pendingABEditor || waitsForOptionsDismissal || framePresentation != nil || pendingVideoSelection != nil ||
            isSwitchingVideo
    }
    private var needsLoadingIndicator: Bool {
        loadFailure == nil && (!controller.isReady || controller.isExportingFrame)
    }
    private var chromeContext: PlaybackChromeState.Context {
        .init(isReady: controller.isReady,
              isPlaying: controller.isPlaying,
              isScrubbing: controller.isScrubbing,
              isLocked: controller.isLocked,
              isTemporaryFastPlayback: controller.isTemporaryFastPlayback,
              isSceneActive: scenePhase == .active,
              isVoiceOverRunning: voiceOverEnabled,
              // Inline editors keep the controls up until they are closed.
              isPresentingOptions: isPresentingOptions || showsABEditor || showsRatePicker,
              hasError: controller.errorMessage != nil || loadFailure != nil)
    }

    // MARK: Layout

    private func videoViewport(safeArea: EdgeInsets, isLandscapeInterface: Bool) -> some View {
        ZStack {
            // The decoder surface stays mounted and keeps the same layout while controls fade.
            PlaybackSurface(controller: controller, onTap: toggleControls, onSwipe: handleSwipe,
                            allowsVideoSwitching: entries.count > 1)
                .accessibilityIdentifier("player.video")
                .accessibilityValue((isFullscreen ? "横屏" : "常规") + "，" +
                                    (controller.isVideoZoomed ? "已放大" : "完整画面"))
            playbackChrome(safeArea: safeArea, isLandscapeInterface: isLandscapeInterface)
                .opacity(controlsAreVisible ? 1 : 0)
                .allowsHitTesting(controlsAreVisible)
                .accessibilityHidden(!controlsAreVisible)
                .accessibilityIdentifier("player.controls")
            statusPills(safeArea: safeArea)
            if controller.isScreenSeeking {
                ScreenSeekPreview(clock: controller.clock, delta: controller.screenSeekDelta)
            }
            if controller.isLocked { lockOverlay(safeArea: safeArea) }
            if let loadFailure {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(AppTypography.title2)
                    Text("无法打开视频").font(AppTypography.headline)
                    Text(loadFailure).font(AppTypography.caption).multilineTextAlignment(.center)
                    Button("返回媒体库", action: closePlayer).buttonStyle(.borderedProminent)
                }
                .padding(24).background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
                .padding(24)
            } else if showsLoadingIndicator {
                ProgressView(isSwitchingVideo ? "正在切换视频…" : controller.isExportingFrame ? "正在保存当前帧…" : "正在打开视频…")
                    .tint(Theme.accent)
                    .padding(16).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                    .allowsHitTesting(false)
            }
        }
        .foregroundStyle(Theme.text)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(isFullscreen ? "player.fullscreen" : "player.viewport")
    }

    private func playbackChrome(safeArea: EdgeInsets, isLandscapeInterface: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: closePlayer) { DesignIcon(name: "IconBack") }
                    .buttonStyle(ChromeIconButtonStyle())
                    .accessibilityLabel("返回媒体库")
                    .accessibilityIdentifier("player.close")
                Text(item.displayTitle)
                    .font(AppTypography.subheadline).lineLimit(1).truncationMode(.middle)
                    .shadow(color: .black.opacity(0.7), radius: 3)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("player.filename")
                Spacer(minLength: 8)
                Button {
                    refreshChrome(reveal: true)
                    showsRatePicker = false
                    showsOptions = true
                } label: { DesignIcon(name: "IconMore") }
                    .buttonStyle(ChromeIconButtonStyle())
                    .accessibilityLabel("更多")
                    .accessibilityIdentifier("player.options")
            }
            .padding(.top, max(8, safeArea.top))
            .padding(.horizontal, max(12, max(safeArea.leading, safeArea.trailing)))
            .padding(.bottom, 18)
            .background {
                LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
            }
            Spacer(minLength: 16)
            VStack(spacing: 0) {
                if showsABEditor {
                    abEditor.padding(.bottom, 12)
                }
                if showsRatePicker {
                    ratePicker.padding(.bottom, 12)
                }
                PlaybackTimeRow(clock: controller.clock, duration: controller.duration,
                                showsMilliseconds: !controller.isPlaying || controller.isScrubbing,
                                highlighted: controller.isScrubbing,
                                onCapture: showsQuickCapture ? controller.captureCurrentFrame : nil)
                timeline
                transportRow(isLandscapeInterface: isLandscapeInterface)
            }
            .padding(.horizontal, max(16, max(safeArea.leading, safeArea.trailing)))
            .padding(.top, 22)
            .padding(.bottom, max(12, safeArea.bottom))
            .background {
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
            }
        }
    }

    private var showsQuickCapture: Bool {
        !controller.isPlaying && controller.canExportFrame && !controller.isScreenSeeking &&
            !showsABEditor && !showsRatePicker && !isPresentingOptions
    }

    private var timeline: some View {
        PlaybackTimelineBar(clock: controller.clock, duration: controller.duration,
                            loopStart: controller.loopStart, loopEnd: controller.loopEnd,
                            enabled: controller.isReady && !controller.isLocked && controlsAreVisible &&
                                !controller.isScreenSeeking && !controller.isExportingFrame,
                            onBegin: {
                                controller.beginScrubbing()
                                refreshChrome(reveal: true)
                            }, onChange: controller.scrub(to:),
                            onCommit: { value in
                                controller.endScrubbing(at: value)
                                refreshChrome(reveal: true)
                            })
    }

    private func transportRow(isLandscapeInterface: Bool) -> some View {
        HStack(spacing: 0) {
            rateButton
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 14) {
                frameButton(-1)
                Button {
                    controller.togglePlayback()
                    refreshChrome(reveal: true)
                } label: {
                    DesignIcon(name: controller.isPlaying ? "IconPause" : "IconPlay", size: 26)
                }
                .buttonStyle(ChromeIconButtonStyle(prominent: true, diameter: 56))
                .disabled(!controller.isReady || controller.isScrubbing || controller.isExportingFrame)
                .accessibilityLabel(controller.isPlaying ? "暂停" : "播放")
                .accessibilityIdentifier("player.playPause")
                frameButton(1)
            }
            rotateButton(isLandscapeInterface: isLandscapeInterface)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.top, 2)
    }

    private var rateButton: some View {
        let rate = controller.playbackRate
        let normal = rate == 1
        return Button {
            showsABEditor = false
            withAnimation(.easeOut(duration: 0.15)) { showsRatePicker.toggle() }
            refreshChrome(reveal: true)
        } label: {
            Text(rateLabel(rate))
                .font(AppTypography.numeric(.footnote, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(minWidth: 48, minHeight: 32)
                .foregroundStyle(normal ? Theme.text : Theme.onAccent)
                .background(normal ? Color.white.opacity(0.14) : Theme.accent, in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!controller.isReady)
        .accessibilityLabel("播放速度")
        .accessibilityValue(rateLabel(rate))
        .accessibilityHint("轻点选择倍速")
        .accessibilityIdentifier("player.rate")
    }

    private var ratePicker: some View {
        HStack(spacing: 6) {
            ForEach(Self.rates, id: \.self) { rate in
                let selected = rate == controller.playbackRate
                Button {
                    Haptics.selection()
                    controller.setRate(rate)
                    withAnimation(.easeOut(duration: 0.15)) { showsRatePicker = false }
                    refreshChrome(reveal: true)
                } label: {
                    Text(rateLabel(rate))
                        .font(AppTypography.numeric(.caption, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .foregroundStyle(selected ? Theme.onAccent : Theme.text)
                        .background(selected ? Theme.accent : Color.white.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("player.rate." + rateLabel(rate))
            }
        }
    }

    private var abEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                abPointButton("A", time: controller.loopStart, enabled: controller.canMarkLoop,
                              identifier: "player.loopStart") {
                    controller.markLoopStart()
                    Haptics.light()
                }
                abPointButton("B", time: controller.loopEnd,
                              enabled: controller.canMarkLoop && controller.loopStart != nil,
                              identifier: "player.loopEnd") {
                    controller.markLoopEnd()
                    if controller.loopEnd != nil { Haptics.light() } else { Haptics.warning() }
                }
                if controller.loopStart != nil {
                    Button("清除") { controller.clearABLoop() }
                        .font(AppTypography.footnote)
                        .foregroundStyle(Theme.danger)
                        .frame(minWidth: 44, minHeight: 36)
                        .accessibilityIdentifier("player.clearABLoop")
                }
                Spacer(minLength: 0)
                Button("完成") { closeABEditor() }
                    .font(AppTypography.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(minWidth: 44, minHeight: 36)
                    .accessibilityIdentifier("player.abDone")
            }
            Text(controller.loopMessage ?? abHint)
                .font(AppTypography.caption)
                .foregroundStyle(controller.loopMessage == nil ? Theme.muted : Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.abEditor")
    }

    private var abHint: String {
        if controller.loopEnd != nil { return "正在循环这一段。可以重新设 A、B 点。" }
        if controller.loopStart != nil { return "拖动或逐帧到终点，再点 B。" }
        return "拖动或逐帧到起点，点 A。"
    }

    private func abPointButton(_ title: String, time: Double?, enabled: Bool, identifier: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(AppTypography.footnote.weight(.bold))
                Text(time.map { MediaFormatting.time($0, milliseconds: true) } ?? "设点")
                    .font(AppTypography.numeric(.caption))
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .foregroundStyle(time == nil ? Theme.text : Theme.onAccent)
            .background(time == nil ? Color.white.opacity(0.12) : Theme.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(title + " 点")
        .accessibilityValue(time.map { MediaFormatting.time($0, milliseconds: true) } ?? "未设置")
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private func rotateButton(isLandscapeInterface: Bool) -> some View {
        if isFullscreen {
            Button(action: exitFullscreen) { DesignIcon(name: "IconCollapse") }
                .buttonStyle(ChromeIconButtonStyle())
                .accessibilityLabel("退出横屏")
                .accessibilityIdentifier("player.fullscreenToggle")
        } else if controller.displayGeometry?.fullscreenOrientation == .landscape && !isLandscapeInterface
                    && horizontalSizeClass != .regular {
            // Portrait and square videos already fill a phone held upright. A wide
            // screen (iPad, an unfolded iPhone Duo) already gives landscape video
            // room, and the system may not honor a forced rotation there.
            Button(action: enterFullscreen) { DesignIcon(name: "IconRotate") }
                .buttonStyle(ChromeIconButtonStyle())
                .accessibilityLabel("横屏播放")
                .accessibilityIdentifier("player.fullscreenToggle")
        } else {
            Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
        }
    }

    private func frameButton(_ direction: Int) -> some View {
        Button {
            Haptics.selection()
            controller.stepFrame(direction)
            refreshChrome(reveal: true)
        } label: { DesignIcon(name: direction < 0 ? "IconFrameprev" : "IconFramenext") }
            .buttonStyle(ChromeIconButtonStyle())
            .buttonRepeatBehavior(.enabled)
            .disabled(!controller.frameStepAvailable || controller.isScrubbing || controller.isExportingFrame)
            .accessibilityLabel(direction < 0 ? "上一帧" : "下一帧")
            .accessibilityHint("暂停并移动一帧，长按可连续逐帧。")
            .accessibilityIdentifier(direction < 0 ? "player.previousFrame" : "player.nextFrame")
    }

    private func statusPills(safeArea: EdgeInsets) -> some View {
        VStack(spacing: 8) {
            if controller.isTemporaryFastPlayback || (controller.isScrubbing && !controller.isScreenSeeking) {
                Text(controller.isTemporaryFastPlayback ? "2× 倍速播放" : "拖动预览")
                    .font(AppTypography.caption)
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.black.opacity(0.6), in: Capsule())
                    .allowsHitTesting(false)
                    .accessibilityIdentifier(controller.isTemporaryFastPlayback ? "player.fastPlayback" : "player.scrubPreview")
            }
            if controller.isVideoZoomed && !controller.isLocked {
                Button {
                    controller.resetVideoZoom()
                    Haptics.light()
                } label: {
                    HStack(spacing: 6) {
                        DesignIcon(name: "IconCollapse", size: 15)
                        Text("还原画面").font(AppTypography.caption)
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 32)
                    .background(.black.opacity(0.6), in: Capsule())
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("还原完整画面")
                .accessibilityIdentifier("player.resetZoom")
            }
            if showsResumeNotice, let resumed = controller.resumedFrom, !controller.isLocked {
                HStack(spacing: 12) {
                    Text("从 \(MediaFormatting.time(resumed)) 继续")
                        .font(AppTypography.caption)
                    Button("从头播放") {
                        controller.restartFromBeginning()
                        Haptics.light()
                        hideResumeNotice()
                    }
                    .font(AppTypography.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("player.restart")
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background(.black.opacity(0.7), in: Capsule())
                .transition(.opacity)
            }
            if let notice {
                Text(notice)
                    .font(AppTypography.caption)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.7), in: Capsule())
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .accessibilityIdentifier("player.notice")
            }
        }
        .padding(.top, max(16, safeArea.top) + (controlsAreVisible ? 52 : 0))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func lockOverlay(safeArea: EdgeInsets) -> some View {
        ZStack(alignment: .topLeading) {
            // While locked, a tap only reveals the unlock button.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { revealUnlockButton() }
                .accessibilityHidden(true)
            if showsUnlockButton || voiceOverEnabled {
                Button {
                    controller.isLocked = false
                    Haptics.light()
                } label: {
                    Label { Text("解锁") } icon: { DesignIcon(name: "IconLock", size: 18) }
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(Theme.onAccent)
                .padding(.top, max(16, safeArea.top))
                .padding(.leading, max(16, safeArea.leading))
                .transition(.opacity)
                .accessibilityIdentifier("player.unlock")
            }
        }
    }

    // MARK: Chrome visibility

    private func refreshChrome(reveal: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        var next = chrome
        next.update(chromeContext, now: now)
        if reveal {
            controller.recordUserInteraction()
            next.interact(now: now)
        }
        applyChrome(next)
    }

    private func toggleControls() {
        if showsRatePicker {
            withAnimation(.easeOut(duration: 0.15)) { showsRatePicker = false }
            return
        }
        controller.recordUserInteraction()
        let now = ProcessInfo.processInfo.systemUptime
        var next = chrome
        next.update(chromeContext, now: now)
        next.tapVideo(now: now)
        applyChrome(next)
    }

    private func applyChrome(_ next: PlaybackChromeState) {
        if next.isVisible != chrome.isVisible && !reduceMotion {
            withAnimation(.easeInOut(duration: 0.2)) { chrome = next }
        } else {
            chrome = next
        }
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        cancelAutoHide()
        guard let deadline = chrome.deadline else { return }
        let generation = timerGeneration
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        autoHideTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard !Task.isCancelled, generation == timerGeneration else { return }
            let now = ProcessInfo.processInfo.systemUptime
            var next = chrome
            next.update(chromeContext, now: now)
            next.advance(now: now)
            applyChrome(next)
        }
    }

    private func cancelAutoHide() {
        timerGeneration &+= 1
        autoHideTask?.cancel()
        autoHideTask = nil
    }

    // MARK: Notices

    private func showNotice(_ text: String) {
        noticeTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { notice = text }
        noticeTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(1.8)) }
            catch { return }
            withAnimation(.easeOut(duration: 0.2)) { notice = nil }
        }
    }

    private func presentResumeNoticeIfNeeded() {
        guard controller.resumedFrom != nil, resumeNoticeTask == nil else { return }
        withAnimation(.easeOut(duration: 0.15)) { showsResumeNotice = true }
        resumeNoticeTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            withAnimation(.easeOut(duration: 0.2)) { showsResumeNotice = false }
        }
    }

    private func hideResumeNotice() {
        resumeNoticeTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { showsResumeNotice = false }
    }

    private func revealUnlockButton() {
        unlockButtonTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { showsUnlockButton = true }
        unlockButtonTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(3)) }
            catch { return }
            withAnimation(.easeOut(duration: 0.3)) { showsUnlockButton = false }
        }
    }

    private func closeABEditor() {
        withAnimation(.easeOut(duration: 0.15)) { showsABEditor = false }
        refreshChrome(reveal: true)
    }

    // MARK: Options and navigation

    private func optionsDidDismiss() {
        waitsForOptionsDismissal = false
        if let target = pendingVideoSelection {
            pendingVideoSelection = nil
            selectVideo(target)
            return
        } else if pendingSubtitleImport {
            pendingSubtitleImport = false
            showsSubtitleImporter = true
        } else if pendingGestureGuide {
            pendingGestureGuide = false
            showsGestureGuide = true
        } else if pendingABEditor {
            pendingABEditor = false
            withAnimation(.easeOut(duration: 0.15)) { showsABEditor = true }
        }
        showExportedFrame()
        refreshChrome(reveal: true)
    }

    private func showExportedFrame() {
        guard !waitsForOptionsDismissal, !showsOptions, let url = controller.exportedFrameURL else { return }
        framePresentation = FramePresentation(url: url)
    }

    private func handleSwipe(_ direction: Int) {
        let target = index + direction
        guard entries.indices.contains(target) else {
            Haptics.warning()
            showNotice(direction > 0 ? "已经是最后一个视频" : "已经是第一个视频")
            return
        }
        Haptics.light()
        selectVideo(target)
    }

    private func handlePlaybackEnded() {
        // Watched to the end: the remembered position is cleared.
        savePlaybackPosition()
        guard endAction == .next, controller.loopEnd == nil else { return }
        if index + 1 < entries.count {
            selectVideo(index + 1)
        } else if entries.count > 1 {
            showNotice("已播完当前列表")
        }
    }

    private func selectVideo(_ target: Int) {
        guard entries.indices.contains(target), target != index, !isSwitchingVideo else { return }
        savePlaybackPosition()
        isSwitchingVideo = true
        cancelAutoHide()
        // A landscape session carries over, so the screen does not rotate back and forth.
        if !isFullscreen { restoreOrientation() }
        controller.stop {
            guard isSwitchingVideo else { return }
            onSelect(target)
        }
    }

    private func saveExternalVideo() {
        guard entry.isExternal, externalSaveState.canSave else { return }
        controller.recordUserInteraction()
        externalSaveState = .saving
        Task {
            do {
                try await onSaveExternal()
                externalSaveState = .saved
            } catch {
                externalSaveState = .failed(error.localizedDescription)
            }
        }
    }

    private func closePlayer() {
        savePlaybackPosition()
        isSwitchingVideo = false
        cancelAutoHide()
        restoreOrientation()
        controller.stop()
        onAutoLockChange(false)
        dismiss()
    }

    private func savePlaybackPosition() {
        guard controller.isReady, controller.duration > 0 else { return }
        onPlaybackPosition(controller.currentTime, controller.duration)
    }

    private func applyEndAction() {
        guard controller.isReady else { return }
        let looping = endAction == .loop
        // An active A–B interval takes precedence over whole-file looping.
        if looping && controller.loopEnd != nil { return }
        if controller.isLooping != looping { controller.setLooping(looping) }
    }

    private func applySubtitleScale() {
        // A landscape video on an upright phone is small, and so are its subtitles.
        let boost = controller.displayGeometry?.fullscreenOrientation == .landscape && !interfaceIsLandscape ? 1.5 : 1
        controller.setSubtitleScale(subtitleScale * boost)
    }

    private var subtitleTypes: [UTType] {
        ["srt", "ass", "ssa", "vtt"].compactMap { UTType(filenameExtension: $0) } + [.plainText, .data]
    }

    private func rateLabel(_ rate: Float) -> String {
        String(format: "%g×", Double(rate))
    }

    // MARK: Orientation

    private func effectiveSafeArea(_ geometryInsets: EdgeInsets) -> EdgeInsets {
        guard let windowInsets = controller.renderView.window?.safeAreaInsets else { return geometryInsets }
        return EdgeInsets(top: max(geometryInsets.top, windowInsets.top),
                          leading: max(geometryInsets.leading, windowInsets.left),
                          bottom: max(geometryInsets.bottom, windowInsets.bottom),
                          trailing: max(geometryInsets.trailing, windowInsets.right))
    }

    private func enterFullscreen() {
        guard !isFullscreen else { return }
        isFullscreen = true
        onFullscreenChange(true)
        synchronizeFullscreenOrientation()
        refreshChrome(reveal: true)
    }

    private func exitFullscreen() {
        guard isFullscreen else { return }
        isFullscreen = false
        onFullscreenChange(false)
        restoreOrientation()
        refreshChrome(reveal: true)
    }

    private func synchronizeFullscreenOrientation() {
        guard isFullscreen, let scene = controller.renderView.window?.windowScene else { return }
        let manager = PlaybackOrientationManager.shared
        let orientation = controller.displayGeometry?.fullscreenOrientation
        // The system can decline a forced rotation (an unfolded iPhone Duo, iPad
        // multitasking). Return to the normal layout instead of reporting an error.
        let onFailure: (Error) -> Void = { _ in exitFullscreen() }
        if let id = orientationSession, manager.isActive(id) {
            manager.updateFullscreen(id, orientation: orientation, onFailure: onFailure)
        } else {
            orientationSession = manager.beginFullscreen(in: scene, orientation: orientation, onFailure: onFailure)
        }
    }

    private func restoreOrientation() {
        if let id = orientationSession { PlaybackOrientationManager.shared.endFullscreen(id) }
        orientationSession = nil
    }

    private func reportMetadata() {
        guard controller.isReady else { return }
        let geometry = controller.displayGeometry
        onMetadata(controller.duration, Int(geometry?.width.rounded() ?? 0), Int(geometry?.height.rounded() ?? 0))
    }
}

/// The time readout observes only the playback clock, so a frame tick does not
/// re-render the rest of the player.
private struct PlaybackTimeRow: View {
    @ObservedObject var clock: PlaybackClock
    let duration: Double
    let showsMilliseconds: Bool
    let highlighted: Bool
    let onCapture: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Text(MediaFormatting.time(clock.time, milliseconds: showsMilliseconds))
                .foregroundStyle(highlighted ? Theme.accent : Theme.text)
                .accessibilityIdentifier("player.currentTime")
                .allowsHitTesting(false)
            Spacer(minLength: 0)
            if let onCapture {
                Button(action: onCapture) {
                    ViewThatFits(in: .horizontal) {
                        Label("保存此帧", systemImage: "camera").fixedSize()
                        Image(systemName: "camera")
                    }
                    .font(AppTypography.footnote)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: Capsule())
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .accessibilityLabel("保存此帧")
                .accessibilityIdentifier("player.quickCapture")
                Spacer(minLength: 0)
            }
            Text(MediaFormatting.time(duration))
                .foregroundStyle(Theme.muted)
                .accessibilityIdentifier("player.duration")
                .allowsHitTesting(false)
        }
        .font(AppTypography.numeric(.footnote))
    }
}

private struct PlaybackTimelineBar: View {
    @ObservedObject var clock: PlaybackClock
    let duration: Double
    let loopStart: Double?
    let loopEnd: Double?
    let enabled: Bool
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    let onCommit: (Double) -> Void

    var body: some View {
        PrecisionTimeline(time: clock.time, duration: duration, loopStart: loopStart, loopEnd: loopEnd,
                          enabled: enabled, onBegin: onBegin, onChange: onChange, onCommit: onCommit)
    }
}

private struct ScreenSeekPreview: View {
    @ObservedObject var clock: PlaybackClock
    let delta: Double

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: delta < 0 ? "arrow.left" : "arrow.right")
                Text(delta < 0 ? "快退" : "快进")
                Text(String(format: "%+.1f 秒", delta))
            }
            .font(AppTypography.numeric(.subheadline))
            .foregroundStyle(Theme.accent)
            .accessibilityIdentifier("player.screenSeekDelta")
            Text(MediaFormatting.time(clock.time, milliseconds: true))
                .font(AppTypography.numeric(.title2))
                .foregroundStyle(Theme.text)
                .accessibilityIdentifier("player.screenSeekTime")
            Text("松手定位").font(AppTypography.caption).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 16))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("player.screenSeekPreview")
    }
}

private struct ChromeIconButtonStyle: ButtonStyle {
    var prominent = false
    var diameter: CGFloat = 44
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: diameter, height: diameter)
            .foregroundStyle(prominent ? Theme.onAccent : Theme.text)
            .background(prominent ? Theme.accent : .black.opacity(0.25), in: Circle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
            .contentShape(Circle())
    }
}
