#!/usr/bin/env python3
"""Add the app/Madeira/Variant/*.swift files to Madeira.xcodeproj.

Xcode's project format is a plist with stable object IDs, and doing this by hand
is easy to get subtly wrong: duplicate object IDs make the project unopenable,
and Xcode will not tell you until it opens.

This script is incremental and idempotent:

  * Running it twice with no new files changes nothing.
  * Adding a file to FILES later wires only that file into the existing group.
  * Object IDs are never reused, so a second pass cannot corrupt the project.

It follows the convention already used in this project (B1xxxxxx for
PBXBuildFile, B2xxxxxx for PBXFileReference) and continues it with a C prefix.

Usage:  python3 tools/add_variant_files.py
Exits 0 on success, 1 on failure, and prints exactly what it changed.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "app" / "Madeira.xcodeproj" / "project.pbxproj"
VARIANT_DIR = ROOT / "app" / "Madeira" / "Variant"

# (filename, object-id suffix)
FILES = [
    ("AppVariant.swift", "01"),
    ("JitManager.swift", "02"),
    ("MadeiraBrowserView.swift", "03"),
    ("WindowsInstallerBridge.swift", "04"),
    ("PointerMode.swift", "05"),
    ("LinuxEnvironmentStore.swift", "06"),
    ("JitOnboardingView.swift", "07"),
]

GROUP_ID = "C3000001"
GROUP_NAME = "Variant"

# Where new entries go: after the last entry of its own kind, so repeated runs
# append rather than scatter.
LAST_BUILD_FILE = re.compile(r"^\t\tC10000\d\d /\* .*? in Sources \*/ = \{isa = PBXBuildFile;.*$", re.M)
LAST_FILE_REF = re.compile(r'^\t\tC20000\d\d /\* .*? \*/ = \{isa = PBXFileReference;.*$', re.M)
FALLBACK_BUILD_FILE = re.compile(r"^\t\tB1000001 /\* JITSetup\.swift in Sources \*/ = .*$", re.M)
FALLBACK_FILE_REF = re.compile(r"^\t\tB2000001 /\* JITSetup\.swift \*/ = \{isa = PBXFileReference;.*$", re.M)

GROUP_CHILDREN_ANCHOR = "\t\t\t\tC3000001 /* Variant */,\n"
PARENT_CHILDREN_ANCHOR = "\t\t\t\tB2000040 /* JITPairing.swift */,\n"
SOURCES_ANCHOR = "\t\t\t\tB1000040 /* JITPairing.swift in Sources */,\n"
GROUP_SECTION_END = "/* End PBXGroup section */"


def build_file_id(suffix: str) -> str:
    return f"C10000{suffix}"


def file_ref_id(suffix: str) -> str:
    return f"C20000{suffix}"


def fail(message: str) -> int:
    print(f"ERROR: {message}", file=sys.stderr)
    return 1


def main() -> int:
    if not PROJECT.exists():
        return fail(f"{PROJECT} not found")

    text = PROJECT.read_text(encoding="utf-8")
    original = text

    # Only the files that are not wired up yet.
    todo = [
        (n, s) for n, s in FILES
        if f"{build_file_id(s)} /* {n} in Sources */" not in text
    ]
    if not todo:
        print("Already wired up; no changes made.")
        return 0

    missing = [n for n, _ in todo if not (VARIANT_DIR / n).exists()]
    if missing:
        return fail(f"source files missing on disk: {', '.join(missing)}")

    # Refuse to touch a project that is already broken, so a bad run cannot
    # compound into a worse one.
    duplicates = re.findall(r"^\t\t([A-F0-9]{8}) ", text, re.M)
    if len(duplicates) != len(set(duplicates)):
        return fail("project already contains duplicate object IDs; fix that first")

    # 1. PBXBuildFile entries for the new files.
    anchor = LAST_BUILD_FILE.search(text) or FALLBACK_BUILD_FILE.search(text)
    if not anchor:
        return fail("could not find a PBXBuildFile anchor")
    text = text[: anchor.end()] + "\n" + "\n".join(
        f"\t\t{build_file_id(s)} /* {n} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref_id(s)} /* {n} */; }};"
        for n, s in todo
    ) + text[anchor.end():]

    # 2. PBXFileReference entries. Paths are relative to the Variant group, so
    #    only the bare filename is used.
    anchor = LAST_FILE_REF.search(text) or FALLBACK_FILE_REF.search(text)
    if not anchor:
        return fail("could not find a PBXFileReference anchor")
    text = text[: anchor.end()] + "\n" + "\n".join(
        f'\t\t{file_ref_id(s)} /* {n} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {n}; sourceTree = "<group>"; }};'
        for n, s in todo
    ) + text[anchor.end():]

    # 3. The group: create it on the first run, otherwise just add the new
    #    children. Recreating it would duplicate the group object ID.
    new_children = "".join(f"\t\t\t\t{file_ref_id(s)} /* {n} */,\n" for n, s in todo)

    if f"\t\t{GROUP_ID} /* {GROUP_NAME} */ = {{" in text:
        if GROUP_CHILDREN_ANCHOR not in text:
            return fail("Variant group exists but its children anchor is missing")
        text = text.replace(GROUP_CHILDREN_ANCHOR, GROUP_CHILDREN_ANCHOR + new_children, 1)
    else:
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
        end = text.find(GROUP_SECTION_END)
        if end == -1:
            return fail("no PBXGroup section")
        text = text[:end] + group_block + text[end:]

        if PARENT_CHILDREN_ANCHOR not in text:
            return fail("could not find the app group children anchor")
        text = text.replace(
            PARENT_CHILDREN_ANCHOR,
            PARENT_CHILDREN_ANCHOR + f"\t\t\t\t{GROUP_ID} /* {GROUP_NAME} */,\n",
            1,
        )

    # 4. Compile them: add to the Madeira app target's Sources phase.
    if SOURCES_ANCHOR not in text:
        return fail("could not find the Sources phase anchor")
    text = text.replace(
        SOURCES_ANCHOR,
        SOURCES_ANCHOR + "".join(
            f"\t\t\t\t{build_file_id(s)} /* {n} in Sources */,\n" for n, s in todo
        ),
        1,
    )

    if text == original:
        return fail("produced no changes")

    PROJECT.write_text(text, encoding="utf-8")
    print(f"Wired {len(todo)} file(s) into the Madeira target:")
    for n, _ in todo:
        print(f"  + Madeira/Variant/{n}")
    return 0


if __name__ == "__main__":
    sys.exit(main())