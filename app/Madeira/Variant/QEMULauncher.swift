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
// libqemu-aarch64-softmmu.dylib out of it. Not a link:
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

/// The files a QEMU machine needs, checked before QEMU is called rather than
/// after it fails. Defined unconditionally so LinuxEnginePlan and the machine
/// screen can ask it a question without knowing whether a launcher was compiled
/// in.
enum LinuxBootCheck {

    /// The embedded sysroot, as it is laid out in the app bundle.
    static var sysroot: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("qemu-ios", isDirectory: true)
    }

    /// The softmmu dylib the launcher dlopens.
    static var engineURL: URL? {
        sysroot?.appendingPathComponent("lib/libqemu-aarch64-softmmu.dylib")
    }

    /// Where an aarch64 UEFI firmware might be. UTM's own sysroot keeps QEMU's
    /// `share/qemu` tree, so the first candidate is the upstream name; the others
    /// are the plain names it has been shipped under. A cloud image - which is
    /// what every image in LinuxDistroCatalog is, except the desktop ISO - has no
    /// separable kernel to boot with `-kernel`, so a firmware is not optional
    /// for those.
    static let firmwareCandidates = [
        "share/qemu/edk2-aarch64-code.fd",
        "share/qemu/QEMU_EFI.fd",
        "edk2-aarch64-code.fd",
        "QEMU_EFI.fd",
    ]

    static var firmwareURL: URL? {
        guard let sysroot else { return nil }
        for name in firmwareCandidates {
            let url = sysroot.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Why this environment cannot boot yet, or nil when it can.
    ///
    /// Ordered from the outermost thing to the innermost. Each message names the
    /// file it looked for and where it looked, because "the emulator is missing"
    /// and "the firmware is missing" send the reader to completely different
    /// places.
    static func blocker(for environment: LinuxEnvironment) -> String? {
        guard let sysroot else { return nil }
        guard FileManager.default.fileExists(atPath: engineURL?.path ?? "") else {
            return "The engine folder is here, but \(sysroot.lastPathComponent)/lib/"
                + "libqemu-aarch64-softmmu.dylib is not in it. The QEMU payload is incomplete."
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

        guard firmwareURL != nil else {
            return "This machine's image needs a UEFI firmware to boot, and the app bundle has none. "
                + "Looked for: " + firmwareCandidates.joined(separator: ", ")
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

        let argv = LinuxMachineConsole.arguments(
            environment: environment, engine: engine, sysroot: sysroot,
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

        append("starting \(engine.title.lowercased()) engine\n")
        append("$ " + argv.joined(separator: " ") + "\n\n")

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
        consoleReader?.stop(); consoleReader = nil
        monitor = nil
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
                                      sysroot: URL, monitorPath: String, consolePath: String) -> [String] {
        var a = ["qemu-system-aarch64"]
        a += ["-M", "virt"]
        a += engine == .utm ? ["-accel", "tcg,thread=multi"] : ["-accel", "tcg,thread=single"]
        a += ["-cpu", "max"]
        a += ["-smp", String(max(1, environment.vcpus))]
        a += ["-m", String(max(512, environment.ramMiB))]

        let image = environment.imagePath ?? ""
        let format = image.lowercased().hasSuffix(".qcow2") ? "qcow2" : "raw"
        a += ["-drive", "file=\(image),if=virtio,format=\(format),cache=writeback"]

        // A cloud image (every catalogue entry but the desktop ISO) boots its own
        // kernel from the ESP, which is what the firmware provides.
        if let firmware = LinuxBootCheck.firmwareURL {
            a += ["-bios", firmware.path]
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

#endif
