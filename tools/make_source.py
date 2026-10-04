#!/usr/bin/env python3
"""Generate a SideStore / AltStore source JSON from the built IPA artifacts.

This replaces the live preview site: instead of a page you have to visit, a
Source URL you add once in SideStore, after which both variants install and
update themselves and SideStore handles the 7-day re-signing.

Usage:
    python3 tools/make_source.py --out source-built.json \
        --windows-ipa dist/Madeira-windows-unsigned.ipa \
        --linux-ipa   dist/Madeira-linux-unsigned.ipa \
        --base-url https://github.com/sheltonsilas/Madeira/releases/download/<tag>

The output follows the AltStore source schema, which SideStore also reads:
    https://docs.sidestore.io/docs/development/source-format
Only fields we can fill honestly are emitted. Notably:

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

# Both variants are the same product built from one codebase with one compile
# flag, so they share a bundle identifier prefix and differ by suffix. Keep this
# in step with MADEIRA_BUNDLE_IDENTIFIER in project.pbxproj.
VARIANTS = {
    "windows": {
        "name": "Madeira Windows",
        "bundle": BUNDLE,
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
        "subtitle": "Linux environments, managed like a virtual machine",
        "description": (
            "A UTM-style manager for Linux environments. NOTE: no guest can be "
            "launched yet - a full Ubuntu desktop needs a full-system emulator, "
            "which is the next milestone and is not in this build."
        ),
    },
}


def ipa_size(path: str) -> int:
    if not os.path.isfile(path):
        print(f"error: IPA not found: {path}", file=sys.stderr)
        sys.exit(1)
    return os.path.getsize(path)


def build_app(key: str, ipa: str, base_url: str, version: str, date: str) -> dict:
    meta = VARIANTS[key]
    asset = os.path.basename(ipa)
    return {
        "name": meta["name"],
        "bundleIdentifier": meta["bundle"],
        "developerName": "Shelton Silas",
        "subtitle": meta["subtitle"],
        "localizedDescription": meta["description"],
        "iconURL": f"{base_url}/icon-{key}.png",
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
    ap.add_argument("--windows-ipa", required=True)
    ap.add_argument("--linux-ipa", required=True)
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--version", default="0.1.0")
    ap.add_argument("--identifier", default="com.madeira.emulator.source")
    args = ap.parse_args()

    date = time.strftime("%Y-%m-%d")
    source = {
        "name": "Madeira (two variants)",
        "identifier": args.identifier,
        "subtitle": "FEX-Emu + Wine on iOS, built for iPad",
        "description": (
            "Two builds from one codebase: Madeira Windows, with a browser and "
            "an installer flow, and Madeira Linux, with an environment manager. "
            "JIT must be enabled separately with StikDebug or the built-in "
            "helper; without it everything runs interpreted and much slower."
        ),
        "iconURL": f"{args.base_url}/icon.png",
        "website": "https://github.com/sheltonsilas/Madeira",
        "tintColor": "7B68EE",
        "featuredApps": [VARIANTS["windows"]["bundle"]],
        "apps": [
            build_app("windows", args.windows_ipa, args.base_url, args.version, date),
            build_app("linux", args.linux_ipa, args.base_url, args.version, date),
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