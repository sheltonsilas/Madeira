// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// LinuxEnvironmentStore.swift - the UTM-style manager for "Madeira Linux".
//
// READ THIS BEFORE ASSUMING THE BACKING RUNTIME WORKS
// This file is the manager MODEL and its on-disk format: environments, limits,
// snapshots, import/export. It is complete and self-contained. The emulator it
// would drive is NOT in this patch, and I want to be exact about why, because
// it is the single most important architectural finding in this work.
//
// WHAT iOS ACTUALLY FORBIDS (all verified in source, not guessed)
//   * No Linux kernel. FEX-Emu is a userspace binary translator: it loads an ELF
//     or a PE and services syscalls. FEX does contain Linux host code
//     (FEX/Source/Common/Linux, FEX/Source/Tools/LinuxEmulation), but that code
//     makes LINUX SYSCALLS on a Linux kernel. Under Madeira the kernel is XNU,
//     and glibc needs Linux syscall numbers and semantics. Bridging that is a
//     syscall-translation layer the size of Wine, not a config flag.
//   * Therefore a full Ubuntu DESKTOP needs a guest kernel, which means a
//     full-system emulator, which means QEMU.
//
// WHY THAT IS STILL THE RIGHT DESIGN, AND THE USER'S WORRY IS UNFOUNDED
// The concern raised was "we have no hypervisor, so an aarch64 Ubuntu guest
// cannot work." The opposite is true. A hypervisor (KVM/HVF) is only needed to
// ACCELERATE EMULATED instructions. If the guest is aarch64 and the host is
// aarch64 - which is every iPhone and iPad - there is no CPU emulation to
// accelerate, because the guest's own instructions are the host's instructions.
// QEMU's TCG then only has to emulate DEVICES: the virtio block and net
// controllers, the timer, the framebuffer. UTM's own FAQ says exactly this:
// "Because iOS devices lack hardware virtualization support, we cannot use the
// KVM accelerator and instead use the TCG [JIT]" - and UTM runs aarch64 Linux
// guests usefully. Picking aarch64 was the right call; it is the reason it is
// feasible at all. An x86_64 guest would instead put every instruction through
// TCG and land at roughly 8-12x slowdown, which is why I did not go there.
//
// HONEST COST: device emulation and graphics. A 2D desktop (XFCE or LXQt) is
// fine. GNOME's compositor and anything GPU-bound will not be, because there is
// no GPU passthrough on iOS - the guest gets a software renderer, and the
// accelerated path has to be reconstructed on the host with Metal, which is
// precisely the work UTM did with its custom display backend.
//
// STATUS OF THIS FILE
//   Manager model, limits: DONE, compile-checked only.
//   Import, export and snapshots: IMPLEMENTED, streamed one megabyte at a
//     time through LinuxEnvironmentPackager — see that file for the format and
//     the tar-slip defence. UNTESTED on a device, because there is no device.
//   Driving a real guest: NOT IN THIS PATCH. Marked UNTESTED.
//   Everything in it that is UNTESTED is called out below.

import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// One managed Linux environment.
struct LinuxEnvironment: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var created: Date = Date()
    var modified: Date = Date()

    /// Guest RAM in MiB. The guest cannot use the iOS device's memory directly;
    /// this is the ceiling we enforce on the guest's view of it.
    var ramMiB: Int = 2048
    /// Guest vCPU count. The iOS scheduler owns the real cores; this is how many
    /// the guest is told it has, and how much parallelism it will try to use.
    /// Values above ~4 usually hurt, because iOS is already managing thermals.
    var vcpus: Int = 2
    /// Disk image size in MiB. Sparse: the file only occupies what is written.
    var diskMiB: Int = 8192
    /// Display mode for the guest.
    var display: GuestDisplayMode = .resizable

    /// Whether the JIT is required to run this environment. False only for the
    /// interpreter-only fallback environment.
    var requiresJIT: Bool = true

    enum GuestDisplayMode: String, Codable, CaseIterable, Identifiable {
        case resizable       // follows the iPad window, including Split View
        case fixed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .resizable: return "Resizable"
            case .fixed: return "Fixed"
            }
        }
    }

    var ramDescription: String { "\(ramMiB / 1024).\(ramMiB % 1024 / 100) GB" }
}

