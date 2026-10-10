#!/usr/bin/env python3
"""Fail on a comment sitting inside a backslash-continued command.

WHY THIS EXISTS
---------------
In bash, a backslash-newline is removed before the line is tokenised, so this

    cmake -S src \\
        -DSOMETHING=ON \\
        # explain why
        -DTUNE_CPU=none

is one logical line by the time comment processing happens. The `#` then begins
a word, so everything after it *on that logical line* is a comment -- and the
rest of the command is silently dropped. `-DTUNE_CPU=none` never reaches cmake.

That is not hypothetical. It is how the ENABLE_FEX_ALLOCATOR change first
shipped: an explanation placed between two arguments dropped both
`-DENABLE_FEX_ALLOCATOR=ON` and `-DTUNE_CPU=none`, and the CI run died in FEX's
configure with a missing /proc/cpuinfo because TUNE_CPU had quietly gone back to
"native". The failure appeared 20 minutes into a macOS run, in a file whose
"options" were still there to read, and `bash -n` passes it because it is valid
syntax. `bash -n` is not a semantic check.

Twenty seconds here, versus a full native-chain rebuild there.

Usage: python3 tools/check_shell_continuations.py [dir ...]
       (default: the whole repo; exit 0 = clean)
"""

import io
import os
import sys

BACKSLASH = chr(92)
SKIP_DIRS = {".git", "node_modules", "toolchains", "research"}


def shell_files(roots):
    for root in roots:
        if os.path.isfile(root):
            yield root
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for name in filenames:
                if name.endswith((".sh", ".bash")):
                    yield os.path.join(dirpath, name)


def check(path):
    problems = []
    try:
        text = io.open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return problems
    lines = text.split("\n")
    for i, line in enumerate(lines[:-1]):
        if not line.rstrip().endswith(BACKSLASH):
            continue
        # The continuation is live; walk forward while it lasts and report the
        # first comment. (One is enough: the first one already eats the rest.)
        j = i
        while j < len(lines) - 1 and lines[j].rstrip().endswith(BACKSLASH):
            nxt = lines[j + 1]
            if nxt.lstrip().startswith("#"):
                problems.append((j + 2, lines[j].strip()[:60], nxt.strip()[:60]))
                break
            j += 1
    return problems


def main(argv):
    roots = argv[1:] or ["."]
    total = 0
    for path in sorted(set(shell_files(roots))):
        for lineno, continued, comment in check(path):
            total += 1
            print("::error file=%s,line=%d::comment inside a continued command "
                  "(the rest of this command is dropped)" % (path, lineno))
            print("    continued: %s" % continued)
            print("    comment  : %s" % comment)
    if total:
        print("\n%d comment(s) inside a continued command." % total)
        print("Move each one above the command: bash discards the remainder of "
              "the logical line, and `bash -n` cannot see it.")
        return 1
    print("shell continuations: clean")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
