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
| **3. CI + IPA** | **DONE.** Two unsigned IPAs are published: run `37495509689` at commit `b30d72d` went green on all four jobs (verify, windows, linux, publish) and released **`build-70`**. Both variants link, package and publish; the SideStore `source.json` is attached and every URL in it answers 200. The native chain (Wine unix side, ntdll/Win32u/libwineserver, the arm64ec PE farm, DXMT's 87 objects, FEX) builds on GitHub's macOS runners. See §9h. |
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

## 5. WHAT CI PROVED BEFORE THE FIRST IPA (historical — the IPA exists, see §9h)

An IPA **is** now published: release `build-70`, from run `37495509689` at
`b30d72d`. This section is kept because it records what each earlier run
established, which is what made the last two failures diagnosable in minutes
instead of hours.

Not claimed, and not faked. What has been **verified by a real run**, not
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

**Resolved:** Xcode's LLVM is not upstream's 15.0.7, and the worry was that
`dxmt-ios` would fail on version skew. It did not: DXMT's 87 objects compile and
the app links (§9h). The substitution stands. A real LLVM-for-iOS build remains
the better answer if a future DXMT bump actually needs LLVM 15's headers.

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

## 9d. SESSION 5 -- THE FIRST RUN THAT GETS PAST THE VARIANT SOURCES

Two facts frame this session, and the second is the important one.

**The fork had two histories, and the local checkout was the wrong one.** The
local branch held 536 commits: upstream's real history, in which the project is
called Mythic for most of it (`app/Mythic/`, and the Wine-side `*_ios.c` files
that name it), with this fork's work interleaved. `fork/feature/
two-variants-browser-and-linux` held 60 commits sharing no commit with it after
`a70caf9` -- the same work, rebuilt on the current upstream base (`fork/main`,
475 commits beyond `origin/main`). Rebasing the 536 onto the 60 was therefore
replaying roughly 415 upstream commits the base already contained, with a
Mythic-to-Madeira rename conflict in every Wine source file it touched. It was
22 commits into 415 when this session stopped it, and stopping it was correct:
the 60-commit lineage is the one every run in section 9c was made from, and the
only thing it was missing is one file, taken from the other
(`build/ci/overnight-loop.sh`). `git tag old-local-lineage-536` keeps the old
branch. Nothing was force-pushed.

**The app had never been compiled. Not once.** Every run until now died before
the app target -- the native chain, then the PE farm, then DXMT and its merge,
then a file that was not where the project file said it was. Run 37400691096 was
the first to build the entire native chain *and* reach the Swift compiler, and
the compiler then reported the first seventeen errors these sources have ever
produced. They were written with no compiler available, and they said so.

Fixed this session, in the order they were found:

  * `app/Madeira/Variant/JitOnboardingView.swift` was a child of the application
    group, so `path = JitOnboardingView.swift` resolved to
    `app/Madeira/JitOnboardingView.swift`, and xcodebuild failed both variants
    with "Build input file cannot be found". It is a child of `Variant` now, like
    the other six. (cd4a469)
  * `tools/check_pbxproj.py` now proves that every Sources and Resources input
    resolves to a file that exists. Pointed at the revision before that fix it
    names `Madeira/JitOnboardingView.swift` in twenty seconds; the checks it
    already had (braces, parens, duplicate IDs, dangling IDs) all passed while a
    run compiled for twenty-four minutes and then failed on that one file. The
    Frameworks phase is deliberately out of scope -- it names archives that
    earlier steps of the same run build, and a check that has to be told which
    of those are legitimate is a check that gets muted. (1427484)
  * The seventeen compile errors, in three files (1427484):
      - `JitManager.debuggableSignature` called `SecTaskCreateFromSelf` and
        `SecTaskCopyValueForEntitlement` directly. The iOS SDK declares neither.
        Upstream's `EntitlementChecker.swift` binds both symbols itself, for
        exactly that reason, and exposes `checkAppEntitlement`; JitManager calls
        that instead of keeping a second copy of the declaration.
      - `BrowserDownload` was not `Codable`, so the download shelf's JSON
        sidecar could never be written or read; `pendingInstall =
        download.id` assigned a UUID where the type wants a download; and
        `WKDownload.originalRequest` is optional, in three places.
      - `WindowsInstallerBridge` used `NSString`'s `deletingPathExtension` and
        `pathExtension` on a `String`, passed `cString(using:)` unapplied where a
        C pointer is required, read a `private` `programRoots` from another type
        in the same file, and named two `URLResourceKey` members without a
        contextual type.
  * `build/ci/overnight-loop.sh`'s documented `chain` mode was dead code --
    nothing called `_run_chained` -- and its first real target,
    `dxmt-ios/combine`, is not a stage this repository's `stage.yml` has (it is
    folded into `dxmt-ios`). `chain` now selects it, and the target list is
    valid. (1427484)
  * A commit made with `git commit -am` partway through swept the FEX and wine
    gitlink changes into it. It was reset before any push: those pointers are
    what a clean checkout resolves, `build.yml` fails its own reachability check
    when a submodule commit is not on the remote, and the change was not this
    session's to make. The working tree still carries them, unstaged, exactly as
    it did before.

  * The `publish` job could never have run. Its condition was "the ref is the
    default branch, or this was a dispatch", and this repository's default
    branch is upstream's `main`, the branch the fork was made from, while every
    build here runs from a working branch -- so every run in sections 9b, 9c and
    here reported `publish` as skipped. Had the IPAs built, they would have
    existed only as 30-day workflow artifacts. The condition is now "not a pull
    request", which is the guard a fork actually needs, and it is the difference
    between an IPA in a download table and an IPA in a folder of run logs.

  * The next run died in step 12 the same way -- curl's exit 28 against
    ftp.gnu.org -- and its log said how it got there. Homebrew had installed
    bison 3.8.2 successfully and reported it as *keg-only*, so it was not
    symlinked into `/opt/homebrew/bin`, which is the only directory
    `ensure-bison.sh` added to PATH. The version check therefore kept running
    macOS's bison 2.3, judged the install a failure, and fell through to a
    source build from a host the runner cannot open a connection to: six
    attempts, two runs. `brew --prefix bison` is the fix -- it is what
    Homebrew's own keg-only message recommends -- and the source path now tries
    two mirrors before ftp.gnu.org, with the pinned SHA-256 deciding whether
    what arrived is what was asked for. Verified against a stub Homebrew that
    reproduces the keg-only case.

    Necessary, and not sufficient. All three callers run that script as a child
    process and then add `$R/toolchains/bison-3.8.2/bin` to their own PATH --
    carrying a comment that says "if it had to build one". With Homebrew's
    bottle there was no such directory, so Wine's configure went on to run
    macOS's 2.3 and failed with "Your bison version is too old" three seconds
    after the script had reported 3.8.2 installed. The script now links the
    keg's binary into `$PREFIX/bin`, where the source build already puts it, so
    both routes leave the same thing behind for the caller to find.

  * Every Swift source in the app target now compiles, in both variants. That is
    the first time this project has ever type-checked its own app target, and it
    was reached only after the JitOnboardingView path, the publish condition and
    the bison fault were out of the way. The run then died in the linker with
    `ld: library 'JemallocLibs' not found`. I first read that as a stale project
    reference and deleted the four pbxproj lines -- **that was wrong, and the
    change is reverted.** `add_library(JemallocLibs STATIC
    Utils/AllocatorHooks.cpp)` in `FEX/FEXCore/Source/CMakeLists.txt` is
    unconditional; it is the nearby `if (APPLE)` block that only disables
    `ENABLE_JEMALLOC_GLIBC_ALLOC`/`ENABLE_FEX_ALLOCATOR`, not the target itself.
    `AllocatorHooks.cpp` is also the *only* definition of
    `FEXCore::Allocator::{malloc,free,memalign,aligned_alloc,aligned_free}` in
    the tree, and its `#else` branch keeps all five on Apple (routing them
    through `posix_memalign` instead of rpmalloc), which is exactly what
    `ENABLE_FEX_ALLOCATOR=OFF` is for. The real fault was one token in
    `build/fex-ios/build.sh`: `cmake --build --target FEXCore FEXCore_Base`
    never asked for the archive, so the linker then reported the five symbols
    undefined. Target added.

