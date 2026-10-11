// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// QEMULauncher.swift - starting a Linux machine with the QEMU engine.
//
// WHAT WAS MISSING, AND WHAT THIS IS
// LinuxEnginePlan already picks between QEMU's two TCG configurations and
// already explains, in three separate words, which piece is absent. The third of
// those was this file: `hasLauncher` was false because nothing in the app built
// QEMU's argument vector, gave it a machine, or read its console. The engine
// built; nothing drove it.
//
// HOW QEMU IS LOADED, AND WHY NOT LINKED
// The sysroot app/Madeira/qemu-ios is embedded as a folder reference and dropped
// into the app bundle verbatim, and this file dlopens
// qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu out of it. Not a link:
//
//   * A static link would add a 400 MB archive to the link line, and every one
//     of the dependency frameworks would have to be embedded and signed
//     individually with its own install names rewritten.
//   * QEMU is built with --enable-shared-lib, which exports exactly the three
//     entry points a driver needs (qemu_init, qemu_main_loop, qemu_cleanup).
//     Those are the supported seam, and UTM's own launcher uses the same one.
//   * dlopen fails at a place where it can be reported. A link failure is a
//     build error that reads like a broken toolchain.
//
// WHY THE FRAMEWORK, AND NOT lib/libqemu-aarch64-softmmu.dylib
// The sysroot ships the same libraries twice, and only one copy can load. The
// copies under lib/ name themselves and their dependencies with the absolute
// path of the machine that built them -
// `/Users/runner/work/.../utm/sysroot-iOS-TCI-arm64/lib/libglib-2.0.0.dylib` -
// which resolves on no device. The copies under Frameworks/ name the same
// libraries `@rpath/glib-2.0.0.framework/glib-2.0.0`, which is a name dyld can
// actually satisfy, and each one carries the Info.plist that makes it a bundle
// iOS will load. So the framework is the engine, lib/ is the build tree, and
// build/ci/trim-qemu-sysroot.sh deletes the build tree before the payload is
// packaged: it was 1.3 GB of a 3 GB payload that could never have been opened.
//
// `@rpath` needs a search path, and the sysroot's frameworks have no LC_RPATH of
// their own, so the app target carries `@executable_path/qemu-ios/Frameworks`
// alongside the usual `@executable_path/Frameworks`. tools/add_engine_embed.py
// adds it and the build checks for it; without it the engine loads and then
// fails to find glib, which is a much worse error than a missing file.
//
// WHY THE PUBLIC CLASS IS NOT BEHIND THE FLAG
// `LinuxMachineConsole` is compiled in every build; only the engine work inside
// it is not. A class that vanishes with a build flag forces `#if` into every call
// site, and a conditional in the middle of a SwiftUI modifier chain is not even
// valid syntax - it would have to be wrapped, and the wrapper's `else` is exactly
// where a "this build has no launcher" lie gets told. Instead, a build without
// the payload gets the same class, the same console screen and the same honest
// error, and LinuxEnginePlan never lets Start be pressed in that build anyway.
//
// DISPLAY AND CONSOLE, AND WHAT THIS DOES NOT DO YET
// QEMU runs headless with two chardevs on Unix sockets this file owns: a serial
// console whose output is read back into the app, and a monitor it writes `quit`
// to for Stop. That is a real, working machine and a real, working stop, with no
// private QEMU API involved - both are documented `-chardev` configurations.
//
// What it does NOT do is present the guest's framebuffer: a desktop image boots
// and is reachable over the serial console, but its windows are not drawn in the
// app. Doing that needs `-device virtio-gpu-pci` plus a scanout reader, which is
// the same problem the Windows side already solved with MetalHostView, and is
// deliberately not guessed at here.

import Foundation
import Darwin
import SwiftUI

// MARK: - What a machine needs before anything is started

/// An aarch64 UEFI firmware: the read-only code image, and the writable
/// variables image when the sysroot ships one.
struct LinuxFirmware {
    let code: URL
    let vars: URL?
}

/// The files a QEMU machine needs, checked before QEMU is called rather than
/// after it fails. Defined unconditionally so LinuxEnginePlan and the machine
/// screen can ask it a question without knowing whether a launcher was compiled
/// in.
enum LinuxBootCheck {

