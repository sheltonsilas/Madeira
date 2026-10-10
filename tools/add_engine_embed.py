#!/usr/bin/env python3
"""Wire the QEMU engine into Madeira.xcodeproj: an embed, a flag forward, an rpath.

Three edits, all required before a Linux guest can start, and all of the kind
that is easy to get subtly wrong by hand.

1. `app/Madeira/qemu-ios` as a folder reference in Resources.

   The sysroot is fetched at build time (build/ci/fetch-payload.sh) into that
   directory, which is tracked empty (.gitkeep) so the project opens before a
   payload run has ever happened. A folder REFERENCE, not a group: a group
   enumerates its children at edit time, so files that appear later would not
   ship, while a reference copies the directory as it stands when the app is
   built. That is the same mechanism `i386-windows` and `aarch64-windows`
   already use, and it is the only one that works with generated content.

   The launcher dlopens the dylib out of the bundle at run time rather than
   linking it, so nothing here adds a link flag or a 400 MB archive to the app.

2. `$(MADEIRA_ENGINE_FLAGS)` in SWIFT_ACTIVE_COMPILATION_CONDITIONS.

   The app asks three questions at compile time -- `MADEIRA_HAS_QEMU`,
   `MADEIRA_HAS_QEMU_TCGI`, `MADEIRA_HAS_QEMU_LAUNCHER` -- and a Swift `#if`
   only reads SWIFT_ACTIVE_COMPILATION_CONDITIONS. Passing `MADEIRA_HAS_QEMU=1`
   on xcodebuild's command line sets a BUILD SETTING of that name, which is a
   different namespace and is read by nothing: the app would report the engine
   missing with the engine sitting in its own bundle. This forwarding is what
   connects the two, exactly as `$(MADEIRA_VARIANT_FLAG)` already does for the
   variant.

   The accepting setting is empty by default, so a build that fetches no payload
   produces a binary that honestly reports the engine as absent.

3. `@executable_path/qemu-ios/Frameworks` in LD_RUNPATH_SEARCH_PATHS.

   The engine and every one of its dependencies is named `@rpath/...` by UTM's
   own packaging, and NOTHING in the payload carries an LC_RPATH to resolve it:
   the frameworks in the sysroot have no rpaths of their own. `@rpath` is
   resolved against the search paths of the main executable (and of the images
   loaded before it), so the app target has to name the directory. Without this
   edit the engine loads and then dyld cannot find glib, which surfaces as a
   launch failure with no missing file to name.

   Added to every configuration of the app target - both Debug and Release -
   because the two must not disagree about where the engine's libraries are.

Idempotent: a second run changes nothing and says so. Every anchor is asserted
before it is edited -- a silent no-op here costs a full CI cycle to notice, and
the app then claims a machine can start and fails at dlopen instead.

Usage:  python3 tools/add_engine_embed.py [--check]
        --check  change nothing; exit 1 if any edit is missing.
Exits 0 on success, 1 on failure, and prints exactly what it changed.
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "app" / "Madeira.xcodeproj" / "project.pbxproj"

# The next two free IDs after the highest in use (A2000910). Taken from the
# project rather than invented: the A1/A2 space is this project's own and a
# collision makes the file unopenable.
BUILD_ID = "A1000911"
REF_ID = "A2000911"

FOLDER = "qemu-ios"

# The setting that accepting definition expands to. Empty in a checkout, set by
# build.yml when the payload is present.
FLAGS_SETTING = "MADEIRA_ENGINE_FLAGS"

# Where the engine's frameworks are, as dyld has to find them: inside the app
# bundle, in the sysroot folder the folder reference copies.
ENGINE_RPATH = "@executable_path/qemu-ios/Frameworks"

TAB = "\t"


def read_project() -> tuple[str, str]:
    """The project text with '\\n' newlines, and the newline it actually uses.

    project.pbxproj here is CRLF. Every anchor below is written with plain
    newlines, so operating on a normalised copy keeps the code readable and the
    original line endings intact on write.
    """
    raw = PROJECT.read_text(encoding="utf-8")
    newline = "\r\n" if "\r\n" in raw else "\n"
    return raw.replace("\r\n", "\n"), newline


def write_project(text: str, newline: str) -> None:
    if newline != "\n":
        text = text.replace("\n", newline)
    PROJECT.write_text(text, encoding="utf-8")


def apply_folder_reference(text: str) -> tuple[str, list[str]]:
    """Add the qemu-ios folder reference, in the four places Xcode needs it."""
    changed: list[str] = []

    if f"{REF_ID} /* {FOLDER} */" in text:
        return text, changed

    # 1. PBXBuildFile: the Resources-phase entry.
    anchor = f"{TAB}{TAB}A1000210 /* i386-windows in Resources */ = {{isa = PBXBuildFile; fileRef = A2000210 /* i386-windows */; }};\n"
    assert anchor in text, "PBXBuildFile anchor for i386-windows is gone; re-read this script"
    text = text.replace(
        anchor,
        anchor + f"{TAB}{TAB}{BUILD_ID} /* {FOLDER} in Resources */ = {{isa = PBXBuildFile; fileRef = {REF_ID} /* {FOLDER} */; }};\n",
        1,
    )
    changed.append(f"PBXBuildFile {BUILD_ID}")

    # 2. PBXFileReference: the folder itself. lastKnownFileType = folder, which
    #    is what makes Xcode copy the directory instead of listing its contents.
    anchor = f"{TAB}{TAB}A2000210 /* i386-windows */ = {{isa = PBXFileReference; lastKnownFileType = folder; path = \"i386-windows\"; sourceTree = \"<group>\"; }};\n"
    assert anchor in text, "PBXFileReference anchor for i386-windows is gone; re-read this script"
    text = text.replace(
        anchor,
        anchor + f"{TAB}{TAB}{REF_ID} /* {FOLDER} */ = {{isa = PBXFileReference; lastKnownFileType = folder; path = \"{FOLDER}\"; sourceTree = \"<group>\"; }};\n",
        1,
    )
    changed.append(f"PBXFileReference {REF_ID}")

    # 3. The Madeira group's children, beside the other bundled folders.
    anchor = f"{TAB}{TAB}{TAB}{TAB}A2000210 /* i386-windows */,\n"
    assert anchor in text, "group-children anchor for i386-windows is gone; re-read this script"
    text = text.replace(
        anchor,
        anchor + f"{TAB}{TAB}{TAB}{TAB}{REF_ID} /* {FOLDER} */,\n",
        1,
    )
    changed.append("Madeira group children")

    # 4. The Resources build phase.
    anchor = f"{TAB}{TAB}{TAB}{TAB}A1000210 /* i386-windows in Resources */,\n"
    assert anchor in text, "Resources-phase anchor for i386-windows is gone; re-read this script"
    text = text.replace(
        anchor,
        anchor + f"{TAB}{TAB}{TAB}{TAB}{BUILD_ID} /* {FOLDER} in Resources */,\n",
        1,
    )
    changed.append("Resources build phase")

    return text, changed


def apply_flags_forward(text: str) -> tuple[str, list[str]]:
    """Forward $(MADEIRA_ENGINE_FLAGS) into the Swift compilation conditions."""
    changed: list[str] = []
    # The upstream project had only DEBUG in its Debug condition and no
    # SWIFT_ACTIVE_COMPILATION_CONDITIONS setting at all in Release. Preserve
    # existing conditions, and wire both app configurations so the variant and
    # optional payload flags actually reach Swift in every build.
    import re

    pattern = re.compile(r'(SWIFT_ACTIVE_COMPILATION_CONDITIONS\s*=\s*")([^"]*)(";)')
    matches = list(pattern.finditer(text))
    assert matches, "no Swift compilation-condition setting exists in the project"
    for match in reversed(matches):
        tokens = match.group(2).split()
        additions = ["$(MADEIRA_VARIANT_FLAG)", f"$({FLAGS_SETTING})"]
        missing = [token for token in additions if token not in tokens]
        if missing:
            value = " ".join(tokens + missing)
            text = text[:match.start(2)] + value + text[match.end(2):]
            changed.append("existing configuration: +" + ", ".join(missing))

    # Release inherits the project's default configuration, but target-level
    # explicit forwarding avoids depending on Xcode's configuration inheritance
    # and makes the variant contract visible to CI's preflight check.
    if "SWIFT_ACTIVE_COMPILATION_CONDITIONS" not in text[text.find("A8000004 /* Release */"):text.find("B8000001 /* Debug */")]:
        anchor = "\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;\n"
        assert anchor in text, "app Release configuration insertion point is missing"
        text = text.replace(anchor, "\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = \"$(inherited) $(MADEIRA_VARIANT_FLAG) $(%s)\";\n" % FLAGS_SETTING + anchor, 1)
        changed.append("app Release configuration: added variant and engine flags")
    return text, changed


def apply_engine_rpath(text: str) -> tuple[str, list[str]]:
    """Add the sysroot's framework directory to the app's search paths."""
    changed: list[str] = []
    if ENGINE_RPATH in text:
        return text, changed

    old = (
        f"{TAB}{TAB}{TAB}{TAB}LD_RUNPATH_SEARCH_PATHS = (\n"
        f'{TAB}{TAB}{TAB}{TAB}{TAB}"$(inherited)",\n'
        f'{TAB}{TAB}{TAB}{TAB}{TAB}"@executable_path/Frameworks",\n'
        f"{TAB}{TAB}{TAB}{TAB});\n"
    )
    new = (
        f"{TAB}{TAB}{TAB}{TAB}LD_RUNPATH_SEARCH_PATHS = (\n"
        f'{TAB}{TAB}{TAB}{TAB}{TAB}"$(inherited)",\n'
        f'{TAB}{TAB}{TAB}{TAB}{TAB}"@executable_path/Frameworks",\n'
        f'{TAB}{TAB}{TAB}{TAB}{TAB}"{ENGINE_RPATH}",\n'
        f"{TAB}{TAB}{TAB}{TAB});\n"
    )

    # The extension's own configurations use `@executable_path/../../Frameworks`,
    # so this anchor matches the app target's two configurations and nothing else.
    n = text.count(old)
    assert n > 0, (
        "no build configuration has the app's runpath search path; the engine's "
        "frameworks have nowhere to be resolved from"
    )
    text = text.replace(old, new)
    changed.append(f"{n} configuration(s): +{ENGINE_RPATH}")
    return text, changed


def main() -> int:
    check_only = "--check" in sys.argv[1:]

    text, newline = read_project()
    original = text

    if check_only:
        problems = []
        if f"{REF_ID} /* {FOLDER} */" not in text:
            problems.append(f"app/Madeira/{FOLDER} is not a folder reference in the target")
        if f"$({FLAGS_SETTING})" not in text:
            problems.append(f"$({FLAGS_SETTING}) is not forwarded into SWIFT_ACTIVE_COMPILATION_CONDITIONS")
        if ENGINE_RPATH not in text:
            problems.append(f"{ENGINE_RPATH} is not in the app's LD_RUNPATH_SEARCH_PATHS")
        for p in problems:
            print("missing: " + p)
        return 1 if problems else 0

    text, folder_changes = apply_folder_reference(text)
    text, flag_changes = apply_flags_forward(text)
    text, rpath_changes = apply_engine_rpath(text)

    changes = folder_changes + flag_changes + rpath_changes
    if text == original:
        print(
            f"nothing to do: {FOLDER} is already embedded, $({FLAGS_SETTING}) is already "
            f"forwarded, and {ENGINE_RPATH} is already a search path"
        )
        return 0

    write_project(text, newline)
    for c in changes:
        print("added: " + c)
    print(f"project written ({len(changes)} change(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
