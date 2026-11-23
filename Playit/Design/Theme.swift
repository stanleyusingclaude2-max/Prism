import SwiftUI
import UIKit

enum Theme {
    static let bg = Color("Background")
    static let surface = Color("Surface")
    static let raised = Color("Raised")
    static let border = Color("Border")
    static let text = Color("TextPrimary")
    static let muted = Color("Muted")
    static let subtle = Color("Subtle")
    // Resolve the brand asset directly. Color.accentColor reads the current
    // environment tint and can otherwise resolve to iOS blue at presentation boundaries.
    static let accent = Color("AccentColor")
    static let uiAccent = UIColor(named: "AccentColor") ?? UIColor(red: 158 / 255, green: 220 / 255, blue: 255 / 255, alpha: 1)
    static let onAccent = Color("OnAccent")
    static let accentSoft = Color("AccentSoft")
    static let success = Color("Success")
    static let danger = Color("Danger")
}

struct DesignIcon: View {
    let name: String
    var size: CGFloat = 22

    var body: some View {
        Image(name)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

enum MediaFormatting {
    /// "0:33", "12:05", "1:02:03"; milliseconds are for paused inspection only.
    static func time(_ seconds: Double, milliseconds: Bool = false) -> String {
        guard seconds.isFinite, seconds >= 0,
              let totalMilliseconds = Int(exactly: (seconds * 1_000).rounded(.down)) else {
            return milliseconds ? "0:00.000" : "0:00"
        }
        let whole = totalMilliseconds / 1_000
        let prefix = whole >= 3_600
            ? String(format: "%d:%02d:%02d", whole / 3_600, whole / 60 % 60, whole % 60)
            : String(format: "%d:%02d", whole / 60, whole % 60)
        return milliseconds ? prefix + String(format: ".%03d", totalMilliseconds % 1_000) : prefix
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
