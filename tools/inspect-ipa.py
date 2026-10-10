#!/usr/bin/env python3
"""Report what is actually inside an .ipa, and whether anything can install it.

Written because "the IPA is corrupt" is a guess until something reads it. Every
claim here comes out of the file: the zip's own integrity, the layout under
Payload/, the architecture of the bundle's executable, nested bundles, symlinks
(including ones that point outside the bundle), the total unpacked size, the
largest entries, and the files the app's two capabilities are made of.

WHY THE SIZE IS A CHECK AND NOT A STATISTIC
Build-8 (2026-10-10) unpacked to 3.5 GiB in 14,136 entries and SideStore refused
to sign it: a sideloader walks the whole tree to re-sign every Mach-O, and what
it reported named a slice because that is where the walk stopped. A green build
produced an app nobody could install, so the archive's own shape is now part of
whether the build is allowed to publish.

WHY THE CAPABILITY FILES ARE CHECKED
The app asks a question and answers it by looking for a file -
`DockInstallers.bundleHas32Bit` is `i386-windows/ntdll.dll`, and
`LinuxBootCheck.engineURL` is the engine framework. A build that resumes
treating a missing payload as a warning produces an IPA that opens and then
cannot run what it offers, which is exactly the report this tool was written
from. So the artifact itself has to contain them.

Usage:  python3 tools/inspect-ipa.py <path.ipa>
Exit 0 if the archive is structurally usable, 1 if something is wrong.
"""

from __future__ import annotations

import collections
import os
import plistlib
import struct
import sys
import zipfile

