#!/usr/bin/env python3
"""Check that tools/inspect-ipa.py accepts a usable IPA and rejects a broken one.

The inspector decides whether the build is allowed to publish an IPA, so a hole
in it ships an app nobody can install - which is exactly what happened. Tested
against archives built here rather than against the real one, because the point
is the verdict on each shape of failure, and the shapes are cheap to write:

  * a well-formed archive                          -> usable
  * a main executable with no arm64 slice          -> NOT usable
  * a symlink that points outside the bundle       -> NOT usable
  * more than one app in Payload/                  -> NOT usable
  * an archive that unpacks past the limit         -> NOT usable
  * no 32-bit farm, no engine framework, no UEFI   -> NOT usable each

The layout written here is the real one, and that is not incidental: a first
version of the inspector looked for an executable named after the bundle
(`Madeira.app/Madeira.app`) and rejected the app it was written for. The bundle
is `Madeira.app`; its executable is `Madeira`, as its Info.plist says, and this
file writes exactly that.

Usage:  python3 tools/self_test_inspect_ipa.py
Exit 0 when the inspector behaves, 1 when it does not.
"""

from __future__ import annotations

import os
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
INSPECTOR = os.path.join(HERE, "inspect-ipa.py")
APP = "Madeira.app"
EXECUTABLE = "Madeira"

ARM64 = 0x0100000C
X86_64 = 0x01000007

# The files the capability checks look for, as the real bundle holds them.
CAPABILITY_FILES = [
    "i386-windows/ntdll.dll",
    "aarch64-windows/wow64.dll",
    "aarch64-windows/wow64win.dll",
    "arm64ec-windows/xtajit64.dll",
    "qemu-ios/Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu",
    "qemu-ios/share/qemu/edk2-aarch64-code.fd",
]
ENGINE_DEPENDENCIES = [
    "glib-2.0.0", "gobject-2.0.0", "gio-2.0.0", "gmodule-2.0.0",
    "pixman-1.0", "jpeg.62", "epoxy.0", "zstd.1", "slirp.0",
    "spice-server.1", "virglrenderer.1",
]


def macho(cpu: int) -> bytes:
    """A Mach-O 64 header for `cpu`, which is all the inspector reads."""
    return struct.pack("<4siiIIIII", b"\xcf\xfa\xed\xfe", cpu, 0, 6, 0, 0, 0, 0)


def write_ipa(path: str, *, cpu: int = ARM64, escape: bool = False,
              second_app: bool = False, padding_mib: int = 0,
              drop: tuple[str, ...] = ()) -> None:
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr(f"Payload/{APP}/", b"")
        z.writestr(f"Payload/{APP}/{EXECUTABLE}", macho(cpu))
        z.writestr(
            f"Payload/{APP}/Info.plist",
            plistlib.dumps({"CFBundleExecutable": EXECUTABLE, "CFBundleIdentifier": "com.example.madeira"}),
        )
        for relative in CAPABILITY_FILES + [
            f"qemu-ios/Frameworks/{d}.framework/{d}" for d in ENGINE_DEPENDENCIES
        ]:
            if relative in drop:
                continue
            z.writestr(f"Payload/{APP}/{relative}", b"payload")
        if second_app:
            z.writestr("Payload/Other.app/Other", macho(cpu))
        if escape:
            info = zipfile.ZipInfo(f"Payload/{APP}/escape")
            info.external_attr = 0o120777 << 16
            z.writestr(info, b"../../../../etc/passwd")
        if padding_mib:
            z.writestr(f"Payload/{APP}/padding", b"\0" * (padding_mib * 1024 * 1024))


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
        def check(name: str, *, expect_ok: bool, contains: str | None = None, **kwargs) -> None:
            path = os.path.join(work, name.replace(" ", "_").replace("/", "-") + ".ipa")
            limits = kwargs.pop("limits", None)
            write_ipa(path, **kwargs)
            status, output = run(path, limits)
            if expect_ok and status != 0:
                failures.append(f"{name}: rejected a usable archive:\n{output}")
            if not expect_ok and status == 0:
                failures.append(f"{name}: accepted, and it must not be:\n{output}")
            if contains and contains not in output:
                failures.append(f"{name}: rejected for the wrong reason (no {contains!r}):\n{output}")

        check("a well formed archive", expect_ok=True)

        # The layout the real bundle has: the bundle's name is not its
        # executable's, and a check that confuses them rejects everything.
        check("a foreign architecture", expect_ok=False, contains="arm64", cpu=X86_64)
        check("a symlink out of the bundle", expect_ok=False, contains="escapes the bundle", escape=True)
        check("two apps", expect_ok=False, contains="exactly one app", second_app=True)
        check("too big to re-sign", expect_ok=False, contains="sideloader",
              padding_mib=4, limits={"MADEIRA_IPA_MAX_UNPACKED_MIB": "1"})
        check("no 32-bit farm", expect_ok=False, contains="i386-windows/ntdll.dll",
              drop=("i386-windows/ntdll.dll",))
        check("no engine", expect_ok=False, contains="qemu-aarch64-softmmu",
              drop=("qemu-ios/Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu",))
        check("no UEFI firmware", expect_ok=False, contains="edk2-aarch64-code.fd",
              drop=("qemu-ios/share/qemu/edk2-aarch64-code.fd",))
        check("no engine dependency", expect_ok=False, contains="glib-2.0.0",
              drop=("qemu-ios/Frameworks/glib-2.0.0.framework/glib-2.0.0",))

        # A lowered limit must not reject the good archive, or the size case
        # above would pass for the wrong reason.
        good = os.path.join(work, "small.ipa")
        write_ipa(good)
        status, output = run(good, {"MADEIRA_IPA_MAX_UNPACKED_MIB": "16"})
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
