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

## What is left

### 1. Link it into the app

`MADEIRA_HAS_QEMU` and `MADEIRA_HAS_QEMU_TCGI` are compilation conditions that
`LinuxEngineSupport` reads. Neither is set, so `hasQEMUCore` is false and a
machine says so. Setting them without linking the libraries would be a lie of
exactly the kind this app has already been criticised for, so the order is:

1. Publish the sysroot somewhere the app build can reach it. The artifact
   expires after fourteen days and `actions/download-artifact` does not cross
   repositories. A **release asset under a fixed tag** in the build host does
   both: stable URL, no expiry, no token. The engine workflow should create it
   once and upload the tarball there.
2. Fetch it in `build.yml` and link `libqemu-aarch64-softmmu.dylib`, then embed
   it and the `Frameworks/` it depends on, the way `StikJIT.xcframework` is
   embedded today. This is the project file work, not the hard part.
3. Set `MADEIRA_HAS_QEMU` for the core and `MADEIRA_HAS_QEMU_TCGI` for the TCI
   sysroot, in `project.pbxproj`, beside `MADEIRA_VARIANT_FLAG`.

### 2. Write the launcher

Linking QEMU does not start a machine. Something has to take an environment
record - image, RAM, vCPUs, display - and turn it into QEMU's argument vector,
give the guest somewhere to draw and somewhere to type, and stop it again. That
is `MADEIRA_HAS_QEMU_LAUNCHER`, a third condition rather than a second, because
"the emulator is missing" and "nothing here knows how to start the emulator" are
different problems with different fixes.

A first useful milestone, in order of decreasing simplicity:

1. A command-line machine: `-M virt -cpu max -m <ram> -smp <vcpus>`, UEFI
   firmware (`edk2-aarch64`), the downloaded cloud image as a drive, and the
   serial console redirected to a pipe that the app renders as text. This is the
   smallest thing that boots the images `LinuxDistroCatalog` already lists and
   verifies checksums for.
2. A graphical machine, which needs a display backend. QEMU's own
   `-display` with a shared-memory framebuffer is what UTM's `QEMURenderServer`
   does; `virglrenderer` is already in the sysroot, but the Metal path was
   removed with kosmickrisp, so GPU acceleration is not on the table yet.

Firmware is the part worth naming early: an arm64 cloud image does not boot
without UEFI, and the firmware is a build input like any other.

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
