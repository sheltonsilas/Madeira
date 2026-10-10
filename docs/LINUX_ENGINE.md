# The Linux engine

This page is about the thing that runs a Linux machine: what it is, what builds
today, and what is left. It is written down because the state of it is the
question "does Linux work yet" always resolves to, and the answer has three
parts that are easy to confuse.

## What runs a guest

Windows programs are run by FEX and Wine. A Linux machine is not: FEX has no
interpreter, so it cannot run without a debugger (see docs/JIT.md, "Why there
is no interpreter for Windows programs"). A machine is run by **QEMU**, the
engine inside UTM, and QEMU's TCG has two build-time configurations:

| | Build flag | Needs a debugger | What it is |
| --- | --- | --- | --- |
| UTM | TCG's JIT | yes | Guest code is compiled to host code |
| UTM SE | `--enable-tcg-threaded-interpreter` | **no** | Guest code is interpreted |

The second row is the answer to "make Linux work without JIT". It allocates no
executable memory, so iOS does not need to grant any, so no debugger is needed.
`LinuxEnginePlan.resolve` (`app/Madeira/Variant/LinuxEngine.swift`) picks between
them per machine, and falls back to the interpreter rather than refusing when a
machine asks for JIT and there is no debugger.

## What builds today

`.github/workflows/linux-engine.yml` builds the iOS sysroot from UTM's pinned
sources rather than re-solving it: UTM already patches this dependency tree for
iOS, and its QEMU packaging is pinned in `patches/sources`
(`qemu-10.0.12-utm`, pixman 0.38.0, libslirp v4.9.1), with UTM itself pinned at
`7eadb056ae0f91d979059544d0ddcd2d5a40be92`.

**The interpreter-only build succeeded on 2026-10-09.** What it produced, read
from the run rather than assumed:

- an artifact of **420.5 MiB**, holding `sysroot-iOS-TCI-arm64/`;
- `libqemu-aarch64-softmmu.dylib` and the same library for i386, x86_64, m68k,
  ppc, ppc64, riscv64 and `qemu-img` - QEMU is built with `--enable-shared-lib`,
  so these are dynamic libraries, not static archives;
- the dependencies beside them, each rewritten into a `.framework` by UTM's
  `fixup.sh` (glib, pixman, virglrenderer, opus, turbojpeg, gstreamer, and the
  rest), under `sysroot-iOS-TCI-arm64/Frameworks/`;
- the script's own last line: `All done!`, followed by the `sysroot-iOS-TCI-arm64`
  directory being uploaded.

### The one thing that had to be removed to get there

It stopped, five times, on dependencies the previous run had not reached - and
then on something no dependency could fix:

```
src/kosmickrisp/bridge/mtl_argument_table.m:9:10: fatal error:
  'Metal/MTL4ArgumentTable.h' file not found
```

Kosmickrisp is Mesa's Vulkan-on-Metal driver and it needs Metal 4, which ships
with the Xcode 26 SDK; the runner has Xcode 16.4. The workflow now comments out
the two post-QEMU GPU driver steps (`build_vulkan_drivers`, `build_d3d_drivers`)
and asserts that the lines it is commenting out were found, so a UTM revision
that renames them fails loudly instead of silently doing nothing. They run after
`build $QEMU_DIR`, so removing them cannot change what QEMU compiles to. The
same trade UTM SE makes - no GPU, runs on a stock device - is the one being
taken.

## How it reaches the app

Three things have to be true, and `LinuxEngineSupport` asks for them
separately: `hasQEMUCore` (the engine is in the bundle), `hasTCGInterpreter` (it
was built with `--enable-tcg-interpreter`) and `hasLauncher` (the app knows how
to start a machine with it). A fourth, runtime question - does this machine have
anything to boot from - is `LinuxBootCheck`, asked last, because a missing image
is not the interesting problem when there is no engine at all.

The engine is not linked. It is **embedded and dlopened**:

1. `linux-engine.yml` publishes `sysroot-iOS-TCI-arm64` as the release asset
   `qemu-ios-tci-arm64.tar.gz` (tag `payloads`). A release asset rather than the
   artifact, because the artifact expires after fourteen days and an app build
   in another repository cannot read it at all.
2. `build.yml` fetches it with `build/ci/fetch-payload.sh` into
   `app/Madeira/qemu-ios/`, which is a **folder reference** in the target, so
   the sysroot ships verbatim in the bundle.
3. The same step exports `MADEIRA_ENGINE_FLAGS`, and
   `SWIFT_ACTIVE_COMPILATION_CONDITIONS` forwards it, so `MADEIRA_HAS_QEMU`,
   `MADEIRA_HAS_QEMU_TCGI` and `MADEIRA_HAS_QEMU_LAUNCHER` reach the Swift
   compiler. Without the payload the variable is empty and the app says the
   engine is absent - which is true.

`tools/add_engine_embed.py` makes the two project-file edits and checks them
(`--check`, run by build.yml's verify job).

Why dlopen rather than link: a static link adds a 400 MB archive and every
dependency framework to the link line, each with its own install names to
rewrite; `--enable-shared-lib` exports exactly the three entry points a driver
needs (`qemu_init`, `qemu_main_loop`, `qemu_cleanup`); and a dlopen failure is
reported where it happens instead of reading as a broken toolchain.

See docs/PAYLOADS.md for the pipeline itself.

## What is left

### 1. The guest's screen

`QEMULauncher.swift` starts a real machine and reads its serial console back
over a Unix socket, and Stop is a `quit` on QEMU's own monitor. What it does not
do is draw the guest: `-display none` is passed deliberately.

A graphical machine needs a scanout path. QEMU's shared-memory framebuffer
backend plus a renderer is what UTM's `QEMURenderServer` does; `virglrenderer` is
in the sysroot, but the Metal path was removed with kosmickrisp, so GPU
acceleration is not on the table. This is the same shape of problem the Windows
side already solved with `MetalHostView`.

### 2. UEFI firmware: present, and verified

An arm64 cloud image - every entry in `LinuxDistroCatalog` except the desktop
ISO - boots its own kernel from the ESP, so it needs UEFI firmware.

It is there. The published payload (`payloads` release,
`qemu-ios-tci-arm64.tar.gz`, 398,119,937 bytes) was read back entry by entry, and
it carries the pair QEMU's own `share/qemu/firmware/60-edk2-aarch64.json`
descriptor names:

| Path in the archive | What it is |
|---|---|
| `lib/libqemu-aarch64-softmmu.dylib` | the engine the launcher dlopens |
| `share/qemu/edk2-aarch64-code.fd` | the read-only UEFI firmware |
| `share/qemu/edk2-arm-vars.fd` | the writable EFI variables image |
| `share/qemu/` | QEMU's data directory, which `-L` points at |
| `Frameworks/*` | the dependency frameworks, install names rewritten by UTM's `fixup.sh` |

The launcher uses the **pflash pair**, not `-bios`: `-drive
if=pflash,readonly=on,file=edk2-aarch64-code.fd` plus a per-machine writable copy
of `edk2-arm-vars.fd` in the machine's own folder. Both forms boot; only the pair
lets the firmware remember a boot entry, and a copy per machine keeps one
machine's boot order out of another's.

`-kernel`/`-initrd` direct boot is not implemented because no catalogue image
ships a separable kernel. A user-supplied kernel would be the next addition, and
`LinuxBootCheck` is where it would be checked.

### 3. Keep the cost in view

One engine build is about **forty-five minutes of macOS runner** and it takes
the whole dependency tree with it. That is why the engine workflow is
`workflow_dispatch` only - `build.yml` publishes a release on every push, and a
multi-hour job there would turn every push red while it iterated. Change one
thing per run, and read the first error rather than the last.

## Licensing

QEMU is GPL-2.0 and UTM is GPL-3.0-or-later. Madeira is GPL-3.0-or-later, so
linking QEMU into it is compatible, and the notices the app already ships cover
the rest.
