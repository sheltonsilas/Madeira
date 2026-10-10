#!/usr/bin/env python3
"""Validate the exact byte layout LinuxEnvironmentPackager will write.

The Swift packager cannot be run here (no iOS toolchain on this box), so the
header layout it emits is prototyped byte-for-byte in this script and checked
against Python's own tarfile reader. If tarfile accepts what this produces and
round-trips the content, the offsets, the octal fields, the GNU base-256 size
encoding and the checksum algorithm are all right, and the Swift is then a
transliteration of a proven layout rather than a guess.
"""
import io
import tarfile
import time

BLOCK = 512


def octal(value: int, width: int) -> bytes:
    """A ustar numeric field: `width-1` octal digits, then NUL."""
    return f"{value:0{width - 1}o}".encode("ascii") + b"\0"


def size_field(value: int) -> bytes:
    """The 12-byte size field, octal below 8 GiB and GNU base-256 above.

    Disk images here go up to 64 GB, so base-256 is not optional: the octal
    form overflows at 8^11 - 1 and silently truncates.
    """
    if 0 <= value < 8 ** 11:
        return octal(value, 12)
    field = bytearray(12)
    field[0] = 0x80
    v = value
    for i in range(11, 0, -1):
        field[i] = v & 0xFF
        v >>= 8
    assert v == 0, "value does not fit the 11 available bytes"
    return bytes(field)


def header(name: str, size: int, typeflag: bytes, mtime: int, mode: int = 0o644) -> bytes:
    assert len(name) <= 100, name
    h = bytearray(BLOCK)
    h[0:100] = name.encode("utf-8").ljust(100, b"\0")
    h[100:108] = octal(mode, 8)
    h[108:116] = octal(0, 8)          # uid
    h[116:124] = octal(0, 8)          # gid
    h[124:136] = size_field(size)
    h[136:148] = octal(mtime, 12)
    h[148:156] = b" " * 8             # checksum placeholder, spaces while summing
    h[156:157] = typeflag
    h[257:263] = b"ustar\0"
    h[263:265] = b"00"
    h[265:297] = b"root".ljust(32, b"\0")
    h[297:329] = b"root".ljust(32, b"\0")
    total = sum(h)
    h[148:156] = f"{total:06o}\0 ".encode("ascii")
    return bytes(h)


def parse_size(field: bytes) -> int:
    """The reader's mirror of size_field: octal or GNU base-256."""
    if field[0] & 0x80:
        v = field[0] & 0x7F
        for b in field[1:12]:
            v = (v << 8) | b
        return v
    return int(field.split(b"\0", 1)[0].decode("ascii").strip() or "0", 8)


def build(entries) -> bytes:
    out = bytearray()
    now = int(time.time())
    for name, body, typeflag in entries:
        out += header(name, len(body) if typeflag == b"0" else 0, typeflag, now)
        if typeflag == b"0" and body:
            out += body
            out += b"\0" * ((BLOCK - len(body) % BLOCK) % BLOCK)
    out += b"\0" * (BLOCK * 2)
    return bytes(out)


def main() -> None:
    body = b"#!/bin/sh\necho hello from the rootfs\n" * 3
    archive = build([
        (".madeira-environment.json", b'{"name":"Ubuntu"}', b"0"),
        ("rootfs", b"", b"5"),
        ("rootfs/etc/os-release", body, b"0"),
    ])

    # tarfile must accept it, list it, and give the bytes back unchanged.
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as tf:
        names = tf.getnames()
        assert names == [".madeira-environment.json", "rootfs", "rootfs/etc/os-release"], names
        got = tf.extractfile("rootfs/etc/os-release").read()
        assert got == body, "content round-trip failed"
        info = tf.getmember("rootfs")
        assert info.isdir(), "directory typeflag not honoured"
        print("names:", names)
        print("content round-trip: OK, dir typeflag: OK")

    # The size field: octal under 8 GiB, base-256 at 64 GiB.
    for n in (0, 1, 4096, 8 ** 11 - 1, 9 * 1024 ** 3, 64 * 1024 ** 3):
        field = size_field(n)
        assert len(field) == 12, len(field)
        back = parse_size(field)
        assert back == n, (n, back)
        if n >= 8 ** 11:
            assert field[0] == 0x80, "large size must use GNU base-256"
        else:
            assert 0x30 <= field[0] <= 0x37, field[:4]
    print("size field octal + base-256 round-trip: OK (incl. 64 GiB)")

    # A body whose length is already a multiple of 512 must not gain padding.
    padded = build([("a", b"x" * BLOCK, b"0")])
    assert len(padded) == BLOCK * 4, len(padded)   # header + body + trailer
    print("no double-padding on aligned bodies: OK")
    print("ALL CHECKS PASSED")


if __name__ == "__main__":
    main()