    /// The embedded sysroot, as it is laid out in the app bundle.
    static var sysroot: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("qemu-ios", isDirectory: true)
    }

    /// The engine as the packaged app carries it: in the bundle's own Frameworks
    /// directory, which is where a sideloader re-signs nested code.
    ///
    /// WHY THE LOCATION IS PART OF THE FIX
    /// The engine and its dependency frameworks are Mach-O libraries. dyld will
    /// not load a Mach-O whose signature does not match, and an unsigned one -
    /// which is what a folder copied in as a resource is - does not fail the
    /// load politely: the process is terminated before any of this code can
    /// report anything. The app already knows this. Its "Sign bundled dylibs"
    /// phase ad-hoc signs the one loose dylib it copies as a resource, and says
    /// so in a comment. Fifty-five more dylibs cannot be signed that way from a
    /// build with signing turned off, so the packaging step moves them into
    /// Frameworks/, which is the one directory every sideloader has to walk
    /// because it is where Xcode puts embedded frameworks. See "Package the
    /// unsigned IPA" in .github/workflows/build.yml.
    static let bundleEnginePath = "Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu"

    /// Where the engine may be inside the embedded sysroot, for a build that has
    /// not been through the packaging step: a local Xcode build, or an IPA made
    /// before the move.
    ///
    /// The framework comes before the library because it is the copy that can
    /// load at all: the library under lib/ names its dependencies with the
    /// absolute path of the machine that built it.
    static let sysrootEnginePaths = [
        "Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu",
        "lib/libqemu-aarch64-softmmu.dylib",
    ]

    /// The softmmu engine the launcher dlopens, or nil when the payload has none.
    static var engineURL: URL? {
        let fm = FileManager.default
        let packaged = Bundle.main.bundleURL.appendingPathComponent(bundleEnginePath)
        if fm.fileExists(atPath: packaged.path) { return packaged }
        guard let sysroot else { return nil }
        for path in sysrootEnginePaths {
            let url = sysroot.appendingPathComponent(path)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// The frameworks the engine names in its own load commands, and which
    /// therefore have to be beside it.
    ///
    /// Checked by name rather than by looking for a directory, because a payload
    /// trimmed past its dependencies has an engine that opens and then fails to
    /// find glib - a failure inside dyld, with no file to point at.
    static let engineDependencyFrameworks = [
        "glib-2.0.0", "gobject-2.0.0", "gio-2.0.0", "gmodule-2.0.0",
        "pixman-1.0", "jpeg.62", "epoxy.0", "zstd.1", "slirp.0",
        "spice-server.1", "virglrenderer.1",
    ]

    /// The directories the engine's dependencies can be in, in the order they are
    /// looked for: the bundle's own Frameworks directory, where the packaging
    /// step puts them, and then the sysroot's, where a local build has them.
    static var frameworkDirectories: [URL] {
        var directories = [Bundle.main.bundleURL.appendingPathComponent("Frameworks", isDirectory: true)]
        if let sysroot {
            directories.append(sysroot.appendingPathComponent("Frameworks", isDirectory: true))
        }
        return directories
    }

    /// The first dependency the installed app is missing, for a message that
    /// names it instead of describing dyld's failure to find it.
    static func missingEngineDependency() -> String? {
        let fm = FileManager.default
        for name in engineDependencyFrameworks {
            let present = frameworkDirectories.contains { directory in
                fm.fileExists(atPath: directory.appendingPathComponent("\(name).framework/\(name)").path)
            }
            if !present { return name }
        }
        return nil
    }

    /// Where an aarch64 UEFI firmware might be.
    ///
    /// UTM's sysroot keeps QEMU's own `share/qemu` tree, and the first names here
    /// are the ones QEMU's firmware descriptor for the `virt` machine - the
    /// embedded copy of `share/qemu/firmware/60-edk2-aarch64.json` - points at. A
    /// cloud image, which is every entry in LinuxDistroCatalog except the desktop
    /// ISO, has no separable kernel to boot with `-kernel`, so a firmware is not
    /// optional for those.
    static let firmwareCodeCandidates = [
        "share/qemu/edk2-aarch64-code.fd",
        "share/qemu/QEMU_EFI.fd",
        "edk2-aarch64-code.fd",
        "QEMU_EFI.fd",
    ]

    /// The writable half of the pair. QEMU packages `virt`'s aarch64 (and 32-bit
    /// arm) variables image as `edk2-arm-vars.fd`, not `edk2-aarch64-vars.fd` -
    /// that is what 60-edk2-aarch64.json names, and the second spelling is here
    /// only in case that is ever corrected upstream.
    static let firmwareVarsCandidates = [
        "share/qemu/edk2-arm-vars.fd",
        "share/qemu/edk2-aarch64-vars.fd",
    ]

    /// The firmware for this bundle, or nil when there is none.
    ///
    /// `vars` is optional on purpose: CODE alone is a bootable firmware and the
    /// launcher falls back to `-bios` for it. The pair is what makes EFI
    /// variables persist per machine, so it is used whenever it is available.
    static func firmware() -> LinuxFirmware? {
        guard let sysroot else { return nil }
        func find(_ names: [String]) -> URL? {
            for name in names {
                let url = sysroot.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
            return nil
        }
        guard let code = find(firmwareCodeCandidates) else { return nil }
        return LinuxFirmware(code: code, vars: find(firmwareVarsCandidates))
    }

    /// The size a pflash bank has to be, which is the size of the code image.
    ///
    /// QEMU's `virt` machine gives the firmware two flash banks of one size,
    /// and a bank whose backend is shorter than the device is not a warning: the
    /// machine does not start, and the message is
    ///
    ///     qemu-system-aarch64: device requires 67108864 bytes, block backend
    ///     provides 329216 bytes
    ///
    /// which reads as a corrupt payload rather than as a file that needed to be
    /// extended. 67108864 is the size of `edk2-aarch64-code.fd` and 329216 is
    /// the whole of `edk2-arm-vars.fd`, and the gap between them is the
    /// difference between an `nvram-template` - a firmware's *initial* variables,
    /// which is what QEMU's own `share/qemu/firmware/60-edk2-aarch64.json` calls
    /// it - and an nvram image, which is a flash bank. The code image is the
    /// size to follow rather than a constant, because it is the bank that is
    /// known to fit the device.
    static func flashSize(for firmware: LinuxFirmware) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: firmware.code.path)
        let code = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        return code > 0 ? code : 64 * 1024 * 1024
    }

    /// A machine's own writable EFI variables file, written out of the bundle on
    /// first use.
    ///
    /// Written rather than copied: the bundle's copy is read-only and shared by
    /// every machine, a firmware that cannot write its variables cannot remember
    /// a boot entry, and - see `flashSize` - the template is a fraction of the
    /// bank it has to fill, so a copy is a machine that never starts. One file
    /// per machine folder, so a machine's boot order is its own.
    ///
    /// An existing file is damaged-checked and not trusted. The machine folder
    /// outlives the app update, and a build before this one left a 321 KB copy
    /// behind, so a file that is too short is replaced instead of being returned
    /// - otherwise the bug outlives its fix on every device that hit it.
    static func writableVars(_ firmware: LinuxFirmware, in folder: URL) -> URL? {
        guard let source = firmware.vars else { return nil }
        let target = folder.appendingPathComponent("efi-vars.fd")
        let flash = flashSize(for: firmware)
        if let existing = try? FileManager.default.attributesOfItem(atPath: target.path),
           let size = (existing[.size] as? NSNumber)?.intValue, size >= flash {
            return target
        }
        do {
            let template = try Data(contentsOf: source)
            FileManager.default.createFile(atPath: target.path, contents: template)
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            // Extends with zeroes to the bank's size; the template's own
            // variables are the first bytes and survive.
            try handle.truncate(atOffset: UInt64(flash))
            return target
        } catch {
            // Not fatal: the launcher falls back to the CODE image alone, which
            // boots without persisting variables. A failure here is not a
            // reason to refuse to start a machine.
            return nil
        }
    }

    /// Why this environment cannot boot yet, or nil when it can.
    ///
    /// Ordered from the outermost thing to the innermost. Each message names the
    /// file it looked for and where it looked, because "the emulator is missing"
    /// and "the firmware is missing" send the reader to completely different
    /// places.
    static func blocker(for environment: LinuxEnvironment) -> String? {
        guard let sysroot else { return nil }
        guard let engineURL else {
            return "This build carries no aarch64 engine: Frameworks/qemu-aarch64-softmmu.framework "
                + "is not in the app bundle, and neither is "
                + "\(sysroot.lastPathComponent)/Frameworks/qemu-aarch64-softmmu.framework. "
                + "The QEMU payload is incomplete."
        }
        if let missing = missingEngineDependency() {
            return "The engine is at \(engineURL.lastPathComponent), but the framework it needs "
                + "is not beside it: \(missing).framework, looked for in "
                + frameworkDirectories.map(\.lastPathComponent).joined(separator: " and ")
                + ". The QEMU payload was trimmed past a dependency, so the engine would open "
                + "and then fail to load."
        }

        // The image. `imagePath` is absolute and set when a download finishes.
        if let path = environment.imagePath {
            if !FileManager.default.fileExists(atPath: path) {
                return "This machine's downloaded image is no longer at the path it was saved to. "
                    + "Download the distribution again from the machine's settings."
            }
        } else {
            return "No distribution image has been downloaded for this machine yet. "
                + "Download one first: QEMU boots the image, and there is nothing to boot without it."
        }

        guard firmware() != nil else {
            return "This machine's image needs a UEFI firmware to boot, and the app bundle has none. "
                + "Looked for: " + firmwareCodeCandidates.joined(separator: ", ")
                + " under \(sysroot.lastPathComponent)/."
        }

        return nil
    }
}

