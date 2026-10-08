#!/usr/bin/env python3
"""Generate a SideStore / AltStore source JSON from the built IPA artifacts.

This replaces the live preview site: instead of a page you have to visit, a
Source URL you add once in SideStore, after which the app installs and updates
itself and SideStore handles the 7-day re-signing.

ONE APP BY DEFAULT
------------------
The two variants used to be two apps because the variant was chosen at compile
time and each build could present only its own front screen. That is no longer
true: `MADEIRA_VARIANT_LINUX` is read in exactly one place, every file in
`app/Madeira/Variant/` is compiled into the single target either way, and the
choice now comes from `AppVariant.selectionKey` at run time. So one binary
presents both, and this script emits ONE app for it.

    python3 tools/make_source.py --out source.json \
        --windows-ipa dist/Madeira-unified-unsigned.ipa \
        --base-url https://github.com/<owner>/<repo>/releases/download/<tag> \
        --version 76.0

Passing --linux-ipa as well restores the old two-app output, which is kept so
an older pipeline cannot break, not because it is still wanted.

The output follows the AltStore source schema, which SideStore also reads:
    https://docs.sidestore.io/docs/development/source-format
Only fields that can be filled honestly are emitted. Notably:

  * `size` is the real byte size of each IPA, read from disk, because SideStore
    shows it and a wrong value is worse than none.
  * `version` comes from --version, and MUST match the tag the assets are
    attached to, or SideStore will offer a phantom update forever.
  * `appPermissions.entitlements` lists get-task-allow. That is not decoration:
    without it the app cannot create executable memory, so a source that omits
    it produces an app that installs and then has no JIT.

Exits non-zero if an IPA listed is missing, rather than publishing a source
with a dead download link.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

BUNDLE = "com.willfaust.madeora"

# The single app this project now ships. Bundle identifier is unchanged from
# the Windows variant on purpose: an existing Madeira install then upgrades in
# place instead of appearing a second time.
UNIFIED = {
    "name": "Madeira",
    "bundle": BUNDLE,
    "icon": "icon.png",
    "subtitle": "Windows apps and Linux environments, in one app",
    "description": (
        "One app, two guests, and a switch between them. "
        "Madeira Windows runs .exe and .msi downloads through Wine on FEX-Emu "
        "with DXMT, installing them from a browser built into the app. "
        "Madeira Linux manages Linux environments: choose a distribution and "
        "whether you want a desktop or a command line, and the image is "
        "downloaded and checked against the checksum the distribution "
        "publishes. "
        "Windows guests need JIT, because this FEX build ships only the ARM64 "
        "JIT core and no interpreter. Linux guests are run by the same engine "
        "UTM uses, QEMU, which can be built with its TCG threaded interpreter "
        "and therefore needs no JIT at all."
    ),
}

# Kept for the legacy two-app output. Both variants are the same product built
# from one codebase, so they share a bundle identifier prefix and differ by
# suffix. Keep this in step with MADEIRA_BUNDLE_IDENTIFIER in project.pbxproj.
VARIANTS = {
    "windows": {
        "name": "Madeira Windows",
        "bundle": BUNDLE,
        "icon": "icon-windows.png",
        "subtitle": "Windows apps, installed from a browser",
        "description": (
            "A Wine-based Windows environment with a browser already installed. "
            "Download an .exe or .msi in the browser, tap Install, and it runs in "
            "the prefix. Natively built for arm64 iOS with FEX-Emu and DXMT."
        ),
    },
    "linux": {
        "name": "Madeira Linux",
        "bundle": BUNDLE + ".linux",
        "icon": "icon-linux.png",
        "subtitle": "Linux environments, managed like a virtual machine",
        "description": (
            "A UTM-style manager for Linux environments. Guests are run by QEMU "
            "- with its TCG JIT when a debugger is attached, and with its TCG "
            "threaded interpreter, the configuration UTM SE ships, when one is "
            "not."
        ),
    },
}


def ipa_size(path: str) -> int:
    if not os.path.isfile(path):
        print(f"error: IPA not found: {path}", file=sys.stderr)
        sys.exit(1)
    return os.path.getsize(path)


def build_app(meta: dict, ipa: str, base_url: str, version: str, date: str) -> dict:
    asset = os.path.basename(ipa)
    return {
        "name": meta["name"],
        "bundleIdentifier": meta["bundle"],
        "developerName": "Shelton Silas",
        "subtitle": meta["subtitle"],
        "localizedDescription": meta["description"],
        "iconURL": f"{base_url}/{meta['icon']}",
        "tintColor": "7B68EE",
        "category": "utilities",
        "version": version,
        "versionDate": date,
        "versionDescription": "Built from the two-variants branch. See TASK_STATE.md for what is tested.",
        "downloadURL": f"{base_url}/{asset}",
        "size": ipa_size(ipa),
        "minOSVersion": "26.0",
        # Required, not decorative: iOS only grants executable memory to an app
        # signed as debuggable, so a source that drops this ships an app with no
        # JIT and no explanation.
        "appPermissions": {
            "entitlements": [
                {"name": "get-task-allow"},
                {"name": "com.apple.security.cs.allow-jit"},
                {"name": "com.apple.developer.kernel.increased-memory-limit"},
            ],
        },
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--windows-ipa", required=True,
                    help="the IPA to publish; the unified build when --linux-ipa is absent")
    ap.add_argument("--linux-ipa", default=None,
                    help="optional; passing it restores the legacy two-app output")
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--version", default="0.1.0")
    ap.add_argument("--identifier", default="com.madeira.emulator.source")
    args = ap.parse_args()

    date = time.strftime("%Y-%m-%d")

    if args.linux_ipa:
        source = {
            "name": "Madeira (two variants)",
            "identifier": args.identifier,
            "subtitle": "FEX-Emu + Wine on iOS, built for iPad",
            "description": (
                "Two builds from one codebase. This is the legacy layout: one "
                "binary can now present both variants, so a single-app source "
                "is the normal output and this path exists only so an older "
                "pipeline cannot break."
            ),
            "iconURL": f"{args.base_url}/icon.png",
            "website": "https://github.com/sheltonsilas/Madeira",
            "tintColor": "7B68EE",
            "featuredApps": [VARIANTS["windows"]["bundle"]],
            "apps": [
                build_app(VARIANTS["windows"], args.windows_ipa, args.base_url, args.version, date),
                build_app(VARIANTS["linux"], args.linux_ipa, args.base_url, args.version, date),
            ],
            "news": [],
        }
    else:
        source = {
            "name": "Madeira",
            "identifier": args.identifier,
            "subtitle": "Windows apps and Linux environments, in one app",
            "description": UNIFIED["description"],
            "iconURL": f"{args.base_url}/icon.png",
            "website": "https://github.com/sheltonsilas/Madeira",
            "tintColor": "7B68EE",
            "featuredApps": [UNIFIED["bundle"]],
            "apps": [
                build_app(UNIFIED, args.windows_ipa, args.base_url, args.version, date),
            ],
            "news": [],
        }

    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(source, fh, indent=2)
        fh.write("\n")
    print(f"wrote {args.out} with {len(source['apps'])} app(s)")
    for app in source["apps"]:
        print(f"  {app['name']}: {app['size'] / 1_048_576:.1f} MB -> {app['downloadURL']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
