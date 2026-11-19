import QuartzCore
import PlayitCore
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// A single, persistent Metal surface. Changing the SwiftUI layout does not recreate mpv.
struct PlaybackSurface: UIViewRepresentable {
    @ObservedObject var controller: PlaybackController
    var onTap: () -> Void = {}
    /// +1 for the next video (swipe up), -1 for the previous one (swipe down).
    var onSwipe: (Int) -> Void = { _ in }
    /// False for a single video: a vertical swipe then has nowhere to go.
    var allowsVideoSwitching = true

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller, onTap: onTap, onSwipe: onSwipe) }

    func makeUIView(context: Context) -> MPVRenderView {
        let view = controller.renderView
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: MPVRenderView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onSwipe = onSwipe
        context.coordinator.allowsVideoSwitching = allowsVideoSwitching
        context.coordinator.updateEnabledState()
    }

    static func dismantleUIView(_ uiView: MPVRenderView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var controller: PlaybackController?
        weak var view: MPVRenderView?
        var onTap: () -> Void
        var onSwipe: (Int) -> Void
        var allowsVideoSwitching = true
        private var tap: UITapGestureRecognizer?
        private var hold: UILongPressGestureRecognizer?
        private var pan: HorizontalSeekGestureRecognizer?
        private var pinch: UIPinchGestureRecognizer?
        private var zoomPan: UIPanGestureRecognizer?
        private var swipeUp: UISwipeGestureRecognizer?
        private var swipeDown: UISwipeGestureRecognizer?
        private var ownsScreenSeek = false
        private var lastPinchCentroid: CGPoint?
        /// 0: zoom unavailable, 1: complete image, 2: magnified. Avoids rebuilding
        /// accessibility actions on every SwiftUI update.
        private var accessibilityState = -1

        init(controller: PlaybackController, onTap: @escaping () -> Void, onSwipe: @escaping (Int) -> Void) {
            self.controller = controller
            self.onTap = onTap
            self.onSwipe = onSwipe
        }

        func attach(to view: MPVRenderView) {
            self.view = view
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
            hold.minimumPressDuration = 0.35
            hold.allowableMovement = 6
            hold.delegate = self
            let pan = HorizontalSeekGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.delegate = self
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            pinch.delegate = self
            let zoomPan = UIPanGestureRecognizer(target: self, action: #selector(handleZoomPan(_:)))
            zoomPan.maximumNumberOfTouches = 1
            zoomPan.delegate = self
            let swipeUp = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
            swipeUp.direction = .up
            swipeUp.delegate = self
            let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
            swipeDown.direction = .down
            swipeDown.delegate = self
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tap.numberOfTapsRequired = 1
            // No double-tap recognizer: a single tap toggles the controls at once
            // instead of waiting about 0.3 s for a possible second tap. Both
            // dependencies below fail as soon as a short tap lifts.
            tap.require(toFail: hold)
            tap.require(toFail: pan)
            tap.delegate = self
            let recognizers: [UIGestureRecognizer] = [hold, tap, pan, pinch, zoomPan, swipeUp, swipeDown]
            for recognizer in recognizers { view.addGestureRecognizer(recognizer) }
            self.hold = hold
            self.tap = tap
            self.pan = pan
            self.pinch = pinch
            self.zoomPan = zoomPan
            self.swipeUp = swipeUp
            self.swipeDown = swipeDown
            updateEnabledState()
        }

        func updateEnabledState() {
            guard let controller else { return }
            let allowed = controller.isReady && !controller.isLocked && !controller.isScrubbing
            setEnabled(hold, allowed)
            setEnabled(tap, allowed)
            setEnabled(pinch, controller.canZoomVideo)
            setEnabled(zoomPan, controller.isVideoZoomed && !controller.isLocked)
            setEnabled(swipeUp, canSwipe)
            setEnabled(swipeDown, canSwipe)
            // The pan owns a live scrub session. Disabling it merely because
            // isScrubbing became true would cancel every drag on its first frame.
            let panAllowed = controller.canBeginScreenSeeking || canSwitchHoldToSeek ||
                (ownsScreenSeek && controller.isScreenSeekTouchActive)
            setEnabled(pan, panAllowed)
            updateAccessibility()
        }

        func detach() {
            // Dismissal must not resume a previously playing clip as the view disappears.
            controller?.pause()
            ownsScreenSeek = false
            let recognizers: [UIGestureRecognizer?] = [hold, tap, pan, pinch, zoomPan, swipeUp, swipeDown]
            for case let recognizer? in recognizers { view?.removeGestureRecognizer(recognizer) }
            hold = nil
            tap = nil
            pan = nil
            pinch = nil
            zoomPan = nil
            swipeUp = nil
            swipeDown = nil
            view?.accessibilityCustomActions = nil
            view = nil
            onTap = {}
            onSwipe = { _ in }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let controller else { return false }
            if gestureRecognizer === pinch { return controller.canZoomVideo }
            if gestureRecognizer === zoomPan { return controller.isVideoZoomed && !controller.isLocked }
            if gestureRecognizer === swipeUp || gestureRecognizer === swipeDown { return canSwipe }
            if let pan, gestureRecognizer === pan {
                return controller.canBeginScreenSeeking || canSwitchHoldToSeek
            }
            return controller.isReady && !controller.isLocked && !controller.isScrubbing
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // Keep tracking after a stationary hold. If the user then drags,
            // restore the pre-hold state and hand the touch to seeking.
            (gestureRecognizer === pan && otherGestureRecognizer === hold) ||
                (gestureRecognizer === hold && otherGestureRecognizer === pan)
        }

        private func setEnabled(_ recognizer: UIGestureRecognizer?, _ enabled: Bool) {
            if let recognizer, recognizer.isEnabled != enabled { recognizer.isEnabled = enabled }
        }

        private var canSwitchHoldToSeek: Bool {
            controller.map {
                $0.isReady && !$0.isLocked && !$0.isScrubbing && !$0.isVideoZoomed &&
                    $0.isTemporaryFastPlayback && $0.duration.isFinite && $0.duration > 0
            } ?? false
        }

        private var canSwipe: Bool {
            guard allowsVideoSwitching, let controller else { return false }
            return controller.isReady && !controller.isLocked && !controller.isScrubbing &&
                !controller.isVideoZoomed && !controller.isTemporaryFastPlayback
        }

        private func updateAccessibility() {
            guard let controller, let view else { return }
            let state = controller.canZoomVideo ? (controller.isVideoZoomed ? 2 : 1) : 0
            guard state != accessibilityState else { return }
            accessibilityState = state
            view.accessibilityValue = controller.isVideoZoomed ? "已放大" : "完整画面"
            view.accessibilityCustomActions = state == 0 ? [] : [
                UIAccessibilityCustomAction(name: state == 2 ? "还原完整画面" : "放大画面2倍",
                                            target: self, selector: #selector(accessibilityZoom(_:)))
            ]
        }

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            if gesture.state == .ended { onTap() }
        }

        @objc private func accessibilityZoom(_ action: UIAccessibilityCustomAction) -> Bool {
            guard controller?.canZoomVideo == true else { return false }
            controller?.toggleAccessibilityZoom()
            updateEnabledState()
            return true
        }

        @objc private func handleHold(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began:
                controller?.beginTemporaryFastPlayback()
                if controller?.isTemporaryFastPlayback == true {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            case .ended, .cancelled, .failed:
                controller?.endTemporaryFastPlayback()
            default: break
            }
        }

        @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let view, let controller else { return }
            switch gesture.state {
            case .began:
                lastPinchCentroid = gesture.numberOfTouches >= 2 ? gesture.location(in: view) : nil
            case .changed:
                // Lifting one finger moves the centroid abruptly; wait for two again.
                guard gesture.numberOfTouches >= 2 else {
                    lastPinchCentroid = nil
                    gesture.scale = 1
                    return
                }
                let centroid = gesture.location(in: view)
                let previous = lastPinchCentroid ?? centroid
                controller.zoomVideo(by: Double(gesture.scale),
                                     anchorX: Double(centroid.x - view.bounds.midX),
                                     anchorY: Double(centroid.y - view.bounds.midY),
                                     panX: Double(centroid.x - previous.x),
                                     panY: Double(centroid.y - previous.y))
                gesture.scale = 1
                lastPinchCentroid = centroid
            case .ended, .cancelled, .failed:
                lastPinchCentroid = nil
                controller.settleVideoZoom()
            default: break
            }
        }

        @objc private func handleZoomPan(_ gesture: UIPanGestureRecognizer) {
            guard let view, gesture.state == .changed || gesture.state == .ended else { return }
            let translation = gesture.translation(in: view)
            controller?.panVideo(byX: Double(translation.x), y: Double(translation.y))
            gesture.setTranslation(.zero, in: view)
        }

        @objc private func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
            guard gesture.state == .ended else { return }
            onSwipe(gesture.direction == .up ? 1 : -1)
        }

        @objc private func handlePan(_ gesture: HorizontalSeekGestureRecognizer) {
            let translation = gesture.horizontalTranslation
            switch gesture.state {
            case .began:
                if controller?.isTemporaryFastPlayback == true { controller?.endTemporaryFastPlayback() }
                ownsScreenSeek = true
                guard controller?.beginScreenSeeking(viewportWidth: Double(view?.bounds.width ?? 0)) == true else {
                    ownsScreenSeek = false
                    return
                }
                // A drag owns this touch now. This also ends any pending hold
                // before it can trigger 2× while the finger is moving slowly.
                hold?.isEnabled = false
                controller?.updateScreenSeeking(horizontalTranslation: translation)
            case .changed:
                if ownsScreenSeek { controller?.updateScreenSeeking(horizontalTranslation: translation) }
            case .ended:
                guard ownsScreenSeek else { return }
                ownsScreenSeek = false
                controller?.endScreenSeeking(horizontalTranslation: translation)
            case .cancelled, .failed:
                guard ownsScreenSeek else { return }
                ownsScreenSeek = false
                controller?.endScreenSeeking(horizontalTranslation: translation, cancelled: true)
            default: break
            }
        }
    }
}

