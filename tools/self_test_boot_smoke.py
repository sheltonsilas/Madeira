#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Prove what tools/boot_smoke.py does with an answer, without QEMU.

WHY THIS EXISTS
The boot smoke test runs on a runner with a host QEMU, which means every
mistake in it costs a full build to find out about. It has already cost one:
the reader asked the app's monitor `info block`, got the *echo of the question*
back - `i\\x1b[K\\x1b[Din\\x1b[K...` - looked for `/Removable media: +Yes/` in it,
found nothing, and failed a run that had actually booted. The command line was
fine; the harness was reading the wrong text.

So the harness now asks QEMU's structured channel instead, and this file is how
that is checked here, on a machine with no QEMU at all:

  * the parsing, the device checks and the byte accounting are pure functions,
    and are called directly with the shapes QEMU documents for `query-block`;
  * the whole of `main()` - sockets, handshake, checks, `quit`, exit status - is
    run against a fake QEMU written in Python, talking the same two protocols
    over real sockets. Nothing about the flow is stubbed except the emulator.

The regression this file exists to keep: a CD-ROM check that passes when the
image was attached to a *disk*. `--expect-removable` has to fail for the
virtio-blk shape below, which is the mistake that was made and fixed - an .iso
is an optical disc, and a disk front end finds no partition table on one.

  python3 tools/self_test_boot_smoke.py     # exit 0 all good, 1 something wrong