// MARK: - The machine host

/// Starts and stops a Linux machine, and carries its console.
///
/// One machine at a time, held as a singleton for the same reason the Wine
/// session is: QEMU is not reentrant, and two launchers racing over one engine is
/// how a console ends up attached to the wrong machine.
@MainActor
final class LinuxMachineConsole: ObservableObject {

    static let shared = LinuxMachineConsole()

    enum LaunchError: LocalizedError {
        case engine(String)
        case busy
        case noEngine

        var errorDescription: String? {
            switch self {
            case let .engine(m): return m
            case .busy: return "A machine is already running. Stop it before starting another."
            case .noEngine:
                return "This build has no engine launcher, so nothing was started. "
                    + "The QEMU payload is fetched at build time; see the build log for whether it was."
            }
        }
    }

    enum State: Equatable {
        case idle
        case running(engine: LinuxEngineKind)
        case failed(String)
        case exited(code: Int32)

        var isRunning: Bool { if case .running = self { return true }; return false }

        var summary: String {
            switch self {
            case .idle: return "Stopped"
            case let .running(engine): return "Running · \(engine.title)"
            case let .failed(m): return m
            case let .exited(code): return "Exited (code \(code))"
            }
        }
    }

    @Published private(set) var state: State = .idle
    /// The guest's serial output. Bounded: a booting machine can produce more
    /// text than is useful to hold, and an unbounded buffer on iOS is a way to be
    /// killed by jetsam during a long boot.
    @Published private(set) var console: String = ""

