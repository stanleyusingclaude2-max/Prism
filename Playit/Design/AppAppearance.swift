import SwiftUI
import UIKit

@MainActor
enum AppAppearance {
    static func install() {
        let accent = Theme.uiAccent
        let text = UIColor(named: "TextPrimary") ?? .label
        let muted = UIColor(named: "Muted") ?? .secondaryLabel

        UIBarButtonItem.appearance().tintColor = accent
        UINavigationBar.appearance().titleTextAttributes = [
            .foregroundColor: text,
            .font: AppTypography.uiFont(for: .headline, weight: .semibold)
        ]
        UINavigationBar.appearance().largeTitleTextAttributes = [
            .foregroundColor: text,
            .font: AppTypography.uiFont(for: .largeTitle, weight: .bold)
        ]

        let tab = UITabBarAppearance()
        tab.configureWithDefaultBackground()
        for appearance in [tab.stackedLayoutAppearance, tab.inlineLayoutAppearance, tab.compactInlineLayoutAppearance] {
            appearance.normal.iconColor = muted
            appearance.normal.titleTextAttributes = [.foregroundColor: muted, .font: AppTypography.uiFont(for: .caption2)]
            appearance.selected.iconColor = accent
            appearance.selected.titleTextAttributes = [.foregroundColor: accent, .font: AppTypography.uiFont(for: .caption2, weight: .bold)]
        }
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
        UITabBar.appearance().unselectedItemTintColor = muted

        // The accent is kept for play, progress and "+": a large lime segment at the
        // top of the library competed with them, so selection uses a raised neutral.
        let segmented = UISegmentedControl.appearance()
        segmented.selectedSegmentTintColor = UIColor(named: "Raised") ?? .tertiarySystemFill
        segmented.setTitleTextAttributes([.foregroundColor: muted, .font: AppTypography.uiFont(for: .subheadline)], for: .normal)
        segmented.setTitleTextAttributes([.foregroundColor: text, .font: AppTypography.uiFont(for: .subheadline, weight: .bold)], for: .selected)
        UISwitch.appearance().onTintColor = accent
        UISlider.appearance().minimumTrackTintColor = accent
        UIProgressView.appearance().progressTintColor = accent
        UIActivityIndicatorView.appearance().color = accent
    }
}

/// UIView tint is inherited from its actual window rather than configured
/// through the unsupported UIView tintColor appearance-proxy path.
struct AppWindowTint: UIViewRepresentable {
    func makeUIView(context: Context) -> TintAnchorView {
        let view = TintAnchorView()
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: TintAnchorView, context: Context) {
        uiView.applyTint()
    }

    final class TintAnchorView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            applyTint()
        }

        func applyTint() { window?.tintColor = Theme.uiAccent }
    }
}