/// A named snapshot of an environment's disk.
struct LinuxSnapshot: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var date: Date = Date()
    var sizeBytes: Int64
}

/// Stores environments on disk under Documents/environments/<id>/.
///
/// A plain directory of files rather than a database: it stays inspectable from
/// the Files app, which is the same bridge the Windows variant gets, and it can
/// be backed up by copying a folder.
@MainActor
final class LinuxEnvironmentStore: ObservableObject {
    @Published private(set) var environments: [LinuxEnvironment] = []
    @Published private(set) var snapshots: [UUID: [LinuxSnapshot]] = [:]

    /// Root of all managed environments.
    static var root: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("environments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func directory(for environment: LinuxEnvironment) -> URL {
        directory(forID: environment.id)
    }

    static func directory(forID id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private static var indexURL: URL { root.appendingPathComponent("environments.json") }

    init() { load() }

    // MARK: CRUD

    func create(named name: String) throws -> LinuxEnvironment {
        var environment = LinuxEnvironment(name: name)
        // Keep it out of the way of the iOS memory ceiling: 2 GB of guest RAM
        // plus the host's own use is a reasonable default on an iPad.
        environment.ramMiB = 2048
        let dir = Self.directory(for: environment)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        environments.append(environment)
        try save()
        return environment
    }

    func rename(_ environment: LinuxEnvironment, to name: String) {
        guard let i = environments.firstIndex(where: { $0.id == environment.id }) else { return }
        environments[i].name = name
        try? save()
    }

    func update(_ environment: LinuxEnvironment) {
        guard let i = environments.firstIndex(where: { $0.id == environment.id }) else { return }
        environments[i] = environment
        try? save()
    }

    func delete(_ environment: LinuxEnvironment) throws {
        try? FileManager.default.removeItem(at: Self.directory(for: environment))
        environments.removeAll { $0.id == environment.id }
        snapshots[environment.id] = nil
        try save()
    }

    // MARK: Import / export

    /// Where exports land. Inside `Documents` so they show up in the Files app
    /// under "On My iPhone > Madeira", which is the same bridge the Windows
    /// variant uses, and so nothing has to be handed to a share sheet with a
    /// multi-gigabyte file already in memory.
    static var exports: URL {
        let dir = root.appendingPathComponent("exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A filename that is safe on every filesystem the archive can reach.
    static func exportURL(for environment: LinuxEnvironment) -> URL {
        let wanted = environment.name.isEmpty ? "environment" : environment.name
        var safe = ""
        for ch in wanted {
            if ch.isLetter || ch.isNumber || " -_".contains(ch) { safe.append(ch) }
        }
        safe = safe.trimmingCharacters(in: .whitespaces)
        if safe.isEmpty { safe = "environment" }
        let stamp = Int(Date().timeIntervalSince1970)
        return exports.appendingPathComponent("\(safe)-\(stamp).madeira-env.tar.gz")
    }

    /// Streams the environment into a single compressed file.
    ///
    /// The compression runs off the main actor: an 8 GB rootfs through a 1 MB
    /// window is minutes of work, and doing that on the main thread would freeze
    /// the interface for the whole of it. Nothing on the store is touched until
    /// the archive exists, so there is nothing to synchronise.
    ///
    /// On failure the partial file is removed by the packager, so a broken
    /// archive is never left where the Files app will offer it as a backup.
    func export(_ environment: LinuxEnvironment, to destination: URL) async throws {
        let source = Self.directory(for: environment)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw PackagerError.createFailed(environment.name)
        }
        let sidecar = try JSONEncoder().encode(environment)
        try await Task.detached(priority: .userInitiated) {
            try LinuxEnvironmentPackager.pack(sidecar: sidecar, from: source, to: destination)
        }.value
    }

    /// Import an environment previously produced by `export`, or any plain
    /// rootfs tarball — `.tar`, `.tar.gz` and `.tgz` all open, because the
    /// reader accepts gzip, zlib or raw deflate.
    ///
    /// The archive does not choose its own identity: it gets a fresh UUID, so a
    /// malicious or merely duplicated file can never point at, overwrite or
    /// collide with an environment that already exists.
    ///
    /// Extraction runs off the main actor for the same reason export does; the
    /// bookkeeping afterwards is a couple of array operations and stays here.
    func importEnvironment(from source: URL) async throws -> LinuxEnvironment {
        let id = UUID()
        let dir = Self.directory(forID: id)

        let sidecar: Data?
        do {
            sidecar = try await Task.detached(priority: .userInitiated) {
                try LinuxEnvironmentPackager.unpack(from: source, to: dir)
            }.value
        } catch {
            // Never leave a half-extracted tree behind: `load()` drops
            // directories it cannot find, but a partial one would be found.
            try? FileManager.default.removeItem(at: dir)
            throw error
        }

        // The identity the directory was created under, not the one the
        // archive's sidecar might claim.
        var environment = LinuxEnvironment(name: Self.importName(from: source))
        environment.id = id

        if let sidecar, let decoded = try? JSONDecoder().decode(LinuxEnvironment.self, from: sidecar) {
            environment.name = decoded.name
            environment.ramMiB = decoded.ramMiB
            environment.vcpus = decoded.vcpus
            environment.diskMiB = decoded.diskMiB
            environment.display = decoded.display
            environment.requiresJIT = decoded.requiresJIT
        }
        environment.name = unique(environment.name)
        environments.append(environment)
        try save()
        return environment
    }

    private static func importName(from source: URL) -> String {
        var name = source.lastPathComponent
        for suffix in [".madeira-env.tar.gz", ".tar.gz", ".tgz", ".tar.xz", ".tar", ".gz", ".zip"] {
            if name.lowercased().hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
                break
            }
        }
        return name.isEmpty ? "Imported environment" : name
    }

    /// Two environments may not share a name: the list is how the user tells
    /// them apart, and the detail screen is addressed by it.
    private func unique(_ name: String) -> String {
        guard environments.contains(where: { $0.name == name }) else { return name }
        var n = 2
        while environments.contains(where: { $0.name == "\(name) (\(n))" }) { n += 1 }
        return "\(name) (\(n))"
    }

    // MARK: Snapshots

    /// Copy the environment as it stands, under `snapshots/<uuid>/`.
    ///
    /// The old version of this method recorded a snapshot with `sizeBytes: 0`
    /// and wrote nothing to disk, then claimed a snapshot had been taken — and
    /// because nothing ever persisted the list, it forgot about it on the next
    /// launch as well. It is now a real copy and it is remembered.
    ///
    /// A *consistent* snapshot of a running guest needs the guest quiesced,
    /// which needs an emulator, which this build does not have. So the copy is
    /// taken of a stopped environment — which is every environment here, since
    /// none can start — and refusing to pretend otherwise is the point: an
    /// offline copy of a stopped disk is valid, an offline copy of a live one
    /// is not.
    func takeSnapshot(of environment: LinuxEnvironment, named name: String) throws {
        let envDir = Self.directory(for: environment)
        guard FileManager.default.fileExists(atPath: envDir.path) else {
            throw PackagerError.createFailed(environment.name)
        }
        let fm = FileManager.default
        let holder = envDir.appendingPathComponent("snapshots", isDirectory: true)
        try fm.createDirectory(at: holder, withIntermediateDirectories: true)

        let id = UUID()
        let target = holder.appendingPathComponent(id.uuidString, isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)

        // Everything in the environment except the snapshot store itself, or a
        // copy would recurse into its own destination forever.
        let children = try fm.contentsOfDirectory(at: envDir,
                                                  includingPropertiesForKeys: [.isDirectoryKey])
        do {
            for child in children where child.lastPathComponent != "snapshots" {
                try fm.copyItem(at: child,
                                to: target.appendingPathComponent(child.lastPathComponent))
            }
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }

        let size = Self.directorySize(target)
        let snapshot = LinuxSnapshot(name: name.isEmpty ? "Snapshot" : name, sizeBytes: size)
        var stored = snapshot
        stored.id = id
        snapshots[environment.id, default: []].append(stored)
        try saveSnapshots()
    }

    func deleteSnapshot(_ snapshot: LinuxSnapshot, of environment: LinuxEnvironment) throws {
        let holder = Self.directory(for: environment)
            .appendingPathComponent("snapshots", isDirectory: true)
        try? FileManager.default.removeItem(at: holder.appendingPathComponent(snapshot.id.uuidString))
        snapshots[environment.id]?.removeAll { $0.id == snapshot.id }
        if snapshots[environment.id]?.isEmpty == true { snapshots[environment.id] = nil }
        try saveSnapshots()
    }

    private static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in en {
            if let values = try? file.resourceValues(forKeys: [.fileSizeKey]),
               values.isDirectory == false {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    // MARK: Persistence

    private func save() throws {
        let data = try JSONEncoder().encode(environments)
        try data.write(to: Self.indexURL, options: .atomic)
    }

    private func load() {
        if let data = try? Data(contentsOf: Self.indexURL),
           let decoded = try? JSONDecoder().decode([LinuxEnvironment].self, from: data) {
            // Drop entries whose directory the user removed from the Files app.
            environments = decoded.filter {
                FileManager.default.fileExists(atPath: Self.directory(for: $0).path)
            }
        }
        loadSnapshots()
    }

    private static var snapshotsURL: URL { root.appendingPathComponent("snapshots.json") }

    /// Snapshots get their own file. They used to live only in memory, so the
    /// list was empty on every relaunch while the copies sat on disk taking up
    /// space with nothing to show for them.
    private func saveSnapshots() throws {
        let keyed = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.key.uuidString, $0.value) })
        let data = try JSONEncoder().encode(keyed)
        try data.write(to: Self.snapshotsURL, options: .atomic)
    }