    private static let consoleLimit = 64 * 1024

    #if MADEIRA_HAS_QEMU_LAUNCHER
    private var entry: QEMUEntryPoints?
    private var monitor: UnixSocketWriter?
    private var consoleReader: UnixSocketReader?
    private var thread: Thread?
    /// The engine's stdout and stderr while a machine runs: see
    /// EngineOutputCapture for why the app takes them over.
    private var engineOutput: EngineOutputCapture?
    #endif

    private init() {}

    /// Start `environment`, or throw with the reason it could not.
    ///
    /// The pre-flight runs first and in the same order LinuxBootCheck uses, so an
    /// environment the UI said could start cannot fail here for a reason the UI
    /// had already decided was fatal.
    func start(environment: LinuxEnvironment, engine: LinuxEngineKind) throws {
        guard !state.isRunning else { throw LaunchError.busy }

        #if MADEIRA_HAS_QEMU_LAUNCHER
        if let blocker = LinuxBootCheck.blocker(for: environment) {
            state = .failed(blocker)
            throw LaunchError.engine(blocker)
        }
        guard let engineURL = LinuxBootCheck.engineURL, let sysroot = LinuxBootCheck.sysroot else {
            throw LaunchError.noEngine
        }

        // The engine this build has against the engine the plan chose. A
        // mismatch is what "press Start and the app disappears" was: QEMU is
        // handed an accelerator it does not have and answers with exit(1) -
        // inside our process. Refusing here turns a crash into a sentence, and
        // LinuxEnginePlan.resolve should already have prevented it; this is the
        // backstop for a caller that chose for itself.
        if engine == .utm && !LinuxEngineSupport.hasJITCore {
            let why = "This build's emulator was compiled with TCG's interpreter only, so it cannot "
                + "run the JIT configuration at all. Choose the interpreter engine (No JIT) and "
                + "start again."
            state = .failed(why)
            throw LaunchError.engine(why)
        }

        // Resolve once and keep it: dlopen of the same path is cheap, but doing it
        // per start would hide a load failure inside an unrelated error.
        let entry: QEMUEntryPoints
        do { entry = try QEMUEntryPoints.load(at: engineURL) }
        catch {
            state = .failed(error.localizedDescription)
            throw error
        }
        self.entry = entry

        // Both chardevs live in the machine's own folder, so a stale socket from a
        // crashed run is removed with it and cannot collide with another machine's.
        // The folder is where the image already is.
        let folder = URL(fileURLWithPath: environment.imagePath ?? sysroot.path).deletingLastPathComponent()
        let monitorPath = folder.appendingPathComponent("monitor.sock").path
        let consolePath = folder.appendingPathComponent("console.sock").path
        for path in [monitorPath, consolePath] { try? FileManager.default.removeItem(atPath: path) }

        // The firmware, and a per-machine writable copy of its variables. Both
        // are resolved here rather than inside arguments() because both touch the
        // filesystem and both can fail, and arguments() is a pure function of its
        // inputs on purpose.
        guard let firmware = LinuxBootCheck.firmware() else {
            // Unreachable: blocker() above returned nil, which requires one.
            let why = "No UEFI firmware is embedded, so there is nothing to boot the image with."
            state = .failed(why)
            throw LaunchError.engine(why)
        }
        let writableVars = LinuxBootCheck.writableVars(firmware, in: folder)

        let argv = LinuxMachineConsole.arguments(
            environment: environment, engine: engine, sysroot: sysroot,
            firmware: firmware, writableVars: writableVars,
            monitorPath: monitorPath, consolePath: consolePath)

        console = ""
        state = .running(engine: engine)
        // The monitor is ours to connect to whenever a Stop arrives.
        monitor = UnixSocketWriter(path: monitorPath)
        // The console socket is a server QEMU creates, so it does not exist until
        // QEMU is up; the reader retries in the background.
        consoleReader = UnixSocketReader(path: consolePath) { [weak self] text in
            Task { @MainActor in self?.append(text) }
        }
        consoleReader?.start()

        // The engine's own output belongs to the console from here on. QEMU
        // reports a problem by printing and exiting, and a print nobody reads is
        // how a crash stays unexplained. Attached before the thread starts, so
        // nothing written during init is missed.
        let capture = EngineOutputCapture(onText: { [weak self] text in
            Task { @MainActor in self?.append(text) }
        })
        capture.attach(header: argv.joined(separator: " "))
        engineOutput = capture

        append("starting \(engine.title.lowercased()) engine\n")
        append("$ " + argv.joined(separator: " ") + "\n\n")
        if environment.imagePath?.lowercased().hasSuffix(".iso") == true {
            append("(this machine boots an installer ISO; its screen is not drawn in the app yet, "
                   + "so watch this console and the guest's own display once it has one)\n")
        }

        let thread = Thread { [weak self] in
            LinuxMachineConsole.run(entry: entry, argv: argv, onExit: { code in
                Task { @MainActor in self?.exited(code: code) }
            })
        }
        thread.name = "qemu"
        // Above the default so a boot is not starved by the UI, below
        // userInteractive because the guest's own latency matters more.
        thread.qualityOfService = .userInitiated
        self.thread = thread
        thread.start()
        #else
        // Unreachable in any build build.yml can produce: without the launcher
        // flag the plan reports hasLauncher == false, Start is disabled, and this
        // is not called. Stated rather than left empty so such a build says what
        // is wrong instead of doing nothing at all.
        state = .failed(LaunchError.noEngine.localizedDescription)
        throw LaunchError.noEngine
        #endif
    }

