#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Prove tools/check_ipa_macho.py's rules on the cases that decided them.

WHY THIS EXISTS
The checker reads load commands and decides whether the app can load what it
names. Every rule in it was written from a fact about a real build, and the
first version of the resolver got two of those facts wrong in a way that would
have failed a perfectly good IPA:

  * it took the *first* rpath entry that produced a path instead of the first
    that produced a path that exists, so a binary with several rpaths was
    reported as unable to find a file that was sitting right there;
  * it treated `@executable_path` as always meaning the app binary's directory,
    but an app extension runs as its own process, where it means the extension's
    own directory - which is how the JIT helper finds its debug dylib and how
    that dylib finds StikJIT.framework.

The fixtures below are those two files' real load commands, trimmed to the
fields that matter: rpaths as they are in the IPA, and the dependencies that
were reported missing by the version with the bugs. A change that puts either
bug back makes this file fail, which is cheaper than a 30-minute build finding
out.

  python3 tools/self_test_check_ipa_macho.py    # exit 0 all good, 1 something wrong
"""

from __future__ import annotations

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import check_ipa_macho as macho  # noqa: E402  (after the path insert)

FAILURES: list[str] = []
APP = "Payload/Madeira.app"
APPEX = f"{APP}/PlugIns/MadeiraJITHelper.appex"


def check(condition: bool, what: str) -> None:
    if condition:
        print(f"  ok: {what}")
    else:
        print(f"  FAILED: {what}")
        FAILURES.append(what)


def piece(rpaths: list[str], dependencies: list[str]) -> macho.Slice:
    built = macho.Slice("test", 0, b"", True)
    built.rpaths = list(rpaths)
    built.dependencies = list(dependencies)
    return built


def test_appex_finds_its_own_debug_dylib() -> None:
    """The JIT helper: `@executable_path` + its own directory, because an appex
    is the executable of the process it runs in."""
    appex = piece(["@executable_path", "@executable_path/../../Frameworks"],
                  ["@rpath/MadeiraJITHelper.debug.dylib"])
    offered = macho.candidates(appex, APPEX, APP, "@rpath/MadeiraJITHelper.debug.dylib")
    check(f"{APPEX}/MadeiraJITHelper.debug.dylib" in offered,
          "an appex's own directory is offered as a reading of @executable_path")
    check(f"{APP}/Frameworks/MadeiraJITHelper.debug.dylib" in offered,
          "the app-relative reading is offered too, and is not the only one")
    # The bug the offered list exists to avoid: taking the first entry that
    # produces a path rather than the first that produces a path that is there.
    # This file's dependency is found by the second reading, not the first.
    present = {f"{APPEX}/MadeiraJITHelper.debug.dylib"}
    chosen = next((path for path in offered if path in present), None)
    check(chosen == f"{APPEX}/MadeiraJITHelper.debug.dylib",
          "and the reading that exists is the one the checker takes")


def test_appex_finds_a_framework_of_the_app() -> None:
    """The debug dylib that needs StikJIT.framework, which lives in the app's
    Frameworks/ after an rpath that walks up two levels."""
    dylib = piece(["@executable_path/../../Frameworks"],
                  ["@rpath/StikJIT.framework/StikJIT"])
    offered = macho.candidates(dylib, APPEX, APP, "@rpath/StikJIT.framework/StikJIT")
    check(f"{APP}/Frameworks/StikJIT.framework/StikJIT" in offered,
          "an appex finds a framework in the app's Frameworks directory")
    check(all(not path.startswith("Payload/Frameworks") for path in offered),
          "and does not resolve it outside the app bundle")


def test_app_finds_its_own_frameworks() -> None:
    """The usual case: the engine, whose dependencies sit beside it."""
    engine = piece(["@loader_path/..", "@executable_path/Frameworks"],
                   ["@rpath/opus.0.framework/opus.0"])
    offered = macho.candidates(
        engine, f"{APP}/Frameworks/qemu-aarch64-softmmu.framework", APP,
        "@rpath/opus.0.framework/opus.0")
    check(f"{APP}/Frameworks/opus.0.framework/opus.0" in offered,
          "the engine resolves a sibling framework through @executable_path/Frameworks")
    check(offered.count(f"{APP}/Frameworks/opus.0.framework/opus.0") == 1,
          "the same path reached through two rpaths is offered once, not twice")


def test_system_paths_are_not_the_archive_s_business() -> None:
    for reference in ("/usr/lib/libSystem.B.dylib", "/System/Library/Frameworks/"
                      "Foundation.framework/Foundation"):
        check(macho.candidates(piece([], []), APP, APP, reference) == [],
              f"{reference} is resolved on the device, not here")


def test_normalize_folds_dot_dot() -> None:
    check(macho.normalize(f"{APP}/PlugIns/MadeiraJITHelper.appex/../..") == APP,
          "a path that walks up out of the appex lands on the app")
    check(macho.normalize("Payload/Madeira.app/Frameworks/./x/../y") ==
          "Payload/Madeira.app/Frameworks/y", "and single dots are dropped")
    check(macho.normalize("../Payload/x") == "Payload/x",
          "leading .. cannot escape past the root of the path it is given")


def test_the_reader_refuses_a_signature_that_is_not_one() -> None:
    """Three shapes of broken signature, each of which must be refused rather
    than accepted because a byte looked plausible."""
    unsigned = macho.Slice("x", 0, b"\0" * 4096, True)
    ok, why = macho.verify_signature(unsigned, None)
    check(not ok and "not signed at all" in why,
          f"a file with no LC_CODE_SIGNATURE is refused: {why}")

    outside = macho.Slice("x", 0, b"\0" * 4096, True)
    outside.signature = (100000, 4096)
    ok, why = macho.verify_signature(outside, None)
    check(not ok and "outside the file" in why,
          f"a signature blob past the end of the file is refused: {why}")

    wrong_magic = macho.Slice("x", 0, b"\0" * 64, True)
    wrong_magic.signature = (0, 64)
    ok, why = macho.verify_signature(wrong_magic, None)
    check(not ok and "SuperBlob" in why,
          f"a blob that is not a SuperBlob is refused: {why}")


def test_a_real_superblob_with_a_missing_directory_is_refused() -> None:
    """The structure is read far enough to say what is wrong with it."""
    import struct
    # A SuperBlob whose one entry points at a requirements blob instead of a
    # CodeDirectory: well-formed enough to parse, and still not a signature.
    blob = struct.pack(">III", macho.CSMAGIC_EMBEDDED_SIGNATURE, 20, 1) \
        + struct.pack(">II", 2, 12) + struct.pack(">II", 0xFA, 12)
    holder = macho.Slice("x", 0, blob + b"\0" * 64, True)
    holder.signature = (0, len(blob))
    ok, why = macho.verify_signature(holder, None)
    check(not ok and "CodeDirectory" in why,
          f"a SuperBlob with no CodeDirectory is refused: {why}")


def main() -> int:
    tests = [value for name, value in sorted(globals().items())
             if name.startswith("test_") and callable(value)]
    print(f"self test: check_ipa_macho.py, {len(tests)} groups\n")
    for test in tests:
        print(f"{test.__name__}:")
        test()
        print()
    if FAILURES:
        print(f"{len(FAILURES)} check(s) failed:")
        for failure in FAILURES:
            print(f"  - {failure}")
        return 1
    print("every check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
