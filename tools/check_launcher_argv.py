#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Read the launcher's command line out of the Swift, on a machine with no Mac.

WHY THIS EXISTS
The Linux side of this app ends at a QEMU argument vector. Everything after it
is QEMU - the firmware, the disc, the console - and everything before it is a
UI. So the argument vector is the whole of the code that can be wrong in the
app, and it is the part that was wrong: `LinuxEnginePlan.resolve` handed a
QEMU built with `--enable-tcg-interpreter` the accelerator `tcg,thread=multi`,
QEMU refuses an accelerator it was not built with by printing and calling
`exit(1)`, and inside an app that embeds QEMU that exit *is* the app. The report
was "Ubuntu crashes immediately", and it was exact.

An iPhone is not needed to know whether a command line boots a machine, only to
know whether *that* binary runs it. This file is the first half: it reads
`LinuxMachineConsole.arguments` out of its Swift source, fills in the values a
launch would have filled in, and both checks the result and prints it as JSON.
`tools/boot_smoke.py` is the second half, and it runs exactly what this prints
against a host QEMU with the firmware this app ships. The point of parsing the
Swift instead of writing the same flags a second time is drift: a hand-written
copy is edited by hand, and the workflow that runs it then tests something the
app stopped doing. (tools/mirror_ci.py exists because of the same failure.)

WHAT IT REFUSES TO GUESS
Every value comes from the source or from its caller. An interpolation this
file does not recognise is an error and not an empty string, because a command
line with a hole in it boots nothing and would look like a QEMU bug.

USAGE
  python3 tools/check_launcher_argv.py                       # check, and report
  python3 tools/check_launcher_argv.py --emit-json argv.json # ... and write it
  python3 tools/check_launcher_argv.py --no-jit-core --image guest.iso
  python3 tools/check_launcher_argv.py --self-test           # this file's test

Exit 0 when the command line is one this app can boot, 1 when it is not, 2 when
the source could not be read at all - a different problem, reported apart.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
import tempfile

DEFAULT_SOURCE = pathlib.Path("app/Madeira/Variant/QEMULauncher.swift")
FUNCTION = "static func arguments("

# Every interpolation the function may use, and what fills it. `String(max(1,
# environment.vcpus))` and its memory twin are parsed rather than listed,
# because their defaults are part of the source and are worth reading.
INTERPOLATIONS = {
    "image": "the path of the image being booted",
    "format": "qcow2 or raw, from the image's extension",
    "firmware.code.path": "the read-only UEFI firmware image",
    "writableVars.path": "the writable EFI variables image",
    "consolePath": "the Unix socket the guest's serial console is written to",
    "monitorPath": "the Unix socket QEMU's monitor listens on",
}
DEFERRED = (
    r"sysroot\.appendingPathComponent\((?P<quote>[\"'])(?P<name>[^\"']+)(?P=quote)\)\.path",
    "sysroot.appendingPathComponent(\"...\").path",
)
STRING_MAX = re.compile(r"String\(max\((?P<floor>\d+), environment\.(?P<name>vcpus|ramMiB)\)\)")

# The flags this file knows how to fill. A literal that contains one of these
# names in braces and is not in this table fails the run.
FILLABLE = ("{image}", "{format}", "{firmware_code_path}", "{writableVars_path}",
            "{consolePath}", "{monitorPath}", "{qemu_share}", "{vcpus}", "{ramMiB}")


class SourceError(Exception):
    """The Swift source is not in a shape this file can read."""


# --------------------------------------------------------------------------
# Reading the function out of the Swift


def function_lines(text: str) -> list[str]:
    """The body of `arguments`, by brace depth from its own opening brace."""
    lines = text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if FUNCTION in line:
            start = i
            break
    if start is None:
        raise SourceError(f"no `{FUNCTION}` in the source: the function was renamed, "
                          "and a checker that silently finds nothing is worse than none")
    depth = 0
    opened = False
    body: list[str] = []
    for line in lines[start:]:
        stripped = line.strip()
        # `\(` opens an interpolation, not a block, and none of the ones this
        # function uses contain a brace - but be explicit rather than lucky.
        code = stripped.replace("\\(", "")
        for ch in code:
            if ch == "{":
                depth += 1
                opened = True
            elif ch == "}":
                depth -= 1
        body.append(line)
        if opened and depth == 0:
            break
    return body