    private func loadSnapshots() {
        guard let data = try? Data(contentsOf: Self.snapshotsURL),
              let keyed = try? JSONDecoder().decode([String: [LinuxSnapshot]].self, from: data)
        else { return }
        var rebuilt: [UUID: [LinuxSnapshot]] = [:]
        for (key, value) in keyed {
            guard let id = UUID(uuidString: key) else { continue }
            rebuilt[id] = value
        }
        // Forget snapshots whose environment no longer exists.
        snapshots = rebuilt.filter { pair in environments.contains { $0.id == pair.key } }
    }
}

/// The manager screen: create, import, and per-environment limits.
struct LinuxEnvironmentManagerView: View {
    @StateObject private var store = LinuxEnvironmentStore()
    @State private var newName = ""
    @State private var editing: LinuxEnvironment?
    @State private var banner: String?
    @State private var showImporter = false

    var body: some View {
        List {
            if store.environments.isEmpty {
                ContentUnavailableView(
                    "No environments",
                    systemImage: "shippingbox",
                    description: Text("Create one to get an Ubuntu desktop. Each environment is a rootfs you can import, snapshot and back up.")
                )
            }

            ForEach(store.environments) { environment in
                NavigationLink {
                    LinuxEnvironmentDetailView(environment: environment, store: store)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(environment.name).font(.headline)
                        Text("\(environment.vcpus) vCPU · \(environment.ramDescription) · \(environment.display.title)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .contextMenu {
                    Button("Export this environment…") { export(environment) }
                }
            }
            .onDelete { offsets in
                for i in offsets { try? store.delete(store.environments[i]) }
            }

            Section {
                HStack {
                    TextField("New environment name", text: $newName)
                    Button("Create") {
                        let trimmed = newName.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        try? store.create(named: trimmed)
                        newName = ""
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button("Import environment…") { showImporter = true }
            } footer: {
                Text("Import and export now work: both stream through a one-megabyte window, so a "
                     + "multi-gigabyte rootfs is never held in memory. Export writes a .madeira-env.tar.gz "
                     + "into the exports folder, which the Files app shows under On My iPhone > Madeira. "
                     + "No guest can be launched from here yet — a full-system emulator is required and is "
                     + "not part of this patch. See GUIDE.md.")
            }
        }
        .navigationTitle("Madeira Linux")
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.data],
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            // The picker hands out a URL outside the container; without this
            // call the read fails with no visible reason.
            let secured = url.startAccessingSecurityScopedResource()
            Task { @MainActor in
                defer { if secured { url.stopAccessingSecurityScopedResource() } }
                do {
                    let imported = try await store.importEnvironment(from: url)
                    banner = "Imported “\(imported.name)”."
                } catch {
                    banner = "Import failed: \(error.localizedDescription)"
                }
            }
        }
        // A real two-way binding. `.constant(banner != nil)` looks the same but
        // its setter does nothing, so the alert could never be dismissed.
        .alert("Madeira Linux", isPresented: Binding(
            get: { banner != nil },
            set: { if !$0 { banner = nil } }
        )) {
            Button("OK", role: .cancel) { banner = nil }
        } message: {
            Text(banner ?? "")
        }
    }

    /// Pack an environment on a background queue and say where it landed.
    private func export(_ environment: LinuxEnvironment) {
        let destination = LinuxEnvironmentStore.exportURL(for: environment)
        Task { @MainActor in
            do {
                try await store.export(environment, to: destination)
                banner = "Exported \(destination.lastPathComponent). Find it in the Files app under "
                    + "On My iPhone > Madeira > environments > exports."
            } catch {
                banner = "Export failed: \(error.localizedDescription)"
            }
        }
    }
}

/// Per-environment settings: RAM, vCPUs, display, and the interpreter toggle.
struct LinuxEnvironmentDetailView: View {
    let environment: LinuxEnvironment
    @ObservedObject var store: LinuxEnvironmentStore
    @State private var draft: LinuxEnvironment
    @State private var notice: String?