/// UIKit's UIPan asks shouldBegin only once. Rejecting a small/slanted first
/// sample loses the whole touch. Track direction until it becomes clear instead.
@MainActor
private final class HorizontalSeekGestureRecognizer: UIGestureRecognizer {
    private var trackedTouch: UITouch?
    private var origin = CGPoint.zero
    private var direction = ScreenSeekDirectionLock()
    private(set) var horizontalTranslation: Double = 0

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard trackedTouch == nil, touches.count == 1, let touch = touches.first else {
            failOrCancel()
            return
        }
        trackedTouch = touch
        origin = touch.location(in: view)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        let location = touch.location(in: view)
        horizontalTranslation = Double(location.x - origin.x)
        switch state {
        case .possible:
            switch direction.update(horizontal: horizontalTranslation, vertical: Double(location.y - origin.y)) {
            case .pending: break
            case .horizontal: state = .began
            case .vertical: state = .failed
            }
        case .began, .changed:
            state = .changed
        default: break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        horizontalTranslation = Double(touch.location(in: view).x - origin.x)
        if state == .began || state == .changed { state = .ended }
        else if state == .possible { state = .failed }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        failOrCancel()
    }

    override func reset() {
        super.reset()
        trackedTouch = nil
        origin = .zero
        horizontalTranslation = 0
        direction = ScreenSeekDirectionLock()
    }

