import SwiftUI

/// Prism's mark: the glass prism of the app icon, without its background.
/// The PrismMark image set holds 1x/2x/3x renders of `Design/PrismMark.svg`.
struct PrismBrandMark: View {
    var height: CGFloat = 28

    var body: some View {
        Image("PrismMark")
            .renderingMode(.original)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(height: height)
    }
}

extension View {
    /// Shows the mark in the top-left corner of the library's root screen.
    /// Tapping it opens "About Prism", the same page as "+ → 关于与开源许可".
    @ViewBuilder
    func prismBrandToolbar(isVisible: Bool, onTap: @escaping () -> Void) -> some View {
        if isVisible {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                // A logo rather than a control: no Liquid Glass platter behind it.
                self.toolbar {
                    ToolbarItem(placement: .topBarLeading) { PrismBrandButton(action: onTap) }
                        .sharedBackgroundVisibility(.hidden)
                }
            } else {
                self.toolbar {
                    ToolbarItem(placement: .topBarLeading) { PrismBrandButton(action: onTap) }
                }
            }
            #else
            self.toolbar {
                ToolbarItem(placement: .topBarLeading) { PrismBrandButton(action: onTap) }
            }
            #endif
        } else {
            self
        }
    }
}

private struct PrismBrandButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PrismBrandMark()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("关于 Prism")
        .accessibilityIdentifier("library.brand")
    }
}
