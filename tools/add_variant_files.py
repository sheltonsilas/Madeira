#!/usr/bin/env python3
"""Add the app/Madeira/<Group>/*.swift files to Madeira.xcodeproj.

Xcode's project format is a plist with stable object IDs, and doing this by hand
is easy to get subtly wrong: duplicate object IDs make the project unopenable,
and Xcode will not tell you until it opens.

This script is incremental and idempotent:

  * Running it twice with no new files changes nothing.
  * Adding a file to a group's list later wires only that file into its group.
  * Object IDs are never reused, so a second pass cannot corrupt the project.

It follows the convention already used in this project (B1xxxxxx for
PBXBuildFile, B2xxxxxx for PBXFileReference) and continues it with a C prefix
for the Variant group and a D prefix for the Shell group. One letter per group
is not decoration: the two lists are walked independently, and a shared prefix
would make the "last entry of this kind" anchor stop working the moment the
second group existed.

Usage:  python3 tools/add_variant_files.py
Exits 0 on success, 1 on failure, and prints exactly what it changed.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "app" / "Madeira.xcodeproj" / "project.pbxproj"


@dataclass
class SourceGroup:
    """A directory whose Swift files are compiled into the Madeira target."""

    name: str
    #: Object-ID prefix for the PBXBuildFile entries (a letter, then 1).
    build_prefix: str
    #: Object-ID prefix for the PBXFileReference entries (a letter, then 2).
    ref_prefix: str
    #: Object ID of the PBXGroup itself (a letter, then 3).
    group_id: str
    #: (filename, two-digit object-id suffix)
    files: list[tuple[str, str]] = field(default_factory=list)

    @property
    def directory(self) -> Path:
        return ROOT / "app" / "Madeira" / self.name

    def build_file_id(self, suffix: str) -> str:
        return f"{self.build_prefix}0000{suffix}"

    def file_ref_id(self, suffix: str) -> str:
        return f"{self.ref_prefix}0000{suffix}"


GROUPS = [
    SourceGroup(
        name="Variant",
        build_prefix="C1",
        ref_prefix="C2",
        group_id="C3000001",
        files=[
            ("AppVariant.swift", "01"),
            ("JitManager.swift", "02"),
            ("MadeiraBrowserView.swift", "03"),
            ("WindowsInstallerBridge.swift", "04"),
            ("PointerMode.swift", "05"),
            ("LinuxEnvironmentStore.swift", "06"),
            ("JitOnboardingView.swift", "07"),
            ("LinuxEnvironmentPackager.swift", "08"),
            ("MadeiraTheme.swift", "09"),
            ("LinuxEngine.swift", "10"),
            ("LinuxImageDownloader.swift", "11"),
            ("LinuxDistroOnboardingView.swift", "12"),
            ("JitNetworkAdvice.swift", "13"),
            ("QEMULauncher.swift", "14"),
        ],
    ),
    SourceGroup(
        name="Shell",
        build_prefix="D1",
        ref_prefix="D2",
        group_id="D3000001",
        files=[
            ("MadeiraComponents.swift", "01"),
            ("MadeiraShellView.swift", "02"),
            ("MadeiraMachinesView.swift", "03"),
            ("MadeiraStoreView.swift", "04"),
        ],
    ),
]

# Where new entries go: after the last entry of its own kind, so repeated runs
# append rather than scatter. Built per group, from that group's prefix.
#
# The fallback is JITSetup.swift, a file that existed before any of this: if a
# group's own entries are somehow all missing, still land somewhere valid
# instead of refusing to work.
FALLBACK_BUILD_FILE = re.compile(r"^\t\tB1000001 /\* JITSetup\.swift in Sources \*/ = .*$", re.M)
FALLBACK_FILE_REF = re.compile(r"^\t\tB2000001 /\* JITSetup\.swift \*/ = \{isa = PBXFileReference;.*$", re.M)

# Where new children go: inside the group's own `children` block.
#
# This used to be the line `C3000001 /* Variant */,`, which is the group's
# entry in its PARENT's children list. Replacing after that put every
# incremental file into the Madeira group instead, where the bare filename
# resolved to Madeira/<name> and the file was reported missing from the build.
# The files that were correct were the ones present when the group was first
# created, because that branch lists them all itself.
PARENT_CHILDREN_ANCHOR = "\t\t\t\tB2000040 /* JITPairing.swift */,\n"
SOURCES_ANCHOR = "\t\t\t\tB1000040 /* JITPairing.swift in Sources */,\n"
GROUP_SECTION_END = "/* End PBXGroup section */"


def fail(message: str) -> int:
    print(f"ERROR: {message}", file=sys.stderr)
    return 1


def group_children_anchor(group: SourceGroup) -> str:
    return (
        f"\t\t{group.group_id} /* {group.name} */ = {{\n"
        "\t\t\tisa = PBXGroup;\n"
        "\t\t\tchildren = (\n"
    )


def last_build_file(group: SourceGroup) -> re.Pattern:
    return re.compile(
        rf"^\t\t{group.build_prefix}0000\d\d /\* .*? in Sources \*/ = \{{isa = PBXBuildFile;.*$",
        re.M,
    )


def last_file_ref(group: SourceGroup) -> re.Pattern:
    return re.compile(
        rf"^\t\t{group.ref_prefix}0000\d\d /\* .*? \*/ = \{{isa = PBXFileReference;.*$",
        re.M,
    )


def pending(group: SourceGroup, text: str) -> list[tuple[str, str]]:
    """The files in this group that are not wired up yet."""
    return [
        (name, suffix)
        for name, suffix in group.files
        if f"{group.build_file_id(suffix)} /* {name} in Sources */" not in text
    ]


def wire(group: SourceGroup, text: str, todo: list[tuple[str, str]]) -> str:
    """Add this group's pending files. Returns an empty string on a bad anchor."""
    # 1. PBXBuildFile entries for the new files.
    anchor = last_build_file(group).search(text) or FALLBACK_BUILD_FILE.search(text)
    if not anchor:
        return ""
    text = text[: anchor.end()] + "\n" + "\n".join(
        f"\t\t{group.build_file_id(s)} /* {n} in Sources */ = {{isa = PBXBuildFile; "
        f"fileRef = {group.file_ref_id(s)} /* {n} */; }};"
        for n, s in todo
    ) + text[anchor.end():]

    # 2. PBXFileReference entries. Paths are relative to the group, so only the
    #    bare filename is used.
    anchor = last_file_ref(group).search(text) or FALLBACK_FILE_REF.search(text)
    if not anchor:
        return ""
    text = text[: anchor.end()] + "\n" + "\n".join(
        f"\t\t{group.file_ref_id(s)} /* {n} */ = {{isa = PBXFileReference; "
        f"lastKnownFileType = sourcecode.swift; path = {n}; sourceTree = \"<group>\"; }};"
        for n, s in todo
    ) + text[anchor.end():]

    # 3. The group: create it on the first run, otherwise just add the new
    #    children. Recreating it would duplicate the group object ID.
    new_children = "".join(f"\t\t\t\t{group.file_ref_id(s)} /* {n} */,\n" for n, s in todo)

    if f"\t\t{group.group_id} /* {group.name} */ = {{" in text:
        anchor = group_children_anchor(group)
        if anchor not in text:
            return ""
        text = text.replace(anchor, anchor + new_children, 1)
    else:
        group_block = (
            f"\t\t{group.group_id} /* {group.name} */ = {{\n"
            "\t\t\tisa = PBXGroup;\n"
            "\t\t\tchildren = (\n"
            + "".join(f"\t\t\t\t{group.file_ref_id(s)} /* {n} */,\n" for n, s in group.files)
            + "\t\t\t);\n"
            + f"\t\t\tpath = {group.name};\n"
            + "\t\t\tsourceTree = \"<group>\";\n"
            + "\t\t};\n"
        )
        end = text.find(GROUP_SECTION_END)
        if end == -1:
            return ""
        text = text[:end] + group_block + text[end:]

        if PARENT_CHILDREN_ANCHOR not in text:
            return ""
        text = text.replace(
            PARENT_CHILDREN_ANCHOR,
            PARENT_CHILDREN_ANCHOR + f"\t\t\t\t{group.group_id} /* {group.name} */,\n",
            1,
        )

    # 4. Compile them: add to the Madeira app target's Sources phase.
    if SOURCES_ANCHOR not in text:
        return ""
    text = text.replace(
        SOURCES_ANCHOR,
        SOURCES_ANCHOR + "".join(
            f"\t\t\t\t{group.build_file_id(s)} /* {n} in Sources */,\n" for n, s in todo
        ),
        1,
    )

    return text


