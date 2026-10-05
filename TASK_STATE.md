# TASK_STATE.md

Persistent state for the "Madeira variants" task. Re-read at the start of every
work session and before every major decision.

> **Session 2 note.** The brief from session 1 is preserved in the local copy at
> `Documents/TASK_STATE.md`. This repository copy carries the same checklist
> with updated statuses and the architecture summary.

---

## 1. STATUS SUMMARY (read this first)

| Phase | Outcome |
|---|---|
| **0. GitHub access + MCP** | Fork created and public. Token minted and working. **MCP itself could not be registered: this Freebuff build has no MCP client** (`grep -rl mcpServers` over the Freebuff source returns nothing). Used the GitHub REST API directly instead, which achieves the same outcomes. |
| **1. Fork + read + research** | **Done.** Fork at `sheltonsilas/Madeira`. Repo read. Architecture summary in §2. iOS 27 JIT research done — see the important negative finding in §3. |
| **2. Two variants** | **Partially done, and the split is not 50/50.** Variant A's browser and installer flow are written. Section 6 (embedded StikDebug) turns out to be **already satisfied upstream**, so that was wiring, not new code. Variant B is a documented architecture plus a manager model, because the emulator itself cannot be written here. iPad input: the model was added; upstream already has the hard parts. |
| **3. CI + IPA** | Workflow written and wired, and the entire native chain now runs on GitHub's macOS runners — the Wine unix side, ntdll/Win32u/libwineserver, the arm64ec PE farm, and DXMT's 87 objects. **No IPA has been published yet**; the first full `build.yml` run died in `dxmt-ios/combine.sh` on a path the script itself invented (fixed), and the chain was re-dispatched from `f9b0d3e`. See §5 and §9f. |
| **4. Guide** | Done. `GUIDE.md`. |