## 9e. WHAT THE LINKER STILL WANTS (run 37411870382, fully enumerated)

With the five `Allocator` symbols accounted for, the run reported exactly
eighteen undefined symbols in three families. I mapped all eighteen in the
tree; the honest state is that the first family is fixed and the other two
are **not yet understood well enough to change anything**.

1. `FEXCore::Allocator::{malloc,free,memalign,aligned_alloc,aligned_free}` --
   fixed by building `JemallocLibs` (above).

2. `_bcrypt_unix_call_funcs`, `_bcrypt_unix_call_wow64_funcs`, and the same
   pair for `secur32` -- **fixed**. Both tables are emitted by the sources and
   both objects compile "OK" and are in the `ar rcs` list, so my first two
   theories were both wrong: not a missing shim, and not archive ordering
   (I checked -- the other six unixlib tables resolve out of the same archive).
   They are emitted *conditionally*. `wine/dlls/bcrypt/gnutls.c` gates its
   entire body, `__wine_unix_call_funcs` included, behind
   `HAVE_GNUTLS_CIPHER_INIT` from line 27; `secur32/schannel_gnutls.c` does the
   same with `SONAME_LIBGNUTLS`. Wine's own configure defines both on a Unix
   build and this one never did, so those two objects were *empty* while
   ws2_32/nsi/dwrite/dnsapi/crypt32 -- which have no such gate -- linked fine.
   Both macros are now passed. This is the lesson worth keeping: "OK" in that
   compile step means the empty translation unit compiled, so a whole-file gate
   is invisible until the link, and the compile log can never tell you.

