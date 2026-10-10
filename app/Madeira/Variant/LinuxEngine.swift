// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// LinuxEngine.swift - what actually runs a Linux guest, and why there are two
// of it.
//
// THE CORRECTION THIS FILE MAKES
// The previous state of the Linux variant refused to start anything without a
// debugger, on the grounds that "FEX has only an ARM64 JIT core and no
// interpreter". That reasoning is correct about FEX and wrong about Linux,
// because FEX is not what should run a Linux guest. Two different engines are
// involved in this repository and they were being conflated:
//
//   * Windows apps run through FEX + Wine. FEX is a static binary translator
//     with no interpreter core, so a Windows session genuinely cannot execute
//     without JIT. Nothing in this file changes that.
//   * A Linux guest is a full machine, and the tool that runs a full machine on
//     iOS is QEMU - the engine inside UTM. QEMU has TCG, and TCG has two
//     build-time configurations:
//
//       .utm    TCG's JIT: guest instructions are compiled to host code.
//               Fastest, and it needs executable memory, which on iOS means a
//               debugger. This is what upstream UTM ships.
//       .utmSE  TCG with --enable-tcg-interpreter: a threaded interpreter that
//               executes guest instructions directly. It allocates no
//               executable memory, so it needs no JIT and no debugger at all.
//               This is exactly what UTM SE ships, and it is why UTM SE can run
//               on a stock iPad.
//
// So the honest answer to "make JIT-less Linux work" is not to restore a FEX
// interpreter that upstream deleted, and it is not to refuse to launch. It is
// to run the guest with the same engine UTM SE uses. That is what
// `LinuxEnginePlan.resolve` below selects.
//
// WHAT IS AND IS NOT HERE, STATED PLAINLY
// Three separate things have to be true before a machine can start, and they
// were being reported as one. They are now three:
//
//   `hasQEMUCore`      QEMU for aarch64-apple-ios is linked into the binary.
//                      `.github/workflows/linux-engine.yml` BUILDS it - the
//                      JIT-less sysroot was produced on 2026-10-09, with
//                      `libqemu-aarch64-softmmu.dylib` and the dependency
//                      frameworks beside it - but the app does not yet link it,
//                      so this is still false and the build job that changes
//                      that is described in docs/LINUX_ENGINE.md.
//   `hasTCGInterpreter` that QEMU was built with `--enable-tcg-interpreter`,
//                      which the same workflow does pass for the TCI sysroot.
//   `hasLauncher`      Madeira has code that starts a guest: the argument
//                      vector, the display, the serial console, the stop. This
//                      is the piece that does not exist, and it is the reason a
//                      linked core would still not make a machine run.
//
// Keeping them apart is not bookkeeping. Reporting "no emulator core" when the
// core is present and only the launcher is missing sends the reader to the
// wrong file, and that is the failure mode this app was already in.

import Foundation

// MARK: - Engine

/// Which QEMU configuration backs a Linux environment.
enum LinuxEngineKind: String, Codable, CaseIterable, Identifiable {
    /// Upstream UTM's configuration: QEMU with the TCG JIT.
    case utm
    /// UTM SE's configuration: QEMU built with `--enable-tcg-interpreter`.
    case utmSE

    var id: String { rawValue }

    var title: String {
        switch self {
        case .utm: return "JIT (UTM)"
        case .utmSE: return "Interpreter (UTM SE)"
        }
    }

    /// Short label for a segmented control; "JIT" is too wide next to it.
    var shortTitle: String {
        switch self {
        case .utm: return "JIT"
        case .utmSE: return "No JIT"
        }
    }

    /// Whether this configuration needs a debugger and executable memory.
    var requiresJIT: Bool { self == .utm }

    var symbol: String {
        switch self {
        case .utm: return "bolt.fill"
        case .utmSE: return "tortoise.fill"
        }
    }

    var summary: String {
        switch self {
        case .utm:
            return "QEMU compiles guest code to native instructions. Several times faster, and it needs a debugger attached."
        case .utmSE:
            return "QEMU interprets guest instructions instead of compiling them. No executable memory is used, so this is the mode that still runs when JIT cannot be enabled at all."
        }
    }
}