def main() -> int:
    if not PROJECT.exists():
        return fail(f"{PROJECT} not found")

    text = PROJECT.read_text(encoding="utf-8")
    original = text

    work = [(group, pending(group, text)) for group in GROUPS]
    if not any(todo for _, todo in work):
        print("Already wired up; no changes made.")
        return 0

    for group, todo in work:
        missing = [n for n, _ in todo if not (group.directory / n).exists()]
        if missing:
            return fail(f"source files missing on disk: {', '.join(missing)}")

    # Refuse to touch a project that is already broken, so a bad run cannot
    # compound into a worse one.
    duplicates = re.findall(r"^\t\t([A-F0-9]{8}) ", text, re.M)
    if len(duplicates) != len(set(duplicates)):
        return fail("project already contains duplicate object IDs; fix that first")

    for group, todo in work:
        if not todo:
            continue
        updated = wire(group, text, todo)
        if not updated:
            return fail(f"could not wire the {group.name} group; an anchor is missing")
        text = updated

    if text == original:
        return fail("produced no changes")

    PROJECT.write_text(text, encoding="utf-8")
    for group, todo in work:
        for n, _ in todo:
            print(f"  + Madeira/{group.name}/{n}")
    print(f"Wired {sum(len(todo) for _, todo in work)} file(s) into the Madeira target.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