FAT_MAGIC = (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf")

CPU_NAMES = {
    7: "x86",
    0x01000007: "x86_64",
    12: "arm",
    0x0100000C: "arm64",
    0x0200000C: "arm64_32",
}

def _limit_mib(variable: str, default: int) -> int:
    """A size limit, overridable so the gate itself can be tested.

    The real limits are megabytes, and writing a multi-gigabyte archive into a
    self test to trip one is not a test anybody would keep running. The default
    is what a build is held to; the override exists for
    tools/self_test_inspect_ipa.py.
    """
    raw = os.environ.get(variable, "").strip()
    if not raw:
        return default * 1024 * 1024
    try:
        return int(raw) * 1024 * 1024
    except ValueError:
        print(f"ignoring {variable}={raw!r}: not a number")
        return default * 1024 * 1024


# A sideloader unpacks the IPA, re-signs every Mach-O and repacks it, on the
# device. These are the sizes at which that stops working in practice, not
# theoretical limits: the archive that failed was 3.5 GiB unpacked, and the one
# this tool was written against is 876 MiB.
MAX_UNPACKED_BYTES = _limit_mib("MADEIRA_IPA_MAX_UNPACKED_MIB", 1500)
MAX_IPA_BYTES = _limit_mib("MADEIRA_IPA_MAX_IPA_MIB", 500)
# Above this entry count the re-signing walk is the slow part of an install.
MANY_ENTRIES = 5000
# Two files this size or more are large enough that a repeat is worth naming.
DUPLICATE_FLOOR = 32 * 1024 * 1024

# What the app promises, and the file that promise is made of. Each entry is
# (what it is, path inside the app bundle, where the file comes from). The
# Windows set is one group: without any of the three the 32-bit farm cannot
# start, and the fourth is FEX's own translator for the 64-bit half.
CAPABILITIES = [
    (
        "32-bit Windows programs",
        "i386-windows/ntdll.dll",
        "build/ci/fetch-payload.sh i386-windows.tar.gz (payloads.yml)",
    ),
    (
        "the WoW64 layer",
        "aarch64-windows/wow64.dll",
        "the tracked aarch64-windows/ tree",
    ),
    (
        "WoW64's window layer",
        "aarch64-windows/wow64win.dll",
        "the tracked aarch64-windows/ tree",
    ),
    (
        "FEX's Windows x86-64 translator",
        "arm64ec-windows/xtajit64.dll",
        "the tracked arm64ec-windows/ tree",
    ),
    (
        "the QEMU engine",
        "qemu-ios/Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu",
        "build/ci/fetch-payload.sh qemu-ios-tci-arm64.tar.gz (linux-engine.yml)",
    ),
    (
        "the UEFI firmware a guest boots from",
        "qemu-ios/share/qemu/edk2-aarch64-code.fd",
        "the same payload, kept by build/ci/trim-qemu-sysroot.sh",
    ),
]

# The frameworks the engine's own load commands name. The trim script checks
# these on the sysroot; checked again here because the trim runs before the
# bundle is built, and this is the file that is published.
ENGINE_DEPENDENCIES = [
    "glib-2.0.0", "gobject-2.0.0", "gio-2.0.0", "gmodule-2.0.0",
    "pixman-1.0", "jpeg.62", "epoxy.0", "zstd.1", "slirp.0",
    "spice-server.1", "virglrenderer.1",
]

ERRORS: list[str] = []


def fail(message: str) -> None:
    ERRORS.append(message)


def macho_slices(data: bytes) -> tuple[list[str], str]:
    """(architectures, kind) for the Mach-O at the start of `data`."""
    if len(data) < 8:
        return [], "too short to be a Mach-O"
    magic = data[:4]
    if magic in FAT_MAGIC:
        count = struct.unpack(">I", data[4:8])[0]
        wide = 32 if magic == FAT_MAGIC[1] else 20
        arches = []
        for i in range(count):
            off = 8 + i * wide
            if off + wide > len(data):
                break
            cpu = struct.unpack(">i", data[off : off + 4])[0]
            arches.append(CPU_NAMES.get(cpu, hex(cpu)))
        return arches, "fat"
    if magic in (b"\xce\xfa\xed\xfe", b"\xcf\xfa\xed\xfe"):
        cpu = struct.unpack("<i", data[4:8])[0]
        return [CPU_NAMES.get(cpu, hex(cpu))], "thin"
    if magic in (b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf"):
        cpu = struct.unpack(">i", data[4:8])[0]
        return [CPU_NAMES.get(cpu, hex(cpu))], "thin"
    return [], "not a Mach-O"


def is_symlink(info: zipfile.ZipInfo) -> bool:
    return (info.external_attr >> 16) & 0o170000 == 0o120000


def bundle_paths(infos: list[zipfile.ZipInfo]) -> list[str]:
    """Every nested bundle, by the path a signer has to walk into."""
    found = set()
    for info in infos:
        parts = info.filename.split("/")
        for depth in range(len(parts)):
            if parts[depth].endswith((".appex", ".framework")):
                found.add("/".join(parts[: depth + 1]))
    return sorted(found)


def app_executable(z: zipfile.ZipFile, app: str) -> str:
    """The name Info.plist gives the bundle's executable.

    Read rather than assumed: the bundle is `Madeira.app` and its executable is
    `Madeira`, and a first version of this file looked for
    `Payload/Madeira.app/Madeira.app` and rejected a perfectly good archive -
    which is the check working, on itself.
    """
    try:
        with z.open(f"Payload/{app}/Info.plist") as f:
            plist = plistlib.load(f)
        name = plist.get("CFBundleExecutable")
        if name:
            return name
    except (KeyError, plistlib.InvalidFileException, ValueError):
        pass
    return app[:-4] if app.endswith(".app") else app


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 1
    path = sys.argv[1]

    with zipfile.ZipFile(path) as z:
        infos = z.infolist()
        files = {i.filename for i in infos if not i.is_dir()}
        unpacked = sum(i.file_size for i in infos)
        print(f"archive: {path}")
        print(f"entries: {len(infos)}")
        print(f"unpacked: {unpacked / 1024 / 1024:.1f} MiB in {len(infos)} entries")

        bad = z.testzip()
        if bad is not None:
            fail(f"the zip fails its own integrity check at {bad}")
        else:
            print("zip integrity: ok")

        app_dirs = sorted(
            {
                i.filename.split("/")[1]
                for i in infos
                if i.filename.startswith("Payload/") and len(i.filename.split("/")) > 2
            }
        )
        print(f"apps: {app_dirs}")
        if len(app_dirs) != 1:
            fail(f"an IPA installs exactly one app; this one has {app_dirs}")
        app = app_dirs[0] if app_dirs else ""

        nested = bundle_paths(infos)
        print(f"nested bundles: {len(nested)}")
        for n in nested[:12]:
            print(f"  {n}")
        if len(nested) > 12:
            print(f"  ... and {len(nested) - 12} more")

        if app:
            executable = app_executable(z, app)
            try:
                with z.open(f"Payload/{app}/{executable}") as f:
                    arches, kind = macho_slices(f.read(4096))
                print(f"main executable: {executable}, {kind} {arches}")
                if "arm64" not in arches:
                    fail(f"the main executable has no arm64 slice ({arches}); no iPhone can run it")
            except KeyError:
                fail(f"Payload/{app}/{executable} is not in the archive")

        symlinks = [i for i in infos if is_symlink(i)]
        print(f"symlinks: {len(symlinks)}")
        for info in symlinks:
            with z.open(info) as f:
                target = f.read().decode("utf-8", "replace")
            depth = info.filename.count("/") - 1
            if target.startswith("/") or target.count("../") > depth:
                fail(f"{info.filename} -> {target} escapes the bundle")

        # What the app claims it can do, and whether the files are there.
        if app:
            print("capabilities:")
            for what, relative, source in CAPABILITIES:
                if f"Payload/{app}/{relative}" in files:
                    print(f"  ok      {what}")
                else:
                    print(f"  MISSING {what}")
                    fail(f"{what}: Payload/{app}/{relative} is absent; it comes from {source}")
            for dependency in ENGINE_DEPENDENCIES:
                relative = f"qemu-ios/Frameworks/{dependency}.framework/{dependency}"
                if f"Payload/{app}/{relative}" not in files:
                    fail(f"the engine names {dependency} and Payload/{app}/{relative} is absent")

        sizes = collections.Counter()
        for info in infos:
            if not info.is_dir() and info.file_size >= DUPLICATE_FLOOR:
                sizes[info.file_size] += 1
        for size, count in sizes.items():
            if count > 1:
                # Same size, not necessarily the same content: the firmware
                # images for different machines are all 64 MiB, and the payload
                # that could not be installed carried 188 MiB cores twice.
                print(
                    f"note: {count} entries of {size / 1024 / 1024:.1f} MiB "
                    "(the same size: a duplicated payload, or same-size images)"
                )

        big = sorted(infos, key=lambda i: i.file_size, reverse=True)[:10]
        for i in big:
            if i.file_size >= 1024 * 1024:
                print(f"  {i.file_size / 1024 / 1024:8.1f} MiB  {i.filename}")

        # The checks about whether the file can be installed, which is the only
        # thing an IPA is for.
        if unpacked > MAX_UNPACKED_BYTES:
            fail(
                f"the archive unpacks to {unpacked / 1024 ** 3:.2f} GiB, over the "
                f"{MAX_UNPACKED_BYTES / 1024 ** 3:.2f} GiB a sideloader can re-sign in place"
            )
        if len(infos) > MANY_ENTRIES:
            print(f"note: {len(infos)} entries is a long walk for a re-signing sideloader")

    compressed = os.path.getsize(path)
    print(f"ipa: {compressed / 1024 / 1024:.1f} MiB compressed")
    if compressed > MAX_IPA_BYTES:
        fail(
            f"the IPA is {compressed / 1024 / 1024:.0f} MB, over the "
            f"{MAX_IPA_BYTES // 1024 // 1024} MB a sideloader handles reliably"
        )

    print()
    for e in ERRORS:
        print("ERROR: " + e)
    print("verdict:", "usable" if not ERRORS else "NOT usable")
    return 0 if not ERRORS else 1


if __name__ == "__main__":
    sys.exit(main())
