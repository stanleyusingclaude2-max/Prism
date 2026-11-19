#!/usr/bin/env python3
"""Parse Swift sources without requiring the Apple SDK.

This checks grammar only. It does not type-check SwiftUI, AVFoundation or Network.
Install prerequisites with:
  python3 -m pip install tree-sitter tree-sitter-swift
"""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

try:
    from tree_sitter import Language, Parser
    import tree_sitter_swift
except ImportError:
    # The temporary installation is useful in this task's Linux environment;
    # normal developer machines should install the documented prerequisites.
    sys.path.insert(0, "/tmp/playit-validation-python")
    try:
        from tree_sitter import Language, Parser
        import tree_sitter_swift
    except ImportError:
        sys.exit("Missing parser: python3 -m pip install tree-sitter tree-sitter-swift")


def main() -> int:
    arguments = argparse.ArgumentParser(description=__doc__)
    arguments.add_argument("paths", nargs="*", type=Path)
    options = arguments.parse_args()
    roots = options.paths or [Path(__file__).resolve().parents[1]]
    files: set[Path] = set()
    for root in roots:
        candidates = [root] if root.is_file() else root.rglob("*.swift")
        for candidate in candidates:
            if not any(part in {".build", ".git", "DerivedData", "Pods"} for part in candidate.parts):
                files.add(candidate.resolve())
    if not files:
        print("No Swift sources found.", file=sys.stderr)
        return 2

    parser = Parser(Language(tree_sitter_swift.language()))
    errors = 0
    for path in sorted(files):
        data = path.read_bytes()
        tree = parser.parse(data)
        if not tree.root_node.has_error:
            continue
        pending = [tree.root_node]
        while pending:
            node = pending.pop()
            if node.is_error or node.is_missing:
                row, column = node.start_point
                detail = data[node.start_byte : min(node.end_byte, node.start_byte + 100)]
                snippet = detail.decode("utf-8", errors="replace").replace("\n", " ")
                print(f"{path}:{row + 1}:{column + 1}: {node.type}: {snippet}")
                errors += 1
            else:
                pending.extend(reversed(node.children))
    print(f"Parsed {len(files)} Swift files; {errors} grammar errors.")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