    /// Stop the running machine by asking QEMU's own monitor to quit.
    ///
    /// Not a thread kill: QEMU holds the guest's disk, and tearing the thread down
    /// mid-write is how a filesystem gets corrupted. `quit` makes QEMU run its own
    /// shutdown path.
    func stop() {
        guard state.isRunning else { return }
        append("\nstop requested\n")
        #if MADEIRA_HAS_QEMU_LAUNCHER
        if let monitor {
            monitor.send(line: "quit")
        } else {
            append("the monitor is not connected yet; the guest was asked to stop and may not have\n")
        }
        #endif
    }

    private func exited(code: Int32) {
        append("\nengine exited with code \(code)\n")
        #if MADEIRA_HAS_QEMU_LAUNCHER
        EngineOutputCapture.note("--- engine exited with code \(code) ---")
        consoleReader?.stop(); consoleReader = nil
        monitor = nil
        engineOutput?.detach(); engineOutput = nil
        #endif
        state = .exited(code: code)
    }

    private func append(_ text: String) {
        console += text
        if console.utf8.count > Self.consoleLimit {
            // Keep the tail: the end of a boot log is what a failure is read from.
            console = "…earlier output discarded…\n" + String(console.suffix(Self.consoleLimit / 2))
        }
    }

    #if MADEIRA_HAS_QEMU_LAUNCHER
    // MARK: The command line

