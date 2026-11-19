# Validation in the development environment

The task workspace is Debian 13 (x86_64). It has Python 3.12, Node.js 24,
`gcc`, and `ffmpeg`. It does not have Xcode or an Apple SDK, so it cannot build,
run, or visually validate the iOS application or its AVFoundation/Network code.

The following Python packages were installed into a temporary directory outside
the project:

```sh
python3 -m pip install --target /tmp/playit-validation-python \
  tree-sitter tree-sitter-swift pbxproj
```

Swift grammar validation can be run with:

```sh
python3 scripts/validate-swift-syntax.py
```

This is a grammar check, not an iOS compilation check. On a Mac, an Xcode build
and simulator/device tests are still required.

An official Swift 6.0.3 Linux toolchain is also installed at
`/tmp/playit-swift/usr/bin`. It was downloaded from `download.swift.org` (the
Ubuntu 24.04 x86_64 distribution) and its version command runs on this Debian
workspace. Pure Foundation package tests can use:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/playit-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/playit-clang-cache \
/tmp/playit-swift/usr/bin/swift test \
  --package-path Packages/PlayitCore \
  --cache-path /tmp/playit-swiftpm-cache \
  --config-path /tmp/playit-swiftpm-config \
  --security-path /tmp/playit-swiftpm-security \
  --scratch-path /tmp/playit-build-core
```

These paths avoid the environment's read-only `/home/agent/.cache`. A Foundation
smoke program using natural filename sorting compiled and ran successfully with
`swift -module-cache-path /tmp/playit-swift-module-cache -e '…'`.

Its compiler can parse iOS source grammar without resolving Apple frameworks:

```sh
/tmp/playit-swift/usr/bin/swiftc -frontend -parse Playit/SomeSource.swift
```

Passing that command still does not type-check the source against an iOS SDK.

Additional checks available without Xcode:

- XML property lists: Python `plistlib.load`.
- Xcode `project.pbxproj`: the `openstep_parser` package installed with `pbxproj`.
- Asset catalog metadata: Python `json.load`.
- Shell scripts: `bash -n`.
- Browser upload JavaScript: extract script contents and run `node --check`.

Actual package test results are recorded separately in the work report; do not
infer that tests passed from this setup note.