/// Whether the parts an engine needs are actually compiled into this binary.
///
/// Reading this instead of assuming is the difference between "the feature is
/// missing" and "the app is broken". Both are bad, but only one of them tells
/// the user what to do next.
enum LinuxEngineSupport {
    /// True once a QEMU core for aarch64-apple-ios is linked in. Set by the
    /// `MADEIRA_HAS_QEMU` compilation condition, which the QEMU build job in
    /// `.github/workflows/build.yml` sets when it has produced one.
    static var hasQEMUCore: Bool {
        #if MADEIRA_HAS_QEMU
        return true
        #else
        return false
        #endif
    }

    /// True when the linked QEMU was built with `--enable-tcg-interpreter`.
    /// A JIT-less launch needs this specific configuration: a QEMU built
    /// without it can only JIT, so it cannot run without a debugger however
    /// the rest of the app behaves.
    static var hasTCGInterpreter: Bool {
        #if MADEIRA_HAS_QEMU_TCGI
        return true
        #else
        return false
        #endif
    }

    /// True when the code that actually starts a guest is compiled in.
    ///
    /// Set by `MADEIRA_HAS_QEMU_LAUNCHER`, which belongs in the same place as
    /// the other two but is not set by linking: it is set when the launcher
    /// exists. Until then a machine says so in those words, because "the
    /// emulator is missing" and "nothing here knows how to start the emulator"
    /// are different problems with different fixes.
    static var hasLauncher: Bool {
        #if MADEIRA_HAS_QEMU_LAUNCHER
        return true
        #else
        return false
        #endif
    }
}

/// The engine an environment will actually start under, and what stops it.
struct LinuxEnginePlan: Equatable {
    let kind: LinuxEngineKind
    /// Non-nil when the environment cannot start at all, with the reason in
    /// words the user can act on. Nil means "this will run".
    let blocker: String?
    /// True when enabling JIT would let the faster engine be used instead, so
    /// the UI can offer it without pretending it is required.
    let jitWouldHelp: Bool

    var canStart: Bool { blocker == nil }

    /// Decide the engine.
    ///
    /// The rule, and the order it applies in:
    ///   1. A guest only needs JIT for the fast configuration. If the user
    ///      asked for JIT and has a debugger, use `.utm`.
    ///   2. If the user asked for JIT but there is no debugger, fall back to
    ///      `.utmSE` rather than refusing. This is the case that used to be a
    ///      dead end; it is now a slower boot, which is the right trade.
    ///   3. If the user asked for the interpreter, use `.utmSE`. It does not
    ///      care whether JIT is available.
    ///
    /// A missing QEMU core is the only hard blocker, because no amount of
    /// choosing can run a guest without an emulator.
    ///
    /// `bootBlocker` is the fourth question, and it is asked LAST on purpose:
    /// what a machine boots from (its image, its firmware) only matters once
    /// there is an engine and a launcher to boot it with. Passing a boot problem
    /// while the engine is absent would send the reader to the wrong file - the
    /// same mistake this whole file exists to undo. Its caller is
    /// MadeiraMachineView, which has the environment; callers that only have an
    /// engine choice (the distro onboarding screen) leave it nil.
    static func resolve(environmentRequiresJIT: Bool, jitIsOn: Bool,
                        bootBlocker: String? = nil) -> LinuxEnginePlan {
        let kind: LinuxEngineKind
        var jitWouldHelp = false

        if environmentRequiresJIT && jitIsOn {
            kind = .utm
        } else if environmentRequiresJIT {
            // Asked for JIT, no debugger: drop to the interpreter rather than
            // telling the user their environment cannot run.
            kind = .utmSE
            jitWouldHelp = true
        } else {
            kind = .utmSE
            jitWouldHelp = jitIsOn == false
        }

        if !LinuxEngineSupport.hasQEMUCore {
            return LinuxEnginePlan(
                kind: kind,
                blocker: "No emulator core is linked into this build. A Linux guest is run by "
                    + "QEMU (the engine inside UTM), and this build does not contain it, so there "
                    + "is nothing to start. The engine itself now builds - see Linux engine in "
                    + "the repository's docs - so what is missing is the step that links it in.",
                jitWouldHelp: jitWouldHelp)
        }

        // Before the interpreter check, and deliberately: a missing launcher
        // stops both engines, so offering "enable JIT" first would be advice
        // that cannot work.
        if !LinuxEngineSupport.hasLauncher {
            return LinuxEnginePlan(
                kind: kind,
                blocker: "The emulator is linked into this build, but nothing here can start a "
                    + "machine with it yet: the launcher - QEMU's arguments, its display and its "
                    + "serial console - is not written. The engine choice, the distribution "
                    + "image and this machine's settings are real.",
                jitWouldHelp: false)
        }

        if kind == .utmSE && !LinuxEngineSupport.hasTCGInterpreter {
            return LinuxEnginePlan(
                kind: .utm,
                blocker: "This build's QEMU was compiled without TCG's interpreter, so it can "
                    + "only run with a debugger attached. Enable JIT, or link a QEMU built with "
                    + "--enable-tcg-interpreter.",
                jitWouldHelp: true)
        }

        // The engine, the launcher and the accelerator are all in place. What is
        // left is whether this particular machine has anything to boot from.
        if let bootBlocker {
            return LinuxEnginePlan(kind: kind, blocker: bootBlocker, jitWouldHelp: jitWouldHelp)
        }

        return LinuxEnginePlan(kind: kind, blocker: nil, jitWouldHelp: jitWouldHelp)
    }
}

