#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Boot the launcher's command line on a host QEMU, and report what happened.

WHY THIS EXISTS
The Linux variant ends in a QEMU argument vector. Whether that vector boots a
machine is a question about QEMU and about the firmware this app ships, and
neither of those needs an iPhone - only the *binary* does. The engine is built
for iOS (LC_BUILD_VERSION platform 2), so no simulator and no Mac can load it,
which leaves two options: say "untestable without the device", or split the
question. This file is the half of it that can be answered anywhere.

What it does is what the app does, in the same order:

  1. starts QEMU with the vector `tools/check_launcher_argv.py` read out of the
     Swift, so the flags are the app's and not a copy of them;
  2. connects to the console socket the launcher creates, and reads the guest's
     serial output;
  3. asks the monitor socket - the same socket the Stop button sends `quit` to -
     what QEMU thinks the drives are, which is how "the .iso is attached as a
     CD-ROM" is checked as a property of the device and not as a hope;
  4. `quit` on the monitor, and requires QEMU to exit 0.

WHAT IT DOES NOT PROVE, WHICH IS THE OTHER HALF
That the iOS build of QEMU boots it on an iPhone. This file proves the command
line, the firmware images and the socket wiring are right; the engine is a
different question and the app answers it by writing its output to
Documents/linux-engine.log.

USAGE
  python3 tools/boot_smoke.py --argv-json /tmp/argv.json --expect BdsDxe
  python3 tools/boot_smoke.py --argv-json /tmp/argv.json \
      --expect "DVD-ROM" --expect "Linux version" --expect-block "Removable media: +Yes"

Exit 0 if every expectation was met and QEMU stopped on `quit`; 1 if not, with
what was actually seen; 2 if the inputs could not be read.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import time


def path_after(argv: list[str], flag: str) -> str | None:
    if flag in argv:
        index = argv.index(flag)
        if index + 1 < len(argv):
            return argv[index + 1]
    return None


def chardev_path(argv: list[str], device_id: str) -> str | None:
    """The socket path a named chardev is bound to, from the vector itself."""
    for argument in argv:
        if argument.startswith("socket,") and f"id={device_id}" in argument:
            match = re.search(r"path=([^,]+)", argument)
            if match:
                return match.group(1)
    return None


def read_until(sock: socket.socket, deadline: float, needles: list[str],
               sink: list[str], label: str, echo: bool) -> str | None:
    """Read `sock` until one of `needles` appears or the deadline passes."""
    buffer = ""
    while time.monotonic() < deadline:
        ready, _, _ = select.select([sock], [], [], 0.5)
        if not ready:
            continue
        chunk = sock.recv(65536)
        if not chunk:
            return None
        text = chunk.decode("utf-8", "replace")
        buffer += text
        sink.append(text)
        if echo:
            for line in text.splitlines():
                print(f"    {label} | {line}", flush=True)
        for needle in needles:
            if needle in buffer:
                return needle
    return None