def split_elements(expression: str) -> list[str]:
    """Top-level comma split of a `[...]` initialiser, ignoring nesting."""
    out, current, depth, quoted, escaped = [], "", 0, False, False
    for ch in expression:
        if escaped:
            current += ch
            escaped = False
            continue
        if ch == "\\":
            current += ch
            escaped = True
            continue
        if ch == '"':
            quoted = not quoted
            current += ch
            continue
        if not quoted:
            if ch in "([":
                depth += 1
            elif ch in ")]":
                depth -= 1
            elif ch == "," and depth == 0:
                out.append(current.strip())
                current = ""
                continue
        current += ch
    if current.strip():
        out.append(current.strip())
    return out


def bracket_elements(text: str) -> list[str]:
    """The elements of a full `[...]` initialiser, brackets and all."""
    text = text.strip()
    if not (text.startswith("[") and text.endswith("]")):
        raise SourceError(f"expected an array initialiser, found `{text}`")
    return split_elements(text[1:-1])


def unescape_literal(text: str) -> str:
    return text[1:-1].replace('\\"', '"').replace("\\n", "\n")


def interpolations(literal: str) -> list[str]:
    return re.findall(r"\\\(([^()]*(?:\([^()]*\)[^()]*)*)\)", literal)


def substitute(literal: str) -> str:
    """A Swift string literal as a filled value, or a failure.

    `\\(name)` becomes `{name}`, spelled the way FILLABLE spells it, so an
    unknown interpolation cannot quietly become an empty string: it stays in
    the output, and a leftover `{...}` is an error this file raises itself.
    """
    out = ""
    index = 0
    for match in re.finditer(r"\\\(([^()]*(?:\([^()]*\)[^()]*)*)\)", literal):
        out += literal[index:match.start()]
        inner = match.group(1).strip()
        if inner in INTERPOLATIONS:
            out += "{" + inner.replace(".", "_") + "}"
        elif re.fullmatch(DEFERRED[0], inner):
            out += "{qemu_share}"
        else:
            raise SourceError(
                f"the source interpolates `\\({inner})`, which this file does not "
                "know how to fill; teach it rather than letting the command line "
                "keep a hole in it"
            )
        index = match.end()
    out += literal[index:]
    return out


def value_of_element(element: str, found: dict[str, str]) -> str:
    if element.startswith('"') and element.endswith('"'):
        return substitute(unescape_literal(element))
    match = STRING_MAX.fullmatch(element)
    if match:
        key = "{" + match.group("name") + "}"
        found[key] = match.group("floor")
        return key
    if re.fullmatch(DEFERRED[0], element):
        return "{qemu_share}"
    raise SourceError(f"the source builds an argument this file cannot read: `{element}`")


# --------------------------------------------------------------------------
# Building the vector


def build(source_path: pathlib.Path, image: str, jit_core: bool) -> tuple[list[str], dict[str, str]]:
    text = source_path.read_text(encoding="utf-8")
    body = function_lines(text)
    is_iso = image.lower().endswith(".iso")
    argv: list[str] = []
    found: dict[str, str] = {}
    problems: list[str] = []
    branch: str | None = None
    iso_block = 0
    i = 0
    while i < len(body):
        line = body[i].strip()
        i += 1
        if line.startswith("if lower.hasSuffix"):
            iso_block, branch = 1, "iso"
            continue
        if iso_block and line == "} else {":
            branch = "other"
            continue
        if iso_block and line == "}":
            iso_block, branch = 0, None
            continue
        if branch == "iso" and not is_iso:
            continue
        if branch == "other" and is_iso:
            continue
        # The accelerator is a three-line ternary, and the condition is the
        # whole point of this file.
        if line.startswith("a += ") and line.rstrip().endswith("hasJITCore"):
            if "engine == .utm" not in line:
                problems.append(
                    "the accelerator's condition no longer names the engine this "
                    "build actually launches; that is the bug this file exists for"
                )
            multi = single = None
            while i < len(body) and (multi is None or single is None):
                nxt = body[i].strip()
                i += 1
                if nxt.startswith("? "):
                    multi = [value_of_element(e, found)
                             for e in bracket_elements(nxt[1:].strip())]
                elif nxt.startswith(": "):
                    single = [value_of_element(e, found)
                              for e in bracket_elements(nxt[1:].strip())]
                elif nxt and not nxt.startswith(("?", ":")):
                    break
            if multi is None or single is None:
                problems.append("the accelerator ternary no longer has both branches")
                continue
            if not jit_core and "-accel" not in single:
                problems.append("the no-JIT branch is not an accelerator")
            argv += multi if jit_core else single
            continue
        match = re.match(r"a \+= \[(.*)\]\s*$", line)
        if match:
            argv += [value_of_element(e, found) for e in split_elements(match.group(1))]
            continue
        match = re.match(r"var a = \[(.*)\]\s*$", line)
        if match:
            argv += [value_of_element(e, found) for e in split_elements(match.group(1))]
            continue
        if line.startswith("a +="):
            problems.append(f"this file cannot read `{line}`; the arguments moved")
    if problems:
        raise SourceError("; ".join(problems))
    if not argv:
        raise SourceError("the source produced no arguments at all")
    return argv, found