    /// QEMU's argument vector for this machine.
    ///
    /// `-accel` is the part that makes the JIT-less engine JIT-less: a QEMU built
    /// with --enable-tcg-interpreter has no other accelerator, and asking for
    /// `thread=multi` (multi-threaded TCG, which needs generated code) is not
    /// offered to it.
    nonisolated static func arguments(environment: LinuxEnvironment, engine: LinuxEngineKind,
                                      sysroot: URL, firmware: LinuxFirmware, writableVars: URL?,
                                      monitorPath: String, consolePath: String) -> [String] {
        var a = ["qemu-system-aarch64"]
        a += ["-M", "virt"]
        // Multi-threaded TCG needs generated code, so it is offered only by an
        // engine that has TCG's JIT. Asking the interpreter for it is not a slow
        // boot - QEMU refuses the accelerator and exits the process - which is
        // why the condition is the build's capability and not the plan's choice.
        a += engine == .utm && LinuxEngineSupport.hasJITCore
            ? ["-accel", "tcg,thread=multi"]
            : ["-accel", "tcg,thread=single"]
        a += ["-cpu", "max"]
        a += ["-smp", String(max(1, environment.vcpus))]
        a += ["-m", String(max(512, environment.ramMiB))]

        let image = environment.imagePath ?? ""
        let lower = image.lowercased()
        if lower.hasSuffix(".iso") {
            // An .iso is an optical disc and not a hard disk, and it takes two
            // things to hand one to a firmware.
            //
            // The backend first: media=cdrom with readonly=on, because the
            // drive is read-only media holding an optical filesystem, and a
            // firmware handed that through a plain disk reads its first sector
            // looking for a partition table, finds an ISO9660 layout instead,
            // and falls through to "no bootable device".
            //
            // Then the front end, which is the part virtio-blk cannot be.
            // virtio-blk is a disk device - its own UEFI driver reports its
            // media as non-removable - so media=cdrom on a virtio-blk-pci drive
            // describes the backend and not what the guest is given, and El
            // Torito is then found, if at all, by accident of the partition
            // scanner's tolerance. virtio-scsi is the front end that has a
            // CD-ROM, which is what a scsi-cd on a virtio-scsi controller is,
            // and the firmware enumerates it as an optical drive with a boot
            // entry of its own. Every desktop ISO in LinuxDistroCatalog is one
            // of these, so this is the difference between an installer that
            // starts and an installer that is never reached.
            a += ["-drive", "file=\(image),if=none,id=cd0,format=raw,media=cdrom,readonly=on"]
            a += ["-device", "virtio-scsi-pci,id=scsi0"]
            a += ["-device", "scsi-cd,bus=scsi0.0,drive=cd0"]
        } else {
            let format = lower.hasSuffix(".qcow2") ? "qcow2" : "raw"
            a += ["-drive", "file=\(image),if=virtio,format=\(format),cache=writeback"]
        }

        // A cloud image (every catalogue entry but the desktop ISO) boots its own
        // kernel from the ESP, which is what the firmware provides.
        //
        // CODE read-only, VARS writable, both through pflash. pflash is not
        // decoration: it is where EFI variables live, and without a writable
        // image the firmware cannot remember a boot entry.
        //
        // The shipped sysroot has both halves - share/qemu/edk2-aarch64-code.fd
        // and share/qemu/edk2-arm-vars.fd, the pair QEMU's own
        // share/qemu/firmware/60-edk2-aarch64.json names - so in practice this is
        // the pair. `writableVars` is optional because a sysroot without a VARS
        // image should still boot, and `firmware` itself is not, because
        // LinuxBootCheck.blocker has already refused a machine that has no
        // firmware at all: a QEMU that cannot boot is worse than a refusal.
        a += ["-drive", "if=pflash,format=raw,readonly=on,file=\(firmware.code.path)"]
        if let writableVars {
            a += ["-drive", "if=pflash,format=raw,file=\(writableVars.path)"]
        }

        // No scanout yet: see this file's header. `-display none` is explicit so
        // the absence of a window is a decision and not a QEMU default.
        a += ["-display", "none"]
        a += ["-device", "virtio-keyboard-pci"]
        a += ["-device", "virtio-tablet-pci"]

        // The two chardevs this launcher owns. `server=on,wait=off` so QEMU does
        // not block at startup waiting for a reader that is a fraction of a second
        // behind - a blocking accept here looks exactly like a hang.
        a += ["-chardev", "socket,id=madeira-console,path=\(consolePath),server=on,wait=off"]
        a += ["-serial", "chardev:madeira-console"]
        a += ["-chardev", "socket,id=madeira-monitor,path=\(monitorPath),server=on,wait=off"]
        a += ["-monitor", "chardev:madeira-monitor"]

        // QEMU resolves its data files (BIOS images, keymaps) relative to its own
        // data path; point it at the embedded tree rather than the bundle root,
        // where share/ would not be found.
        a += ["-L", sysroot.appendingPathComponent("share/qemu").path]

        return a
    }