3. `_IosMonoResolveRW`, `_IosSubfloorToReal`, `_ios_fex_band_base`,
   `_ios_fex_band_end`, `_ios_fex_mono_*` and `_rpm_cas_snapshot_take`.
   These are defined in the FEX *guest module* sources
   (`Source/Windows/ARM64EC/IosJitAlias.cpp`, `Source/Windows/WOW64/
   IosMonoBridge.cpp`) and in `External/rpmalloc/rpmalloc.c` -- none of
   which is compiled into `libFEXCore.a`. `build.yml` builds only
   `fex-ios` (the host library); `fex-wow64` and `fex-arm64ec` build the
   guest modules as DLLs shipped into the prefix as `xtajit.dll` /
   `xtajit64.dll`. So FEXCore's host build is calling across a module
   boundary that does not exist in a single-process iOS link. This is an
   architecture question, not a typo, and I am not going to guess at it.

Also worth recording because it cost me a wrong turn: the submodule gitlink
in HEAD says FEX `08aca96`, but the FEX worktree here is on `1adb337`
(`heads/ios-port-2607`), and `External/rpmalloc/` exists at `08aca96` but
not at `1adb337`. CI checks out the recorded gitlink, so CI's tree is not
the tree I can read. Any future fix for family 3 has to be reasoned about
against `git show 08aca96:<path>`, not against the worktree.

## 9f. FAMILY 3, FULLY TRACED (investigation only -- nothing changed)

Run 37415160482 confirmed the first two families are fixed: the undefined list
went from eighteen symbols to ten, with every `FEXCore::Allocator` symbol and
all four `bcrypt`/`secur32` table symbols gone. The ten that remain are two
unrelated gaps, and they have different owners. Neither has been changed.

### 3a. rpmalloc is never compiled (3 symbols)

`ios_fex_band_base`, `ios_fex_band_end`, `rpm_cas_snapshot_take`.

They are defined in the *nested* submodule `FEX/External/rpmalloc`, at
`rpmalloc/rpmalloc.c` lines 884, 889 and 2140 (repo `willfaust/rpmalloc`,
branch `ios-madeira`, pinned to `812c2b9`). That submodule is compiled only
under `if (ENABLE_FEX_ALLOCATOR)` in `FEX/CMakeLists.txt:366`, and
`build/fex-ios/build.sh` passes `-DENABLE_FEX_ALLOCATOR=OFF` -- while the
sibling `build/fex-arm64ec/build.sh` passes `ON`. `Core.cpp:1971` calls
`rpm_cas_snapshot_take` with no guard, and `AllocatorHooks.h`/`Allocator.cpp`
read `ios_fex_band_base`.

