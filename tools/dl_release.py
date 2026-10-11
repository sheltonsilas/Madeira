#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Madeira Converter Exception: see LICENSE-EXCEPTION.md
"""Download a build-host release asset to a local path.

Written because the release assets live in the private build host repository,
so a plain URL is not enough: the request needs the push token, and the GitHub
API answers with a redirect to blob storage that rejects the Authorization
header. That redirect is the one thing this file exists to get right - the
header is dropped for any host that is not api.github.com, and kept otherwise.

USAGE
  python3 tools/dl_release.py --tag build-14 --name Madeira-unified-unsigned.ipa \\
      --out /tmp/build14.ipa
  python3 tools/dl_release.py --url <api url> --out /tmp/thing.json --json

Exit 0 written, 1 not (with the status), 2 bad inputs.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys
import urllib.error
import urllib.request


def token() -> str:
    path = pathlib.Path.home() / ".madeira_push_token"
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError as error:
        raise SystemExit(f"error: {path}: {error}")


class DropAuthOffGitHub(urllib.request.HTTPRedirectHandler):
    """Follow the redirect to blob storage without the Authorization header."""

    def redirect_request(self, req, fp, code, msg, hdrs, newurl):
        new = super().redirect_request(req, fp, code, msg, hdrs, newurl)
        if new is not None and "api.github.com" not in newurl:
            new.headers.pop("Authorization", None)
            new.unredirected_hdrs.pop("Authorization", None)
        return new


def opener() -> urllib.request.OpenerDirector:
    return urllib.request.build_opener(DropAuthOffGitHub)


def api(host: str, path: str, accept: str = "application/vnd.github+json"):
    request = urllib.request.Request(
        f"https://api.github.com/repos/{host}{path}",
        headers={
            "Authorization": f"Bearer {token()}",
            "Accept": accept,
            "User-Agent": "madeira-tools",
        },
    )
    return opener().open(request)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--host", default="sheltonsilas/madeira-ci")
    parser.add_argument("--tag", help="release tag, e.g. build-14")
    parser.add_argument("--name", help="asset name inside that release")
    parser.add_argument("--url", help="an api.github.com URL instead")
    parser.add_argument("--out", required=True)
    parser.add_argument("--json", action="store_true",
                        help="this URL answers JSON, so print it as well")
    args = parser.parse_args()

    if bool(args.url) == bool(args.tag):
        print("error: pass exactly one of --url or --tag", file=sys.stderr)
        return 2
    if args.tag and not args.name:
        print("error: --tag needs --name", file=sys.stderr)
        return 2

    try:
        if args.url:
            where = args.url if args.url.startswith("https://") else f"https://api.github.com/repos/{args.host}{args.url}"
            response = urllib.request.Request(
                where,
                headers={
                    "Authorization": f"Bearer {token()}",
                    "Accept": "application/vnd.github+json",
                    "User-Agent": "madeira-tools",
                },
            )
            body = opener().open(response)
        else:
            release = json.load(api(args.host, f"/releases/tags/{args.tag}"))
            assets = [a for a in release["assets"] if a["name"] == args.name]
            if not assets:
                print(f"error: {args.tag} has no asset {args.name}; it has "
                      + ", ".join(a["name"] for a in release["assets"]), file=sys.stderr)
                return 2
            request = urllib.request.Request(
                assets[0]["url"],
                headers={
                    "Authorization": f"Bearer {token()}",
                    "Accept": "application/octet-stream",
                    "User-Agent": "madeira-tools",
                },
            )
            body = opener().open(request)
    except urllib.error.HTTPError as error:
        print(f"error: HTTP {error.code} {error.reason}", file=sys.stderr)
        return 1

    target = pathlib.Path(args.out)
    target.parent.mkdir(parents=True, exist_ok=True)
    if args.json:
        payload = body.read()
        target.write_bytes(payload)
        print(payload.decode("utf-8", "replace"))
    else:
        expected = int(body.headers.get("Content-Length") or 0)
        written = 0
        with open(target, "wb") as sink:
            while True:
                chunk = body.read(1 << 20)
                if not chunk:
                    break
                sink.write(chunk)
                written += len(chunk)
        print(f"wrote {target} {written} bytes" + (f" of {expected}" if expected else ""))
        if expected and written != expected:
            print(f"error: {target} is truncated", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
