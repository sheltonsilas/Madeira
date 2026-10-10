#!/usr/bin/env python3
"""Report what is actually inside an .ipa, and whether anything can install it.

Written because "the IPA is corrupt" is a guess until something reads it. Every
claim here comes out of the file: the zip's own integrity, the layout under
Payload/, each Mach-O's header (thin or fat, and which architectures), nested
bundles, symlinks (including ones that point outside the bundle), the total
unpacked size, and the largest entries.

WHY THE SIZE IS A CHECK AND NOT A STATISTIC
Build-8 (2026-10-10) unpacked to 3.5 GiB in 14,136 entries and SideStore refused
to sign it: a sideloader walks the whole tree to re-sign every Mach-O, and what
it reported named a slice because that is where the walk stopped. A green build
produced an app nobody could install, so the archive's own shape is now part of
whether the build is allowed to publish.

Usage:  python3 tools/inspect-ipa.py <path.ipa>
Exit 0 if the archive is structurally usable, 1 if something is wrong.
"""

from __future__ import annotations

import collections
import os
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
    is what a build is held to; the override exists for tools/self_test_inspect_ipa.py.
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
# theoretical limits: the archive that failed was 3.5 GiB unpacked.
MAX_UNPACKED_BYTES = _limit_mib("MADEIRA_IPA_MAX_UNPACKED_MIB", 1500)
MAX_IPA_BYTES = _limit_mib("MADEIRA_IPA_MAX_IPA_MIB", 500)
# Above this entry count the re-signing walk is the slow part of an install.
MANY_ENTRIES = 5000
# Two files this size or more are large enough that a repeat is worth naming.
DUPLICATE_FLOOR = 32 * 1024 * 1024

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
        return [CPU_NAMES.get(struct.unpack("<i", data[4:8])[0], hex(struct.unpack("<i", data[4:8])[0]))], "thin"
    if magic in (b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf"):
        return [CPU_NAMES.get(struct.unpack(">i", data[4:8])[0], hex(struct.unpack(">i", data[4:8])[0]))], "thin"
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


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 1
    path = sys.argv[1]

    with zipfile.ZipFile(path) as z:
        infos = z.infolist()
        unpacked = sum(i.file_size for i in infos)
        print(f"archive: {path}")
        print(f"entries: {len(infos)}")
        print(f"unpacked: {unpacked / 1024 / 1024:.1f} MiB in {len(infos)} entries")

        bad = z.testzip()
        if bad is not None:
            fail(f"the zip fails its own integrity check at {bad}")
        else:
            print("zip integrity: ok")

        app_dirs = sorted({i.filename.split("/")[1] for i in infos if i.filename.startswith("Payload/") and len(i.filename.split("/")) > 2})
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

        # The bundle's own executable is the one iOS checks first.
        if app:
            try:
                with z.open(f"Payload/{app}/{app}") as f:
                    arches, kind = macho_slices(f.read(4096))
                print(f"main executable: {kind} {arches}")
                if "arm64" not in arches:
                    fail(f"the main executable has no arm64 slice ({arches}); no iPhone can run it")
            except KeyError:
                fail(f"Payload/{app}/{app} is not in the archive")

        symlinks = [i for i in infos if is_symlink(i)]
        print(f"symlinks: {len(symlinks)}")
        for info in symlinks:
            with z.open(info) as f:
                target = f.read().decode("utf-8", "replace")
            depth = info.filename.count("/") - 1
            if target.startswith("/") or target.count("../") > depth:
                fail(f"{info.filename} -> {target} escapes the bundle")

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

        # The checks that turn into a failed build. Both are about whether the
        # file can be installed, which is the only thing an IPA is for.
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
        fail(f"the IPA is {compressed / 1024 / 1024:.0f} MB, over the {MAX_IPA_BYTES // 1024 // 1024} MB a sideloader handles reliably")

    print()
    for e in ERRORS:
        print("ERROR: " + e)
    print("verdict:", "usable" if not ERRORS else "NOT usable")
    return 0 if not ERRORS else 1


if __name__ == "__main__":
    sys.exit(main())