The file says the intent outright, at line 900: they live there "purely so that
every FEX binary that links FEXCore has" them. So the invariant FEX is written
to is *links FEXCore => links rpmalloc*, and the OFF setting breaks it.

This one needs **no FEX change at all**. It is three files in this repo:
pass `ON` in `build/fex-ios/build.sh`; add `librpmalloc.a` to the app's
Frameworks phase (`JemallocLibs` declares `target_link_libraries(... PUBLIC
rpmalloc)`, but a static lib's transitive dependency does not survive into
Xcode's link line); and make sure the nested submodule is actually present.
Note this is *not* a replacement for building `JemallocLibs` -- that is still
required, and with `ON` it simply routes through rpmalloc instead of
`posix_memalign`.

### 3b. The guest-module bridge is not in the host link (7 symbols)

`IosMonoResolveRW`, `IosSubfloorToReal`, and the five `ios_fex_mono_*`.

They are defined in `FEX/Source/Windows/WOW64/IosMonoBridge.cpp` and
`FEX/Source/Windows/ARM64EC/IosJitAlias.cpp`. FEX resolves them by linking the
module and FEXCore into *one* image: both module `CMakeLists.txt` files list
`$<TARGET_OBJECTS:FEXCore_object>`, and `FEXCore_object` is real -- created by
`AddObject(${PROJECT_NAME}_object)` at `FEXCore/Source/CMakeLists.txt:271`,
with `AddLibrary` at 279 wrapping it into the archive. So the module and
FEXCore share a link by construction.

`build/fex-ios/build.sh` builds `FEXCore`, `FEXCore_Base` and `JemallocLibs`
only, so the app receives `FEXCore_object` with no module beside it. The app
*does* carry `xtajit.dll` and `xtajit64.dll` (the built modules, in
`aarch64-windows/` and `arm64ec-windows/`), but those are PE images loaded at
runtime and cannot satisfy a static link.

Three ways out, and they are not equivalent:
  1. Compile the bridge sources into a host-side archive the app links. Real
     definitions, smallest blast radius, all inside this repo.
  2. Build and link the actual module target into the app.
  3. Stop the host build from referencing them at all -- but `FEX_IOS_HOST`
     currently means two different things (genuinely iOS-only host code, and
     guest-module-only code), so this needs a *new* macro in FEX, which is a
     FEX change.

The trap in 1 and 2: `IosMonoBridge.cpp` and `IosJitAlias.cpp` define the *same*
symbol names, so exactly one can be linked. That choice is really a statement
about which guests the host supports -- WOW64 (32-bit) or ARM64EC (x86-64) --
and Variant A is the x86-64 one, which points at `IosJitAlias.cpp`. That
decision is why this half is left alone pending review.

## 9g. FAMILY 3 SOLVED, AND THE THREE MISTAKES ON THE WAY

The goal now is one push away, but **the push is blocked on an account
condition, not on code** -- see the end of this section.

### The answer to family 3: the app supplies all ten symbols itself

Both halves turned out to be the same shape of problem. FEX arranges for a
guest *module* to define these symbols, and the app is a third consumer of
FEXCore that links no module, so the app must define them.

The bridge half: `IosMonoBridge.cpp` says it outright -- "each statically links
its own copy of FEXCore, so neither can borrow the other's storage".
`build/ntdll-unix/ios_fex_host_bridge.c` is the app's copy, taken from the WOW64
variant because the app's FEXCore is a plain aarch64 build (`Core.cpp` itself
calls the WOW64 module "a plain aarch64 PE"), and the ARM64EC file cannot be
used at all here since it needs `windows.h` and its alias table is consumed by
`Module.S`.

The allocator half is the same story with a twist I got wrong first.
`ios_fex_band_base`, `ios_fex_band_end` and `rpm_cas_snapshot_take` live in the
`External/rpmalloc` submodule, under `if (ENABLE_FEX_ALLOCATOR)` -- and FEX's
CMakeLists.txt does not merely default that off on Apple, it *forces* it:

    if (APPLE)
      set(ENABLE_FEX_ALLOCATOR FALSE)
      message(STATUS "Apple platform detected - disabling jemalloc and rpmalloc")