def fill(argv: list[str], values: dict[str, str]) -> list[str]:
    out = []
    for argument in argv:
        filled = argument
        for name, value in values.items():
            filled = filled.replace("{" + name + "}", value)
        left = [token for token in FILLABLE if token in filled]
        if left:
            raise SourceError(f"nothing was given for {', '.join(left)} in `{argument}`")
        out.append(filled)
    return out


# --------------------------------------------------------------------------
# The checks


def value_after(argv: list[str], flag: str) -> str | None:
    if flag in argv:
        index = argv.index(flag)
        if index + 1 < len(argv):
            return argv[index + 1]
    return None


def check(argv: list[str], image: str, writable_vars: str | None, jit_core: bool) -> list[str]:
    """Everything about this command line that would stop a machine booting."""
    bad: list[str] = []

    def need(condition: bool, message: str) -> None:
        if not condition:
            bad.append(message)

    need(argv[0] == "qemu-system-aarch64",
         f"the vector starts with {argv[0]!r}; the machine is qemu-system-aarch64")

    need(value_after(argv, "-M") == "virt",
         "no `-M virt`: an aarch64 guest boots the virt machine or nothing")

    accel = value_after(argv, "-accel")
    wanted = "tcg,thread=multi" if jit_core else "tcg,thread=single"
    need(accel == wanted,
         f"-accel is {accel!r} and this build needs {wanted!r}: QEMU refuses an "
         "accelerator it was not built with by calling exit(), and inside this app "
         "that exits the app - the whole of the \"it crashes immediately\" report")

    pflash = [a for a in argv if a.startswith("if=pflash")]
    code = [a for a in pflash if "readonly=on" in a]
    vars_ = [a for a in pflash if "readonly=on" not in a]
    need(len(code) == 1, f"the UEFI firmware needs exactly one read-only pflash drive, found {len(code)}")
    need(len(vars_) <= 1, "the EFI variables image is one drive")
    if writable_vars:
        need(len(vars_) == 1,
             "a writable EFI variables image was given and the vector has none: the "
             "firmware then cannot remember a boot entry")

    need(value_after(argv, "-display") == "none",
         "`-display none` is how this app draws nothing; a scanout it does not "
         "render would be a second window it cannot show")

    chardevs = [a for a in argv if a.startswith("socket,")]
    need(len(chardevs) == 2, f"the launcher owns two sockets, the vector has {len(chardevs)}")
    for chardev in chardevs:
        need("server=on,wait=off" in chardev,
             f"{chardev.split(',')[1]} is not server=on,wait=off: a blocking accept "
             "at startup is a hang the user cannot tell from a slow boot")
    need(value_after(argv, "-serial") == "chardev:madeira-console",
         "the guest's serial console is not wired to the console socket")
    need(value_after(argv, "-monitor") == "chardev:madeira-monitor",
         "the monitor is not wired to the monitor socket, so Stop has nothing to talk to")

    if image.lower().endswith(".iso"):
        discs = [a for a in argv if "media=cdrom" in a]
        need(len(discs) == 1, "an .iso must be attached as one CD-ROM")
        need(all("readonly=on" in a for a in discs), "a CD-ROM is read-only")
        need(len([a for a in argv if a.startswith("virtio-scsi-pci")]) == 1,
             "the CD-ROM needs a front end that has one: virtio-blk is a disk "
             "device, so media=cdrom on it describes the backend and not what the "
             "guest is given, and the firmware then has a non-removable disk "
             "holding an optical image")
        need(len([a for a in argv if a.startswith("scsi-cd")]) == 1,
             "a virtio-scsi controller with no CD device on it")
        need(not [a for a in argv if a.startswith("virtio-blk-pci")],
             "the .iso is attached to a disk front end as well, which is the "
             "attachment that never boots")
    else:
        disks = [a for a in argv if "if=virtio" in a and "format=" in a]
        need(len(disks) == 1, "a disk image must be attached as one virtio disk")
        if disks:
            wanted_format = "qcow2" if image.lower().endswith(".qcow2") else "raw"
            need(f"format={wanted_format}" in disks[0],
                 f"{image} needs format={wanted_format}: a qcow2 read as raw is a "
                 "corrupt disk")

    share = value_after(argv, "-L")
    need(bool(share) and share.endswith("share/qemu"),
         f"`-L` is {share!r}; QEMU's data files (BIOS images, keymaps) live in the "
         "sysroot's share/qemu and are found nowhere else")

    return bad