    /// Call QEMU on its own thread and report the exit code.
    ///
    /// `qemu_init` is given ownership of the vector until `qemu_cleanup`, so the C
    /// strings are intentionally not freed: freeing them after init returns would
    /// leave QEMU holding pointers into released memory for the whole life of the
    /// machine.
    nonisolated static func run(entry: QEMUEntryPoints, argv: [String], onExit: @escaping (Int32) -> Void) {
        let cStrings: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        let vector = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: argv.count + 1)
        for (i, s) in cStrings.enumerated() { vector[i] = s }
        vector[argv.count] = nil

        entry.init_(Int32(argv.count), vector)
        entry.mainLoop()
        entry.cleanup()

        vector.deallocate()
        onExit(0)
    }
    #endif
}

// MARK: - The console, as the user sees it

/// The running machine's serial output, and the way to stop it.
///
/// A sheet rather than a permanent panel, because a machine is started and then
/// observed; and because a terminal is the whole of what this launcher can show
/// until a scanout path exists (see this file's header).
struct QEMUConsoleView: View {
    @ObservedObject private var console = LinuxMachineConsole.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(console.console.isEmpty ? "Waiting for output…" : console.console)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                        .id("console")
                }
                // Follow the tail: a boot log is read from its end.
                .onChange(of: console.console) { _, _ in
                    withAnimation(.linear(duration: 0.1)) { proxy.scrollTo("console", anchor: .bottom) }
                }
            }
            .background(Color.black)
            .foregroundStyle(Color.green)
            .navigationTitle("Console")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text(console.state.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Stop") { console.stop() }
                        .disabled(!console.state.isRunning)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#if MADEIRA_HAS_QEMU_LAUNCHER

// MARK: - The three entry points QEMU's shared library exports

/// QEMU's driver API, resolved once. QEMU built with `--enable-shared-lib`
/// exports exactly these, and the spellings are asserted rather than assumed: a
/// dylib that loads but is missing one of them is reported by name instead of
/// crashing at the first call site.
///
/// A struct, not an enum: it holds the resolved pointers. An enum cannot carry
/// stored properties, which the type-check pass reported as four lines of
/// "enums must not contain stored properties" on a type that otherwise looked
/// like the usual namespace-only enum.
struct QEMUEntryPoints {
    typealias Init = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Void
    typealias MainLoop = @convention(c) () -> Void
    typealias Cleanup = @convention(c) () -> Void

    let handle: UnsafeMutableRawPointer
    let init_: Init
    let mainLoop: MainLoop
    let cleanup: Cleanup

    static func load(at url: URL) throws -> QEMUEntryPoints {
        guard let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
            let why = dlerror().map { String(cString: $0) } ?? "no reason given"
            throw LinuxMachineConsole.LaunchError.engine("The engine at \(url.path) would not load: \(why)")
        }

        var missing: [String] = []
        func symbol(_ name: String) -> UnsafeMutableRawPointer? {
            guard let p = dlsym(handle, name) else { missing.append(name); return nil }
            return p
        }
        guard let i = symbol("qemu_init"), let m = symbol("qemu_main_loop"), let c = symbol("qemu_cleanup") else {
            dlclose(handle)
            throw LinuxMachineConsole.LaunchError.engine(
                "The engine loaded but does not export \(missing.joined(separator: ", ")). "
                    + "It was probably built without --enable-shared-lib.")
        }
        return QEMUEntryPoints(
            handle: handle,
            init_: unsafeBitCast(i, to: Init.self),
            mainLoop: unsafeBitCast(m, to: MainLoop.self),
            cleanup: unsafeBitCast(c, to: Cleanup.self))
    }
}

// MARK: - The sockets

/// A client that sends whole lines to a Unix socket, connecting lazily.
///
/// The monitor is QEMU's own, and `quit` on it is the documented way to ask a
/// machine to stop itself.
final class UnixSocketWriter {
    private let path: String
    private var fd: Int32 = -1

    init(path: String) { self.path = path }

    func send(line: String) {
        if fd < 0 { fd = UnixSocket.connect(path: path) }
        guard fd >= 0 else { return }
        let bytes = Array((line + "\n").utf8)
        _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
    }
}

/// A reader that waits for a Unix socket to appear, then streams what arrives.
///
/// QEMU creates the console socket as it starts, so the first connect attempts
/// legitimately fail; that is retried rather than reported.
final class UnixSocketReader {
    private let path: String
    private let onText: (String) -> Void
    private var thread: Thread?
    private var stopped = false

    init(path: String, onText: @escaping (String) -> Void) {
        self.path = path
        self.onText = onText
    }

