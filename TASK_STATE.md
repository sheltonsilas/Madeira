# Madeira clean rebuild — task state

## Objective
Use the Freebuff conversation as the product brief and rebuild Madeira from the clean upstream baseline at `willfaust/Madeira` commit `48f976429c189f8396e23d251d8a82f43c705922`. Preserve the existing fork, release history, and Freebuff branch. Build a single integrated iPad app called Madeira; do not embed a separate SideStore app. Reuse existing GitHub access without displaying or committing credentials.

## Requirements and status

| Requirement | Status | Acceptance evidence |
|---|---|---|
| Keep the existing Madeira fork and Freebuff work intact | In progress | Separate worktree and branch; compare/preserve original checkout |
| Clean baseline and complete architecture/feasibility audit | In progress | This file; source map and constraints |
| One integrated app with a redesigned iPad-first UI | In progress | New single-app dashboard shell added to the app target; still needs macOS type-check/build and interaction review |
| Windows apps through the existing Wine + FEX runtime | In progress | Existing runtime is retained. Installer launch is routed through the existing library/JIT launch path; Xcode build and device behavior remain unverified |
| 32-bit and 64-bit Windows setup executables | In progress | Browser/import bridge accepts PE installer files and determines PE bitness; clean-build WoW64 payload and device install behavior remain unverified |
| In-app browser and file import/download/install flow | In progress | WebKit browser/download shelf, unique filenames, prefix staging and launch handoff ported; Files type registration and URL routing added; compile and end-to-end device behavior remain unverified |
| Linux virtual machines using QEMU; distro and GUI choice at first setup | In progress | QEMU launcher, image downloader, distro/setup flow and manager ported; payload, display integration and a bootable image are still needed |
| Linux JIT and interpreter operation | In progress | Engine selection and explicit capability gates exist; actual JIT/interpreter QEMU payloads and device execution remain unverified |
| JIT setup and status for FEX/Wine | Not started | Verified entitlements, separate helper/StikJIT path, pairing/DDI/network guidance; device test required |
| iPad pointer, touch, keyboard, Pencil, display resizing and external display support | Not started | Feature checklist against UTM/iOS behavior; compile and device validation |
| File sharing, networking, audio, snapshots/import/export, RAM/CPU limits | Not started | Implemented only where runtime supports it; end-to-end checks |
| Reproducible GitHub Actions, payload publishing, IPA validation, release | Not started | Green macOS workflow, checksummed payloads, thin arm64 IPA passes inspector and SideStore/Sideloadly installation |
| Licensing, privacy, beginner guide and limitations | Not started | Notices, no secret material committed, accurate guide |
| Real iPad/iPhone compatibility, heat and app execution | Untested | Must be tested on physical devices; cannot be certified from CI |

## Verified starting facts
- Existing checkout: `C:\Users\Ramya\Documents\madeira`, branch `feature/two-variants-browser-and-linux`, HEAD `1dd1465c2ba5ae94c941172d40cf8ac017aaeb5a`.
- Clean rebuild worktree: `work/madeira-clean-rebuild`, branch `codex/madeira-clean-rebuild`, clean upstream HEAD `48f976429c189f8396e23d251d8a82f43c705922` (upstream main, fetched 2026-10-10).
- Existing Freebuff release `build-10` passed CI IPA inspection: 187.5 MiB compressed, 876.4 MiB unpacked, 1,431 entries, one app, thin arm64 main executable, required 32-bit Windows and QEMU files present. This is historical evidence, not a build from this branch or proof of device installability.
- The current Freebuff conversation confirms FEX's iOS port exposes an ARM64 JIT core; there is no FEX interpreter core. QEMU TCG interpreter is the feasible no-JIT path for Linux, not Windows.
- iOS JIT, sideload signing, Windows installer compatibility, guest performance, iPad input, and thermal behavior require physical-device tests. Do not claim them verified from a green build.
- `FEX/AGENTS.md` in the existing checkout says AI must not generate code for contributions to that project. Do not edit or generate code inside the FEX subtree; work on Madeira-owned code/build integration only.

## Execution principles
1. Verify upstream/current source and licenses before designing; record evidence and distinguish tested, inferred, and untested claims.
2. Keep this branch isolated. Never reset, force-push, or overwrite the existing user branch/releases.
3. Keep payloads pinned and checksummed; missing required features fail the build instead of silently publishing.
4. Validate the packaged IPA itself (integrity, one app, arm64 Mach-O, nested bundles, size, and promised capability files) before release.
5. Do not place credentials in URLs, logs, source files, workflow artifacts, or Git history. Use existing token only at runtime.
6. A feature is not done because a UI or build flag exists: verify the code path reaches the actual engine and label device-dependent behavior UNTESTED.

## Decision log
- 2026-10-10: Read the saved Freebuff conversation and used its full history as the brief.
- 2026-10-10: Fetched current upstream `main` (48f9764) and created an isolated worktree/branch; existing fork checkout remains on 1dd1465.
- 2026-10-10: Latest Freebuff build-10 was inspected locally and passes the repository IPA inspector, including payload presence and thin arm64 main executable. Rebuild must reproduce/strengthen those gates.
- 2026-10-10: Added `MadeiraHomeShell.swift` as the integrated app entry with responsive navigation, existing Windows/JIT screens, and an explicitly unavailable Linux-engine state. The Windows card reports JIT requirement from debugger state; Linux is labeled as planned rather than ready. Swift compilation is pending because this Windows workspace has no Xcode toolchain.
- 2026-10-10: Used the layout's `GeometryReader` width for responsive decisions instead of `UIScreen.main.bounds`, which is unreliable for resized iPad windows.
- 2026-10-10: Ported the Freebuff project's native WebKit download shelf and Windows installer bridge into the clean baseline. The bridge stages installers inside Wine's `drive_c`, saves a launchable library entry, and uses the existing `ShortcutRouter`/`ContentView` JIT-aware start path. File associations and file-URL routing now feed `IncomingInstaller`. The old Freebuff branch remains untouched. Still needs an iOS build before treating this handoff as verified.
- 2026-10-10: Wired the QEMU folder as an Xcode folder reference, added a tracked empty payload directory, and forwarded variant/engine build flags plus the engine framework rpath to both app configurations. The first check found that upstream had no target-level variant condition; the wiring tool was corrected to preserve DEBUG and add explicit Debug/Release settings. `check_pbxproj.py`, `add_engine_embed.py --check`, `check_swift_balance.py`, `check_shell_continuations.py`, and the tar layout self-check pass. No Xcode or `gh` executable is available on this Windows host; the QEMU payload is intentionally absent locally, so these checks do not prove an IPA or Linux runtime.
- 2026-10-10: Corrected `add_variant_files.py` so it does not try to re-add the browser, installer bridge, and theme from the wrong directory; it now wires the 15 actual Variant/Shell source files. Project validation reports 375 objects, no duplicate IDs or dangling references, and all 128 build inputs resolve.
- 2026-10-10: Direct merge of the Freebuff checkout was rejected by Git because the two checkout histories are unrelated. Kept the new branch anchored to the clean upstream snapshot and selectively ported Madeira-owned components instead.
