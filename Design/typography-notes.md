# D-DIN typography

The user's request for the SpaceX typeface is implemented as D-DIN, the text
family referenced by the SpaceX website's public stylesheet. The interface does
not use the stylized SpaceX logo letterforms as a body-text font.

The app bundles the author's unmodified OpenType distribution from
https://github.com/amcchord/datto-d-din under SIL OFL 1.1:

| File | PostScript name | SHA-256 |
| --- | --- | --- |
| D-DIN.otf | D-DIN | 6d67834e2a76646c456c087ce42a6bd6b6b0c85c88dd9918618a8b4c563c2bdf |
| D-DIN-Bold.otf | D-DIN-Bold | b0f96a3730041605b139ca2d15e29a36c55e49058ba2b72ee4d09b5e4ca210c1 |

FontTools inspection confirmed 231 Unicode glyph mappings in each font, with
the complete printable ASCII range. Neither file includes Chinese characters,
so Chinese text uses iOS's Core Text fallback. Latin letters and numbers use
D-DIN within the same string. The original font binaries are unchanged.

`AppTypography` exposes semantic SwiftUI text roles with `.custom(...,
relativeTo:)` for Dynamic Type, and a UIFontMetrics-based UIKit counterpart for
navigation, segment and tab text. Semibold/bold roles select the actual bundled
bold face. SF Symbol icons retain their system symbol font.

`UIAppFonts` lists the two filenames at the bundle root, matching the existing
project generator's handling of font resources. After adding these files, run
`python3 scripts/generate-project.py` before the next Xcode build.

Linux checks cover font structure, PostScript names, glyph coverage, license,
Info.plist registration and Swift source syntax. Actual UIFont registration,
mixed Chinese/Latin line layout and accessibility scaling require Xcode/iPhone
verification.