// MARK: - Distributions

/// One downloadable image for a distribution.
struct LinuxDistroImage: Identifiable, Hashable {
    /// Whether this image gives a command line or a graphical desktop.
    ///
    /// The brief asks the first question a new user answers to be this one, so
    /// it lives in the catalogue rather than being inferred from the file name.
    enum Kind: String, CaseIterable, Codable, Identifiable {
        case commandLine
        case desktop

        var id: String { rawValue }

        var title: String {
            switch self {
            case .commandLine: return "Command line"
            case .desktop: return "Desktop (GUI)"
            }
        }

        var summary: String {
            switch self {
            case .commandLine:
                return "A terminal, no windows. Smallest download and the fastest to boot."
            case .desktop:
                return "A full graphical desktop. A larger download and a slower boot."
            }
        }

        var symbol: String {
            switch self {
            case .commandLine: return "terminal"
            case .desktop: return "macwindow"
            }
        }
    }

    let id: String
    let kind: Kind
    /// The name the file is saved under, and the name the checksum file lists.
    let fileName: String
    let url: URL
    let byteCount: Int64
    /// The published checksum list containing `fileName`, when upstream
    /// publishes one. Fedora's is not included because the URL could not be
    /// verified; an unverified checksum is worse than an absent one.
    let checksumURL: URL?
    let checksumAlgorithm: ChecksumAlgorithm?

    enum ChecksumAlgorithm: String, Codable {
        case sha256
        case sha512

        var displayName: String { rawValue.uppercased() }
    }

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}

/// A distribution a user can pick on first run.
struct LinuxDistro: Identifiable, Hashable {
    let id: String
    let name: String
    /// The family it belongs to, for grouping in the picker.
    let family: String
    let summary: String
    let images: [LinuxDistroImage]

    func images(of kind: LinuxDistroImage.Kind) -> [LinuxDistroImage] {
        images.filter { $0.kind == kind }
    }

    var hasDesktop: Bool { !images(of: .desktop).isEmpty }
}

/// The distributions this build offers.
///
/// EVERY URL AND EVERY BYTE COUNT IN THIS TABLE WAS FETCHED BEFORE IT WAS
/// WRITTEN DOWN. That is not ceremony: a catalogue of plausible-looking links
/// that 404 is how a first run becomes a bug report, and there is no way to
/// test a download without a device attached.
///
/// Verified 2026-10-08 with a HEAD request, final status and Content-Length:
///
///   Ubuntu 24.04 minimal  200  229,048,320
///   Ubuntu 24.04 server   200  620,224,512
///   Ubuntu 24.04 desktop  200 3,473,190,912
///   Debian 12 generic     200  342,294,528
///   Fedora 41 Cloud       200  495,255,552
///
/// Checksum lists verified in the same pass:
///   cloud-images.ubuntu.com/.../SHA256SUMS     200
///   cloud-images.ubuntu.com/minimal/.../SHA256SUMS 200
///   cdimage.ubuntu.com/releases/24.04/release/SHA256SUMS 200
///   cloud.debian.org/images/cloud/bookworm/latest/SHA512SUMS 200
///
/// Alpine is deliberately absent: the aarch64 directory for the versions
/// checked contains netboot images and rootfs tarballs, and the qcow2 paths
/// that looked right both returned 404.
enum LinuxDistroCatalog {
    static let all: [LinuxDistro] = [ubuntu, debian, fedora]

