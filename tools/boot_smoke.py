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
  3. asks QEMU what the drives are, which is how "the .iso arrived as an optical
     disc" is checked as a property of the device and not as a hope;
  4. `quit` on the monitor socket - the same socket the Stop button writes to -
     and requires QEMU to exit 0.

TWO ANSWERS, TWO CHANNELS
Step 3 was originally asked on the app's own monitor, in its human language:
`info block`, and the answer was read with a regular expression. That failed,
and the way it failed is worth keeping: the monitor is a line editor, so
everything typed into it is echoed back with the redraw sequences a terminal
would interpret (`i\\x1b[K\\x1b[Din\\x1b[K\\x1b[Dinfo...`), and the same text
`(qemu)` that ends an answer also appears in the middle of the echo of the next
question. The reader returned the echo of the question it had just asked, found
no answer in it, and reported a drive it had never actually looked at.

So the facts come from QMP instead - one JSON object per line, no echo, no
prompt, no terminal - and the app's monitor keeps the one job it has in the app:
`quit`. The `-qmp` channel is the only thing this file adds to the vector, and
it is added here, not in the launcher: it is how the harness asks questions, not
part of what the app does. Everything asserted about the machine is then a field
in a documented structure (`removable`, `inserted.file`, `stats.rd_bytes`) rather
than a substring of a human-readable table that changes between QEMU releases.

WHAT IT DOES NOT PROVE, WHICH IS THE OTHER HALF
That the iOS build of QEMU boots it on an iPhone. This file proves the command
line, the firmware images, the disc device and the socket wiring are right; the
engine is a different question, and the app answers it by writing its output to
Documents/linux-engine.log.

USAGE
  python3 tools/boot_smoke.py --argv-json /tmp/argv.json --expect BdsDxe
  python3 tools/boot_smoke.py --argv-json /tmp/argv.json \\
      --what "an installer ISO" --forbid "no bootable option" \\
      --expect-removable --expect-medium /tmp/installer.iso \\
      --min-read-bytes 100000 --settle 120

Exit 0 if every expectation was met and QEMU stopped on `quit`; 1 if not, with
what was actually seen; 2 if the inputs could not be read.

The logic below the socket is covered by tools/self_test_boot_smoke.py, which
runs this file's own `main()` against a fake QEMU speaking both protocols, and
includes the mistake this exists to catch: an .iso on a virtio-blk disk.
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


# QEMU's monitor is a line editor, so anything typed into it can come back with
# the redraw sequences a terminal would interpret. Nothing here reads the
# monitor any more, but the escapes are stripped before any of it is printed,
# because an error report full of `\x1b[K` is unreadable at exactly the moment
# it matters. The pattern is exercised in the self test against a recorded
# sample of that echo.
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b[()][A-Za-z0-9]|\x1b[=>]")


def plain(text: str) -> str:
    return ANSI.sub("", text).replace("\r", "")


def with_qmp(arguments: list[str], spec: str) -> list[str]:
    """The app's vector, plus the harness's own structured channel.

    Appended, never substituted: the launcher's arguments are the thing under
    test and have to reach QEMU untouched. `-qmp` opens a second channel; it
    cannot change what the vector's own arguments do.
    """
    return arguments + ["-qmp", spec]


# MARK: - QMP, which answers in JSON and never echoes


class Qmp:
    """One JSON object per line: the greeting, then replies, then events."""

    def __init__(self, sock: socket.socket):
        self.sock = sock
        self.buffer = b""
        self.greeting: dict | None = None

    def _read_object(self, deadline: float) -> dict | None:
        while True:
            if b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                line = line.strip()
                if not line:
                    continue
                try:
                    return json.loads(line.decode("utf-8", "replace"))
                except ValueError:
                    return {"_unparsed": plain(line.decode("utf-8", "replace"))}
            if time.monotonic() >= deadline:
                return None
            ready, _, _ = select.select([self.sock], [], [], 0.25)
            if not ready:
                continue
            chunk = self.sock.recv(65536)
            if not chunk:
                return None
            self.buffer += chunk

    def handshake(self, deadline: float) -> bool:
        greeting = self._read_object(deadline)
        if greeting is None or "QMP" not in greeting:
            self.greeting = greeting
            return False
        self.greeting = greeting
        reply = self.execute("qmp_capabilities", None, deadline)
        return reply is not None

    def execute(self, command: str, arguments: dict | None,
                deadline: float) -> object | None:
        request = {"execute": command}
        if arguments is not None:
            request["arguments"] = arguments
        self.sock.sendall((json.dumps(request) + "\n").encode())
        while True:
            reply = self._read_object(deadline)
            if reply is None:
                return None
            if "event" in reply:  # RESET, SHUTDOWN, ... - not an answer
                continue
            if "error" in reply:
                return {"_error": reply["error"]}
            if "return" in reply:
                return reply["return"]