A plain `set()` shadows a `-D` from the command line. So the submodule is never
added on this platform, period, and those three symbols plus
`ios_fex_jit_pool_rx/_end` have no definition in any build that links FEXCore.
The app defines them, all at the values the submodule itself would start them
at: the band and JIT-pool globals at 0, which every reader documents as "not
published" (AllocatorHooks.h returns nullptr and calls failing visibly the
right answer for a constrained device), and `rpm_cas_snapshot_take` returning 0,
which is its documented "no snapshot" and which Core.cpp uses only to print one
diagnostic line.

### Three mistakes, all mine, all worth recording

1. **I read the CMake message and drew the wrong conclusion.** "Apple platform
   detected -- disabling jemalloc and rpmalloc" did not stop me from passing
   `-DENABLE_FEX_ALLOCATOR=ON`, adding `rpmalloc` to the cmake `--target` list
   (no such target exists on Apple -- that alone would have failed the build)
   and adding `librpmalloc.a` to the app's Frameworks phase, asking the linker
   for a file that branch guarantees is never produced. It would have replaced a
   missing-symbol failure with a missing-library one. Reverted.

2. **I put a comment inside a backslash-continued `cmake` argument list.** In
   bash the backslash-newline is removed *before* comment processing, so the
   `#` begins a word on the joined line and drops the rest of the command.
   `-DENABLE_FEX_ALLOCATOR=ON` *and* `-DTUNE_CPU=none` were both silently never
   passed; `TUNE_CPU` went back to `native`, FEX's probe opened `/proc/cpuinfo`
   on macOS, and the configure died 20 minutes in. `bash -n` passes it, because
   it is valid syntax. `tools/check_shell_continuations.py` now catches it in
   twenty seconds and the verify job runs it.

3. **I trusted `bash -n` as a semantic check.** Twice. It only ever means "this
   parses", and both of the defects above parse perfectly.

### The block, and what it needs

Every GitHub *write* now returns

    403  "At least one email address must be verified to do that."

and `git push` says `remote: You must verify your email address.` Reads are
unaffected, and earlier pushes in the same session succeeded, so this appeared
partway through. The account `sheltonsilas` has no verified email address. It
cannot be worked around from here and no amount of retrying will change it.

**A human has to open https://github.com/settings/emails and click the
verification link for `sheltonsilas@gmail.com`.**

Until then the work sits in two local commits, `52b154e` and `66707f2`, on top
of the pushed `b650b93`. `build/ci/overnight/retry-push.sh` (scratch, git-
ignored) is running detached: every two minutes it probes write access, and the
moment it opens it pushes the branch, then launches the build driver so the run
is watched and the IPAs are collected. Nothing else needs doing.

Also verified while blocked, since each of these would have cost a run:
`Madeira.app` is the product name, so the IPA packaging step's `find` will match;
the xcodebuild step passes no `-derivedDataPath`, so the default
`~/Library/Developer/Xcode/DerivedData` is where it looks; and the publish job's
gate is now `github.event_name != 'pull_request'`, where it used to compare
against a default branch this repository never builds from.

For section 5, this changes the honest reason no IPA exists. It is no longer
"the native chain does not build", and no longer "the project file points at a
file that is not there". It is only the Swift in the app target, which has now
been compiled exactly once. Expect a second generation of these errors; that is
progress, not regression.

## 9h. THE FIRST IPA — run 37495509689, release build-70

The account email was verified at 21:22 IST on 2026-10-06; `retry-push.sh`
pushed on attempt 101 (`b650b93..d94a4b4`) and launched the driver, which
dispatched the run below.

**What that run proved, in order:**

- `verify-jit-invariants` green, including the new `No comment sits inside a
  continued shell command` check — the guard for §9g mistake 2.
- Steps 3–11 green: toolchain caches hit, FEX rebuilt from scratch.
- Step 12 `Build the native pieces` green **for the first time** on both
  variants.