# --------------------------------------------------------------------------
# Its own test: a checker that cannot fail is a comment


# (what a wrong edit looks like, the edits that produce it, whether the engine
# has TCG's JIT, the image, and the writable EFI variables image). Each is a
# mistake that ships a machine that does not boot, written as the edit that
# makes it, so the control - the source as it stands - has to pass and every
# mutation has to be refused.
SELF_TEST_CASES = (
    ("the source as it stands is accepted  (control)", (), True, "/tmp/guest.qcow2", None),
    ("the accelerator stops asking about the build", (
        ("engine == .utm && LinuxEngineSupport.hasJITCore",
         "LinuxEngineSupport.hasJITCore"),), False, "/tmp/guest.qcow2", None),
    ("the accelerator branches are the wrong way round", (
        ("tcg,thread=multi", "TEMP_MULTI"),
        ("tcg,thread=single", "tcg,thread=multi"),
        ("TEMP_MULTI", "tcg,thread=single")), False, "/tmp/guest.qcow2", None),
    ("an .iso goes back to a disk front end", (
        ('["-device", "virtio-scsi-pci,id=scsi0"]',
         '["-device", "virtio-blk-pci,drive=cd0"]'),),
     False, "/tmp/guest.iso", None),
    ("the CD-ROM drive arrives read-write", (
        ('media=cdrom,readonly=on', 'media=cdrom'),),
     False, "/tmp/guest.iso", None),
    ("the firmware arrives without a writable variables image", (
        ("if=pflash,format=raw,file=\\(writableVars.path)",
         "if=pflash,format=raw,readonly=on,file=\\(writableVars.path)"),),
     True, "/tmp/guest.qcow2", "/tmp/efi-vars.fd"),
    ("the console socket is asked to wait for its reader", (
        ('"socket,id=madeira-console,path=\\(consolePath),server=on,wait=off"',
         '"socket,id=madeira-console,path=\\(consolePath),server=on"'),), False,
     "/tmp/guest.qcow2", None),
    ("the monitor is not the thing Stop talks to", (
        ('"-monitor", "chardev:madeira-monitor"', '"-monitor", "none"'),),
     False, "/tmp/guest.qcow2", None),
    ("QEMU's data path is dropped", (
        ("a += [\"-L\", sysroot.appendingPathComponent(\"share/qemu\").path]", ""),),
     False, "/tmp/guest.qcow2", None),
    ("a scanout is asked for that nothing draws", (
        ('"-display", "none"', '"-display", "gtk"'),), False,
     "/tmp/guest.qcow2", None),
)