def devices(blocks: object) -> list[dict]:
    return [b for b in blocks if isinstance(b, dict)] if isinstance(blocks, list) else []


def describe(blocks: object) -> list[str]:
    """One line per device, for the log: what QEMU says the drives are."""
    lines: list[str] = []
    for block in devices(blocks):
        medium = None
        inserted = block.get("inserted")
        if isinstance(inserted, dict):
            medium = inserted.get("file") or inserted.get("node-name")
        lines.append(
            "device={device!r} qdev={qdev!r} removable={removable!r} "
            "locked={locked!r} tray_open={tray_open!r} medium={medium!r}".format(
                device=block.get("device"), qdev=block.get("qdev"),
                removable=block.get("removable"), locked=block.get("locked"),
                tray_open=block.get("tray_open"), medium=medium,
            )
        )
        # A nodename'd backend carries the same facts one level in, and it is
        # where `inserted` is absent but the file still shows up.
        if not medium and block.get("file"):
            lines.append("  backend {!r} file={!r}".format(block.get("device"), block.get("file")))
    return lines


def removable_devices(blocks: object) -> list[str]:
    """Devices QEMU reports as removable media - what a disc needs to be."""
    return [str(b.get("device")) for b in devices(blocks) if b.get("removable")]


def devices_with_medium(blocks: object, path: str) -> list[str]:
    """Devices whose inserted medium is `path` - a substring match, because a
    backend may report the resolved path and the harness the one it passed."""
    found: list[str] = []
    for block in devices(blocks):
        inserted = block.get("inserted")
        candidates = []
        if isinstance(inserted, dict):
            candidates = [inserted.get("file"), inserted.get("node-name")]
        candidates.append(block.get("file"))
        for candidate in candidates:
            if isinstance(candidate, str) and candidate and (
                candidate == path or path in candidate or candidate in path
            ):
                found.append(str(block.get("device")))
                break
    return found


def read_bytes(stats: object) -> int:
    """Every `rd_bytes` in the tree, including backing and parent nodes."""
    total = 0
    if isinstance(stats, dict):
        value = stats.get("rd_bytes")
        if isinstance(value, (int, float)):
            total += int(value)
        for key, child in stats.items():
            if key != "rd_bytes" and isinstance(child, (dict, list)):
                total += read_bytes(child)
    elif isinstance(stats, list):
        for item in stats:
            total += read_bytes(item)
    return total


def trimmed(value: object, limit: int = 3000) -> str:
    text = json.dumps(value, indent=2, sort_keys=True)
    return text if len(text) <= limit else text[:limit] + "\n... (truncated)"


# MARK: - The console, which is plain bytes


def plain_console(text: str) -> str:
    return text.replace("\r", "")


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
            for line in plain_console(text).splitlines():
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


