# Building this without a Mac

This project needs Xcode: the app is an iOS app, and the parts it links are
cross-compiled for the iOS triple. This page is about what that costs when the
machine you have is not a Mac, and what is and is not possible.

It exists because the work of editing this tree has been done on Windows. Every
statement here is either a property of the toolchains, verifiable in this
repository, or a limit observed in the build host described below.

## Xcode and the iOS Simulator on Windows: not possible

There is no Windows build of Xcode and no Windows build of the iOS Simulator.
The Simulator is a macOS application that runs the iOS userland against the
host's frameworks; there is no port to another operating system, and no
compatibility layer that provides one. Apple's licence also restricts macOS to
Apple hardware, so a macOS virtual machine on a Windows PC is not a route this
project can recommend even where it boots.

Two things that are sometimes offered as an equivalent, and are not:

- **Docker-OSX and similar**: boots macOS in a container on non-Apple hardware.
  It is a licence violation, and Apple's virtualisation framework will not run
  the Simulator's GPU paths well enough to be worth the trouble.
- **A Hackintosh**: the same problem at a larger scale.

## What *is* possible, and what this repository uses

### A macOS CI runner, for free, on a public repository

GitHub Actions gives macOS runners to public repositories without charge, and
that is how the IPAs here are built: `.github/workflows/build.yml` runs on
`macos-15`, builds the native pieces, then `xcodebuild` and a zip. This is the
only route that has actually been taken to a working IPA in this project.

What it does not give you is the Simulator. On a hosted runner you can *boot* a
simulator headlessly with `xcrun simctl`, take screenshots and run tests, and
that is genuinely useful. It is not available here for a different reason
entirely: the archives this app links are device-only. `build/fex-ios/build.sh`
cross-compiles FEX with `-DCMAKE_OSX_SYSROOT=iphoneos`, so there is no simulator
slice of FEX, Wine, DXMT or the converter, and a Simulator build would fail at
link rather than at compile. See "Fast Swift feedback" for what to do instead.

### Fast Swift feedback without linking

The most useful thing a CI runner can give a Mac-less developer is not a
screenshot, it is a compiler that tells you about your own Swift in two minutes
instead of twenty-five. `xcodebuild` cannot be used for that alone: it links.
`swiftc -typecheck` can:

```sh
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun swiftc -typecheck -swift-version 5 -sdk "$SDK" \
  -target arm64-apple-ios17.0 \
  -F app/Frameworks/StikJIT.xcframework/ios-arm64 \
  $(find app/Madeira -name '*.swift')
```

That checks every file the app target compiles, including the C declarations the
app depends on, without needing FEX or Wine to exist. It has not been wired into
a workflow yet; the full build in `build.yml` is what currently reports Swift
errors, and it reports them after the native pieces have been rebuilt.

### A real Mac, paid, per hour

If you need the interactive Simulator specifically - to watch the interface
render, to use the debugger's view hierarchy, to test a gesture - then the only
honest answer is a Mac, at least for those hours:

- **MacStadium** and **MacinCloud**: an hourly Mac with Xcode and Screen
  Sharing. Paid, with a trial.
- **Xcode Cloud**: Apple's own, needs a paid Apple Developer Program membership.
- **Cirrus CI** and **AppVeyor**: macOS jobs on their free tiers for open-source
  projects. Build-only, the same shape as GitHub's, with no interactive
  Simulator.

## Where that leaves this repository

- **Editing** happens anywhere.
- **`tools/check_swift_balance.py`** is the second-long pre-flight for the one
  mistake that costs the most: a brace closed one time too many or too few,
  which a compiler reports as a cascade at the end of the file.
- **The build host** is a second, near-empty public repository
  (`tools/mirror_ci.py` generates its workflows from these, `tools/push_mirror.py`
  uploads them and dispatches). It exists because GitHub has Actions disabled on
  the fork this work is pushed to; the workflows there check this repository out
  by name, so the job bodies are the same and only the checkout changes.
- **The caches are per-repository**, which is the build host's real cost. A
  fresh host has to rebuild the hour-long LLVM-for-iOS toolchain
  (`.github/workflows/heavy.yml`) before `build.yml` can link anything, and its
  FEX and Wine trees start cold, which is most of a build's wall clock. Once
  warm, they are shared between the workflows of that one repository.

## A summary worth keeping

| What you want | Windows | Free cloud | Notes |
| --- | --- | --- | --- |
| Edit the tree | Yes | - | Any editor |
| Compile and link the app | No | GitHub Actions / Cirrus | Device build only |
| Check your own Swift quickly | No | `swiftc -typecheck` | Not yet wired up here |
| Run the app | No | No | Needs a device and a signature |
| Interactive iOS Simulator | No | No | Needs macOS, and a device-only link path anyway |
