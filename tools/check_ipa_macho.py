#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Read the Mach-O files inside an .ipa, and answer the questions dyld will ask.

WHY THIS EXISTS
tools/inspect-ipa.py answers "can a sideloader walk this archive": the layout,
the size, the entry count, the files the app's capabilities are made of. It
cannot answer the two questions that decide whether the *engine* loads, because
both of them are inside the Mach-O files:

  1. **Is each nested framework signed, and does its signature match the file it
     is in?** dyld does not load a Mach-O whose signature does not match - it
     terminates the process rather than failing a load - and an unsigned one is
     terminated the same way. That is why the packaging step moved the engine
     out of the resource folder and into `Frameworks/`, where a re-signing tool
     walks, and it is why the signature has to be verified here and not assumed
     from a `codesign --verify` line in a log nobody kept.
  2. **Do the engine's own load commands resolve to files that are actually
     there?** The engine names its dependencies with `@rpath/...`, and the
     `LC_RPATH` entries that expand those names are inside the same files. A
     payload that has been trimmed by one framework, or a build whose rpath
     points at the sysroot's own `lib/`, produces an engine that opens and then
     dies at the first dependency - which is one of the failures this app had.

So this reads the load commands, resolves every `@rpath` dependency against the
loader's own rpaths and the bundle, verifies each embedded code signature by
hashing the file's pages against the CodeDirectory, and reports the platform of
each slice - because the engine is built for iOS (platform 2) and a version of
it built for the simulator would be refused by dyld on a device.

Usage:  python3 tools/check_ipa_macho.py <path.ipa>
        python3 tools/check_ipa_macho.py --expect-arch arm64 <path>
