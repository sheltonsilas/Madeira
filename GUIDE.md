# Madeira install and first-run guide

## Build status

This clean rebuild has **not produced an IPA yet**. Do not download or install
an IPA from another branch or from the earlier Freebuff build. When a verified
clean GitHub Actions run exists, its IPA will be available from that run's
Artifacts section. An artifact should be called installable only after the
archive and its embedded app/helper contents have been inspected.

The only supported source for this rebuild is the `codex/madeira-fresh` branch
based on the original upstream commit recorded in `docs/PRODUCT-STATUS.md`.

## Signing and installing on Windows

An IPA produced without an Apple signing identity is not ready to install as-is.
Use a current version of Sideloadly or SideStore to sign it with your Apple ID:

1. Download the IPA artifact from the verified GitHub Actions run to your
   Windows PC.
2. Install and open Sideloadly, connect the iPad by USB, select the IPA, and
   sign it with your Apple ID. Follow the signer's prompts on the iPad.
   Alternatively, install the IPA from SideStore using its documented pairing
   and refresh setup.
3. On the iPad, enable Developer Mode in **Settings → Privacy & Security →
   Developer Mode** if iPadOS requests it, then restart and confirm the prompt.
4. Open Madeira. If iPadOS says the developer is not trusted, use the device's
   VPN & Device Management settings to trust the profile shown for your Apple
   ID, then open Madeira again.

Exact Sideloadly/SideStore screens vary by version. Follow their current
official instructions if a step has moved. Never enter Apple ID credentials on
a third-party web page.

## Free Apple Account limits

The [SideStore FAQ](https://docs.sidestore.io/docs/faq) documents the free
account's normal seven-day app signing period and three simultaneously
installed apps (including SideStore). Plan to refresh
Madeira before its signature expires and leave an app slot available. A paid
Apple Developer Program membership changes these provisioning limits; it does
not guarantee that Apple will authorize every private entitlement.

With a free Apple ID, assume the increased-memory entitlement is unavailable
unless the final signature proves otherwise. [Apple's entitlement reference](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit)
says the higher limit is available only on some device models, and the app must
still work when extra memory is not granted. Madeira must keep a usable
interpreter path; that entitlement cannot make a missing Linux guest or
incomplete runtime work.

JIT depends on entitlements and provisioning that survive signing. The source
project requests `get-task-allow`, JIT, and increased-memory capabilities, but
the final signed app must be checked after Sideloadly or SideStore re-signs it.
[Apple documents](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
that provisioning profiles authorize the final entitlements.
If the signer removes a required entitlement, JIT can fail even though the
source is configured correctly. Do not infer JIT support from an IPA filename
or an in-app green indicator alone.

## Madeira setup

The clean source already includes an embedded JIT helper and setup flow. On an
iPad, follow the in-app pairing/DDI instructions and run its health check. The
pairing, helper launch, DDI mount and JIT status need real-device verification;
they have not been tested in this rebuild.

The installer intake work adds a native iPad download view and Files import.
It stores `.exe` and `.msi` files in **Files → On My iPad → Madeira → wine →
drive_c → Downloads**. The app library should then show an `.exe` launch entry
or an MSI install entry. This view is not a Windows browser running under Wine.
Browser downloads and Windows app compatibility remain UNTESTED until checked
on an iPad.

## What this build does not promise

- A Linux/Ubuntu environment is not present in this iteration.
- A Wine-run Windows browser is not present in this iteration.
- No IPA has been built or verified yet.
- JIT, interpreter-only repeatability, and broad `.exe`/`.msi` compatibility
  require an actual iPad test.

\n