"""

from __future__ import annotations

import contextlib
import io
import json
import pathlib
import socket
import sys
import threading
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import boot_smoke  # noqa: E402  (after the path insert, on purpose)


FAILURES: list[str] = []


def check(condition: bool, what: str) -> None:
    if condition:
        print(f"  ok: {what}")
    else:
        print(f"  FAILED: {what}")
        FAILURES.append(what)


# MARK: - Fixtures
#
# Shapes, not inventions: `query-block` reports a front end with `device`,
# `qdev`, `removable` and `inserted`, and the inserted medium carries `file`.
# The first is what the launcher's vector produces for an .iso; the second is
# what it produced before the disc fix, and is here as the negative case.

ISO_ON_A_DISC = [
    {
        "device": "cd0",
        "qdev": "/machine/peripheral/scsi0/scsi0.0",
        "removable": True,
        "locked": False,
        "tray_open": False,
        "inserted": {"file": "/tmp/installer.iso", "drv": "raw", "ro": True},
    },
    {
        "device": "", "qdev": None, "removable": False, "locked": False,
        "inserted": None, "node-name": "#block174", "file": "/tmp/installer.iso",
    },
]

ISO_ON_A_DISK = [
    {
        "device": "virtio0",
        "qdev": "/machine/peripheral/virtio0/virtio0.0",
        "removable": False,
        "locked": False,
        "tray_open": False,
        "inserted": None,
    },
    {
        "device": "", "qdev": None, "removable": False, "locked": False,
        "inserted": None, "node-name": "#block174", "file": "/tmp/installer.iso",
    },
]

STATS = [
    {"device": "cd0", "stats": {"rd_bytes": 131072, "rd_operations": 40}},
    {"device": "", "node-name": "#block174",
     "stats": {"rd_bytes": 81920, "rd_operations": 8},
     "parent": {"stats": {"rd_bytes": 4096, "rd_operations": 1}}},
]

# Recorded from a real monitor socket: the echo of `info version` as it arrived
# during the run that failed, escape sequences and all.
RECORDED_HMP_ECHO = (
    "i\x1b[K\x1b[Din\x1b[K\x1b[D\x1b[Dinf\x1b[K\x1b[D\x1b[D\x1b[Dinfo\x1b[K"
    "\x1b[D\x1b[D\x1b[D\x1b[Dinfo \x1b[K\x1b[D\x1b[D\x1b[D\x1b[D\x1b[Dinfo v"
    "\x1b[K\x1b[D\x1b[D\x1b[D\x1b[D\x1b[D\x1b[Dinfo ve\x1b[K\r\n"
    "QEMU 8.2.2 monitor - type 'help' for more information\r\n"
    "(qemu) i\x1b[K\r\n"
)


# MARK: - Pure functions


def test_plain_strips_the_echo() -> None:
    text = boot_smoke.plain(RECORDED_HMP_ECHO)
    check("\x1b" not in text, "the recorded monitor echo has no escape left in it")
    check("QEMU 8.2.2 monitor" in text, "the answer after the echo survives")
    check("\r" not in text, "carriage returns are gone, so the log has no overwrite")
    # And the reason nothing is parsed out of this any more. Stripping the redraw
    # sequences does not put the line back together: every character of
    # `info version` is in there once per redraw, so the result reads
    # `iininfinfoinfo info vinfo vein...`. Removing the escapes makes it
    # printable, which is all it is for; it does not make it parseable.
    check("infoinfo" in text,
          "the echo of the typed command strips to interleaved noise, not to the "
          "command - which is why the facts come from QMP")
    check("info version" not in text,
          "and a reader looking for the typed command in it would find nothing")


def test_with_qmp_appends_only() -> None:
    original = ["qemu-system-aarch64", "-M", "virt", "-display", "none"]
    spec = "unix:/tmp/x-qmp.sock,server=on,wait=off"
    combined = boot_smoke.with_qmp(original, spec)
    check(combined[: len(original)] == original,
          "the launcher's own arguments arrive untouched, and in order")
    check(combined[len(original):] == ["-qmp", spec],
          "the harness's channel is the only thing added")
    check(original == ["qemu-system-aarch64", "-M", "virt", "-display", "none"],
          "the vector being extended is not mutated")


def test_device_checks() -> None:
    check(boot_smoke.removable_devices(ISO_ON_A_DISC) == ["cd0"],
          "a disc front end is reported as removable media")
    check(boot_smoke.removable_devices(ISO_ON_A_DISK) == [],
          "a disk front end is not - which is the bug this catches")
    check(boot_smoke.devices_with_medium(ISO_ON_A_DISC, "/tmp/installer.iso") != [],
          "the inserted medium is found by the path that was passed")
    check(boot_smoke.devices_with_medium(ISO_ON_A_DISK, "/tmp/installer.iso") != [],
          "the same file behind a disk front end is found too, on purpose: the "
          "medium check answers 'is it there', the removable check answers 'as what'")
    check(boot_smoke.devices_with_medium(ISO_ON_A_DISC, "/tmp/other.iso") == [],
          "a medium that is not attached is not reported as attached")
    check(boot_smoke.devices(ISO_ON_A_DISC) and boot_smoke.describe(ISO_ON_A_DISC),
          "a device list is described without raising")
    check(boot_smoke.devices_with_medium(None, "/tmp/installer.iso") == [],
          "an empty answer is not a match")


def test_read_bytes() -> None:
    total = boot_smoke.read_bytes(STATS)
    check(total == 131072 + 81920 + 4096,
          f"reads are counted through backing and parent nodes ({total})")
    check(boot_smoke.read_bytes(None) == 0, "nothing is zero, not an exception")


def test_qmp_framing() -> None:
    """The line protocol, including the two things that make it robust: several
    objects in one read, and events interleaved with replies."""
    server, client = socket.socketpair()
    try:
        reader = boot_smoke.Qmp(client)
        # Two objects in one write, split in the middle of the second one: the
        # framing has to survive both, because a socket read is a byte count and
        # not a message.
        server.sendall(b'{"QMP": {"version": {"qemu": {"major": 8}}}}\r\n'
                       b'{"event": "RESET", "data"')
        server.sendall(b': {}}\r\n')
        deadline = time.monotonic() + 5
        greeting = reader._read_object(deadline)
        check(isinstance(greeting, dict) and "QMP" in greeting,
              "the greeting is one object, read across a split buffer")
        event = reader._read_object(deadline)
        check(isinstance(event, dict) and event.get("event") == "RESET",
              "the event that arrives in the same read is parsed, not merged")
        server.sendall(b'{"return": [{"device": "cd0"}]}\r\n')
        reply = reader.execute("query-block", None, deadline)
        check(reply == [{"device": "cd0"}],
              "the reply to the command just sent is returned")
        check(reader.buffer == b"", "nothing is left unread in the buffer")
    finally:
        server.close()
        client.close()


# MARK: - A fake QEMU, over the real socket protocol


class FakeProcess:
    def __init__(self, exited: threading.Event):
        self.exited = exited
        self.killed = False
        self.command: list[str] = []

    def wait(self, timeout: float | None = None) -> int:
        if not self.exited.wait(timeout if timeout is not None else 5):
            raise boot_smoke.subprocess.TimeoutExpired("fake-qemu", timeout)
        return 0

    def poll(self):
        return 0 if self.exited.is_set() else None

    def kill(self) -> None:
        self.killed = True
        self.exited.set()


class FakeQemu(threading.Thread):
    """Plays QEMU's side: a QMP greeting and answers, console output, and a
    monitor that stops the machine on `quit` - the app's own stop path."""

    def __init__(self, console, monitor, qmp, blocks, stats, console_text,
                 answer_block=True):
        super().__init__(daemon=True)
        self.console, self.monitor, self.qmp = console, monitor, qmp
        self.blocks, self.stats = blocks, stats
        self.console_text = console_text
        self.answer_block = answer_block
        self.exited = threading.Event()

    def _lines(self, sock):
        buffer = b""
        while True:
            try:
                ready = boot_smoke.select.select([sock], [], [], 5)
                if not ready[0]:
                    return
                chunk = sock.recv(65536)
            except OSError:
                return
            if not chunk:
                return
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                if not line.strip():
                    continue
                try:
                    yield json.loads(line.decode())
                except ValueError:
                    # The harness closing mid-request is not this fake's problem;
                    # a truncated line is simply not a message.
                    continue

    def run(self) -> None:
        # Each channel is served on its own thread, the way QEMU's own loops are
        # independent of each other: the monitor must be readable while the QMP
        # channel is idle, or the harness's `quit` would wait for a read that is
        # waiting for the `quit`.
        try:
            threading.Thread(target=self.serve_qmp, daemon=True).start()
            threading.Thread(target=self.serve_monitor, daemon=True).start()
            # The guest's console output, written as the firmware would write it.
            if self.console_text:
                self.console.sendall(self.console_text)
        except OSError:
            self.exited.set()

    def serve_qmp(self) -> None:
        try:
            self.qmp.sendall(b'{"QMP": {"version": {"qemu": {"major": 8, '
                             b'"minor": 2, "micro": 2}, "package": "Debian"}}}\r\n')
            for request in self._lines(self.qmp):
                command = request.get("execute")
                if command == "qmp_capabilities":
                    self.qmp.sendall(b'{"return": {}}\r\n')
                elif command == "query-version":
                    self.qmp.sendall(json.dumps({"return": {
                        "qemu": {"major": 8, "minor": 2, "micro": 2},
                        "package": "Debian 1:8.2.2"}}).encode() + b"\r\n")
                elif command == "query-block":
                    if not self.answer_block:
                        continue
                    self.qmp.sendall(json.dumps({"return": self.blocks}).encode() + b"\r\n")
                elif command == "query-blockstats":
                    self.qmp.sendall(json.dumps({"return": self.stats}).encode() + b"\r\n")
        except OSError:
            pass

    def serve_monitor(self) -> None:
        # The monitor is only ever asked to stop, which is how the app's Stop
        # button stops a machine.
        try:
            for line in self._lines(self.monitor):
                if "quit" in json.dumps(line):
                    break
        except Exception:  # a fake, torn down from under a failing test
            pass
        finally:
            self.exited.set()
            for sock in (self.console, self.monitor, self.qmp):
                with contextlib.suppress(OSError):
                    sock.close()


