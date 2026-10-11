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

Four things have to be true, and `LinuxEngineSupport` asks for them
separately: `hasQEMUCore` (the engine is in the bundle), `hasTCGInterpreter` (it
was built with `--enable-tcg-interpreter`), `hasJITCore` (it was built with
TCG's JIT) and `hasLauncher` (the app knows how to start a machine with it). A
fifth, runtime question - does this machine have anything to boot from - is
`LinuxBootCheck`, asked last, because a missing image is not the interesting
problem when there is no engine at all.

`hasJITCore` is the one that was missing, and its absence was not cosmetic. The
published payload is interpreter-only, so it cannot run the JIT configuration at
all - but `LinuxEnginePlan.resolve` used to choose the engine from what the
*environment* wanted ("this machine would be faster with JIT") and what the
debugger was doing, never from what the build had. Any environment with
`requiresJIT` set - which was the default a new environment was created with -
plus a debugger therefore started with `-accel tcg,thread=multi` on an engine
that has no JIT. QEMU's way of refusing an accelerator it does not have is to
print the reason and call `exit(1)`, and in a process that embeds QEMU that exit
is the app: press Start and Madeira is gone, with no window, no message and
nothing in any log. `resolve` now asks the build first, `arguments` asks it again
before writing the accelerator, and `LinuxMachineConsole.start` refuses a `.utm`
launch outright in a build with no JIT core.

The engine is not linked. It is **embedded and dlopened**:

1. `linux-engine.yml` publishes `sysroot-iOS-TCI-arm64` as the release asset
   `qemu-ios-tci-arm64.tar.gz` (tag `payloads`). A release asset rather than the
   artifact, because the artifact expires after fourteen days and an app build
   in another repository cannot read it at all. It is **trimmed before it is
   tarred** - see "The payload is a build tree" below.
2. `build.yml` fetches it with `build/ci/fetch-payload.sh` into
   `app/Madeira/qemu-ios/`, which is a **folder reference** in the target, so
   the sysroot ships verbatim in the bundle. It is trimmed there too, so an
   asset published before the trim existed still ships correctly.
3. The same step exports `MADEIRA_ENGINE_FLAGS`, and
   `SWIFT_ACTIVE_COMPILATION_CONDITIONS` forwards it, so `MADEIRA_HAS_QEMU`,
   `MADEIRA_HAS_QEMU_TCGI` and `MADEIRA_HAS_QEMU_LAUNCHER` reach the Swift
   compiler. Without the payload the variable is empty and the app says the
   engine is absent - which is true.

`tools/add_engine_embed.py` makes the three project-file edits and checks them
(`--check`, run by build.yml's verify job): the folder reference, the flag
forward, and `@executable_path/qemu-ios/Frameworks` in the app's
`LD_RUNPATH_SEARCH_PATHS`.

Why dlopen rather than link: a static link adds a 400 MB archive and every
dependency framework to the link line, each with its own install names to
rewrite; `--enable-shared-lib` exports exactly the three entry points a driver
needs (`qemu_init`, `qemu_main_loop`, `qemu_cleanup`); and a dlopen failure is
reported where it happens instead of reading as a broken toolchain.

### The payload is a build tree, and the framework is the part that loads

UTM's sysroot is what its build directory looks like, not what its app runs,
and the difference matters twice over.

The same libraries are in it **twice**. Under `lib/` they name themselves and
their dependencies with the absolute path of the machine that built them -
`/Users/runner/work/.../utm/sysroot-iOS-TCI-arm64/lib/libglib-2.0.0.dylib` -
which resolves on no device, and the copies are plain files beside `.a`
archives, gstreamer plugin directories and 1,093 headers. Under `Frameworks/`
the same libraries are `@rpath/<name>.framework/<name>`, each in a bundle with
an `Info.plist`, and those are the ones a device can open. So the launcher
dlopens `Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu` and
`lib/` is deleted before packaging.

Nothing in the payload carries an `LC_RPATH`, so the `@rpath` names have to be
resolved against a search path the app provides: `@executable_path/Frameworks`,
the standard one, plus `@executable_path/qemu-ios/Frameworks` for a build that
has not been through the packaging step. Without them the engine opens and dyld
then cannot find glib.

### Where the frameworks end up, and why that is load-bearing

The sysroot ships the frameworks under `qemu-ios/Frameworks/`, and the launcher
used to look for them there. It does not any more, and the move is the second
half of the crash fix above.

The frameworks are Mach-O libraries. dyld will not load one whose signature does
not match, and a file copied into the bundle as a **resource** - which is what a
folder reference is - is sealed by the bundle signature but is not itself
signed. This project already knew that in one place: the "Sign bundled dylibs"
phase ad-hoc signs `d3d12/libmetalirconverter.dylib` and its comment says why.
Fifty-five more libraries could not be signed there, so `build.yml`'s "Package
the unsigned IPA" step now, in order:

1. moves `qemu-ios/Frameworks/*.framework` to the bundle's own `Frameworks/`,
2. ad-hoc signs every framework binary (`codesign --force --sign -`), and
3. refuses to package anything that is not 1:1 with the frameworks it moved.

`Frameworks/` is the destination for the second reason as well: it is the one
directory a sideloader has to walk, because it is where Xcode puts embedded
frameworks, so a re-signing tool signs what it finds there. Under `qemu-ios/`
the same files are only reached by a tool that walks every nested directory,
which is a property of the signer and not something this app can promise.
`LinuxBootCheck` looks in the bundle's `Frameworks/` first and still accepts the
sysroot, so a local build - which has no packaging step - keeps working, and
`tools/inspect-ipa.py` accepts either location and reports which one it found.

### When the engine does explain itself

QEMU writes errors to stderr, and in an app that embeds it that output went to
the device console where nobody reads it. `EngineOutputCapture` now takes over
stdout and stderr for the life of a machine, streams both into the console
screen and appends them to `Documents/linux-engine.log` - on the device, in the
Files app, and still there after an `exit(1)` takes the process with it. The
argument vector and the exit code are written to the same file, so it reads as
one story. This is the difference between "the machine crashed" and a bug
report, and it is the reason a QEMU that refuses is now diagnosable rather than
fatal to the whole app.

And it ships all seven simulation targets when one is used. Measured on the
published asset (398,119,937 bytes) and on the IPA built from it:

| | whole payload | trimmed |
|---|---|---|
| sysroot | 3,010 MiB in 12,442 files | **~305 MiB in ~250 files** |
| of which `lib/` | 1,331 MiB | 0 (the build tree) |
| of which `Frameworks/` | 1,289 MiB | 233 MiB (one target, not seven) |
| of which `share/` | 354 MiB in 10,712 files | ~70 MiB (`qemu/` firmware and keymaps, `glib-2.0/` schemas) |
| build-8 IPA | 534 MB, unpacking to 3.5 GiB in 14,136 entries | one a sideloader re-signs |

That last row is the reason: SideStore could not re-sign the 3.5 GiB archive,
and what it reported named a Mach-O slice because that is where its walk over
the tree stopped. An uninstallable app is not a feature, so the payload is
trimmed by `build/ci/trim-qemu-sysroot.sh`, which asserts that the engine and
every framework its load commands name survive the trim, and `build.yml`
refuses to publish an IPA that fails `tools/inspect-ipa.py`.

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
| `Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu` | the engine the launcher dlopens, `@rpath`-named |
| `Frameworks/*.framework` | 54 more bundles: the 11 dependencies the engine names, and theirs, closing over every `@rpath` name in the tree |
| `share/qemu/edk2-aarch64-code.fd` | the read-only UEFI firmware, 64 MiB |
| `share/qemu/edk2-arm-vars.fd` | the **template** for the writable EFI variables, 321 KB |
| `share/qemu/` | QEMU's data directory, which `-L` points at |
| `loader/` | the Vulkan loader `virglrenderer` looks for |

The launcher uses the **pflash pair**, not `-bios`: `-drive
if=pflash,readonly=on,file=edk2-aarch64-code.fd` plus a per-machine writable copy
of `edk2-arm-vars.fd` in the machine's own folder. Both forms boot; only the pair
lets the firmware remember a boot entry, and a copy per machine keeps one
machine's boot order out of another's.

**The copy is written, not copied, and this was the crash.** Two flash banks of
QEMU's `virt` machine are one size, and the pair that ships is 64 MiB of code
against 321 KB of variables, because `edk2-arm-vars.fd` is an nvram *template* -
the descriptor above calls it exactly that: the initial contents of a file that
has to be as large as the bank. Handing QEMU the template itself does not
produce a firmware without saved variables; it produces

```
qemu-system-aarch64: device requires 67108864 bytes, block backend provides 329216 bytes
```

and a process that exits during `qemu_init`, which inside an app that embeds
QEMU is the app. The report was "Ubuntu crashes immediately", and this was it.
`LinuxBootCheck.writableVars` now extends the template to the size of the code
image (the bank that is known to fit), and replaces a short file it finds rather
than returning it, because the machine folder outlives an app update and every
device that hit this has one on disk. It was found by
`linux-boot-smoke` on its first run - see "What can be checked without a
device" below - after three days of the failure surviving because nothing could
start the machine.

`-kernel`/`-initrd` direct boot is not implemented because no catalogue image
ships a separable kernel. A user-supplied kernel would be the next addition, and
`LinuxBootCheck` is where it would be checked.

### 3. The disc is an optical disc, and only a CD-ROM front end is one

A desktop ISO in `LinuxDistroCatalog` is not a disk image with a filesystem on
it; it is an ISO9660 volume with an El Torito boot catalogue whose EFI entry the
firmware runs. Two separate things have to be true in the argument vector, and
the first is not enough without the second:

* the **backend** is `media=cdrom,readonly=on`, because the image is read-only
  optical media;
* the **front end** is a `scsi-cd` on a `virtio-scsi-pci` controller, because
  `virtio-blk` is a disk device. `media=cdrom` on a virtio-blk drive describes
  the backend and not what the guest is given: the UEFI driver for it, in EDK2's
  `OvmfPkg/VirtioBlkDxe`, reports its media as non-removable, and the El Torito
  catalogue is then found, if at all, by accident of the partition scanner's
  tolerance for a 512-byte block device. QEMU's own storage guidance says the
  same thing - virtio-blk has no CD-ROM, virtio-scsi does.

Both device models are in the published payload (`virtio-scsi-pci`, `scsi-cd`,
and the `virtio-scsi-*` aliases), which was checked rather than assumed: a
device the engine does not have is a machine that refuses to start.

This is also the check that `tools/check_launcher_argv.py` refuses an .iso for:
an optical image attached to a disk front end is not a slow boot, it is no boot
at all.

### 4. Keep the cost in view

One engine build is about **forty-five minutes of macOS runner** and it takes
the whole dependency tree with it. That is why the engine workflow is
`workflow_dispatch` only - `build.yml` publishes a release on every push, and a
multi-hour job there would turn every push red while it iterated. Change one
thing per run, and read the first error rather than the last.

## What can be checked without a device

The engine is a Mach-O built for iOS (`LC_BUILD_VERSION` platform 2), so no
simulator and no Mac can load it, and the app cannot be run anywhere but on a
device. That is a property of the payload and not a choice, and it is how three
days of "Ubuntu crashes immediately" went without anything anyone could run.

The question splits, though. Whether the **command line** boots a machine is a
question about QEMU and about the firmware this app ships, and both of those can
be answered on a runner:

* `tools/check_launcher_argv.py` reads the vector out of
  `LinuxMachineConsole.arguments`, fills in the values a launch would have
  resolved (the firmware pair, the console and monitor sockets, `-L`), and
  refuses it for the mistakes that produce a machine that does
  not boot: an accelerator the build cannot have, an `.iso` on a disk front end,
  a chardev that waits for a reader, a firmware pair without its writable half,
  a missing `-L`. Its `--self-test` mutates the real source into each of those
  and requires each to be refused, because a gate that cannot fail is a comment.
* `tools/boot_smoke.py` runs exactly that vector against a host QEMU, with the
  firmware images from the payload release, and requires the firmware's own
  output on the console socket; then `quit` on the monitor socket, which is the
  Stop button's own mechanism, and an exit status of 0.

`build.yml`'s `linux-boot-smoke` job does this on every build, twice: a machine
whose disk holds nothing, which boots the firmware and reaches its boot manager,
and an installer ISO (Alpine's virtual flavour, pinned by version and hash),
which must be reported as removable media by QEMU, must produce a boot option in
the firmware, and must be read from - the last as `rd_bytes` on the disc, so a
bootloader that starts and dies cannot pass as a boot.

What this does **not** prove is the other half: that the iOS build of QEMU
boots it on an iPhone. That part is answered on the device, by
`Documents/linux-engine.log`, which the launcher writes to because a message on
the screen of an app that has just exited is no message at all.

## Licensing

QEMU is GPL-2.0 and UTM is GPL-3.0-or-later. Madeira is GPL-3.0-or-later, so
linking QEMU into it is compatible, and the notices the app already ships cover
the rest.