    private func failOrCancel() {
        if state == .possible { state = .failed }
        else if state == .began || state == .changed { state = .cancelled }
    }
}

final class MPVRenderView: UIView {
    let videoLayer = PlayitMetalLayer()
    var onDrawableReady: (() -> Void)?
    var onViewportSizeChange: (() -> Void)?
    private var lastViewportSize: CGSize = .zero
    var displayGeometry: VideoDisplayGeometry? {
        didSet {
            if oldValue != displayGeometry { setNeedsLayout() }
        }
    }
    /// Pinch magnification and pan. The decoder's square target never changes size.
    var zoom = VideoZoomState() {
        didSet { if oldValue != zoom { setNeedsLayout() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
        // The square layer keeps a fixed drawable. At 1×, only black margins
        // are clipped; a magnified view deliberately crops the image.
        clipsToBounds = true
        videoLayer.framebufferOnly = true
        videoLayer.contentsGravity = .resize
        videoLayer.drawableSize = videoLayer.sessionDrawableSize
        videoLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        videoLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(videoLayer)
        accessibilityLabel = "视频画面"
        isAccessibilityElement = true
        accessibilityHint = "左右拖动快进或快退，上下滑动切换视频，轻点显示或隐藏控件，双指捏合放大，长按临时以2倍速播放。"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let previousSize = lastViewportSize
        lastViewportSize = bounds.size
        if previousSize != .zero, previousSize != bounds.size { onViewportSizeChange?() }
        if let window, bounds.width > 1, bounds.height > 1 {
            videoLayer.prepare(for: window.screen)
        }
        guard let layout = VideoSurfaceLayout(viewportWidth: Double(bounds.width),
                                              viewportHeight: Double(bounds.height),
                                              geometry: displayGeometry, zoomScale: zoom.scale,
                                              offsetX: zoom.offsetX, offsetY: zoom.offsetY),
              let scale = layout.contentsScale(forDrawableSide: Double(videoLayer.sessionDrawableSize.width)) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let frame = layout.layerFrame
        videoLayer.frame = CGRect(x: bounds.minX + CGFloat(frame.x),
                                  y: bounds.minY + CGFloat(frame.y),
                                  width: CGFloat(frame.width), height: CGFloat(frame.height))
        videoLayer.contentsScale = CGFloat(scale)
        // MPVKit's moltenvk backend has no host-resize event. A fixed square
        // swapchain prevents cached p->dst from becoming stale on rotation,
        // fullscreen transitions, and paused-frame resizing.
        videoLayer.drawableSize = videoLayer.sessionDrawableSize
        CATransaction.commit()
        if window != nil, bounds.width > 1, bounds.height > 1 { onDrawableReady?() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
    }
}

/// Pin the render target for the entire playback session. Only layer.frame is
/// transformed; its square shape guarantees uniform scaling even while paused.
final class PlayitMetalLayer: CAMetalLayer {
    private(set) var sessionDrawableSize = CGSize(width: 2048, height: 2048)
    /// The video's longer side in pixels when the library already knows it.
    var sourceLongSide: Double?
    private var prepared = false

    @MainActor
    func prepare(for screen: UIScreen) {
        guard !prepared else { return }
        prepared = true
        let size = screen.nativeBounds.size
        let process = ProcessInfo.processInfo
        let side = PlaybackRenderPolicy.drawableSide(nativeWidth: Double(size.width), nativeHeight: Double(size.height),
                                                      physicalMemory: process.physicalMemory,
                                                      conservingPower: process.isLowPowerModeEnabled ||
                                                          process.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue,
                                                      sourceLongSide: sourceLongSide)
        sessionDrawableSize = CGSize(width: CGFloat(side), height: CGFloat(side))
    }

    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            // Also rejects the upstream MoltenVK temporary 1×1 completion size.
            if newValue == sessionDrawableSize { super.drawableSize = newValue }
        }
    }
}
