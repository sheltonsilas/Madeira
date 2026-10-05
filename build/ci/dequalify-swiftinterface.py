#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
#
# Rewrite the qualified type names in a .swiftinterface so that a compiler older
# than the one that printed them can read the module.
#
# Why this is needed at all: app/Frameworks/StikJIT.xcframework ships interfaces
# printed by Swift 6.4, which writes protocol and type references as
# `Module::Type`:
#
#     public struct DDIPaths : Swift::Sendable {
#     public enum StikJITError : Swift::Error, Foundation::LocalizedError {
#
# Swift 6.3 -- which is what Xcode 26.3, the newest Xcode on GitHub's macOS
# runners, contains -- cannot parse that at all. The build fails before it
# compiles a line of Madeira:
#
#     arm64-apple-ios.private.swiftinterface:12:31: error: expected '{' in struct
#     public struct DDIPaths : Swift::Sendable {
#                                   ^
#
# The framework has no binary .swiftmodule, only the interfaces, so the
# interfaces are the only description of the module the app imports. Rewriting
# them is therefore the difference between an app that builds and one that does
# not. The rewrite is mechanical and meaning-preserving: `Module::Type` and
# `Type` name the same declaration, and every name here is unambiguous in its
# own scope (the file is one module's API).
#
# Usage: build/ci/dequalify-swiftinterface.py <file> [<file> ...]
import re
import sys

# The wording avoids `Word::Word` on purpose: this text is inserted before the
# replacements run are complete for a caller that passes the file twice, and the
# qualified-name pattern would eat a literal example of itself out of the
# comment. It is stated in words instead.
HEADER = (
    "// MADEIRA: this interface was printed by Swift 6.4, whose qualified names\n"
    "// put the module and two colons in front of the type they name. No shipped\n"
    "// Xcode (26.3 is the newest on GitHub's runners) can parse that: it fails\n"
    "// with \"expected '{' in struct\" on the first conformance clause. The\n"
    "// qualified names were removed mechanically by\n"
    "// build/ci/dequalify-swiftinterface.py, which names the same declarations;\n"
    "// the module's API is unchanged. Re-run that script if this framework is\n"
    "// ever replaced with a new build from upstream.\n"
)

# Inside `public enum StikJIT`, Swift 6.4 wrote references to the enum's own
# nested types in a doubly qualified form that is nonsense as text --
# `StikJIT::StikJIT.StikJIT::Configuration`. Dequalifying that to
# `StikJIT.StikJIT.Configuration` would lean on the compiler resolving the first
# `StikJIT` as the module rather than as the type of the same name, which is
# exactly the ambiguity the printed form was working around. These four appear
# only inside the enum body, where the plain name is the nested type.
IN_ENUM = {
    b"StikJIT::StikJIT.StikJIT::Configuration": b"Configuration",
    b"StikJIT::StikJIT.StikJIT::Script": b"Script",
    b"StikJIT::StikJIT.StikJIT::PreparationStage": b"PreparationStage",
    b"StikJIT::StikJIT.StikJIT::DeviceSecurityState": b"DeviceSecurityState",
    b"StikJIT::StikJIT.StikJIT::JITReadiness": b"JITReadiness",
    # What the first pass leaves behind for the one reference that was not in
    # the map above: `StikJIT::StikJIT.StikJIT::JITReadiness` loses both
    # `StikJIT::` prefixes and keeps the middle `.StikJIT`. Same reasoning as
    # above -- this is inside the enum body, where the plain name is right.
    b"StikJIT.JITReadiness": b"JITReadiness",
}

QUALIFIED = re.compile(rb"(?<![A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)::")
# The marker carries no line ending on purpose: these files are checked out with
# CRLF on Windows and LF in the index, and a marker with one of the two matched
# neither. The comment is inserted after the marker's line instead.
IMPORTS = b"import _SwiftConcurrencyShims"


def fix(path: str) -> int:
    with open(path, "rb") as fh:
        text = fh.read()
    eol = b"\r\n" if b"\r\n" in text[:200] else b"\n"
    header = HEADER.replace("\n", eol.decode()).encode()
    # Re-runnable on purpose: a second pass must be harmless (it is what fixes
    # a leftover from an earlier version of this script), so the replacements
    # always run and only the header is inserted once.
    already = header in text
    original = text
    for old, new in IN_ENUM.items():
        text = text.replace(old, new)
    text, n = QUALIFIED.subn(rb"", text)
    at = text.find(IMPORTS)
    if at < 0:
        print(f"{path}: unexpected interface (no import block); refusing to guess", file=sys.stderr)
        return 2
    end_of_line = text.find(b"\n", at)
    if end_of_line < 0:
        print(f"{path}: unexpected interface (import block does not end a line)", file=sys.stderr)
        return 2
    if not already:
        text = text[: end_of_line + 1] + header + text[end_of_line + 1:]
    if text == original:
        print(f"{path}: nothing to do")
        return 0
    with open(path, "wb") as fh:
        fh.write(text)
    print(f"{path}: removed {n} qualified name(s), {len(IN_ENUM)} enum-local form(s) normalised")
    return 0


def main(argv):
    if len(argv) < 2:
        print(__doc__ or "usage: dequalify-swiftinterface.py <file> ...", file=sys.stderr)
        return 2
    rc = 0
    for path in argv[1:]:
        rc |= fix(path)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