# MARK: - main


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--argv-json", required=True)
    parser.add_argument("--qemu-bin", default="qemu-system-aarch64")
    parser.add_argument("--expect", action="append", default=[],
                        help="guest console text that means the machine booted")
    parser.add_argument("--forbid", action="append", default=[],
                        help="guest console text that must NOT appear")
    parser.add_argument("--expect-removable", action="store_true",
                        help="QEMU must report some device as removable media")
    parser.add_argument("--expect-medium", action="append", default=[],
                        help="a path some device must report as its inserted medium")
    parser.add_argument("--min-read-bytes", type=int, default=0,
                        help="the guest must have read at least this much from the discs")
    parser.add_argument("--note", action="append", default=[],
                        help="console text worth reporting, and not required")
    parser.add_argument("--what", default="the guest",
                        help="what this run is, for the report")
    parser.add_argument("--connect-timeout", type=float, default=30)
    parser.add_argument("--console-timeout", type=float, default=300)
    parser.add_argument("--qmp-timeout", type=float, default=30)
    parser.add_argument("--settle", type=float, default=0,
                        help="seconds to keep reading the console before the "
                             "statistics are read, for work that outlives its output")
    parser.add_argument("--quit-timeout", type=float, default=30)
    parser.add_argument("--echo-console", action="store_true", default=True)
    parser.add_argument("--save-console",
                        help="write the guest's console output here, whatever happens")
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
    # The last two arguments are the harness's own, and are printed with the
    # rest so the log never shows a command line that was not run.
    qmp_path = str(workdir / "qmp.sock")
    command = [args.qemu_bin] + with_qmp(argv[1:], f"unix:{qmp_path},server=on,wait=off")
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
    qmp: socket.socket | None = None
    status = 1
    try:
        deadline = time.monotonic() + args.connect_timeout
        try:
            console = connect(console_path, deadline)
        except SystemExit as error:
            process.kill()
            print(str(error), file=sys.stderr)
            print(plain(log.read_text(encoding="utf-8", errors="replace"))[-4000:],
                  file=sys.stderr)
            return 1
        monitor = connect(monitor_path, deadline)
        qmp = connect(qmp_path, deadline)
        query = Qmp(qmp)
        if not query.handshake(time.monotonic() + args.qmp_timeout):
            print(f"ERROR: QMP did not answer the handshake: {trimmed(query.greeting)}",
                  file=sys.stderr)
            return 1

        version = query.execute("query-version", None, time.monotonic() + args.qmp_timeout)
        if isinstance(version, dict):
            qemu = version.get("qemu")
            if isinstance(qemu, dict):
                qemu = ".".join(str(qemu.get(part, "?")) for part in ("major", "minor", "micro"))
            package = version.get("package")
            print(f"  host qemu: {qemu}" + (f" ({package})" if package else ""))
        else:
            print(f"  host qemu: (not reported: {trimmed(version)})")

        # The drives first: what QEMU thinks it was given is a property of the
        # device the vector created, and it answers before the guest does
        # anything at all.
        blocks = query.execute("query-block", None, time.monotonic() + args.qmp_timeout)
        if blocks is None:
            print("ERROR: QMP did not answer query-block", file=sys.stderr)
            return 1
        print("  drives:")
        for line in describe(blocks):
            print(f"    {line}")

        if args.expect_removable:
            names = removable_devices(blocks)
            if names:
                print(f"  removable media ok: {', '.join(names)}")
            else:
                print("ERROR: no device is reported as removable media, so the "
                      "image did not arrive as a disc: " + trimmed(blocks), file=sys.stderr)
                return 1
        for wanted in args.expect_medium:
            names = devices_with_medium(blocks, wanted)
            if names:
                print(f"  medium ok: {names[0]} holds {wanted}")
            else:
                print(f"ERROR: no device reports {wanted} as its medium: "
                      + trimmed(blocks), file=sys.stderr)
                return 1

        # Then the guest: the firmware's own output on the console socket. Read
        # only when there is something to look for, or for as long as --settle
        # asks: a run that asserts nothing about the console should not sit on
        # an empty socket until its timeout, which is a hang wearing a hat.
        if args.expect:
            matched = read_until(console, time.monotonic() + args.console_timeout,
                                 args.expect, seen, "guest", args.echo_console)
            guest = "".join(seen)
            if matched:
                print(f"\n  console match: {matched!r} after {len(guest)} bytes")
            else:
                print(f"\nERROR: none of {args.expect} appeared in {len(guest)} bytes of "
                      "guest console output", file=sys.stderr)
                print(f"  everything the guest said:\n"
                      f"{plain_console(guest)[-2000:] or '(nothing)'}", file=sys.stderr)
                return 1
        else:
            print("\n  console: nothing is required of it on this run")
            if args.settle:
                read_until(console, time.monotonic() + args.settle, [], seen,
                           "guest", args.echo_console)
                guest = "".join(seen)

        for text in args.note:
            print(f"  also seen: {text!r}" if text in guest else f"  not seen: {text!r}")

        # Keep reading for a while: a bootloader's output can end long before the
        # work that proves it ran finishes.
        if args.settle and args.expect:
            read_until(console, time.monotonic() + args.settle, [], seen, "guest",
                       args.echo_console)
            guest = "".join(seen)

        for text in args.forbid:
            if text in guest:
                print(f"ERROR: the guest console contains {text!r}, which must not "
                      "happen on this command line", file=sys.stderr)
                return 1
            print(f"  absent as required: {text!r}")

        if args.min_read_bytes:
            stats = query.execute("query-blockstats", None, time.monotonic() + args.qmp_timeout)
            if stats is None:
                print("ERROR: QMP did not answer query-blockstats", file=sys.stderr)
                return 1
            total = read_bytes(stats)
            if total >= args.min_read_bytes:
                print(f"  disc reads ok: {total} bytes read from the machine's "
                      f"drives (>= {args.min_read_bytes})")
            else:
                print(f"ERROR: only {total} bytes were read from the drives; the guest "
                      f"never consumed the image (>= {args.min_read_bytes} required)",
                      file=sys.stderr)
                return 1

        # Stop, the way the app's Stop button does it: one word, on the socket
        # the launcher owns.
        monitor.sendall(b"quit\n")
        try:
            code = process.wait(timeout=args.quit_timeout)
        except subprocess.TimeoutExpired:
            print("ERROR: `quit` on the monitor did not stop QEMU", file=sys.stderr)
            return 1
        print(f"  quit on the monitor: QEMU exited {code}")
        if code != 0:
            print(f"ERROR: QEMU exited {code} after `quit`", file=sys.stderr)
            return 1
        status = 0
    finally:
        guest_so_far = plain_console("".join(seen))
        if args.save_console:
            pathlib.Path(args.save_console).write_text(guest_so_far, encoding="utf-8")
        for sock in (console, monitor, qmp):
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
        for line in plain(engine).strip().splitlines()[-20:]:
            print(f"    | {line}")
    if status == 0:
        print(f"\n{args.what}: booted, and stopped on quit")
    return status


if __name__ == "__main__":
    sys.exit(main())