def run_main(arguments: list[str], blocks=None, stats=None, console_text=b"",
             answer_block=True) -> tuple[int, str, FakeProcess, FakeQemu]:
    """Run boot_smoke.main() with a fake QEMU underneath it."""
    pairs = {name: socket.socketpair() for name in ("console", "monitor", "qmp")}
    paths = {name: f"/tmp/fake-{name}.sock" for name in pairs}

    def fake_connect(path: str, deadline: float):
        for name, known in paths.items():
            if path == known:
                return pairs[name][0]
        # The QMP channel's path is the harness's own, chosen inside its working
        # directory, so it is recognised by its name and not by its location.
        if path.endswith("qmp.sock"):
            return pairs["qmp"][0]
        raise AssertionError(f"the harness connected to {path}, which the fake QEMU "
                             "was not told to listen on")

    process = FakeProcess(threading.Event())
    fake = FakeQemu(pairs["console"][1], pairs["monitor"][1], pairs["qmp"][1],
                    blocks if blocks is not None else ISO_ON_A_DISC,
                    stats if stats is not None else STATS,
                    console_text, answer_block=answer_block)
    process.exited = fake.exited

    def fake_popen(command, **kwargs):
        process.command = list(command)
        fake.start()
        return process

    argv_json = pathlib.Path(boot_smoke.tempfile.mkdtemp(prefix="fake-argv-")) / "argv.json"
    argv_json.write_text(json.dumps({
        "image": "/tmp/installer.iso",
        "argv": ["qemu-system-aarch64", "-M", "virt", "-display", "none",
                 "-chardev", f"socket,id=madeira-console,path={paths['console']},server=on,wait=off",
                 "-serial", "chardev:madeira-console",
                 "-chardev", f"socket,id=madeira-monitor,path={paths['monitor']},server=on,wait=off",
                 "-monitor", "chardev:madeira-monitor"],
    }), encoding="utf-8")

    original_connect, original_popen = boot_smoke.connect, boot_smoke.subprocess.Popen
    boot_smoke.connect = fake_connect
    boot_smoke.subprocess.Popen = fake_popen
    original_argv = sys.argv
    sys.argv = (["boot_smoke.py", "--argv-json", str(argv_json), "--qemu-bin", "fake-qemu"]
                + arguments)
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            code = boot_smoke.main()
    finally:
        boot_smoke.connect, boot_smoke.subprocess.Popen = original_connect, original_popen
        sys.argv = original_argv
        for server, client in pairs.values():
            with contextlib.suppress(OSError):
                client.close()
    return code, out.getvalue(), process, fake


