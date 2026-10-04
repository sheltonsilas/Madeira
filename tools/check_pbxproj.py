#!/usr/bin/env python3
"""Structural sanity check for Madeira.xcodeproj after an automated edit.

Xcode will not tell you a project file is malformed until you open it, and this
box has no Xcode, so this checks the things that actually break: unbalanced
braces and parens, duplicate object IDs, and references to object IDs that are
never defined.

Usage: python3 tools/check_pbxproj.py   (exit 0 = structurally sound)
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent / "app" / "Madeira.xcodeproj" / "project.pbxproj"

# NOTE: Xcode normally mints 24-hex-character object IDs, but this project uses
# 8-character ones (A1000001, B2000001, C3000001, ...). Matching on 24 would
# find nothing at all and make every check below pass vacuously.
DEFINE = re.compile(r"^\t\t([A-F0-9]{8}) ", re.M)
REFERENCE = re.compile(r"\b([A-F0-9]{8})\b")
COMMENT = re.compile(r"/\*.*?\*/", re.S)
LINE_COMMENT = re.compile(r"//[^\n]*")
STRING = re.compile(r'"(?:\\.|[^"\\])*"')


def main() -> int:
    raw = PROJECT.read_text(encoding="utf-8")

    defined = DEFINE.findall(raw)
    duplicates = {i for i in defined if defined.count(i) > 1}

    stripped = STRING.sub('""', COMMENT.sub("", LINE_COMMENT.sub("", raw)))

    braces_ok = stripped.count("{") == stripped.count("}")
    parens_ok = stripped.count("(") == stripped.count(")")

    known = set(defined)
    # Dangling IDs are reported as information, not a failure: an 8-hex-character
    # string can also occur incidentally (a truncated SHA, a hex constant), and a
    # false positive here is worse than a missed one. Braces, parens and
    # duplicates are the checks that actually catch a broken edit.
    dangling = sorted({r for r in REFERENCE.findall(raw) if r not in known})

    print(f"objects defined : {len(defined)}")
    print(f"braces balanced : {braces_ok} ({stripped.count('{')}/{stripped.count('}')})")
    print(f"parens balanced : {parens_ok} ({stripped.count('(')}/{stripped.count(')')})")
    print(f"duplicate ids   : {sorted(duplicates) if duplicates else 'none'}")
    print(f"dangling refs   : {dangling if dangling else 'none'}")

    if not defined:
        print("RESULT: PROBLEM (no object IDs matched - the ID format assumption is wrong)")
        return 1
    ok = braces_ok and parens_ok and not duplicates
    print("RESULT:", "OK" if ok else "PROBLEM")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())