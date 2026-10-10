// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// MadeiraMachinesView.swift - the two libraries and a machine's own page.
//
// THE RULE THE START BUTTON FOLLOWS
// A Start button that cannot start anything is worse than no Start button: it
// teaches the user that the app is broken rather than that a part is missing,
// and they go looking for the fault in the wrong place. So a machine's Start is
// enabled by exactly the condition that decides whether the engine can run -
// LinuxEnginePlan.canStart - and while that is false the reason sits directly
// under it in the user's words. When the QEMU core is linked in, the condition
// turns true and the button turns on with no further edit here. That is the
// difference between a placeholder and a gate.

import SwiftUI

// MARK: - Windows

/// The installed Windows programs.
struct MadeiraWindowsView: View {
    var play: (LibraryEntry) -> Void
    var goToStore: () -> Void

    @ObservedObject private var library = LibraryModel.shared
    @State private var search = ""

    var body: some View {
        List {
            if library.entries.isEmpty {
                Section {
                    MadeiraEmptyState(
                        title: "No Windows programs yet",
                        message: "A program is installed by running its installer. Open the browser in the classic screen, download an .exe or .msi, and it lands in the same Wine prefix these entries run from.",
                        symbol: "display",
                        actionTitle: "Read about installing",
                        action: goToStore
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                ForEach(filtered) { entry in
                    MadeiraProgramRow(entry: entry, play: play)
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, prompt: "Search programs")
        .navigationTitle("Windows")
    }

    private var filtered: [LibraryEntry] {
        guard !search.isEmpty else { return library.entries }
        return library.entries.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }
}

/// One program, as a row.
struct MadeiraProgramRow: View {
    let entry: LibraryEntry
    var play: (LibraryEntry) -> Void

    var body: some View {
        HStack(spacing: 12) {
            MadeiraIconTile(name: entry.title)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(MadeiraTheme.heading())
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if entry.bits == 32 || entry.bits == 64 {
                        Text("\(entry.bits)-bit")
                            .font(MadeiraTheme.mono())
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.relativePath)
                        .font(MadeiraTheme.mono())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            Button {
                play(entry)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(MadeiraTheme.brandGradient, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Run \(entry.title)")
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Linux

/// The machine list.
struct MadeiraLinuxView: View {
    @ObservedObject var store: LinuxEnvironmentStore
    var newMachine: () -> Void
    var manage: () -> Void

    var body: some View {
        List {
            if store.environments.isEmpty {
                Section {
                    MadeiraEmptyState(
                        title: "No machine yet",
                        message: "A machine is a distribution image, its own disk, and the settings it runs with. Madeira picks the image, downloads it and checks it against the checksum its publisher publishes.",
                        symbol: "shippingbox",
                        actionTitle: "Choose a distribution",
                        action: newMachine
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(store.environments) { environment in
                        NavigationLink {
                            MadeiraMachineView(environment: environment, store: store)
                        } label: {
                            MadeiraMachineRow(environment: environment)
                        }
                    }
                } footer: {
                    Text("Machines are folders under Documents/environments, so the Files app can see them and a backup is a copy.")
                        .font(MadeiraTheme.caption())
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Linux")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: manage) {
                    Label("Manage", systemImage: "slider.horizontal.3")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: newMachine) {
                    Label("New machine", systemImage: "plus")
                }
            }
        }
    }
}

/// One machine, as a row: its canvas, its name and what it is.
struct MadeiraMachineRow: View {
    let environment: LinuxEnvironment

    var body: some View {
        HStack(spacing: 12) {
            MadeiraMachineCanvas(symbol: "terminal", running: false, height: 62)
                .frame(width: 104)

            VStack(alignment: .leading, spacing: 4) {
                Text(environment.name)
                    .font(MadeiraTheme.heading())
                    .lineLimit(1)
                Text(distribution)
                    .font(MadeiraTheme.caption())
                    .foregroundStyle(.secondary)
                Text("\(environment.vcpus) vCPU · \(environment.ramDescription) · \(environment.diskMiB / 1024) GB")
                    .font(MadeiraTheme.mono())
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 6)

            MadeiraStatusChip(
                level: environment.imagePath == nil ? .attention : .ready,
                text: environment.imagePath == nil ? "No image" : "Ready",
                compact: true
            )
        }
        .padding(.vertical, 2)
    }

    private var distribution: String {
        guard let distroID = environment.distroID, let distro = LinuxDistroCatalog.distro(id: distroID) else {
            return "Distribution not recorded"
        }
        guard let imageID = environment.imageID, let image = LinuxDistroCatalog.image(id: imageID) else {
            return distro.name
        }
        return "\(distro.name) · \(image.kind.title)"
    }
}

// MARK: - One machine

/// A machine's page.
struct MadeiraMachineView: View {
    let environment: LinuxEnvironment
    @ObservedObject var store: LinuxEnvironmentStore
    @ObservedObject private var library = LibraryModel.shared
    @State private var debuggerAttached = isDebuggerAttached()
    @State private var confirmDelete = false
    @State private var notice: String?
    @State private var showConsole = false

    /// The engine this machine will actually start under, and what stops it.
    ///
    /// The boot check is asked here and not inside LinuxEnginePlan, because only
    /// this screen has the environment. It is the last question the plan asks, so
    /// a machine with no engine still hears about the engine.
    private var plan: LinuxEnginePlan {
        LinuxEnginePlan.resolve(
            environmentRequiresJIT: environment.requiresJIT,
            jitIsOn: debuggerAttached,
            bootBlocker: LinuxBootCheck.blocker(for: environment)
        )
    }

    var body: some View {
        List {
            Section {
                MadeiraMachineCanvas(symbol: "terminal", running: false, height: 160)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                startPanel
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }

            Section("This machine") {
                MadeiraStatRow(label: "Distribution", value: distributionName, symbol: "shippingbox")
                MadeiraStatRow(label: "Engine", value: plan.kind.title, symbol: plan.kind.symbol)
                MadeiraStatRow(label: "Processor", value: "\(environment.vcpus) vCPU", symbol: "cpu")
                MadeiraStatRow(label: "Memory", value: environment.ramDescription, symbol: "memorychip")
                MadeiraStatRow(label: "Disk", value: "\(environment.diskMiB / 1024) GB", symbol: "internaldrive")
                MadeiraStatRow(label: "Display", value: environment.display.title, symbol: "rectangle.on.rectangle")
                MadeiraStatRow(
                    label: "Image",
                    value: environment.imagePath == nil ? "Not downloaded" : "Downloaded",
                    symbol: environment.imagePath == nil ? "arrow.down.circle" : "checkmark.circle",
                    tint: environment.imagePath == nil ? MadeiraTheme.warning : MadeiraTheme.running
                )
            }

            Section {
                NavigationLink {
                    LinuxEnvironmentDetailView(environment: environment, store: store)
                } label: {
                    Label("Machine settings and snapshots", systemImage: "slider.horizontal.3")
                }
            } footer: {
                Text("Snapshots copy the machine's folder, so they cost what the machine costs.")
                    .font(MadeiraTheme.caption())
            }

            Section {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete this machine", systemImage: "trash")
                }
            } footer: {
                Text("Deleting removes the machine's folder from this device. There is no copy anywhere else unless you exported one.")
                    .font(MadeiraTheme.caption())
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(environment.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { debuggerAttached = isDebuggerAttached() }
        .sheet(isPresented: $showConsole) { QEMUConsoleView() }
        .confirmationDialog(
            "Delete \(environment.name)?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { delete() }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("Its disk image and any snapshots in its folder go with it.")
        }
        .alert("Could not delete", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) { notice = nil }
        } message: {
            Text(notice ?? "")
        }
    }

    // MARK: Start

    /// Start the machine, or put the real reason it could not start in front of
    /// the user.
    ///
    /// The pre-flight has already run in `plan`, so reaching the launcher means
    /// every precondition was met. A failure here is therefore not a missing
    /// piece - it is the engine refusing to load or refusing its arguments, and
    /// it is reported verbatim because that is the only thing that will help.
    private func startMachine() {
        // LinuxMachineConsole exists in every build, so this call site carries no
        // conditional: a build without the engine gets the same call and the
        // error that says so, rather than a different screen.
        do {
            try LinuxMachineConsole.shared.start(environment: environment, engine: plan.kind)
            showConsole = true
        } catch {
            notice = error.localizedDescription
        }
    }

    /// The Start button, and the truth about it.
    ///
    /// Enabled by `plan.canStart` and nothing else. `plan.blocker` is written by
    /// LinuxEnginePlan in the user's words, so it is shown as-is rather than
    /// paraphrased here: one place decides why a machine cannot run.
    private var startPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    startMachine()
                } label: {
                    Label("Start", systemImage: "play.fill")
                        .font(MadeiraTheme.heading())
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .background(
                            plan.canStart ? AnyShapeStyle(MadeiraTheme.brandGradient) : AnyShapeStyle(MadeiraTheme.surface),
                            in: Capsule()
                        )
                        .foregroundStyle(plan.canStart ? Color.white : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!plan.canStart)

                if plan.jitWouldHelp && plan.canStart {
                    MadeiraStatusChip(level: .ready, text: "Faster with JIT")
                }
                Spacer(minLength: 0)
            }

            if let blocker = plan.blocker {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MadeiraTheme.warning)
                        .padding(.top, 1)
                    Text(blocker)
                        .font(MadeiraTheme.caption())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if !debuggerAttached {
                Text("This machine will start on \(plan.kind.title). Enable JIT to use the faster configuration instead.")
                    .font(MadeiraTheme.caption())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MadeiraTheme.surface, in: RoundedRectangle(cornerRadius: MadeiraTheme.corner, style: .continuous))
    }

    // MARK: Helpers

    private var distributionName: String {
        guard let distroID = environment.distroID, let distro = LinuxDistroCatalog.distro(id: distroID) else {
            return "Not recorded"
        }
        guard let imageID = environment.imageID, let image = LinuxDistroCatalog.image(id: imageID) else {
            return distro.name
        }
        return "\(distro.name) · \(image.kind.title)"
    }

    private func delete() {
        do {
            try store.delete(environment)
        } catch {
            notice = error.localizedDescription
        }
    }
}
