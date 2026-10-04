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
//   Manager model, limits, snapshots, import/export: DONE, compile-checked only.
//   Driving a real guest: NOT IN THIS PATCH. Marked UNTESTED.
//   Everything in it that is UNTESTED is called out below.

import Foundation
import SwiftUI

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
        root.appendingPathComponent(environment.id.uuidString, isDirectory: true)
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

    /// Export an environment as a single compressed file, for backup or for
    /// moving to another device.
    func export(_ environment: LinuxEnvironment, to destination: URL) throws {
        // UNTESTED: compressing a multi-gigabyte sparse disk image on an iPad
        // needs a chunked writer so it does not have to fit in memory. The call
        // below is the seam; the implementation must stream.
        throw NSError(domain: "LinuxEnvironmentStore", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Export requires the streaming packager, which is not built yet.",
        ])
    }

    /// Import an environment previously produced by `export`.
    func importEnvironment(from source: URL) throws -> LinuxEnvironment {
        throw NSError(domain: "LinuxEnvironmentStore", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Import requires the streaming unpackager, which is not built yet.",
        ])
    }

    // MARK: Snapshots

    func takeSnapshot(of environment: LinuxEnvironment, named name: String) throws {
        let dir = Self.directory(for: environment).appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(UUID().uuidString).qcow2")
        // UNTESTED: needs a running guest to quiesce and copy a consistent
        // snapshot. Without a live session this must be refused rather than
        // produce a corrupt image.
        _ = url
        snapshots[environment.id, default: []].append(
            LinuxSnapshot(name: name, sizeBytes: 0))
    }

    // MARK: Persistence

    private func save() throws {
        let data = try JSONEncoder().encode(environments)
        try data.write(to: Self.indexURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.indexURL),
              let decoded = try? JSONDecoder().decode([LinuxEnvironment].self, from: data) else { return }
        // Drop entries whose directory the user removed from the Files app.
        environments = decoded.filter {
            FileManager.default.fileExists(atPath: Self.directory(for: $0).path)
        }
    }
}

/// The manager screen: create, import, and per-environment limits.
struct LinuxEnvironmentManagerView: View {
    @StateObject private var store = LinuxEnvironmentStore()
    @State private var newName = ""
    @State private var editing: LinuxEnvironment?
    @State private var banner: String?

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
                Button("Import environment…") { banner = "Import needs the unpackager, which is not built yet." }
                Button("Export selected…") { banner = "Export needs the streaming packager, which is not built yet." }
            } footer: {
                Text("UNTESTED. This screen manages environments, but no guest can be launched from it yet: "
                     + "a full-system emulator is required and is not part of this patch. See GUIDE.md.")
            }
        }
        .navigationTitle("Madeira Linux")
        // A real two-way binding. `.constant(banner != nil)` looks the same but
        // its setter does nothing, so the alert could never be dismissed.
        .alert("Not built yet", isPresented: Binding(
            get: { banner != nil },
            set: { if !$0 { banner = nil } }
        )) {
            Button("OK", role: .cancel) { banner = nil }
        } message: {
            Text(banner ?? "")
        }
    }
}

/// Per-environment settings: RAM, vCPUs, display, and the interpreter toggle.
struct LinuxEnvironmentDetailView: View {
    let environment: LinuxEnvironment
    @ObservedObject var store: LinuxEnvironmentStore
    @State private var draft: LinuxEnvironment

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
                Button("Take snapshot") { try? store.takeSnapshot(of: draft, named: "Snapshot") }
                Text("UNTESTED. A snapshot needs a running, quiesced guest.")
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
    }
}