    static func distro(id: String) -> LinuxDistro? {
        all.first { $0.id == id }
    }

    static func image(id: String) -> LinuxDistroImage? {
        for distro in all {
            if let image = distro.images.first(where: { $0.id == id }) { return image }
        }
        return nil
    }

    /// Ubuntu, because it has both a command-line and a desktop image on a
    /// stable release path and publishes a SHA-256 list that covers each.
    static let ubuntu = LinuxDistro(
        id: "ubuntu-24.04",
        name: "Ubuntu 24.04 LTS",
        family: "Ubuntu",
        summary: "The distribution UTM documents first. Long-term support until 2029.",
        images: [
            LinuxDistroImage(
                id: "ubuntu-24.04-minimal",
                kind: .commandLine,
                fileName: "ubuntu-24.04-minimal-cloudimg-arm64.img",
                url: URL(string: "https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-arm64.img")!,
                byteCount: 229_048_320,
                checksumURL: URL(string: "https://cloud-images.ubuntu.com/minimal/releases/noble/release/SHA256SUMS"),
                checksumAlgorithm: .sha256),
            LinuxDistroImage(
                id: "ubuntu-24.04-server",
                kind: .commandLine,
                fileName: "ubuntu-24.04-server-cloudimg-arm64.img",
                url: URL(string: "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-arm64.img")!,
                byteCount: 620_224_512,
                checksumURL: URL(string: "https://cloud-images.ubuntu.com/releases/24.04/release/SHA256SUMS"),
                checksumAlgorithm: .sha256),
            LinuxDistroImage(
                id: "ubuntu-24.04-desktop",
                kind: .desktop,
                fileName: "ubuntu-24.04.3-desktop-arm64.iso",
                url: URL(string: "https://cdimage.ubuntu.com/releases/24.04/release/ubuntu-24.04.3-desktop-arm64.iso")!,
                byteCount: 3_473_190_912,
                checksumURL: URL(string: "https://cdimage.ubuntu.com/releases/24.04/release/SHA256SUMS"),
                checksumAlgorithm: .sha256),
        ])

    static let debian = LinuxDistro(
        id: "debian-12",
        name: "Debian 12 (bookworm)",
        family: "Debian",
        summary: "No desktop, very stable, and the smallest of the general-purpose images.",
        images: [
            LinuxDistroImage(
                id: "debian-12-generic",
                kind: .commandLine,
                fileName: "debian-12-genericcloud-arm64.qcow2",
                url: URL(string: "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-arm64.qcow2")!,
                byteCount: 342_294_528,
                checksumURL: URL(string: "https://cloud.debian.org/images/cloud/bookworm/latest/SHA512SUMS"),
                checksumAlgorithm: .sha512),
        ])

    static let fedora = LinuxDistro(
        id: "fedora-41",
        name: "Fedora 41 Cloud",
        family: "Fedora",
        summary: "Recent packages and a recent kernel. Command line only.",
        images: [
            LinuxDistroImage(
                id: "fedora-41-cloud",
                kind: .commandLine,
                fileName: "Fedora-Cloud-Base-Generic-41-1.4.aarch64.qcow2",
                url: URL(string: "https://download.fedoraproject.org/pub/fedora/linux/releases/41/Cloud/aarch64/images/Fedora-Cloud-Base-Generic-41-1.4.aarch64.qcow2")!,
                byteCount: 495_255_552,
                checksumURL: nil,
                checksumAlgorithm: nil),
        ])
}
