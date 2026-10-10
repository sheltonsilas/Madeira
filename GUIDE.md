# Madeira setup guide

## Build status

There is no installable IPA from this rebuild yet. GitHub Actions on the fork is
currently paused by GitHub because of its Actions usage limits. Do not install
an older release as if it contained this rebuild. When the macOS workflow is
available again, this guide will be checked against the resulting IPA and
updated with its direct download link.

Madeira is one app with Windows and Linux workspaces. The Windows workspace
uses the existing Wine and FEX runtime. Its installer browser is a native iOS
WebKit view that downloads `.exe` and `.msi` files into Madeira's shared
Downloads area; it is **not** a Windows browser running inside Wine. A bundled
Windows browser has not been produced. Linux uses a QEMU virtual machine rather
than trying to run Linux userspace directly on iOS. QEMU's bootable runtime,
Linux desktop display, and a boot-tested Ubuntu image must be present in a build
before a Linux desktop can be claimed as working.

## Install the IPA on Windows

These steps apply only after a validated unsigned IPA is linked from this
project's GitHub Actions run or release.

### Sideloadly

1. Download the IPA to the Windows PC.
2. Install Sideloadly from its [official website](https://sideloadly.io/).
3. Connect the iPad to the PC by USB, unlock it, and tap **Trust** if prompted.
4. Open Sideloadly, select the Madeira IPA and the connected iPad, then sign in
   with the Apple Account you want to use for signing.
5. Start the sideload. If signing succeeds, trust the developer under **Settings
   → General → VPN & Device Management** when iPadOS asks.

### SideStore

SideStore's current Windows setup uses its `iloader` installer and a pairing
file. Follow the official [prerequisites](https://docs.sidestore.io/docs/installation/prerequisites)
and [installation guide](https://docs.sidestore.io/docs/installation/install)
for the current downloads and screenshots.

1. Install `iloader` and its required Apple device support on Windows.
2. Connect the iPad over USB, trust the PC on the iPad, and install SideStore
   Stable using `iloader`.
3. Trust the signing developer in **Settings → General → VPN & Device
   Management**. Enable **Developer Mode** under **Settings → Privacy & Security**
   if iPadOS requests it; the iPad will restart.
4. Connect the required LocalDevVPN connection and complete SideStore's setup
   using the same Apple Account. SideStore requires this VPN for installing,
   updating, and refreshing apps.
5. Import the Madeira IPA into SideStore and install it. Use SideStore's own
   pairing-file recovery guide if the pairing file expires or stops working.

## Enable JIT in Madeira

Open Madeira's JIT setup screen and follow its status checks. JIT is required
for the FEX Windows runtime. The Linux interpreter mode is designed to run
without JIT when the build actually contains the TCG interpreter payload; the
Linux JIT mode requires a JIT-capable QEMU payload. A label in the interface is
not proof that the engine was included or that it runs on the iPad.

Pairing files are device credentials. Import them only into Madeira or the
trusted sideloading/JIT tool you chose; do not leave them in a shared folder.
After a device reset or iOS update, regenerate or reimport a pairing file if
the JIT setup check reports it is invalid. Follow the in-app messages for
LocalDevVPN and Developer Disk Image setup.

The built-in StikJIT extension and pairing path are **UNTESTED on a physical
iPad** in this rebuild. Until that validation is done, keep the standalone
StikDebug route available as a fallback.

## Apple Account limits and memory

Apple documents that a free Personal Team can install up to **three apps per
device**, and the provisioning profiles expire after **seven days**. The app
must be refreshed or re-signed before expiry. If SideStore itself and other
sideloaded apps already use the three-app allowance, Madeira may not install
until one slot is freed or a different signing arrangement is used. A paid
Apple Developer Program membership extends normal provisioning validity, but
does not make JIT or extra memory automatic.

The increased-memory entitlement is device-dependent and may not be available
from the free signing profile. Madeira must work within the memory iPadOS
actually grants; Linux RAM settings are caps for a guest and cannot increase
the app's host memory allowance. Large desktops may be killed or run slowly on
devices with less available memory. Check `os_proc_available_memory` at runtime
and use conservative guest RAM limits.

## Known limits before release

- No IPA has been built from this branch yet.
- Windows program compatibility varies. The supported runtime is not a full
  Windows installation, and arbitrary desktop applications are not guaranteed.
- The current in-app download browser is native WebKit, not Firefox or Chromium
  running inside Wine.
- A full Ubuntu desktop, display/input bridge, hardware-accelerated graphics,
  and physical-device performance still require implementation and testing.
- A physical iPad is required to verify installation, JIT attachment, app
  launches, interaction, memory pressure, and heat.

## References

- [SideStore prerequisites](https://docs.sidestore.io/docs/installation/prerequisites)
- [SideStore installation](https://docs.sidestore.io/docs/installation/install)
- [SideStore pairing-file recovery](https://docs.sidestore.io/docs/advanced/pairing-file)
- [Sideloadly official site and FAQ](https://sideloadly.io/faq)
- [Apple: free Apple Account limits](https://developer.apple.com/help/account/basics/about-your-developer-account/)
- [Apple: increased-memory entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit)
- [Madeira JIT setup notes](docs/JIT.md)
- [Madeira clean-build notes](docs/BUILDING.md)
