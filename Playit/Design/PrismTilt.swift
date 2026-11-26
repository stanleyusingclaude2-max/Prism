import CoreMotion
import SwiftUI
import UIKit

/// How far the phone is tilted from the way it is being held, for the Prism
/// mark. Gravity from Core Motion needs no permission. Updates run only while a
/// mark is on screen, and the neutral position follows the hand within a few
/// seconds, so the mark settles whenever the phone is held still.
@MainActor
final class PrismTilt: ObservableObject {
    static let shared = PrismTilt()

    /// −1…1 on each axis, in screen directions: x grows when the right edge
    /// tips down, y when the top tips away from the viewer.
    @Published private(set) var value = CGVector.zero

    private let manager = CMMotionManager()
    private var viewers = 0
    private var neutral: CGVector?
    #if DEBUG
    /// `-prism-demo-tilt`: the Simulator has no motion sensors, so this swings
    /// the mark by itself for previews and UI-test screenshots.
    private var demo: Timer?
    #endif

    /// A change of gravity this large, about 20°, reaches the end of the range.
    private static let fullTilt = 0.35
    /// Share of the distance to the current position the neutral moves per update.
    private static let neutralFollow = 0.015
    /// Share of the distance to the new tilt the published value moves per update.
    private static let smoothing = 0.3

    private init() {}

    func attach() {
        viewers += 1
        #if DEBUG
        if viewers == 1, ProcessInfo.processInfo.arguments.contains("-prism-demo-tilt") {
            let start = Date()
            demo = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                let t = Date().timeIntervalSince(start)
                MainActor.assumeIsolated {
                    self?.value = CGVector(dx: sin(t * 1.3), dy: 0.7 * sin(t * 0.9 + 1))
                }
            }
            return
        }
        #endif
        guard viewers == 1, manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let gravity = motion?.gravity else { return }
            MainActor.assumeIsolated { self?.receive(gravity) }
        }
    }

    func detach() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        #if DEBUG
        demo?.invalidate()
        demo = nil
        #endif
        manager.stopDeviceMotionUpdates()
        neutral = nil
        value = .zero
    }

    private func receive(_ gravity: CMAcceleration) {
        let screen = Self.screenGravity(gravity, orientation: Self.interfaceOrientation)
        let base = neutral.map {
            CGVector(dx: $0.dx + (screen.dx - $0.dx) * Self.neutralFollow,
                     dy: $0.dy + (screen.dy - $0.dy) * Self.neutralFollow)
        } ?? screen
        neutral = base
        let target = CGVector(dx: Self.clamp((screen.dx - base.dx) / Self.fullTilt),
                              dy: Self.clamp((screen.dy - base.dy) / Self.fullTilt))
        let next = CGVector(dx: value.dx + (target.dx - value.dx) * Self.smoothing,
                            dy: value.dy + (target.dy - value.dy) * Self.smoothing)
        // A phone lying still must not redraw the mark thirty times a second.
        guard abs(next.dx - value.dx) > 0.003 || abs(next.dy - value.dy) > 0.003 else { return }
        value = next
    }

    private static var interfaceOrientation: UIInterfaceOrientation {
        UIApplication.shared.connectedScenes.lazy
            .compactMap { $0 as? UIWindowScene }
            .first?.effectiveGeometry.interfaceOrientation ?? .portrait
    }

    /// Gravity along the screen's right and up directions. In portrait these are
    /// the device's x and y axes; landscape turns them a quarter.
    private static func screenGravity(_ gravity: CMAcceleration, orientation: UIInterfaceOrientation) -> CGVector {
        switch orientation {
        case .portraitUpsideDown: return CGVector(dx: -gravity.x, dy: -gravity.y)
        case .landscapeLeft: return CGVector(dx: gravity.y, dy: -gravity.x)
        case .landscapeRight: return CGVector(dx: -gravity.y, dy: gravity.x)
        default: return CGVector(dx: gravity.x, dy: gravity.y)
        }
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, -1), 1)
    }
}
