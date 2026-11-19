import PlayitCore
import UIKit

/// The app delegate consults this mask so geometry requests are permitted only
/// while the player owns a fullscreen session. Normal automatic rotation is restored.
@MainActor
final class PlaybackOrientationManager {
    static let shared = PlaybackOrientationManager()

    @MainActor
    private final class Session {
        let id = UUID()
        weak var scene: UIWindowScene?
        let previousMask: UIInterfaceOrientationMask
        let previousOrientation: UIInterfaceOrientation
        var appliedOrientation: VideoDisplayGeometry.FullscreenOrientation?

        init(scene: UIWindowScene, previousMask: UIInterfaceOrientationMask) {
            self.scene = scene
            self.previousMask = previousMask
            previousOrientation = scene.interfaceOrientation
        }
    }

    private(set) var supportedOrientations: UIInterfaceOrientationMask =
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    private var session: Session?
    private var requestRevision = 0

    /// Captures orientation even when display metadata has not arrived yet.
    /// Unknown video geometry deliberately leaves the device orientation unchanged.
    func beginFullscreen(in scene: UIWindowScene,
                         orientation: VideoDisplayGeometry.FullscreenOrientation?,
                         onFailure: @escaping (Error) -> Void) -> UUID {
        if let existing = session { endFullscreen(existing.id) }
        requestRevision &+= 1
        let saved = Session(scene: scene, previousMask: supportedOrientations)
        session = saved
        updateFullscreen(saved.id, orientation: orientation, onFailure: onFailure)
        return saved.id
    }

    func updateFullscreen(_ id: UUID,
                          orientation: VideoDisplayGeometry.FullscreenOrientation?,
                          onFailure: @escaping (Error) -> Void) {
        guard let saved = session, saved.id == id, let scene = saved.scene,
              let orientation, orientation != saved.appliedOrientation else { return }
        saved.appliedOrientation = orientation
        let mask: UIInterfaceOrientationMask = orientation == .landscape ? .landscape : .portrait
        supportedOrientations = mask
        request(mask, in: scene, onFailure: onFailure)
    }

    func endFullscreen(_ id: UUID) {
        guard let saved = session, saved.id == id else { return }
        session = nil
        requestRevision &+= 1
        supportedOrientations = saved.previousMask
        guard let scene = saved.scene else { return }
        invalidateOrientationSupport(in: scene)
        guard let previous = mask(for: saved.previousOrientation) else { return }
        request(previous, in: scene, onFailure: nil)
    }

    func finishPlayerPresentation() {
        if let session { endFullscreen(session.id) }
    }

    /// Whether a landscape session is still current, so the next video can reuse it
    /// instead of rotating back and forth.
    func isActive(_ id: UUID) -> Bool {
        session?.id == id
    }

    private func request(_ mask: UIInterfaceOrientationMask, in scene: UIWindowScene,
                         onFailure: ((Error) -> Void)?) {
        requestRevision &+= 1
        let revision = requestRevision
        invalidateOrientationSupport(in: scene)
        // Let SwiftUI update navigation/status-bar layout before asking the scene to rotate.
        DispatchQueue.main.async { [weak self, weak scene] in
            guard let self, let scene, revision == self.requestRevision,
                  scene.activationState == .foregroundActive else { return }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { [weak self] error in
                Task { @MainActor [weak self] in
                    guard self?.requestRevision == revision else { return }
                    NSLog("playit orientation request failed: %@", error.localizedDescription)
                    onFailure?(error)
                }
            }
        }
    }

    private func invalidateOrientationSupport(in scene: UIWindowScene) {
        var visited: Set<ObjectIdentifier> = []
        func visit(_ controller: UIViewController) {
            guard visited.insert(ObjectIdentifier(controller)).inserted else { return }
            controller.setNeedsUpdateOfSupportedInterfaceOrientations()
            controller.children.forEach(visit)
            if let presented = controller.presentedViewController { visit(presented) }
        }
        scene.windows.compactMap(\.rootViewController).forEach(visit)
    }

    private func mask(for orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask? {
        switch orientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return nil
        }
    }
}

@MainActor
final class PlayitOrientationAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        PlaybackOrientationManager.shared.supportedOrientations
    }
}