Exit 0 if everything checked out, 1 if not, 2 if the archive could not be read.
"""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import struct
import sys
import zipfile

MH_MAGIC = 0xFEEDFACE
MH_CIGAM = 0xCEFAEDFE
MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFECA
FAT_MAGIC_64 = 0xCAFEBABF
FAT_CIGAM_64 = 0xBFBAFECA

LC_SEGMENT = 0x1
LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0xC
LC_ID_DYLIB = 0xD
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
LC_CODE_SIGNATURE = 0x1D
LC_RPATH = 0x8000001C
LC_VERSION_MIN_IPHONEOS = 0x25
LC_BUILD_VERSION = 0x32

PLATFORMS = {
    1: "macOS", 2: "iOS", 3: "tvOS", 4: "watchOS", 5: "bridgeOS",
    6: "macCatalyst", 7: "iOS-simulator", 8: "tvOS-simulator",
    9: "watchOS-simulator", 10: "driverKit", 11: "visionOS",
    12: "visionOS-simulator",
}
CPU_NAMES = {
    7: "x86", 0x01000007: "x86_64", 12: "arm", 0x0100000C: "arm64",
    0x0200000C: "arm64_32",
}

CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_CODEDIRECTORY = 0xFADE0C02
CSSLOT_CODEDIRECTORY = 0
CSSLOT_ALTERNATE_CODEDIRECTORIES = 0x1000
CS_ADHOC = 0x2

HASH_TYPES = {1: "sha1", 2: "sha256", 3: "sha256-truncated", 4: "sha384", 5: "sha512"}


def align(value: int, boundary: int = 8) -> int:
    return (value + boundary - 1) & ~(boundary - 1)


class Slice:
    """One architecture inside one Mach-O file."""

    def __init__(self, name: str, offset: int, data: bytes, sixty_four: bool):
        self.name = name
        self.offset = offset
        self.data = data
        self.sixty_four = sixty_four
        self.cpu = 0
        self.filetype = 0
        self.platform: str | None = None
        self.minimum: str | None = None
        self.rpaths: list[str] = []
        self.dependencies: list[str] = []
        self.identifier: str | None = None
        self.signature: tuple[int, int] | None = None

    @property
    def cpu_name(self) -> str:
        return CPU_NAMES.get(self.cpu, f"cputype={self.cpu}")


def slices_of(name: str, data: bytes) -> list[Slice]:
    """Split a Mach-O into its slices, thin or fat."""
    if len(data) < 8:
        return []
    magic = struct.unpack_from(">I", data, 0)[0]
    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        wide = magic == FAT_MAGIC_64
        count = struct.unpack_from(">I", data, 4)[0]
        entry_size = 32 if wide else 20
        found = []
        for index in range(count):
            base = 8 + index * entry_size
            if base + entry_size > len(data):
                break
            if wide:
                cpu, _sub, offset, size = struct.unpack_from(">iiQQ", data, base)
            else:
                cpu, _sub, offset, size = struct.unpack_from(">iiII", data, base)
            if offset + size > len(data):
                break
            found.append(parse_slice(f"{name} [{CPU_NAMES.get(cpu, cpu)}]",
                                     offset, data[offset:offset + size]))
        return found
    little = struct.unpack_from("<I", data, 0)[0]
    if little in (MH_MAGIC, MH_MAGIC_64):
        return [parse_slice(name, 0, data)]
    return []


def parse_slice(name: str, offset: int, data: bytes) -> Slice:
    little = struct.unpack_from("<I", data, 0)[0]
    sixty_four = little == MH_MAGIC_64
    header_size = 32 if sixty_four else 28
    cpu, _sub, filetype, ncmds, _sizeofcmds, _flags = struct.unpack_from("<iiIIII", data, 4)
    piece = Slice(name, offset, data, sixty_four)
    piece.cpu = cpu
    piece.filetype = filetype

    position = header_size
    for _ in range(ncmds):
        if position + 8 > len(data):
            break
        command, size = struct.unpack_from("<II", data, position)
        if size < 8 or position + size > len(data):
            break
        body = data[position:position + size]
        if command == LC_CODE_SIGNATURE:
            dataoff, datasize = struct.unpack_from("<II", body, 8)
            piece.signature = (dataoff, datasize)
        elif command == LC_RPATH:
            (string_offset,) = struct.unpack_from("<I", body, 8)
            piece.rpaths.append(c_string(body, string_offset))
        elif command in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_ID_DYLIB):
            (string_offset,) = struct.unpack_from("<I", body, 8)
            text = c_string(body, string_offset)
            if command == LC_ID_DYLIB:
                piece.identifier = text
            else:
                piece.dependencies.append(text)
        elif command == LC_BUILD_VERSION:
            platform, minos, _sdk, _ntools = struct.unpack_from("<IIII", body, 8)
            piece.platform = PLATFORMS.get(platform, f"platform={platform}")
            piece.minimum = dotted(minos)
        elif command == LC_VERSION_MIN_IPHONEOS:
            minos, _sdk = struct.unpack_from("<II", body, 8)
            piece.platform = "iOS"
            piece.minimum = dotted(minos)
        position += size
    return piece


def c_string(body: bytes, offset: int) -> str:
    end = body.find(b"\0", offset)
    return body[offset:end if end != -1 else len(body)].decode("utf-8", "replace")


def dotted(value: int) -> str:
    return f"{value >> 16}.{(value >> 8) & 0xFF}.{value & 0xFF}"


# MARK: - The signature, checked against the bytes it covers


def verify_signature(piece: Slice, info_plist: bytes | None) -> tuple[bool, str]:
    """Hash every page of the slice against its CodeDirectory, and every special
    slot against the thing it is supposed to be the hash of.

    This is the check dyld makes when it loads the file, made here where it can
    be reported: an ad-hoc signature is replaced by a sideloader, but a
    signature that does not match its own file is not a signature, and a
    framework that arrives that way proves the packaging step copied bytes it
    did not sign.

    The special slots are the other half of a signature, and the half that says
    what the file *is*: slot 1 is the Info.plist beside the binary, slot 2 is the
    requirements blob, slot 5 would be the entitlements. Where the thing a slot
    refers to is in the archive, the slot is checked against it; where it is not
    (the resource directory, slot 3, is a hash tree this tool does not rebuild),
    the slot is reported as filled and unchecked rather than assumed.
    """
    if piece.signature is None:
        return False, "no LC_CODE_SIGNATURE: the file is not signed at all"
    dataoff, datasize = piece.signature
    if dataoff + datasize > len(piece.data) or datasize < 12:
        return False, f"the signature blob ({datasize} bytes at {dataoff}) is outside the file"
    blob = piece.data[dataoff:dataoff + datasize]
    magic, _length, count = struct.unpack_from(">III", blob, 0)
    if magic != CSMAGIC_EMBEDDED_SIGNATURE:
        return False, f"the signature blob has magic {magic:#x}, not a SuperBlob"

    # Every blob in the SuperBlob, by its slot number: the CodeDirectory, the
    # requirements, the entitlements, and the CMS signature (which is empty for
    # an ad-hoc signature, because there is no identity to sign it with).
    embedded: dict[int, bytes] = {}
    directories: list[bytes] = []
    for index in range(count):
        if 12 + index * 8 + 8 > len(blob):
            break
        slot, at = struct.unpack_from(">II", blob, 12 + index * 8)
        if at + 8 > len(blob):
            continue
        length = struct.unpack_from(">I", blob, at + 4)[0]
        if at + length > len(blob):
            continue
        if slot in (CSSLOT_CODEDIRECTORY, CSSLOT_ALTERNATE_CODEDIRECTORIES):
            directories.append(blob[at:at + length])
        else:
            embedded[slot] = blob[at:at + length]
    if not directories:
        return False, "the signature blob carries no CodeDirectory"

    reasons: list[str] = []
    for directory in directories:
        ok, why = check_code_directory(piece, directory, embedded, info_plist)
        if ok:
            return True, why
        reasons.append(why)
    return False, reasons[0]


def check_code_directory(piece: Slice, directory: bytes,
                         embedded: dict[int, bytes],
                         info_plist: bytes | None) -> tuple[bool, str]:
    if len(directory) < 44:
        return False, "the CodeDirectory is too short to read"
    magic, _length, version, flags = struct.unpack_from(">IIII", directory, 0)
    if magic != CSMAGIC_CODEDIRECTORY:
        return False, f"the CodeDirectory has magic {magic:#x}"
    (hash_offset, ident_offset, n_special, n_code, code_limit) = struct.unpack_from(
        ">IIIII", directory, 16)
    hash_size, hash_type, _platform, page_power = struct.unpack_from(">BBBB", directory, 36)
    if hash_type not in HASH_TYPES:
        return False, f"hashType {hash_type} is not one this tool knows"
    if page_power > 30:
        return False, f"pageSize {page_power} is not a page size"
    if code_limit > len(piece.data):
        return False, (f"the CodeDirectory covers {code_limit} bytes but the file is "
                       f"{len(piece.data)}")

    ident = c_string(directory, ident_offset) if ident_offset < len(directory) else "?"
    page_size = 0 if page_power == 0 else 1 << page_power
    digest = getattr(hashlib, HASH_TYPES[hash_type].split("-")[0])

    # The code slots are the file's pages, each hashed whole.
    covered = 0
    for index in range(n_code):
        at = hash_offset + index * hash_size
        if at + hash_size > len(directory):
            return False, f"code slot {index} is past the end of the CodeDirectory"
        want = directory[at:at + hash_size]
        if page_size == 0:
            chunk = piece.data[:code_limit]
        else:
            start = index * page_size
            chunk = piece.data[start:min(start + page_size, code_limit)]
        covered += len(chunk)
        if digest(chunk).digest()[:hash_size] != want:
            return False, (f"page {index} of {ident!r} does not hash to its slot: this "
                           "signature was made for different bytes")
    # And the file must be exactly what the CodeDirectory claims to cover.
    expected_pages = 1 if page_size == 0 else (code_limit + page_size - 1) // page_size
    if n_code != expected_pages:
        return False, (f"the CodeDirectory has {n_code} slots for a {code_limit}-byte "
                       f"region; {expected_pages} pages are expected")
    # A signature never covers itself: it is appended after the region it signs,
    # so the blob's own offset is where the covered region ends. What would be
    # wrong is a blob that starts *before* the region it covers, or bytes
    # between the two that nothing signed.
    dataoff, datasize = piece.signature
    if code_limit > dataoff:
        return False, (f"the CodeDirectory covers {code_limit} bytes but its signature "
                       f"blob starts at {dataoff}: it claims to sign itself")
    if code_limit < dataoff:
        return False, (f"{dataoff - code_limit} bytes between the end of the signed "
                       f"region ({code_limit}) and the signature blob ({dataoff}) are "
                       "covered by nothing")

    # The special slots. Each is the hash of something outside the CodeDirectory:
    # slot 1 the Info.plist, slot 2 the requirements, slot 3 the resource
    # directory's hash tree, slot 5 the entitlements. Where this tool can get at
    # the bytes a slot refers to, it requires the match; where it cannot, the slot
    # is named and left alone, because a claim that could not be checked is worth
    # reporting and not worth failing a build over.
    named = {1: "Info.plist", 2: "requirements", 5: "entitlements", 7: "DER entitlements"}
    unchecked: list[str] = []
    for slot in range(1, n_special + 1):
        at = hash_offset - slot * hash_size
        if at < 0:
            return False, f"special slot {slot} is before the start of the CodeDirectory"
        stored = directory[at:at + hash_size]
        expected: bytes | None = None
        if slot == 1:
            expected = info_plist
        elif slot in embedded:
            expected = embedded[slot]
        if expected is None:
            if any(stored):
                unchecked.append(f"slot {slot} ({named.get(slot, 'unknown')}, filled)")
            continue
        if digest(expected).digest()[:hash_size] != stored:
            return False, (f"special slot {slot} is not the hash of this file's "
                           f"{named.get(slot, 'value')}: the signature describes "
                           "different content")

    adhoc = "ad-hoc" if flags & CS_ADHOC else f"flags={flags:#x}"
    return True, (f"signed, {adhoc}, {HASH_TYPES[hash_type]}, {n_code} pages, "
                  f"ident {ident!r}"
                  + (f", {', '.join(unchecked)} not rebuilt here" if unchecked else ""))


# MARK: - rpaths, resolved the way dyld resolves them


def candidates(piece: Slice, loader_dir: str, executable_dir: str,
               reference: str) -> list[str]:
    """Every path a dependency could resolve to, in a stable order.

    `@executable_path` is the one name whose meaning depends on who is running:
    for code loaded into the app's process it is the app binary's directory, and
    for an app extension or a helper that runs as its own process it is *that*
    binary's directory. Both are documented behaviours and a given file is built
    for one of them, so both are offered, and the answer that exists is the
    answer. A reference that resolves to nothing under either is the failure this
    function is here to find.

    An absolute path returns no candidates on purpose: `/usr/lib/libSystem.B.
    dylib` is resolved by dyld on the device and is not this archive's business.
    """
    bases = [executable_dir, loader_dir] if executable_dir != loader_dir else [executable_dir]
    found: list[str] = []
    if reference.startswith("@rpath/"):
        for base in bases:
            for rpath in piece.rpaths:
                expanded = expand_rpath(base, rpath, reference)
                if expanded:
                    found.append(expanded)
    elif reference.startswith("@loader_path/"):
        found.append(normalize(f"{loader_dir}/{reference[len('@loader_path/'):]}"))
    elif reference.startswith("@executable_path/"):
        for base in bases:
            found.append(normalize(f"{base}/{reference[len('@executable_path/'):]}"))
    elif reference.startswith("@"):
        return []
    elif reference.startswith("/"):
        return []
    else:
        found.append(normalize(f"{loader_dir}/{reference}"))
    return list(dict.fromkeys(found))


def normalize(path: str) -> str:
    parts: list[str] = []
    for part in path.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if parts:
                parts.pop()
            continue
        parts.append(part)
    return "/".join(parts)


def expand_rpath(base: str, rpath: str, reference: str) -> str | None:
    """Expand one `@rpath/...` dependency against one rpath entry.

    `base` is what `@executable_path` and `@loader_path` in the entry expand to
    for this caller; the caller offers both readings and keeps the answer that
    turns out to exist.
    """
    if not reference.startswith("@rpath/"):
        return None
    tail = reference[len("@rpath/"):]
    head = rpath.split("/", 1)[0]
    if head in ("@executable_path", "@loader_path"):
        rest = rpath[len(head):].lstrip("/")
        return normalize("/".join(part for part in (base, rest, tail) if part))
    if rpath.startswith("@") or rpath.startswith("/"):
        return None
    return normalize(str(pathlib.PurePosixPath(base) / rpath / tail))


# MARK: - main


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("archive", help="a path to an .ipa")
    parser.add_argument("--expect-arch", action="append", default=["arm64"],
                        help="an architecture every Mach-O must have (default arm64)")
    parser.add_argument("--expect-platform", default="iOS",
                        help="the platform every Mach-O must be built for (default iOS)")
    parser.add_argument("--quiet", action="store_true",
                        help="only the summary and the failures")
    args = parser.parse_args()

    path = pathlib.Path(args.archive)
    if not path.is_file():
        print(f"error: {path}: not a file", file=sys.stderr)
        return 2
    try:
        archive = zipfile.ZipFile(path)
    except (OSError, zipfile.BadZipFile) as error:
        print(f"error: {path}: {error}", file=sys.stderr)
        return 2

    names = archive.namelist()
    # `Payload/` itself is a directory entry, so the second component has to be
    # checked for being there at all before it can be counted.
    apps: set[str] = set()
    for name in names:
        parts = name.split("/")
        if len(parts) > 1 and parts[0] == "Payload" and parts[1].endswith(".app"):
            apps.add(parts[1])
    if len(apps) != 1:
        print(f"error: expected one .app under Payload/, found {sorted(apps)}", file=sys.stderr)
        return 2
    app = sorted(apps)[0]
    executable = None
    for name in names:
        if name.startswith(f"Payload/{app}/") and name.count("/") == 2 and not name.endswith("/"):
            candidate = name.split("/")[2]
            if candidate == app[: -len(".app")]:
                executable = candidate
    executable_path = f"Payload/{app}" + (f"/{executable}" if executable else "")
    executable_dir = executable_path.rsplit("/", 1)[0]

    present = set(names)
    problems: list[str] = []
    warnings: list[str] = []
    signed = 0
    checked = 0
    app_binary_seen = False

    def is_macho(blob: bytes) -> bool:
        if len(blob) < 8:
            return False
        if struct.unpack_from(">I", blob, 0)[0] in (FAT_MAGIC, FAT_MAGIC_64):
            return True
        return struct.unpack_from("<I", blob, 0)[0] in (MH_MAGIC, MH_MAGIC_64)

    def bundle_path(name: str) -> str:
        return name[len(f"Payload/{app}/"):]

    def loader_directory(name: str) -> str:
        relative = bundle_path(name)
        return (f"Payload/{app}/" + relative.rsplit("/", 1)[0]) if "/" in relative \
            else f"Payload/{app}"

    # First pass: every file that is a Mach-O, wherever it is - the app's own
    # binary, the frameworks, anything else a build left behind. Reading them all
    # before judging any of them is what makes the next pass able to ask "does
    # anything here name this file".
    entries: list[tuple[str, list[Slice]]] = []
    for name in names:
        if name.endswith("/") or not name.startswith(f"Payload/{app}/"):
            continue
        blob = archive.read(name)
        if not is_macho(blob):
            continue
        checked += 1
        pieces = slices_of(name, blob)
        if not pieces:
            problems.append(f"{bundle_path(name)}: looks like a Mach-O but has no "
                            "readable slice")
            continue
        entries.append((name, pieces))

    # The dependency graph, each reference expanded the way dyld expands it. A
    # name that resolves to nothing in the bundle is a failure - that is the
    # engine opening and then dying on its first `@rpath` - and a name that
    # resolves to a file inside the bundle is what makes that file's signature
    # matter.
    referenced: set[str] = set()
    for name, pieces in entries:
        relative = bundle_path(name)
        loader_dir = loader_directory(name)
        for piece in pieces:
            for reference in piece.dependencies:
                offered = candidates(piece, loader_dir, executable_dir, reference)
                if not offered:
                    continue  # a system library, resolved by dyld on the device
                resolved = next((path for path in offered if path in present), None)
                if resolved is not None:
                    referenced.add(resolved)
                    if not args.quiet:
                        print(f"  {relative}: names {reference} -> {resolved}")
                else:
                    tried = ", ".join(offered[:4]) + (" ..." if len(offered) > 4 else "")
                    problems.append(f"{relative}: names {reference}, and the archive has "
                                    f"none of the paths that could satisfy it: {tried}")

    # Second pass: the signatures. What has to be signed is anything another
    # Mach-O in this bundle names, and everything under Frameworks/, which is the
    # directory the packaging step moved the engine into and the directory every
    # re-signing tool walks. A sideloader replaces the app's own signature - which
    # is why an unsigned IPA ships an unsigned binary, and why an unsigned appex
    # is reported rather than refused: the tool signing the IPA signs nested code
    # as well, and if it did not, nothing would install at all.
    #
    # What is not survivable is a Mach-O this bundle *loads* being unsigned or
    # signed for other bytes: dyld terminates the process instead of reporting a
    # load failure, so a framework that arrives that way is a crash with no log.
    # Whether this IPA is signed at all decides what an unsigned file means. In
    # an unsigned archive - which is what this build produces, with signing off -
    # every Mach-O is unsigned and the tool that installs it signs the whole
    # bundle. In a signed one, a file the app's own code loads has to be signed
    # already, or dyld terminates the process as it opens.
    executable_pieces = [piece for name, pieces in entries if name == executable_path
                         for piece in pieces]
    ipa_signed = any(piece.signature for piece in executable_pieces)

    for name, pieces in entries:
        relative = bundle_path(name)
        if name == executable_path:
            app_binary_seen = True
        must_be_signed = (relative.startswith("Frameworks/")
                          or (name in referenced and ipa_signed))
        nested = (relative.startswith(("Frameworks/", "PlugIns/", "Watch/"))
                  or ".appex/" in relative)
        # The Info.plist beside a binary is what its signature's slot 1 has to
        # match; a framework has one, and so does an appex.
        plist_name = name.rsplit("/", 1)[0] + "/Info.plist"
        info_plist = archive.read(plist_name) if plist_name in present else None
        if not args.quiet:
            print(f"\n{relative}  ({len(pieces)} slice(s))")
        for piece in pieces:
            ok, why = verify_signature(piece, info_plist)
            if ok:
                signed += 1
            elif name == executable_path:
                why = ("unsigned, as an unsigned IPA's own binary is: a sideloader "
                       "replaces this signature")
            elif must_be_signed:
                problems.append(f"{relative} [{piece.cpu_name}]: {why}")
            elif name in referenced:
                warnings.append(f"{relative} [{piece.cpu_name}]: {why}; this IPA is "
                                "unsigned, so whatever opens it has to sign this file "
                                "too, and the app cannot load without it")
            elif nested:
                warnings.append(f"{relative} [{piece.cpu_name}]: {why}; this is nested "
                                "code, and the tool that signs this IPA has to sign "
                                "this too")
            else:
                warnings.append(f"{relative} [{piece.cpu_name}]: {why}, and nothing in "
                                "the bundle names it")
            for arch in args.expect_arch:
                if arch not in [p.cpu_name for p in pieces]:
                    problems.append(f"{relative}: has no {arch} slice "
                                    f"(it has {[p.cpu_name for p in pieces]})")
                    break
            if piece.platform and piece.platform != args.expect_platform:
                problems.append(f"{relative} [{piece.cpu_name}]: built for "
                                f"{piece.platform}, not {args.expect_platform}")
            if not args.quiet:
                print(f"    {piece.cpu_name}, {piece.platform or 'no platform command'}"
                      + (f" {piece.minimum}" if piece.minimum else "")
                      + f", filetype {piece.filetype}, id {piece.identifier!r}")
                print(f"    {why}")

    if not app_binary_seen:
        problems.append(f"the bundle's executable ({executable_path}) was not found")

    print(f"\n{path.name}: {checked} Mach-O file(s) read, {signed} signed slice(s), "
          f"{len(problems)} problem(s), {len(warnings)} warning(s)")
    for warning in warnings:
        print(f"warning: {warning}")
    for problem in problems:
        print(f"  - {problem}", file=sys.stderr)
    if problems:
        return 1
    print("every Mach-O this bundle loads is signed, matches its signature, and resolves")
    return 0


if __name__ == "__main__":
    sys.exit(main())
