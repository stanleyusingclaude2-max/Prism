# Third-party sources

The application uses the non-GPL `MPVKit` Swift Package product from
https://github.com/mpvkit/MPVKit at revision
`98c3453e252922e3136422da3fbb2e341ed9edc8` (`1.1.0-n9.0.2`).

MPVKit supplies libmpv, FFmpeg, libplacebo, MoltenVK and their codec/rendering
dependencies as binary frameworks. The pinned upstream Package.swift identifies
every binary release URL and checksum. The package's LGPLv3 text is included in
`Playit/Resources/MPVKit-LICENSE.txt`; each bundled library retains its own terms.

Upstream sources and notices:

- MPVKit: https://github.com/mpvkit/MPVKit/tree/98c3453e252922e3136422da3fbb2e341ed9edc8
- mpv: https://github.com/mpv-player/mpv/tree/v0.41.0
- mpv copyright: https://github.com/mpv-player/mpv/blob/v0.41.0/Copyright
- FFmpeg: https://github.com/FFmpeg/FFmpeg
- FFmpeg license: https://github.com/FFmpeg/FFmpeg/blob/master/LICENSE.md
- MoltenVK: https://github.com/KhronosGroup/MoltenVK
- libplacebo: https://github.com/haasn/libplacebo

This source deliverable is a development project. Before distributing a binary,
provide the corresponding dependency sources, complete notices and required
relinking materials for the exact shipped artifacts. Selecting the LGPL product
does not itself satisfy distribution obligations.

Figma icon vectors were authored for this prism design and exported directly
from the approved file. Test fixtures are synthetic FFmpeg test patterns and
sine-wave audio; they do not contain third-party video content.

## D-DIN typeface

The application bundles the unmodified D-DIN Regular and Bold OpenType fonts
by Datto Inc., distributed under the SIL Open Font License 1.1. The license and
copyright notices are included in `Playit/Resources/Fonts/D-DIN-OFL.txt` and
copied into the application bundle.

- Author's public distribution: https://github.com/amcchord/datto-d-din
- Original font names: `D-DIN` and `D-DIN-Bold`.

The D-DIN files have no Chinese glyphs. iOS supplies the system Chinese fallback
within mixed-language labels; the font files are not modified to invent glyphs.
