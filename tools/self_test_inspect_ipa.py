#!/usr/bin/env python3
"""Check that tools/inspect-ipa.py accepts a usable IPA and rejects a broken one.

The inspector decides whether the build is allowed to publish an IPA, so a hole
in it ships an app nobody can install - which is exactly what happened. Tested
against archives built here rather than against the real IPA, because the point
is the verdict on each shape of failure, and the shapes are cheap to write:

  * a small, well-formed archive                 -> usable
  * a main executable with no arm64 slice        -> NOT usable
  * a symlink that points outside the bundle     -> NOT usable
  * more than one app in Payload/                -> NOT usable
  * an archive that unpacks past the limit       -> NOT usable

Usage:  python3 tools/self_test_inspect_ipa.py
Exit 0 when the inspector behaves, 1 when it does not.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import struct
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
INSPECTOR = os.path.join(HERE, "inspect-ipa.py")
APP = "Madeira.app"


def macho(cpu: int) -> bytes:
    """A Mach-O 64 header for `cpu`, which is all the inspector reads."""
    return struct.pack("<4siiIIIII", b"\xcf\xfa\xed\xfe", cpu, 0, 6, 0, 0, 0, 0)


ARM64 = 0x0100000C
X86_64 = 0x01000007


def write_ipa(path: str, *, cpu: int = ARM64, extra: bool = False, escape: bool = False,
              second_app: bool = False, padding_mib: int = 0) -> None:
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr(f"Payload/{APP}/", b"")
        z.writestr(f"Payload/{APP}/{APP}", macho(cpu))
        plist = (
            b'<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>'
            b"<key>CFBundleExecutable</key><string>" + APP.split(".")[0].encode() + b"</string>"
            b"</dict></plist>\n"
        )
        z.writestr(f"Payload/{APP}/Info.plist", plist)
        if second_app:
            z.writestr("Payload/Other.app/Other", macho(cpu))
        if escape:
            info = zipfile.ZipInfo(f"Payload/{APP}/escape")
            info.external_attr = (0o120777 << 16)
            z.writestr(info, b"../../../../etc/passwd")
        if padding_mib:
            z.writestr(f"Payload/{APP}/padding", b"\0" * (padding_mib * 1024 * 1024))
        if extra:
            z.writestr(f"Payload/{APP}/resources/blob.bin", b"x" * 4096)


def run(path: str, limits: dict[str, str] | None = None) -> tuple[int, str]:
    environment = dict(os.environ)
    environment.update(limits or {})
    done = subprocess.run(
        [sys.executable, INSPECTOR, path], capture_output=True, text=True, env=environment
    )
    return done.returncode, done.stdout + done.stderr


def main() -> int:
    failures: list[str] = []
    work = tempfile.mkdtemp()
    try:
        good = os.path.join(work, "good.ipa")
        write_ipa(good, extra=True)
        status, output = run(good)
        if status != 0:
            failures.append(f"a well-formed archive was rejected ({status}):\n{output}")

        # The size check is the one a small archive cannot trip on its own, so
        # the limit is lowered for that case rather than a gigabyte written to
        # disk: the override exists in inspect-ipa.py for exactly this.
        cases = [
            ("no arm64 slice", dict(cpu=X86_64), None, "arm64"),
            ("a symlink out of the bundle", dict(escape=True), None, "escapes the bundle"),
            ("two apps", dict(second_app=True), None, "exactly one app"),
            ("too big to re-sign", dict(padding_mib=4),
             {"MADEIRA_IPA_MAX_UNPACKED_MIB": "1"}, "sideloader"),
        ]
        for name, kwargs, limits, expected in cases:
            path = os.path.join(work, name.replace(" ", "_") + ".ipa")
            write_ipa(path, **kwargs)
            status, output = run(path, limits)
            if status == 0:
                failures.append(f"{name}: accepted, and it must not be:\n{output}")
                continue
            if expected not in output:
                failures.append(f"{name}: rejected for the wrong reason (no {expected!r}):\n{output}")

        # And a lowered limit must not reject the good archive by accident, or
        # the case above would pass for the wrong reason.
        status, output = run(good, {"MADEIRA_IPA_MAX_UNPACKED_MIB": "64"})
        if status != 0:
            failures.append(f"the override rejected a small archive:\n{output}")
        if "unpacked:" not in output or "verdict:" not in output:
            failures.append("the report does not state the unpacked size and a verdict")
    finally:
        shutil.rmtree(work, ignore_errors=True)

    for f in failures:
        print("FAIL: " + f)
    print("self test:", "ok" if not failures else f"{len(failures)} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
