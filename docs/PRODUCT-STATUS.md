# Clean rebuild status

This document records what is present in the clean upstream baseline and what
this rebuild has actually changed. It deliberately separates working source
from features that still need a macOS build or a physical iPad.

## Baseline and current changes

The rebuild branch starts at upstream commit `48f976429c189f8396e23d251d8a82f43c705922`.
It does not use the Freebuff fork's code, workflows, build host, generated
scripts, or IPA.

This iteration adds an installer intake path to the existing Windows library:

- The library can import `.exe` and `.msi` installers from Files or download
  them from a native iPad web view.
- Installers are stored at `Documents/wine/drive_c/Downloads`, which is visible
  in Files and resolves to `C:\Downloads` inside the Wine prefix.
- `.exe` files are added as launch entries. `.msi` files are added as
  `msiexec /i` entries. The user launches the entry from the Madeira library.
- Download names are normalized for Windows path rules, and collisions are
  preserved by adding a numbered suffix.
- The library's empty state and labels now describe Windows apps rather than
  games.

The built-in web view runs on iPadOS. It is a download center, **not** a browser
running inside Wine. A preinstalled Wine browser remains unimplemented and must
not be claimed as delivered. Browser download behavior is not yet device-tested.

## Capability audit

| Area | Clean upstream source contains | Status after this iteration |
|---|---|---|
| Windows app runtime | Custom Wine/FEX ARM64EC runtime and a library that can launch PE programs | Existing implementation retained; broad app compatibility needs testing with real installers |
| Installer intake | Files picker and native `WKWebView` download center added here | Source implemented; iPad build/download/install UNTESTED |
| Wine browser | No bundled Windows browser identified in the baseline | Missing |
| iPad input | Existing pointer, keyboard, touch/gamepad and display code | Retained; requested device matrix UNTESTED |
| JIT helper | Separate `MadeiraJITHelper` extension, StikJIT integration, pairing/DDI code, JIT allocator protocol and source entitlements | Existing implementation retained; final signed entitlements and iOS 27 behavior UNTESTED |
| Interpreter-only repeatability | No clean-room device evidence in this task | UNTESTED; do not claim reliable repeated runs |
| Linux guest | No QEMU/UTM guest integration, Ubuntu rootfs, Linux environment manager, or Linux first-run flow in this baseline | Missing; no Linux desktop is delivered by these changes |
| IPA | No complete dependency closure or independent workflow in the checkout | Not produced |

## Linux architecture decision

The existing app embeds Wine and FEX in its iOS process. That is not a Linux
kernel and cannot provide Ubuntu's Linux system calls. A real Ubuntu ARM64 guest
needs a full-system emulator such as QEMU, a root filesystem and firmware, plus
display, input, network, audio, clipboard and shared-folder integration. FEX
could be run inside that Linux guest for x86-64 Linux programs; it does not
replace the guest kernel. On iPad without hardware virtualization, software
emulation is expected to be slow and thermally demanding. No UTM code is reused
in this iteration.

This is an architectural plan, not an implemented Linux feature. The next
milestone needs to bring in and license the selected QEMU components, boot one
known ARM64 image, and prove keyboard/display/storage lifecycle on a device
before adding distro selection or promising thermal behavior.

## Build and verification limits

The Windows development host has no `xcodebuild`. The clean checkout is missing
generated static libraries, toolchains, initialized submodules, and the ignored
Microsoft VC++ runtime input required by the Xcode project. The original
upstream `docs/BUILDING.md` also marks multiple clean macOS build steps
UNVERIFIED. A separate, clean GitHub Actions workflow has not yet been proven
against those prerequisites, so an IPA must not be claimed until a clean run
packages and inspects it.

No device is attached. Installer downloads, app compatibility, JIT, signing
entitlements after re-signing, interpreter fallback, input, display, audio,
networking, external monitors, heat and repeated launches remain UNTESTED.

## Sources consulted

- UTM architecture (QEMU full-system design): https://github.com/utmapp/UTM/blob/main/Documentation/Architecture.md
- UTM project overview: https://github.com/utmapp/UTM/blob/main/README.md
- StikJIT integration requirements: https://github.com/StikDebug/StikJIT/blob/main/INTEGRATION.md
- Apple provisioning profile and entitlement behavior: https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles

\n