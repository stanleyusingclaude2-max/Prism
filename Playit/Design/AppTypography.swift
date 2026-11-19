import SwiftUI
import UIKit

/// D-DIN (Datto Inc., SIL OFL 1.1) is the app's text family. The bundled, unmodified
/// open-source fonts cover Latin text and numbers; Core Text supplies the system
/// Chinese fallback for characters outside that font's glyph repertoire.
enum AppTypography {
    static let regularName = "D-DIN"
    static let boldName = "D-DIN-Bold"

    static var largeTitle: Font { font(size: 34, weight: .bold, relativeTo: .largeTitle) }
    static var title: Font { font(size: 28, relativeTo: .title) }
    static var title2: Font { font(size: 22, relativeTo: .title2) }
    static var title3: Font { font(size: 20, relativeTo: .title3) }
    static var headline: Font { font(size: 17, weight: .semibold, relativeTo: .headline) }
    static var subheadline: Font { font(size: 15, relativeTo: .subheadline) }
    static var body: Font { font(size: 17, relativeTo: .body) }
    static var callout: Font { font(size: 16, relativeTo: .callout) }
    static var footnote: Font { font(size: 13, relativeTo: .footnote) }
    static var caption: Font { font(size: 12, relativeTo: .caption) }
    static var caption2: Font { font(size: 11, relativeTo: .caption2) }
    static var wordmark: Font { font(size: 32, weight: .bold, relativeTo: .largeTitle) }

    /// Fixed-width system numerals for times, counters and addresses. D-DIN's
    /// figures are proportional ("1" is 36% narrower than "8") and the font has
    /// no `tnum` feature, so `.monospacedDigit()` cannot steady it.
    static func numeric(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .default, weight: weight).monospacedDigit()
    }

    /// Uses a real bundled bold face for heavier roles. `relativeTo` retains
    /// Dynamic Type instead of fixing every label to its Figma point size.
    static func font(size: CGFloat, weight: Font.Weight = .regular, relativeTo: Font.TextStyle = .body) -> Font {
        let name: String
        switch weight {
        case .semibold, .bold, .heavy, .black:
            name = boldName
        default:
            name = regularName
        }
        return .custom(name, size: size, relativeTo: relativeTo)
    }

    /// Matching font for UIKit-backed navigation bars, segmented controls and
    /// tab labels. SwiftUI content should use the semantic Font properties.
    static func uiFont(for style: UIFont.TextStyle, weight: UIFont.Weight = .regular) -> UIFont {
        let defaultTraits = UITraitCollection(preferredContentSizeCategory: .large)
        let pointSize = UIFont.preferredFont(forTextStyle: style, compatibleWith: defaultTraits).pointSize
        let name = weight.rawValue >= UIFont.Weight.semibold.rawValue ? boldName : regularName
        let base = UIFont(name: name, size: pointSize) ?? UIFont.systemFont(ofSize: pointSize, weight: weight)
        return UIFontMetrics(forTextStyle: style).scaledFont(for: base)
    }
}