    func start() {
        let t = Thread { [weak self] in self?.loop() }
        t.name = "qemu-console"
        t.qualityOfService = .utility
        thread = t
        t.start()
    }

    func stop() { stopped = true }

    private func loop() {
        var fd: Int32 = -1
        // About ten seconds of patience: a booting QEMU creates the socket well
        // before that. Giving up is not an error - the machine still runs - so it
        // is reported to the console and the thread ends.
        for _ in 0..<100 where fd < 0 {
            if stopped { return }
            fd = UnixSocket.connect(path: path)
            if fd < 0 { Thread.sleep(forTimeInterval: 0.1) }
        }
        guard fd >= 0 else {
            onText("\n(console socket never appeared; the machine is running without a console view)\n")
            return
        }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !stopped {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            if let text = String(bytes: buffer[0..<n], encoding: .utf8) { onText(text) }
        }
        close(fd)
    }
}

enum UnixSocket {
    /// Connect to a Unix-domain socket, or -1.
    static func connect(path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd); return -1
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: bytes.count) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        // Darwin.connect, qualified: this function is itself called `connect`, so
        // the unqualified name resolves to the static method being defined and
        // not to the C function - which is a type error the compiler reports as
        // "use of 'connect' refers to instance method rather than global
        // function", pointing at a line that looks obviously correct.
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        if result != 0 { close(fd); return -1 }
        return fd
    }
}

// MARK: - The engine's own output

/// QEMU's stdout and stderr, kept instead of lost.
///
/// WHY THIS EXISTS
/// QEMU answers a command line it cannot use by printing a line and calling
/// `exit(1)`. In a process that embeds it - this app - that is the app
/// terminating: the window goes, and the reason went with it. So the engine's
/// output is redirected into a pipe, streamed into the console view and
/// appended to `Documents/linux-engine.log`, which is on the device and survives
/// the exit. "The machine crashed" and "the machine said: multi-threaded TCG is
/// not supported with the TCI interpreter" are the same symptom and completely
/// different bug reports, and this is the thing that tells them apart.
///
/// The redirection is process-wide because that is what file descriptors are:
/// QEMU writes to fd 2 and cannot be asked to write anywhere else. It is
/// attached when a machine starts and handed back when the engine returns, so
/// the app's own diagnostics reappear afterwards.
final class EngineOutputCapture {
    private let onText: (String) -> Void
    private var readFD: Int32 = -1
    private var savedOut: Int32 = -1
    private var savedErr: Int32 = -1
    private var thread: Thread?
    private var stopped = false

    /// Documents/linux-engine.log: where a reason outlives the process that
    /// printed it. In the app's own Documents, so it is readable from the Files
    /// app without a debugger.
    static var logURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("linux-engine.log")
    }

    init(onText: @escaping (String) -> Void) { self.onText = onText }

    /// Record one line in the log without a running capture, for the things the
    /// app knows and the engine does not - the exit code, the header - so the
    /// file reads as one story rather than a fragment.
    static func note(_ line: String) {
        let text = line.hasSuffix("\n") ? line : line + "\n"
        guard let data = text.data(using: .utf8) else { return }
        let url = logURL
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// Take over the process's stdout and stderr, and stream what arrives.
    func attach(header: String) {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return }
        readFD = fds[0]
        let writeFD = fds[1]
        savedOut = dup(STDOUT_FILENO)
        savedErr = dup(STDERR_FILENO)
        dup2(writeFD, STDOUT_FILENO)
        dup2(writeFD, STDERR_FILENO)
        close(writeFD)
        // Line buffered: a crash must not lose the line that explains it to a
        // block buffer that never got flushed.
        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IOLBF, 0)
        Self.note("--- engine start ---")
        Self.note("$ " + header)
        let t = Thread { [weak self] in self?.loop() }
        t.name = "qemu-output"
        t.qualityOfService = .utility
        thread = t
        t.start()
    }

    /// Give stdout and stderr back to the app. The reader ends when the read end
    /// closes; leaving it open would park a thread on a pipe nothing writes to.
    func detach() {
        stopped = true
        fflush(stdout); fflush(stderr)
        if savedOut >= 0 { dup2(savedOut, STDOUT_FILENO); close(savedOut); savedOut = -1 }
        if savedErr >= 0 { dup2(savedErr, STDERR_FILENO); close(savedErr); savedErr = -1 }
        if readFD >= 0 { close(readFD); readFD = -1 }
    }

    private func loop() {
        let fd = readFD
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !stopped {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            guard let text = String(bytes: buffer[0..<n], encoding: .utf8) else { continue }
            Self.note(text)
            onText(text)
        }
    }
}

#endif
