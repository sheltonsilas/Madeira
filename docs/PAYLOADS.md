# Payloads

Two things the app ships cannot be built by the app build. They are built by
dedicated workflows, published as assets of one rolling release, and downloaded
by `build.yml` through `build/ci/fetch-payload.sh`.

| Asset | Ends up at | Built by | Enables |
|---|---|---|---|
| `i386-windows.tar.gz` | `app/Madeira/i386-windows/` | `payloads.yml` | 32-bit x86 Windows programs (docs/WOW64.md) |
| `qemu-ios-tci-arm64.tar.gz` | `app/Madeira/qemu-ios/` | `linux-engine.yml` | Linux guests, no debugger needed (docs/LINUX_ENGINE.md) |

## Why a release, and why one rolling tag

Both payloads are pure functions of a pinned submodule revision, so they do not
need rebuilding per app build. Producing them inline would push `build.yml` past
its timeout and make every fix cycle slower.

A workflow artifact cannot be used instead: `actions/download-artifact` reads
another repository's artifacts only with a token that can read that repository's
Actions, which a fork's `GITHUB_TOKEN` is not. A public release asset is a plain
HTTPS GET, so an app build anywhere can consume it. The tag is `payloads`, and
assets are replaced in place with `--clobber`: the app build wants "the current
farm", not "the farm from run 42".

## Running them

Both are `workflow_dispatch` only. A payload failure must not be able to turn an
app build red, and the app build is what produces the IPA.

```
Actions -> payloads    -> Run workflow  (input `what`: i386-farm)
Actions -> linux-engine -> Run workflow (input `targets`: interpreter-only)
```

Run them on the build host (`sheltonsilas/madeira-ci`), which is where
`build.yml` downloads from. `tools/mirror_ci.py` is what puts the same workflows
there.

## Consuming them

`build/ci/fetch-payload.sh <asset> <destination>` has three exit codes, and the
distinction is the whole design:

| Code | Meaning | Caller does |
|---|---|---|
| 0 | The payload is in place | Use it |
| 10 | It has not been published (yet) | Warn and continue: the app build must still produce an IPA |
| 1 | Anything else (network, truncated download, empty archive) | Stop: a half-extracted payload looks exactly like a feature that is switched off |

`build.yml` maps 0/10/1 onto, in order: set `MADEIRA_ENGINE_FLAGS` and record
`32-bit Windows farm: yes` in `build-info.txt`; warn and record `no`; fail. That
record is deliberate - an IPA's capabilities depend on payloads that are not in
git, so the binary alone does not say what it can do, and `build-info.txt` is
the first thing to read when a reported feature does nothing.

## When one fails

Read the **first** error, not the last.

- **The i386 farm.** `build/wine-i386/build.sh` was translated from a WSL script
  and its own header says it had not been run on macOS. Its module loop uses
  `make -k`, so one broken module produces hundreds of lines of fallout and then
  a tidy summary; the real answer is the `FAIL <target>` list printed just before
  the exit. Modules that fail are rebuilt serially with `make -j1`, so a genuine
  error appears there too.
- **The QEMU sysroot.** See the run log in linux-engine.yml's header, which keeps
  the ordered list of what each run revealed. Five runs in, the lesson recorded
  there is worth repeating: when a failure looks unlike the previous ones, stop
  adding packages and read what it is actually asking for.

Nothing publishes unless the build step succeeded. The QEMU publish step is
guarded by `success()`, unlike the artifact upload which runs `always()`: a
partial sysroot links, ships, and crashes inside the guest, whereas a partial
artifact is only ever inspected.
