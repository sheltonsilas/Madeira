#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
#
# check_swift_balance.py - brace, bracket and paren balance for the Swift sources.
#
# WHY THIS EXISTS
# These files are edited on a machine with no Swift compiler and no Xcode, so the
# first thing that can compile them is a macOS runner twenty minutes and one push
# away. An unbalanced brace is the most common way to throw that away: the
# compiler reports it as a cascade of errors at the end of the file, which reads
# like something else entirely.
#
# WHAT IT IS NOT
# It is not a parser. It counts delimiters while skipping comments and string
# literals, and it fails a file whose nesting ever goes negative or never returns
# to zero. That catches an edit that closed one brace too many or too few - the
# mistake this is for - and nothing subtler. A file that passes is not
# necessarily valid Swift, and a file that fails is worth reading before pushing.
#
# HOW STRINGS ARE HANDLED
# Swift nests quotes inside interpolation: "\(f("x"))" is legal, and a naive
# quote toggle ends the string at the second quote and then treats the rest of the
# line as code. So the scanner keeps a stack of contexts rather than a flag:
#
#   string        inside a literal;  \( pushes an interpolation context
#   multi         inside a """ block; the next """ ends it
#   paren         a ( ..., marked when it is the () of an interpolation
#   brace, bracket
#
# An interpolation is a paren context pushed *on top of* the string it came from,
# so when its ) arrives the string is still underneath and scanning resumes in it
# with no special case. Raw strings (#"...") are not understood; none are used in
# this tree, and a file that needs one will be reported as an unclosed string
# rather than quietly miscounted.
#
# USAGE
#   python3 tools/check_swift_balance.py            # every .swift in the repo
#   python3 tools/check_swift_balance.py app/Madeira/ContentView.swift

from __future__ import annotations

import argparse
import pathlib
import sys

CLOSE_FOR = {"{": "}", "[": "]", "(": ")", '"': '"'}


def scan(text: str, path: str) -> list[str]:
    problems: list[str] = []
    # Each entry: (kind, line, is_interpolation)
    stack: list[tuple[str, int, bool]] = []
    line = 1
    i = 0
    n = len(text)

    while i < n:
        ch = text[i]

        if ch == "\n":
            line += 1
            i += 1
            continue

        kind = stack[-1][0] if stack else ""

        if kind == "multi":
            if text.startswith('"""', i):
                stack.pop()
                i += 3
                continue
            i += 1
            continue

        if kind == "string":
            if ch == "\\":
                if i + 1 < n and text[i + 1] == "(":
                    stack.append(("paren", line, True))
                    i += 2
                    continue
                i += 2  # an escape, including \" and \\
                continue
            if ch == '"':
                stack.pop()
                i += 1
                continue
            i += 1
            continue

        # --- code ---
        if text.startswith('"""', i):
            stack.append(("multi", line, False))
            i += 3
            continue

        if text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
            continue

        if text.startswith("/*", i):
            depth = 1
            i += 2
            while i < n and depth:
                if text.startswith("/*", i):
                    depth += 1
                    i += 2
                elif text.startswith("*/", i):
                    depth -= 1
                    i += 2
                else:
                    if text[i] == "\n":
                        line += 1
                    i += 1
            continue

        if ch == '"':
            stack.append(("string", line, False))
            i += 1
            continue

        if ch in ("{", "[", "("):
            stack.append(("brace" if ch == "{" else "bracket" if ch == "[" else "paren", line, False))
            i += 1
            continue

        if ch in ("}", "]", ")"):
            if not stack:
                problems.append(f"{path}:{line}: a '{ch}' closes nothing")
                i += 1
                continue
            kind, opened_at, _ = stack.pop()
            expected = {"brace": "}", "bracket": "]", "paren": ")", "string": '"'}[kind]
            if expected != ch:
                problems.append(
                    f"{path}:{line}: '{ch}' closes the {kind} opened on line {opened_at}"
                )
            i += 1
            continue

        i += 1

    for kind, opened_at, _ in stack:
        problems.append(f"{path}:{opened_at}: an unclosed {kind}")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", help="files or directories; default the whole repo")
    args = parser.parse_args()

    root = pathlib.Path(__file__).resolve().parent.parent
    if args.paths:
        targets: list[pathlib.Path] = []
        for raw in args.paths:
            candidate = pathlib.Path(raw)
            if not candidate.is_absolute():
                candidate = root / candidate
            if candidate.is_dir():
                targets.extend(sorted(candidate.rglob("*.swift")))
            elif candidate.is_file():
                targets.append(candidate)
            else:
                print(f"ERROR: {raw} not found", file=sys.stderr)
                return 1
    else:
        targets = sorted(p for p in root.rglob("*.swift") if ".git" not in p.parts)

    problems: list[str] = []
    for path in targets:
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        problems.extend(scan(text, str(path.relative_to(root))))

    if problems:
        for problem in problems:
            print(problem)
        print(f"\n{len(problems)} problem(s) in {len(targets)} file(s)")
        return 1

    print(f"delimiters balance in {len(targets)} Swift file(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
