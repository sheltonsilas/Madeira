#!/usr/bin/env python3
"""Add the app/Madeira/Variant/*.swift files to Madeira.xcodeproj.

Xcode's project format is a plist with stable 24-hex-char object IDs. Doing this
by hand is easy to get subtly wrong, so this script does it deterministically
and is idempotent: running it twice changes nothing the second time.

It follows the convention already used in this project (B1xxxxxx for
PBXBuildFile, B2xxxxxx for PBXFileReference) and continues it with a C prefix
for the files added here, so they cannot collide with anything existing.

Usage:  python3 tools/add_variant_files.py
Exits 0 on success, 1 on failure, and prints exactly what it changed.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent / "app" / "Madeira.xcodeproj" / "project.pbxproj"

# (filename, object-id suffix)
FILES = [
    ("AppVariant.swift", "01"),
    ("JitManager.swift", "02"),
    ("MadeiraBrowserView.swift", "03"),
    ("WindowsInstallerBridge.swift", "04"),
    ("PointerMode.swift", "05"),
    ("LinuxEnvironmentStore.swift", "06"),
]

GROUP_ID = "C3000001"
GROUP_NAME = "Variant"


def build_file_id(suffix: str) -> str:
    return f"C10000{suffix}"


def file_ref_id(suffix: str) -> str:
    return f"C20000{suffix}"


def main() -> int:
    if not PROJECT.exists():
        print(f"ERROR: {PROJECT} not found", file=sys.stderr)
        return 1

    text = PROJECT.read_text(encoding="utf-8")
    original = text

    missing = [n for n, _ in FILES if not (PROJECT.parent.parent / "Madeira" / "Variant" / n).exists()]
    if missing:
        print(f"ERROR: source files missing on disk: {', '.join(missing)}", file=sys.stderr)
        return 1

    # Already wired up? Nothing to do.
    if any(f"{build_file_id(s)} /* {n} in Sources */" in text for n, s in FILES):
        print("Already wired up; no changes made.")
        return 0

    # 1. PBXBuildFile entries, appended after the first existing one.
    anchor = re.search(r"^\t\tB1000001 /\* JITSetup\.swift in Sources \*/ = .*$", text, re.M)
    if not anchor:
        print("ERROR: could not find the PBXBuildFile anchor", file=sys.stderr)
        return 1
    build_lines = "\n".join(
        f"\t\t{build_file_id(s)} /* {n} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref_id(s)} /* {n} */; }};"
        for n, s in FILES
    )
    text = text[: anchor.end()] + "\n" + build_lines + text[anchor.end():]

    # 2. PBXFileReference entries. Paths are relative to the Variant group, so
    #    only the bare filename is used.
    ref_anchor = re.search(
        r"^\t\tB2000001 /\* JITSetup\.swift \*/ = \{isa = PBXFileReference;.*$", text, re.M
    )
    if not ref_anchor:
        print("ERROR: could not find the PBXFileReference anchor", file=sys.stderr)
        return 1
    ref_lines = "\n".join(
        f'\t\t{file_ref_id(s)} /* {n} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {n}; sourceTree = "<group>"; }};'
        for n, s in FILES
    )
    text = text[: ref_anchor.end()] + "\n" + ref_lines + text[ref_anchor.end():]

    # 3. The Variant group itself, inserted just before the group section ends.
    group_block = (
        f"\t\t{GROUP_ID} /* {GROUP_NAME} */ = {{\n"
        "\t\t\tisa = PBXGroup;\n"
        "\t\t\tchildren = (\n"
        + "".join(f"\t\t\t\t{file_ref_id(s)} /* {n} */,\n" for n, s in FILES)
        + "\t\t\t);\n"
        f"\t\t\tpath = {GROUP_NAME};\n"
        "\t\t\tsourceTree = \"<group>\";\n"
        "\t\t};\n"
    )
    section_end = text.find("/* End PBXGroup section */")
    if section_end == -1:
        print("ERROR: no PBXGroup section", file=sys.stderr)
        return 1
    text = text[:section_end] + group_block + text[section_end:]

    # 4. Hang the Variant group off the main app group (the one whose children
    #    list already contains JITSetup.swift).
    children_anchor = "\t\t\t\tB2000040 /* JITPairing.swift */,\n"
    if children_anchor not in text:
        print("ERROR: could not find the app group children anchor", file=sys.stderr)
        return 1
    text = text.replace(
        children_anchor,
        children_anchor + f"\t\t\t\t{GROUP_ID} /* {GROUP_NAME} */,\n",
        1,
    )

    # 5. Compile them: add to the Madeira app target's Sources phase.
    sources_anchor = "\t\t\t\tB1000040 /* JITPairing.swift in Sources */,\n"
    if sources_anchor not in text:
        print("ERROR: could not find the Sources phase anchor", file=sys.stderr)
        return 1
    text = text.replace(
        sources_anchor,
        sources_anchor
        + "".join(
            f"\t\t\t\t{build_file_id(s)} /* {n} in Sources */,\n" for n, s in FILES
        ),
        1,
    )

    if text == original:
        print("ERROR: produced no changes", file=sys.stderr)
        return 1

    PROJECT.write_text(text, encoding="utf-8")
    print(f"Wired {len(FILES)} files into the Madeira target:")
    for n, _ in FILES:
        print(f"  + Madeira/Variant/{n}")
    return 0


if __name__ == "__main__":
    sys.exit(main())