**The single most important thing to know:** the four submodules are NOT missing.
My session-1 finding (taken from upstream's own `docs/BUILDING.md`) was that a
recursive clone fails because the forks were never pushed. **That is stale.** All
four resolve today, at exactly the pinned commits:

```
FEX            1adb337a   (branch ios-port-2607)
wine           4f5b1971   (branch madeira-lgpl)
dxmt           020a8480   (branch ios-port)
madeira-dock   3cadfbe7   (branch main)
```

A recipient can therefore build this, unlike what upstream's docs say.

---

## 2. UPSTREAM ARCHITECTURE (verified in code, not assumed)

### The translation stack
- **FEX-Emu** translates x86 and x86-64 to ARM64 as code runs.
- **Wine 11.4**, built for **ARM64EC**, provides Windows. Wine itself runs
  natively; only the *guest's* code is translated. 32-bit guests go through WoW64.
- **DXMT** renders Direct3D 9/10/11 on Metal. `madeira-d3d12` is Madeira's own
  D3D12 implementation, converting DXIL with Apple's Metal Shader Converter.
- iOS cannot spawn processes, so **everything is one process**: even Wine's
  server is a thread (`build/wineserver`).

### The app layer (all present, ~37.7k lines)
Largest files: `ContentView.swift` (4410), `Library.swift` (3639),
`HardwareInput.swift` (2123), `Winios/Winios.m` (1929),
`WineProcessBridge.m` (1828).

| Concern | File | Notes |
|---|---|---|
| FEX lifecycle | `FEXBridge.mm`, `FEXBridge.h` | `fex_initialize`, JIT write-offset publishing to `xtajit64.dll` |
| Wine session | `WineProcessBridge.m/.h` | `wine_process_start(prefix_path)`; env-driven via `MADEIRA_EXE`, `MADEIRA_ARGS`, `MADEIRA_USE_ARM64EC`, `MADEIRA_WAIT_CHILDREN` |
| JIT allocator | `JITAllocator.c/.h` | Dual-mapped RW/RX pool; probes `jit_check_debugged()`, `jit_test_mapping()`, `jit_test_execute()`, `jit_cs_status()`, `jit_available_memory()` |
| JIT setup | `JITSetup.swift` (696), `JITNetwork.swift`, `JITPairing.swift` | Pairing file in the **Keychain**, LocalDevVPN loopback checks, Shortcuts integration |
| JIT helper | `StikJITHelper.swift`, `MadeiraJITHelper/` | App extension on the `com.apple.ar.viewer` extension point |
| Display | `GuestDisplay.swift`, `IOSDisplayShim.m` | Metal surface for the guest |
| Input | `HardwareInput.swift`, `TouchGamepad.swift`, `PadKeyboardMouse.swift` | Already covers mouse/trackpad/keyboard/touch |
| Steam | `SwiftSteam/`, `Steam*.swift` | Sign-in, library, downloads, Cloud saves, Madeira Dock |

### Build facts
- Xcode project: Debug + Release. `IPHONEOS_DEPLOYMENT_TARGET` **26.0**.
- `MADEIRA_BUNDLE_IDENTIFIER = com.willfaust.madeora`; helper is `<id>.JITHelper`.
- PE DLL farms **are** tracked: `arm64ec-windows` (144 files),
  `aarch64-windows` (135 files). `app/` is 304 MB.
- Compiled iOS static libs are git-ignored and must be built:
  `libFEXCore.a`, `libntdll_unix.a`, `libwineserver.a`, `libwin32u_unix.a`,
  `libdxmt_combined.a`, `libmadeira_rppairing.a`.
- **Debug is the only configuration that runs games** ("Release builds have
  crashed the guest"). The CI builds Debug only, deliberately.
- Inputs not in the repo: llvm-mingw (downloadable, hash pinned), LLVM-for-iOS
  (hours to build), MSVC runtime DLLs (not redistributable), Metal Shader
  Converter pkg (licence-bound; the library is tracked so not needed).

### Entitlements (already correct upstream — no change needed)
`app/Madeira/Madeira.entitlements` has `get-task-allow`,
`com.apple.security.cs.allow-jit`,
`com.apple.developer.kernel.increased-memory-limit`.

---

## 3. THE iOS 27 JIT FINDING — READ THIS

From SideStore's official documentation (as of 17 June 2026), verbatim:

> "iOS 26 has broken JIT once again, and **26.6 and 27 only work with a few
> apps**. An update has been released to StikDebug with a fix, but support is
> limited."

The apps listed as working on iOS 26.6/27: UTM, Amethyst, MeloNX, maciOS,
DolphiniOS, Geode, Manic EMU, Flycast (iOS 26 fork), MeloCafe, ARMSX2, DukeX.

**Madeira is not on that list.** This does not prove Madeira's built-in helper
fails — it uses a different code path (its own StikJIT extension plus on-device
pairing, which upstream added for iOS 27) — but it is the single biggest
technical risk to this whole task, and it is outside my control.
**UNTESTED; verify on device first, before anything else in GUIDE.md.**

Mitigations already built: the interpreter-only fallback
(`JitManager.forceInterpreter`, `InterpreterFallbackNotice`), the StikDebug deep
link as a second path, and the setup wizard.

---

## 4. WHAT WAS BUILT (all compile-checked only; no Mac, no device)

| File | Purpose |
|---|---|
| `app/Madeira/Variant/AppVariant.swift` | One codebase, two variants, selected by `MADEIRA_VARIANT_LINUX` |
| `app/Madeira/Variant/JitManager.swift` | JIT status via `csops` + a real MAP_JIT probe; StikDebug deep link; auto-poll; interpreter fallback |
| `app/Madeira/Variant/MadeiraBrowserView.swift` | Preinstalled WKWebView browser + download shelf |
| `app/Madeira/Variant/WindowsInstallerBridge.swift` | Stages downloads into `drive_c`, runs `.msi` via msiexec, enumerates installed apps |
| `app/Madeira/Variant/PointerMode.swift` | Trackpad/Touch switch, Pencil, capture, Retina scale, interpreter notice |
| `app/Madeira/Variant/LinuxEnvironmentStore.swift` | UTM-style manager: create/import/export/delete/snapshot, vCPU + RAM limits |
| `tools/add_variant_files.py` | Idempotent pbxproj wiring for the six new sources |
| `tools/check_pbxproj.py` | Structural validator (308 objects, braces/parens balanced, no duplicate or dangling IDs) |
| `.github/workflows/build.yml` | Both variants, macOS runner, caching, JIT invariant gate, IPA upload |
| `GUIDE.md` | Beginner guide for a Windows user |
| `LICENSES/NOTICE` | Licence analysis, including the StikJIT-vs-StikDebug question |

The StikDebug deep link uses the URL format verified from upstream's own caller
in `StikJITHelper.swift`: scheme `stikdebug`, host `enable-jit`, carrying
`bundle-id`, `pid` and `script-data` (base64 `madeira-jit.js`).

---

## 5. WHY NO IPA WAS BUILT (yet) — updated with what CI has proven

Not claimed, and not faked. What has now been **verified by a real run**, not
assumed:

- `Confirm the submodules resolved` **PASSED** on both matrix jobs. A recursive
  clone works on a clean checkout. This directly contradicts upstream's
  `docs/BUILDING.md`, which claims the fork's submodule commits were never
  pushed. **That doc is stale** — see §1.
- The `verify-jit-invariants` job **PASSES on every push**: the three JIT
  entitlements, the JIT helper extension and StikJIT framework, the JIT script
  and `madeira://` URL scheme, and all seven Variant sources being in the
  Sources phase.
- The llvm-mingw download and SHA-256 verification **PASSED**.

The remaining hard link was the LLVM-for-iOS input, and it turned out to be
smaller than upstream's docs imply. Reading `build/dxmt-ios/build.sh` shows
`LLVM_BUILD` is **never linked from**. It is used for exactly two things:

```sh
LLVM_INCLUDES="-I$LLVM_BUILD/include -I$LLVM_SRC/include"   # include path
"$LLVM_BUILD/include/llvm/Config/llvm-config.h"            # shader cache hash
```

Xcode ships those same public headers (including `llvm/Config/llvm-config.h`) in
its own toolchain, so the workflow substitutes a symlink farm
(`toolchains/llvm-ios-build/include -> <Xcode>/usr/include`).

`build/fex-ios/build.sh` needs nothing special at all — it is plain
`cmake -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64
-DCMAKE_OSX_SYSROOT=iphoneos`, which Xcode's clang satisfies.

**UNTESTED:** Xcode's LLVM is not upstream's 15.0.7, so the dxmt-ios step may
still fail on version skew. If it does, the correct fix is a real LLVM-for-iOS
build on hardware with enough disk and RAM, not a better symlink.

**Corrected in session 6 (§9f):** the headers-only substitution above is enough
to *compile* DXMT and not enough to *link* the app. `dxmt-ios/combine.sh` merges
`libdxmt_unix.a` with `toolchains/llvm-ios-build/lib/libLLVM*.a`, because airconv
is a shader compiler that calls into LLVM. Those archives come from the separate
`llvm-ios` workflow (about an hour, on demand) and reach later runs through a
cache — a cache that never restored, for a reason worth knowing:
`actions/cache` hashes the **path list** into a cache's identity, so a cache
written for `toolchains/llvm-ios-build` is invisible to a step that asks for
`toolchains`, whatever the keys say. Both workflows now name the same three
paths the `llvm-ios` workflow does, and assert the archives are there before the
stage that needs them runs.

---

## 6. VARIANT B: WHY THE aarch64 CHOICE IS RIGHT

The worry raised was "there is no hypervisor, so an aarch64 Ubuntu guest cannot
work". It is the reverse.

A hypervisor is only needed to accelerate **emulated** instructions. If the
guest is aarch64 and the host is aarch64 — every iPhone and iPad — the guest's
instructions *are* the host's instructions, so there is nothing to accelerate.
QEMU's TCG only emulates devices: virtio block/net, timer, framebuffer. UTM's
own FAQ says exactly this: "Because iOS devices lack hardware virtualization
support, we cannot use the KVM accelerator and instead use the TCG", and UTM runs
aarch64 Linux guests usefully.

The cost is graphics, not CPU: there is no GPU passthrough on iOS, so the guest
gets a software renderer and the accelerated path has to be rebuilt on Metal —
the work UTM did with its custom display backend. **XFCE or LXQt will be usable;
GNOME's compositor will not be.** An x86_64 guest would instead route every
instruction through TCG at roughly 8–12x slowdown, which is why I did not go
there.

**What is NOT built:** the full-system emulator. This is a multi-month
engineering effort — a QEMU TCG core, a virtio device layer, a Metal display
backend, and a rootfs pipeline. `LinuxEnvironmentStore.swift` is the manager
model and its on-disk format; `export`, `import` and `snapshot` deliberately
throw rather than producing a corrupt file.

---

## 7. LICENCE CONCLUSION (Section 6.7)

The brief said "StikDebug is AGPL-3.0, so embedding its code obliges our fork to
comply with AGPL", and preferred StikJIT where possible. **Upstream already took
that option**: it ships the MPL-2.0 `StikJIT.xcframework`, not AGPL StikDebug
source. MPL-2.0 is file-level copyleft and does not force AGPL.

So: no AGPL code was added, and the fork stays **GPL-3.0-or-later + Madeira
Converter Exception**. Full detail in `LICENSES/NOTICE`. Had AGPL StikDebug been
embedded, the whole fork would have had to become AGPL-3.0.

Not redistributed: MSVC runtime DLLs (not redistributable), any Windows browser
binary (a native WebKit browser is shipped instead, with an empty extension slot
for a future redistribution-safe build), any Ubuntu rootfs, Apple's Metal Shader
Converter.

---

## 8. REQUIREMENT CHECKLIST (reconciled)

Status key: `not started` / `in progress` / `done` / `untested` / `infeasible` /
`upstream-already-done`.

### Phase 0
| # | Requirement | Status | Note |
|---|---|---|---|
| 0.1 | Control Chrome, profile sheltonsilas@Gmail.com | infeasible | Browser tool is an isolated profile. **User signed in there directly**; session now authenticated as `sheltonsilas` |
| 0.2 | Sign in to github.com | done | By the user, in the agent browser |
| 0.3 | Look up current github-mcp-server docs | done | Remote server is OAuth-based and GA; local uses a PAT |
| 0.4 | Create credential | done | Classic PAT, `repo` + `workflow`, 30-day expiry |
| 0.5 | Register MCP server | infeasible | **No MCP client in this Freebuff build.** REST API used instead |
| 0.6 | Confirm by listing repos | done | `/user` returns `sheltonsilas`, 5000 req/hr |
| 0.7 | Record outcome, never store token in a repo | done | Token lives only in `~/.madeira-gh-token` (chmod 600), outside every repository. **Delete after use.** |

### Phase 1
| # | Requirement | Status | Note |
|---|---|---|---|
| 1.1 | Fork, public | done | `sheltonsilas/Madeira`, public, parent `willfaust/Madeira` |
| 1.2 | Read repo fully | done | App layer + all four submodules cloned and read |
| 1.3 | Architecture summary | done | §2 above |
| 1.4 | Research iOS 27 JIT/entitlements/sideloading | done | §3 |
| 1.5 | Read StikDebug, SideStore, AltStore, UTM, FEX | done | UTM FAQ, SideStore JIT docs, FEX tree |
| 1.6 | Optimise for iPad first | untested | Pointer model is iPad-first; no device |

### Phase 2
| # | Requirement | Status | Note |
|---|---|---|---|
| 2.1 | Two targets from one codebase | done | `AppVariant` + compile flag |
| 2.2 | A: preinstalled browser, first launch | untested | `MadeiraBrowserView`; **deviation**: native WebKit, not a Wine PE browser — rationale in file header |
| 2.3 | A: browser choice tested & justified | untested | Justified on paper (FEX is a poor fit for a browser); not measured |
| 2.4 | A: install apps via .exe/.msi | untested | `WindowsInstallerBridge` |
| 2.5 | A: preconfigured prefix | not started | Needs macOS to build a prefix image |
| 2.6 | A: automatic first-run flow | untested | `firstRunProgram` defined; needs ContentView hookup |
| 2.7 | A: downloads folder + Files bridge | untested | `Documents/Downloads`, staged into `drive_c/downloads` |
| 2.8 | A: launcher UI | untested | `AppLauncherView` |
| 2.9 | A: no bundled Windows OS files; licence-checked | done | `LICENSES/NOTICE` |
| 2.10 | B: Ubuntu ARM64 rootfs | not started | Not shipped; none bundled |
| 2.11 | B: desktop | not started | XFCE/LXQt recommended; GNOME reported unsuitable |
| 2.12 | B: Metal-backed display | not started | Needs the QEMU core |
| 2.13 | B: accelerated graphics | not started | No GPU passthrough on iOS; §6 |
| 2.14 | B: audio | not started | Needs the runtime |
| 2.15 | B: clipboard | not started | Needs the runtime |
| 2.16 | B: networking | not started | Needs virtio-net |
| 2.17 | B: shared folders | untested | Manager uses Documents, visible to Files |
| 2.18 | B: terminal with apt | not started | Needs the runtime |
| 2.19 | B: x86_64 via FEX, ARM64 native | not started | FEX does contain Linux host code (`FEX/Source/Common/Linux`) but it targets a Linux kernel |
| 2.20 | B: manager UI with RAM/CPU limits | untested | `LinuxEnvironmentStore` |
| 2.21 | B: speed tuning | not started | Needs the runtime |
| 2.22 | B: state iOS impossibilities | done | §6 |
| 2.23 | iPad: capture + release | untested | Setting added; upstream has the plumbing |
| 2.24 | iPad: relative vs absolute + switch | untested | `PointerMode` |
| 2.25 | iPad: L/R/M click | upstream-already-done | `Winios/WiniosCursor.c`, `HardwareInput.swift` |
| 2.26 | iPad: two-finger scroll/drag/pinch | upstream-already-done | `HardwareInput.swift` |
| 2.27 | iPad: touch-as-mouse / direct touch | upstream-already-done | `TouchControlPresets.swift` |
| 2.28 | iPad: visible guest cursor | upstream-already-done | `WiniosCursor.c`, `GuestDisplay.swift` |
| 2.29 | iPad: Apple Pencil | untested | Toggle added |
| 2.30 | iPad: keyboard + remap | upstream-already-done | `HardwareInput.swift`, `PadKeyboardMouse.swift` |
| 2.31 | iPad: on-screen keyboard | upstream-already-done | `PadKeyboardMouse.swift` |
| 2.32 | iPad: Stage Manager / Split View | untested | `display: .resizable` defined |
| 2.33 | iPad: external display + Retina | untested | `retinaScale` setting |
| 2.34 | iPad: Magic Keyboard / Smart Folio | upstream-already-done | UIKit handles the keyboard |
| 2.35 | Interpreter-only fallback | untested | `InterpreterFallbackNotice` + `forceInterpreter` |
| 2.36 | FEX uses JIT when available | untested | `JitManager.shouldUseJIT` |
| 2.37 | `get-task-allow` entitlement | done (upstream) | Already present |
| 2.38 | Detect JIT at launch | untested | `jit_check_debugged()` + `jit_test_mapping()` |
| 2.39 | Deep-link StikDebug, verified scheme | untested | URL verified from upstream caller |
| 2.40 | Document pairing + VPN | done | `GUIDE.md` §4 |
| 2.41 | SideStore / AltStore / AltJIT | done | `GUIDE.md` §2, §4 |
| 2.42 | Keep interpreter fallback | untested | see 2.35 |
| **6.1** | Embed StikJIT at a pinned commit | upstream-already-done | `app/Frameworks/StikJIT.xcframework`, StikJIT 1.9.0, SHA-256 recorded in `docs/JIT.md` |
| **6.2** | Separate process (no self-attach) | upstream-already-done | `MadeiraJITHelper.appex`; "a process cannot synchronously debug itself" |
| **6.3** | get-task-allow | upstream-already-done | |
| **6.4** | In-app setup wizard | upstream-already-done | `JITSetup.swift`, `JITNetwork.swift`, `JITPairing.swift` |
| **6.5** | What Sideloadly/AltStore/SideStore strip | done | `GUIDE.md` §2, §6 |
| **6.7** | Licence analysis | done | `LICENSES/NOTICE`, §7 |

### Phase 3
| # | Requirement | Status | Note |
|---|---|---|---|
| 3.1 | build.yml, macOS, matrix | done | Both variants |
| 3.2 | FEX/Wine/rootfs deps + caching | done | Submodule check, `actions/cache`, pinned llvm-mingw hash |
| 3.3 | Large assets sensibly | done | Rootfs/MSC not bundled; downloaded or supplied as secrets |
| 3.4 | Upload unsigned IPA | done | `actions/upload-artifact` |
| 3.5 | Commit, push, trigger, monitor, fix | in progress | See session log |
| 3.6 | Publish as Release | not started | Only if an IPA is actually produced |
| 3.7 | Never claim an IPA that wasn't built | obeyed | §5 |

### Phase 4
| # | Requirement | Status | Note |
|---|---|---|---|
| 4.1 | GUIDE.md: download on Windows | done | |
| 4.2 | GUIDE.md: Sideloadly / SideStore | done | |
| 4.3 | GUIDE.md: Developer Mode | done | |
| 4.4 | GUIDE.md: StikDebug | done | |
| 4.5 | Honest free-Apple-ID limits | done | 7-day, 3-app, no memory entitlement, mitigations |

### Rules
| # | Requirement | Status |
|---|---|---|
| R.1 | Verify, label UNTESTED | obeyed — every hardware claim is marked |
| R.2 | Modular, commented patch series | done — one file per concern, headers explain rationale |
| R.3 | Document licences in LICENSES/NOTICE | done |
| R.4 | Explain infeasible + alternative | done — §5, §6, §3 |
| R.5 | Ask only when blocking | one question set, early |

---

## 9. SESSION LOG

- **Session 1** — Explored upstream on Windows; cloned anonymously; read README,
  BUILDING.md, JIT.md, `.gitmodules`, `.gitignore`, entitlements, `project.pbxproj`.
  Concluded (incorrectly, as it turned out) that the submodule commits were
  unpublished. No `gh` CLI, no WSL, no Xcode, 15 GB free.
- **Session 2** —
  - Confirmed empirically that the agent browser is an isolated profile; user
    signed in manually as `sheltonsilas`.
  - Created a classic PAT (`repo`, `workflow`), verified via API.
  - Established there is **no MCP client** in this Freebuff build; switched to
    REST API.
  - Forked to `sheltonsilas/Madeira` (public).
  - **Cloned all four submodules successfully** — BUILDING.md is stale. This
    removed the biggest blocker.
  - Found the iOS 26.6/27 JIT compatibility allowlist (SideStore docs); Madeira
    absent from it. Flagged as the top risk.
  - Wrote six Swift files, two Python tools, the workflow, GUIDE.md and
    LICENSES/NOTICE. Wired the sources into the Xcode project and verified the
    project file structurally.
- **Session 3** —
  - Pushed the branch; the first CI run fired and its `verify-jit-invariants`
    job passed all checks.
  - Wired the Variant screens into `ContentView`'s navigation so they are
    reachable, and added `JitOnboardingView.swift` (the JIT setup wizard).
  - Found and fixed a real bug in my own tooling: `add_variant_files.py`
    recreated the Variant group on every run, duplicating its object ID and
    making the project unopenable. Now incremental, and it refuses to run
    against an already-duplicated project.
  - Discovered that only `dxmt-ios` needs the custom LLVM, and only for include
    paths, so Xcode's headers can stand in. Added that substitution, marked
    UNTESTED.
  - Hosted preview: **abandoned at the user's request**. The Android box at
    192.168.87.3:8022 was reachable in principle but Proton VPN's kernel filter
    blocks all LAN traffic (`WSAEACCES`, even to the gateway); the fix is
    Proton's own "Allow LAN connections" toggle.

## 9b. SESSION 4 — THE FIRST REAL BUILDS, AND WHAT THEY FOUND

CI had never got past the LLVM step. Once it did, each run bought a real
answer. Nothing below is inferred; every item is a thing a run printed.

**Proven to work on a runner (all previously UNVERIFIED):**

| Stage | Result |
|---|---|
| `gnutls-ios` | GMP, Nettle and GnuTLS build; `libgnutls.a` is arm64 |
| `ffmpeg` | builds; `libavformat/avcodec/swresample/avutil.a` produced |
| `Provide LLVM headers` | the official 15.0.7 headers extract and satisfy DXMT |
| `dxmt-ios` | ~90 of ~92 objects compile against them, including every airconv file |
| `verify-jit-invariants` | passes, now 7 checks |

**The four defects this session found and fixed:**

1. **FEX would not configure.** `-DCMAKE_SYSTEM_NAME=iOS` leaves
   `CMAKE_SYSTEM_PROCESSOR` unset on the runner's CMake, and FEX opens with
   `string(TOLOWER ${CMAKE_SYSTEM_PROCESSOR} processor)`, which dies as
   "string no output variable specified" and reports "Unsupported processor
   type" two errors later. `build/fex-ios/build.sh` now passes `arm64`
   explicitly and discards a cache a dead configure left behind.
2. **The Linux variant was Windows.** `MADEIRA_VARIANT_LINUX=1` was passed to
   `xcodebuild` as a bare build setting, and a build setting with no consumer
   sets nothing: `#if MADEIRA_VARIANT_LINUX` in `AppVariant.swift` never saw
   it, so the "linux" job would have shipped a second Windows build. The
   target's `SWIFT_ACTIVE_COMPILATION_CONDITIONS` now forwards
   `$(MADEIRA_VARIANT_FLAG)`, the matrix gives the variant its own bundle id
   (`com.willfaust.madeira.linux`, so both can be installed at once and
   SideStore's source points at something real), and the invariant job fails if
   that wiring is removed again.
3. **The stage workflow's LLVM download had nowhere to write.** Its
   `toolchains/` directory is created by the llvm-mingw step, which is skipped
   for `dxmt-ios`, and a cache miss creates nothing either, so `curl -o` failed
   with exit 56.
4. **`libdxmt_combined.a` had no producer.** This is the one that gated every
   IPA. The app's Frameworks phase links it; it is DXMT's unix side plus
   airconv plus **LLVM's static archives**, and `dxmt-ios/build.sh` never built
   the LLVM half -- upstream made that file by hand. `build/ci/build-llvm-ios.sh`
   now cross-builds LLVM 15.0.7 for iOS (upstream's documented flags plus the
   `AddLLVM.cmake` `Darwin|iOS` patch), `.github/workflows/heavy.yml` runs it on
   demand and caches it under `llvm-ios-*`, and `build/dxmt-ios/combine.sh`
   merges the two halves with `libtool`.

**Still open at the time of writing:** two DXMT objects did not compile; the
compiler diagnostics were being written to `.err` files that never reached the
log, which is itself fixed. (Both compile now — see below.)

## 9c. WHAT THE RUNS WENT ON TO FIND

Each fix turned one green step into the next failure. All of it was discovered by
reading runner logs, never by guessing.

| Found by a run | Cause | Fix |
|---|---|---|
| `airconv_context.cpp`: `'air_msad.h' file not found` | the three `air_*.h` files are generated by DXMT's meson build; the script only generated `dxmt_command.h` | `build/dxmt-ios/build.sh` runs the same `xcrun metal` + `xxd` chain for all three |
| `winemetal_unix.c`: `undeclared identifier 'MTLFXFrameInterpolatorDescriptor'` | the image's default Xcode 16 has the iOS 18 SDK; that class arrives in the iOS 26 SDK | `build/ci/select-xcode.sh` picks the newest Xcode (26.3 with SDK 26.2 here) and installs the Metal toolchain if absent. **This stage now passes: 87 objects, 0 failed.** |
| `ntdll-unix`: 36 of 37 objects failed | every Wine unix-side script force-includes `wine/build-macos/include/config.h`, and nothing created that tree | `build/wine-macos/build.sh` configures it (aarch64) and builds the host tools |
| `wine/build-macos`: `bison ... too old` | macOS ships bison 2.3; and this is not a soft check — `tools/widl/parser.c` and `tools/wrc/parser.c` are generated from `.y` files | `build/ci/ensure-bison.sh`: Homebrew, else GNU bison 3.8.2 built from a SHA-256-pinned tarball. Both Wine trees call it |
| LLVM iOS: `ld: unknown options: -z` | `make all` also builds `tools/remarks-shlib`, which links a dylib with `-Wl,-z,defs`; Apple's ld has no `-z` | build only the ~33 archive targets airconv names, filtered against what CMake configured |
| LLVM iOS: tree deleted a second after it was built | `find ... ! -name lib ! -name include -exec rm -rf {} +` — find also tests its **starting point**, so it was handed the whole build tree | `-mindepth 1`. **The LLVM-for-iOS build now succeeds (33 archives) and is cached under `llvm-ios-15.0.7-v1`; it takes about 13 minutes.** |
| header substitution deleted the restored LLVM build | the step began `rm -rf toolchains/llvm-ios-build` and was gated only on an input, so it could not know the archives had come from the cache | the check moved inside the script, where the filesystem can be asked |
| `ntdll-unix`: 35 of 37, then `dwrite.h` and `wtypes.h` not found | **these headers are not source files.** `wine/include` holds `dwrite.idl` and `wtypes.idl`; widl writes the headers into a *configured* build tree's `include/`. Building the host tools left that directory with only `config.h`, so the last two objects failed on headers that looked like source but are build output | `build/ci/build-wine-tools.sh` now runs `make -C include` after the tools and asserts `dwrite.h`, `wtypes.h`, `mfobjects.h`, `mftransform.h`. The dwrite compile had also pointed at `wine/build-arm64ec/include`, a tree not configured until the later PE stage. **Result: 37 succeeded, 0 failed.** |
| `wineserver`: `ERROR: No base libwineserver.a found` | the script patched objects *into* an archive it assumed existed. That archive is gitignored and was produced by hand on the original dev machine, so no clean checkout — and no CI run — ever had one | `build/wineserver/build.sh` builds the base from the submodule's own `server/*.c` with the same flags, skipping the files whose originals `REPLACEMENTS` overwrites. **23 base objects, all 25 patched objects, archive produced.** |
| `wineserver`: `line 308: .../llvm-objcopy: No such file or directory` | the lookup ended in a hardcoded Homebrew Cellar path pinned to llvm 22.1.0; Homebrew moves that version | resolve via `brew --prefix llvm`, installing llvm if absent |
| `wineserver`: `llvm-objcopy not found` after that | `xcrun -f` was the wrong tool — it searches the toolchain's shim dir, and llvm-objcopy is in `usr/bin`. Then a `find` over **every** `/Applications/Xcode*.app` on a runner with both Xcode 16.4 and 26.3 found nothing: **Apple no longer ships llvm-objcopy in the toolchain at all** | Homebrew is the only source; `brew --prefix llvm` follows the version symlink so nothing is pinned. **Rename sweep and repack now succeed; libwineserver.a is 1.3 MB.** |

### 9d. THE WINE UNIX-SIDE CHAIN IS GREEN

`stage.yml` stage `wine-unix` passed end to end (run 37217805223). For the first
time a clean checkout produced all three app-side Wine archives:

| archive | size | notes |
|---|---|---|
| `app/Madeira/libntdll_unix.a` | 1.9 MB | 37 of 37 objects |
| `app/Madeira/libwineserver.a` | 1.3 MB | 23 base + 25 patched objects, symbols renamed |
| `app/Madeira/libwin32u_unix.a` | 3.3 MB | freetype merged in |

The recurring theme across every one of these is worth recording: **the scripts
were written against a developer's hand-prepared machine, and nothing in the
repository reproduces that machine.** A gitignored archive, headers that are
build output rather than source, and a Homebrew path pinned to one LLVM version
are all the same class of fault. Each one only shows up on a clean runner.

### 9e. BACKGROUND OPERATION

`build/ci/overnight-loop.sh <stage> [iterations]` drives dispatch → wait →
record, so the ~9-minute wait per iteration does not need an open terminal. It is
launched detached (`Start-Process`, no elevation) so it survives a locked screen
and the end of a session, and it logs to stderr because the wait runs inside a
command substitution that would otherwise swallow its progress lines.

It deliberately **stops on failure rather than retrying**. Reading a compile
error and deciding what it means is the judgement part; an automatic fixer would
paper over real faults. It surfaces the first error inline and saves the full log
to `build/ci/overnight/<stage>-<run>.log`, so only that needs reading. It also
adopts a run already in flight rather than racing a duplicate over it.

What this means for the original complaint — "I could not run a single app": the
reason is now understood and addressed at the build level. The arm64ec PE farm
carried every Direct3D DLL for the games that had been added to it and none of
the general-purpose modules (`explorer.exe`, `cmd.exe`, `services.exe`,
`wineboot.exe`, `msiexec.exe`, `gdiplus.dll`, `msi.dll`, installers of any kind),
so an ordinary x86-64 program had no shell, no installer and no GDI+.
`build/wine-pe/build-universal.sh` builds that set into the farm.

### 9f. SESSION 6 — WHY THE FIRST FULL RUN DIED, AND HOW IT RUNS UNATTENDED

The full `build.yml` run at `285397c` (37250901109) got through the **whole
native chain** — gnutls, ffmpeg, freetype, FEX, the Wine macOS tree, the unix
side, libwineserver, win32u, `ntdll.dll`, and the arm64ec PE farm — and failed in
`dxmt-ios/combine.sh` with:

```
::error::missing .../dxmt/build-ios/libdxmt_unix.a - run build/dxmt-ios/build.sh first
```

Nothing was missing. `build.sh` had just compiled 87 objects, archived them to
`build/dxmt-ios/libdxmt_unix.a` and said so in the log; `combine.sh` looked in
`dxmt/build-ios/libdxmt_unix.a`, a path no script has ever written. An error that
names a missing prerequisite and is really a typo is the expensive kind: it
costs a 40-minute run and the next person looks for a missing build.

The second thing the run exposed was quieter. Every `build.yml` run logged:

```
Cache not found for input keys: toolchain-linux-<hash>, toolchain-linux-, llvm-ios-
```

so the hour-long LLVM-for-iOS build never came back, the run fell through to the
headers-only fallback, and `combine.sh` would have failed one step later on
`toolchains/llvm-ios-build/lib`. The cause is that `actions/cache` hashes the
**path list** into a cache's identity: the `llvm-ios` workflow saves
`toolchains/llvm-ios-build`, `toolchains/llvm-host-bin`,
`toolchains/llvm-project`, and both consumers asked for `toolchains`. Same-key
different-paths is not a near miss, it is a different cache. Fixed in both
workflows, with an explicit assertion in front of each stage that links LLVM, so
a cache eviction says "run the llvm-ios workflow" instead of appearing as a
compile error half an hour later.

**Unattended operation (the part that decides whether overnight works).**
`build/ci/overnight-loop.sh` is now a chain rather than one stage:

```
bash build/ci/launch-overnight.sh rppairing-ios xcodebuild build
```

`launch-overnight.sh` starts it through PowerShell's `Start-Process`, so it has
no console of its own — a detached bash child dies with the console Windows
created for the tool call, which is exactly what locking the laptop ends — and
starts `keep-awake.ps1`, which holds
`SetThreadExecutionState(ES_CONTINUOUS|ES_SYSTEM_REQUIRED)`. The display is
deliberately **not** requested: the screen may go dark, the machine stays up. It
still cannot override a lid-close action configured as "sleep" on battery; that
is a power policy and needs an elevated `powercfg`. A run slept through is simply
noticed afterwards, because conclusions are read from the GitHub API rather than
from an internal clock.

The driver's state is in `build/ci/overnight/` (gitignored): `state` records
which targets are green *at which commit*, `inflight` records the run being
waited on so a restart adopts it instead of racing a duplicate, `heartbeat` is
rewritten every poll, and a failure writes `NEEDS_FIX.md` with the run URL and
the first real error. The `build` target dispatches the full `build.yml` run and
finishes by writing `IPA-READY.md` with the release and the two IPA downloads.

### 9g. SESSION 6 — THE APP TARGET BUILDS FOR THE FIRST TIME, AND WHAT IT FOUND

With the combine path and the cache identity fixed, the chain ran end to end for
the first time (`build.yml` run 37310723333, `c41df05`): gnutls, ffmpeg,
freetype, FEX, the Wine macOS tree, the unix side, libwineserver, win32u,
`ntdll.dll`, the arm64ec PE farm, DXMT's 87 objects **including the merge into
`libdxmt_combined.a`**, `rppairing-ios` (cargo, iOS target), and then the app
target itself. It failed there, in the **JIT helper extension**, on this:

```
app/Frameworks/StikJIT.xcframework/.../arm64-apple-ios.private.swiftinterface:12:31:
  error: expected '{' in struct
public struct DDIPaths : Swift::Sendable {
                              ^
```

The framework ships **no binary `.swiftmodule`** -- only two `.swiftinterface`
files -- so those files are the only description of the module the app imports.
They were printed by **Swift 6.4**, which writes qualified type names as
`module`, two colons, `type`. The newest Xcode on GitHub's runners is **26.3**,
and its parser rejects that syntax outright, on the first conformance clause and
again on `StikJITError : Swift::Error, Foundation::LocalizedError`.

There is no newer Xcode on the runner and no compiler flag that fixes this, so
the interfaces were rewritten mechanically by
`build/ci/dequalify-swiftinterface.py`. 86 qualified names were reduced to the
name they qualify. Five references to the module's own nested types were worse
than that -- Swift printed them as `StikJIT::StikJIT.StikJIT::Configuration`,
the module being named the same as an enum inside it -- and those became the
plain nested name, which is what they resolve to inside the enum body. The
module's API is unchanged: every name here is unambiguous in its own scope. The
script is re-runnable, and the `verify-jit-invariants` job now fails in 20
seconds if a future framework drop reintroduces the syntax, instead of 30
minutes into a run on a Swift error that is really a bad input file.

That the app target compiles at all is the news: the twelve-library native chain
is green, and what remains is the Swift side of the app.

---

## 10. NEXT ACTIONS FOR A HUMAN

1. **Test JIT on the iPad first.** Everything else is blocked behind it (§3).
2. The chain is driven from `build/ci/overnight/`; `bash
   build/ci/launch-overnight.sh status` shows the live run and the heartbeat,
   and `... stop` ends it. A failure leaves `NEEDS_FIX.md` naming the run and the
   first error, which is the only thing worth reading before changing code.
3. The general-purpose arm64ec modules (`explorer.exe`, `services.exe`,
   `msiexec.exe`, `gdiplus.dll`, `msi.dll`, ...) are built by
   `build/wine-pe/build-universal.sh` and are **not tracked in git**, unlike the
   game DLLs around them. `build.yml` builds them into the app, so an IPA is
   complete, but a *stage* `xcodebuild` run bundles only what is tracked. If a
   fresh clone should build without the PE step, commit them — that is a
   deliberate follow-up, not an oversight to fix blindly.
4. Delete `~/.madeira-gh-token` when finished, and revoke the PAT in
   GitHub → Settings → Developer settings → Personal access tokens.