def test_main_with_a_disc() -> None:
    console = b"BdsDxe: loading Boot0001 from the CD-ROM\r\nGRUB loading...\r\n"
    code, output, process, _ = run_main(
        ["--what", "an installer ISO", "--expect", "BdsDxe",
         "--forbid", "no bootable option", "--expect-removable",
         "--expect-medium", "/tmp/installer.iso", "--min-read-bytes", "100000"],
        console_text=console)
    print(output)
    check(code == 0, "a machine whose image arrived as a disc passes")
    check("removable media ok: cd0" in output, "the removable check reports the device")
    check("host qemu: 8.2.2" in output.replace("'", ""), "the host QEMU version is reported")
    check("disc reads ok: 217088 bytes" in output,
          "reads are summed over the whole tree, not just the front end")
    check(process.command[len(process.command) - 2] == "-qmp",
          "the fake was started with the harness's channel appended, not replacing")
    check("-M" in process.command and "virt" in process.command,
          "and with the app's own arguments still in place")
    check("GRUB loading" in output, "the guest's console is echoed into the log")


def test_main_with_a_disk() -> None:
    """The regression: the .iso is attached to a disk front end."""
    code, output, _, _ = run_main(
        ["--what", "an installer ISO", "--expect", "BdsDxe",
         "--expect-removable", "--expect-medium", "/tmp/installer.iso"],
        blocks=ISO_ON_A_DISK, console_text=b"BdsDxe: loading...\r\n")
    check(code == 1, "an image on a disk front end is refused, and stops the run")
    check("no device is reported as removable media" in output,
          "and says why: nothing on the machine is a disc")
    check("virtio0" in output, "the device it did get is printed for the reader")


def test_main_without_a_boot() -> None:
    code, output, _, _ = run_main(
        ["--what", "an installer ISO", "--expect", "BdsDxe",
         "--console-timeout", "2"],
        console_text=b"")
    check(code == 1, "a disc with nothing on the console is refused")


def test_main_when_nothing_was_read() -> None:
    code, output, _, _ = run_main(
        ["--what", "an installer ISO", "--expect-removable", "--min-read-bytes", "100000000"],
        stats=[{"device": "cd0", "stats": {"rd_bytes": 2048}}],
        console_text=b"BdsDxe: loading...\r\n")
    check(code == 1, "a machine that never read the image is refused")
    check("only 2048 bytes were read" in output, "and the count is in the message")


def test_main_when_qmp_is_silent() -> None:
    """The harness must fail, and say so, rather than hang: a QMP channel that
    never answers is a broken run, not a booting one."""
    code, output, _, _ = run_main(["--what", "an installer ISO", "--qmp-timeout", "2"],
                                  answer_block=False, console_text=b"BdsDxe\r\n")
    check(code == 1, "a QMP channel that does not answer query-block is a failure")
    check("did not answer query-block" in output, "with the reason named")


def main() -> int:
    tests = [value for name, value in sorted(globals().items())
             if name.startswith("test_") and callable(value)]
    print(f"self test: boot_smoke.py, {len(tests)} groups\n")
    for test in tests:
        print(f"{test.__name__}:")
        test()
        print()
    if FAILURES:
        print(f"{len(FAILURES)} check(s) failed:")
        for failure in FAILURES:
            print(f"  - {failure}")
        return 1
    print("every check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