- Step 13 `Build the app` failed — **but not on symbols. The link succeeded.**
  All ten family-3 symbols from run 37415160482 were gone. `ios_fex_host_bridge.c`
  did its job, and no undefined symbol has appeared in a Madeira run since.

What stopped it was a defect nobody could have seen, because no run had ever
reached it:

```
error: bundled LICENSE-MADEIRA-GPL-3.0.txt is missing or stale; run build/stage-licenses.sh
```

`app/Madeira/licenses` is a bundled folder reference, but the two Madeira
copies inside it are generated from `COPYING` / `LICENSE-EXCEPTION.md` and are
**gitignored** (`.gitignore` lines 151–153), so a fresh checkout has neither.
The only caller of `build/stage-licenses.sh` is
`build/madeira-d3d12/fetch-converter.sh`, and because `libmetalirconverter.dylib`
is committed, that script never runs on a runner. Fixed in `b30d72d` by
staging the copies in the workflow immediately before xcodebuild — which keeps
the check honest, since a genuinely stale copy still fails it.

**Run 37495509689 at `b30d72d`: all four jobs green.** Release
https://github.com/sheltonsilas/Madeira/releases/tag/build-70:

| asset | bytes |
|---|---|
| `Madeira-windows-unsigned.ipa` | 90,495,480 |
| `Madeira-linux-unsigned.ipa` | 90,495,574 |
| `source.json` | 3,155 |
| `icon.png`, `icon-windows.png`, `icon-linux.png` | 429,496 each |

Verified locally after downloading both IPAs, rather than trusting the job
summary:

- Both unpack to `Payload/Madeira.app` with `CFBundleExecutable = Madeira` and a
  71,984-byte `Payload/Madeira.app/Madeira` binary present.
- **The bundle IDs differ**: `com.willfaust.madeora` vs
  `com.willfaust.madeora.linux`. The variant flag therefore produces two
  genuinely different apps — the earlier fear that every run built the Windows
  variant twice is disproved.
- `PlugIns/MadeiraJITHelper.appex`, `Frameworks/StikJIT.framework`, and both
  `licenses/LICENSE-MADEIRA-GPL-3.0.txt` and `LICENSE-MADEIRA-EXCEPTION.txt` are
  all inside the bundle.
- Every URL in `source.json` (both IPA downloads, all three icons) answers
  **200**.

A second defect was found the same way and fixed the same day:
`tools/make_source.py` writes `iconURL` as `icon.png` / `icon-windows.png` /
`icon-linux.png` inside the release, and nothing uploaded them — the SideStore
source shipped with three broken images. The publish job now attaches them
(three copies of the committed 1024px app icon, deliberately not `gh`'s
`file#name` rename, so a cosmetic step cannot fail on a syntax detail), and the
three were backfilled onto `build-70` by hand so the already-published source
resolves today.

**Honest limits, unchanged:** none of this has run on a device. iOS 27 will not
JIT a bundle that is not on SideStore's allowlist (§3), so the first real test
is an iPad with StikDebug. Also worth reconciling one day: the project-level
`IPHONEOS_DEPLOYMENT_TARGET` is **17.0** (only `MadeiraJITHelper` sets 26.0), so
the built `Info.plist` says `MinimumOSVersion = 17.0`, while `source.json`
advertises `minOSVersion` 26.0. The mismatch is in the safe direction — SideStore
simply will not offer it below 26 — but it is not what the project file claims.

---

## 10. NEXT ACTIONS FOR A HUMAN

1. **Test JIT on the iPad first.** Everything else is blocked behind it (§3).
2. The chain is driven from `build/ci/overnight/`; `bash
   build/ci/launch-overnight.sh status` shows the live run and the heartbeat,
   and `... stop` ends it. The launcher also holds the machine awake with
   SetThreadExecutionState, which needs no elevation. It cannot override a
   lid-close action configured as sleep -- that is a power policy, not an idle
   decision, and changing it needs an elevated powercfg. A run is not lost when
   that happens: everything expensive happens on GitHub's runners, and the loop
   reads conclusions from the API, so it simply notices the run later. A failure leaves `NEEDS_FIX.md` naming the run and the
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
   It is deliberately still on disk while a run is in flight: the driver reads
   it on every poll.