def connect(path: str, deadline: float) -> socket.socket:
    """Connect to a Unix socket QEMU is listening on, waiting for it to exist."""
    last: OSError | None = None
    while time.monotonic() < deadline:
        if pathlib.Path(path).exists():
            try:
                sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                sock.connect(path)
                return sock
            except OSError as error:  # QEMU has created it and not listened yet
                last = error
                sock.close()
        time.sleep(0.1)
    raise SystemExit(f"error: nothing was listening on {path} before the deadline"
                     + (f" (last: {last})" if last else ""))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--argv-json", required=True)
    parser.add_argument("--qemu-bin", default="qemu-system-aarch64")
    parser.add_argument("--expect", action="append", default=[],
                        help="guest console text that means the machine booted")
    parser.add_argument("--forbid", action="append", default=[],
                        help="guest console text that must NOT appear")
    parser.add_argument("--expect-block", action="append", default=[],
                        help="a regex the monitor's `info block` must match")
    parser.add_argument("--expect-stats", action="append", default=[],
                        help="a regex the monitor's `info blockstats` must match")
    parser.add_argument("--note", action="append", default=[],
                        help="console text worth reporting, and not required")
    parser.add_argument("--what", default="the guest",
                        help="what this run is, for the report")
    parser.add_argument("--connect-timeout", type=float, default=30)
    parser.add_argument("--console-timeout", type=float, default=300)
    parser.add_argument("--settle", type=float, default=0,
                        help="seconds to keep reading the console before the "
                             "statistics are read, for work that outlives its output")
    parser.add_argument("--quit-timeout", type=float, default=30)
    parser.add_argument("--echo-console", action="store_true", default=True)
    args = parser.parse_args()

    try:
        recorded = json.loads(pathlib.Path(args.argv_json).read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        print(f"error: {args.argv_json}: {error}", file=sys.stderr)
        return 2
    argv: list[str] = recorded["argv"]
    if len(argv) < 2:
        print("error: the vector has no arguments", file=sys.stderr)
        return 2

    console_path = chardev_path(argv, "madeira-console")
    monitor_path = chardev_path(argv, "madeira-monitor")
    if not console_path or not monitor_path:
        print("error: the vector does not create the launcher's two sockets", file=sys.stderr)
        return 2
    workdir = pathlib.Path(tempfile.mkdtemp(prefix="boot-smoke-"))
    log = workdir / "qemu.log"

    print(f"what:    {args.what}")
    print(f"qemu:    {shutil.which(args.qemu_bin) or args.qemu_bin}")
    print(f"image:   {recorded.get('image', '?')}")
    print(f"console: {console_path}")
    print(f"monitor: {monitor_path}")
    print()

    # argv[0] is the name QEMU is told it has; the binary is this file's choice.
    command = [args.qemu_bin] + argv[1:]
    print("$ " + " ".join(command))
    print()
    try:
        with open(log, "wb") as logfile:
            process = subprocess.Popen(command, stdout=logfile, stderr=subprocess.STDOUT)
    except OSError as error:
        print(f"error: {args.qemu_bin}: {error}", file=sys.stderr)
        return 2

    seen: list[str] = []
    console: socket.socket | None = None
    monitor: socket.socket | None = None
    deadline = time.monotonic() + args.connect_timeout
    try:
        console = connect(console_path, deadline)
    except SystemExit as error:
        process.kill()
        print(str(error), file=sys.stderr)
        print(log.read_text(encoding="utf-8", errors="replace")[-4000:], file=sys.stderr)
        return 1
    try:
        monitor = connect(monitor_path, deadline)

        # The monitor first: it answers immediately, and what it says about the
        # drives is a property of the device the vector created.
        monitor.sendall(b"info version\n")
        banner: list[str] = []
        read_until(monitor, time.monotonic() + 10, ["(qemu)"], banner, "monitor", False)
        version = "".join(banner).strip().splitlines()[:1]
        print(f"  monitor version: {version[0] if version else '(nothing)'}")

        def monitor_says(command_text: str, label: str) -> str:
            monitor.sendall(command_text.encode() + b"\n")
            collected: list[str] = []
            read_until(monitor, time.monotonic() + 15, ["(qemu)"], collected, label, False)
            listing = "".join(collected)
            print(f"  monitor {command_text.strip()}:")
            for line in listing.splitlines():
                print(f"    | {line}")
            return listing

        if args.expect_block:
            listing = monitor_says("info block", "block")
            for pattern in args.expect_block:
                if re.search(pattern, listing):
                    print(f"  drive check ok: /{pattern}/")
                else:
                    print(f"ERROR: `info block` does not match /{pattern}/", file=sys.stderr)
                    process.kill()
                    return 1

        # Then the guest: the firmware's own output on the console socket.
        matched = read_until(console, time.monotonic() + args.console_timeout,
                             args.expect, seen, "guest", args.echo_console)
        guest = "".join(seen)
        if matched:
            print(f"\n  console match: {matched!r} after {len(guest)} bytes")
        else:
            print(f"\nERROR: none of {args.expect} appeared in {len(guest)} bytes of "
                  "guest console output", file=sys.stderr)
            print(f"  everything the guest said:\n{guest[-2000:] or '(nothing)'}", file=sys.stderr)
            process.kill()
            return 1

        for text in args.note:
            print(f"  also seen: {text!r}" if text in guest else f"  not seen: {text!r}")

        # Keep reading for a while: a bootloader's output can end long before the
        # work that proves it ran finishes.
        if args.settle:
            read_until(console, time.monotonic() + args.settle, [], seen, "guest",
                       args.echo_console)
            guest = "".join(seen)

        for text in args.forbid:
            if text in guest:
                print(f"ERROR: the guest console contains {text!r}, which must not "
                      "happen on this command line", file=sys.stderr)
                process.kill()
                return 1
            print(f"  absent as required: {text!r}")

        if args.expect_stats:
            listing = monitor_says("info blockstats", "blockstats")
            for pattern in args.expect_stats:
                if re.search(pattern, listing, re.MULTILINE):
                    print(f"  statistics check ok: /{pattern}/")
                else:
                    print(f"ERROR: `info blockstats` does not match /{pattern}/: nothing "
                          "was read from the disc this run is about", file=sys.stderr)
                    process.kill()
                    return 1

        # Stop, the way the app's Stop button does it.
        monitor.sendall(b"quit\n")
        try:
            code = process.wait(timeout=args.quit_timeout)
        except subprocess.TimeoutExpired:
            print("ERROR: `quit` on the monitor did not stop QEMU", file=sys.stderr)
            process.kill()
            return 1
        print(f"  quit on the monitor: QEMU exited {code}")
        if code != 0:
            print(f"ERROR: QEMU exited {code} after `quit`", file=sys.stderr)
            return 1
    finally:
        for sock in (console, monitor):
            try:
                if sock is not None:
                    sock.close()
            except OSError:
                pass
        if process.poll() is None:
            process.kill()

    engine = log.read_text(encoding="utf-8", errors="replace")
    if engine.strip():
        print("  qemu's own output:")
        for line in engine.strip().splitlines()[-20:]:
            print(f"    | {line}")
    print(f"\n{args.what}: booted, and stopped on quit")
    return 0


if __name__ == "__main__":
    sys.exit(main())