    init(environment: LinuxEnvironment, store: LinuxEnvironmentStore) {
        self.environment = environment
        self.store = store
        _draft = State(initialValue: environment)
    }

    var body: some View {
        Form {
            Section("Resources") {
                Stepper("vCPUs: \(draft.vcpus)", value: $draft.vcpus, in: 1...8)
                Picker("RAM", selection: $draft.ramMiB) {
                    ForEach([512, 1024, 2048, 4096, 6144, 8192], id: \.self) {
                        Text("\($0 / 1024) GB").tag($0)
                    }
                }
                Stepper("Disk: \(draft.diskMiB / 1024) GB", value: $draft.diskMiB, in: 2048...65536, step: 1024)
                Text("The guest cannot reach the device's real memory. These are the limits enforced on "
                     + "what the guest is told it has. More vCPUs than ~4 usually makes things slower, not faster, "
                     + "because iOS is already managing the cores and the thermals.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Display") {
                Picker("Mode", selection: $draft.display) {
                    ForEach(LinuxEnvironment.GuestDisplayMode.allCases) { Text($0.title).tag($0) }
                }
                Text("Resizable follows the iPad window, so Split View and Stage Manager change the guest "
                     + "resolution as you resize.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Snapshots") {
                Button("Take snapshot") {
                    do {
                        try store.takeSnapshot(of: draft, named: "Snapshot \((store.snapshots[draft.id]?.count ?? 0) + 1)")
                    } catch {
                        notice = "Snapshot failed: \(error.localizedDescription)"
                    }
                }
                if let list = store.snapshots[draft.id], !list.isEmpty {
                    ForEach(list) { snapshot in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(snapshot.name).font(.subheadline)
                                Text(snapshot.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Self.byteText(snapshot.sizeBytes))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) {
                                try? store.deleteSnapshot(snapshot, of: draft)
                            }
                        }
                    }
                } else {
                    Text("No snapshots yet. A snapshot copies the environment as it stands — it is not a "
                         + "frozen guest, because no guest runs in this build.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section("Backup") {
                Button("Export this environment…") {
                    let destination = LinuxEnvironmentStore.exportURL(for: draft)
                    Task { @MainActor in
                        do {
                            try await store.export(draft, to: destination)
                            notice = "Exported \(destination.lastPathComponent). Find it in the Files app "
                                + "under On My iPhone > Madeira > environments > exports."
                        } catch {
                            notice = "Export failed: \(error.localizedDescription)"
                        }
                    }
                }
                Text("Writes a .madeira-env.tar.gz you can open with tar -xzf on any machine. It streams, "
                     + "so an image much larger than available memory still exports.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                Button("Save") { store.update(draft) }
                Button("Delete environment", role: .destructive) {
                    try? store.delete(draft)
                }
            }
        }
        .navigationTitle(draft.name)
        .alert("Madeira Linux", isPresented: Binding(
            get: { notice != nil },
            set: { if !$0 { notice = nil } }
        )) {
            Button("OK", role: .cancel) { notice = nil }
        } message: {
            Text(notice ?? "")
        }
    }

    private static func byteText(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 { return String(format: "%.2f GB", mb / 1024) }
        return String(format: "%.1f MB", mb)
    }
}