def self_test() -> int:
    """Mutate the real source and require the checks to notice.

    Each case rewrites one thing a real edit would get wrong, in the source
    this file parses, and demands a failure. The first case is the control - the
    source unchanged, which must pass - because a checker that refuses
    everything is as useless as one that refuses nothing.
    """
    failures = 0
    original = DEFAULT_SOURCE.read_text(encoding="utf-8")
    for name, edits, jit_core, image, writable in SELF_TEST_CASES:
        mutated = original
        missing = False
        for old, new in edits:
            if old not in mutated:
                print(f"self test: {name}: SKIPPED, the source no longer contains {old!r}")
                missing = True
                break
            mutated = mutated.replace(old, new, 1)
        if missing:
            failures += 1
            continue
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "QEMULauncher.swift"
            path.write_text(mutated, encoding="utf-8")
            try:
                argv, floors = build(path, image, jit_core)
                argv = fill(argv, {
                    "image": image,
                    "format": "qcow2" if image.lower().endswith(".qcow2") else "raw",
                    "vcpus": floors.get("{vcpus}", "1"),
                    "ramMiB": floors.get("{ramMiB}", "512"),
                    **values_for("/tmp/qemu-ios", writable or "/tmp/qemu-ios/efi-vars.fd",
                                 "/tmp/c.sock", "/tmp/m.sock"),
                })
                bad = check(argv, image, writable, jit_core)
            except SourceError as error:
                bad = [f"the source could not be read: {error}"]
        if edits:
            if bad:
                print(f"self test: {name}: refused - {bad[0][:80]}")
            else:
                print(f"self test: {name}: NOT REFUSED - that check does not work")
                failures += 1
        else:
            if bad:
                print(f"self test: {name}: the real source is refused - {bad[0][:80]}")
                failures += 1
            else:
                print(f"self test: {name}: accepted")
    print(f"self test: {'ok' if not failures else str(failures) + ' case(s) wrong'}")
    return 0 if not failures else 1


def values_for(sysroot: str, writable_vars: str, console: str, monitor: str) -> dict[str, str]:
    """The files a launch would have resolved before it built the vector."""
    return {
        "firmware_code_path": f"{sysroot}/share/qemu/edk2-aarch64-code.fd",
        "writableVars_path": writable_vars,
        "consolePath": console,
        "monitorPath": monitor,
        "qemu_share": f"{sysroot}/share/qemu",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--source", default=str(DEFAULT_SOURCE))
    parser.add_argument("--image", default="/tmp/guest.qcow2")
    parser.add_argument("--sysroot", default="/tmp/qemu-ios",
                        help="where the payload's share/qemu lives")
    parser.add_argument("--writable-vars", default="", help="the EFI variables copy")
    parser.add_argument("--console", default="/tmp/madeira-console.sock")
    parser.add_argument("--monitor", default="/tmp/madeira-monitor.sock")
    parser.add_argument("--vcpus", default="")
    parser.add_argument("--ram", default="")
    parser.add_argument("--jit-core", dest="jit_core", action="store_true", default=None,
                        help="the engine was built with TCG's JIT (the default)")
    parser.add_argument("--no-jit-core", dest="jit_core", action="store_false",
                        help="the engine is TCI: no generated code, no threaded TCG")
    parser.add_argument("--emit-json", default="", help="write the vector here")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    jit_core = True if args.jit_core is None else args.jit_core

    source = pathlib.Path(args.source)
    try:
        argv, floors = build(source, args.image, jit_core)
        argv = fill(argv, {
            "image": args.image,
            "format": "qcow2" if args.image.lower().endswith(".qcow2") else "raw",
            "vcpus": args.vcpus or floors.get("{vcpus}", "1"),
            "ramMiB": args.ram or floors.get("{ramMiB}", "512"),
            **values_for(args.sysroot, args.writable_vars or f"{args.sysroot}/efi-vars.fd",
                         args.console, args.monitor),
        })
    except SourceError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    print(f"source: {source}")
    print(f"image:  {args.image}")
    print(f"engine: {'TCG with its JIT' if jit_core else 'TCG interpreter (no JIT)'}")
    print()
    for index, argument in enumerate(argv):
        print(f"  {index:2}  {argument}")

    bad = check(argv, args.image, args.writable_vars, jit_core)
    print()
    for problem in bad:
        print("ERROR: " + problem)
    print("verdict:", "booting" if not bad else "NOT booting")

    if args.emit_json:
        pathlib.Path(args.emit_json).write_text(
            json.dumps({"argv": argv, "image": args.image, "jit_core": jit_core,
                        "problems": bad}, indent=2) + "\n", encoding="utf-8")
        print(f"wrote {args.emit_json}")
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
