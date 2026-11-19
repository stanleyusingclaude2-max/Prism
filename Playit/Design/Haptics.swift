import UIKit

/// Small, consistent touch feedback for discrete player actions.
@MainActor
enum Haptics {
    /// A detent: one frame, one rate step.
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    /// A light confirmation: an A/B point, a video switch.
    static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    /// Hitting a hard stop such as the start or end while dragging.
    static func edge() { UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.7) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}
