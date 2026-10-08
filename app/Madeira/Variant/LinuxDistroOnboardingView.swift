// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// LinuxDistroOnboardingView.swift - the first screen a Linux user should see.
//
// THE FLOW, AND WHY IT IS IN THIS ORDER
// The brief is specific: a new user should choose a distribution and whether
// they want a GUI, and the app should do the rest. So the questions are asked
// in that order and nothing else is asked at all:
//
//   1. Distribution  - Ubuntu, Debian or Fedora.
//   2. Command line or desktop.
//   3. Done. The image is fetched, checked against the distribution's own
//      published hash, and recorded as an environment.
//
// The engine is shown but not asked about. It is derived: a desktop that needs
// the JIT engine gets it when a debugger is present and the interpreter when it
// is not, which is the whole point of the UTM/UTM SE split. Asking a user to
// choose a QEMU accelerator on first run would be asking them to answer a
// question about their own device that the app can answer itself.
//
// WHAT IT DOES NOT DO
// It does not launch a guest, because the QEMU core is not linked into this
// build. `LinuxEnginePlan` says so in the plan section below rather than
// letting the button look like it might work.

import SwiftUI

struct LinuxDistroOnboardingView: View {
    @ObservedObject var store: LinuxEnvironmentStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var downloader = LinuxImageDownloader()

    @State private var selectedDistroID: String = LinuxDistroCatalog.all.first?.id ?? ""
    @State private var selectedKind: LinuxDistroImage.Kind = .commandLine
    @State private var engineKind: LinuxEngineKind = .utmSE
    /// The environment this flow created, so its record can be updated with the
    /// downloaded image path when the transfer finishes.
    @State private var createdEnvironmentID: UUID?
    @State private var banner: String?

    // MARK: Derived state

    private var distro: LinuxDistro? { LinuxDistroCatalog.distro(id: selectedDistroID) }

    private var availableKinds: [LinuxDistroImage.Kind] {
        LinuxDistroImage.Kind.allCases.filter { kind in
            !(distro?.images(of: kind).isEmpty ?? true)
        }
    }

    private var image: LinuxDistroImage? { distro?.images(of: selectedKind).first }

    /// Whether a debugger is attached right now.
    ///
    /// Read from the same C probe ContentView gates launches with, so this
    /// screen and the launch path cannot disagree about the device's state.
    private var jitIsOn: Bool { jit_check_debugged() }

    private var plan: LinuxEnginePlan {
        LinuxEnginePlan.resolve(environmentRequiresJIT: engineKind == .utm, jitIsOn: jitIsOn)
    }

    var body: some View {
        NavigationStack {
            List {
                distributionSection
                sessionSection
                engineSection
                planSection
            }
            .navigationTitle("New environment")
            .navigationBarTitleDisplayMode(.inline)
            .tint(MadeiraTheme.accent)
            .font(MadeiraTheme.body())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { downloader.cancel(); dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .disabled(!canFinish)
                }
            }
            // The image path is only known once the transfer has finished, so
            // the record is completed here rather than when it was created.
            .onChange(of: downloader.state) { _, newState in
                guard case let .finished(url) = newState,
                      let id = createdEnvironmentID,
                      var environment = store.environments.first(where: { $0.id == id }) else { return }
                environment.imagePath = url.path
                store.update(environment)
            }
            .alert("New environment", isPresented: Binding(
                get: { banner != nil },
                set: { if !$0 { banner = nil } }
            )) {
                Button("OK", role: .cancel) { banner = nil }
            } message: {
                Text(banner ?? "")
            }
        }
    }

    private var canFinish: Bool { createdEnvironmentID != nil && !downloader.state.isBusy }

    // MARK: Sections

    private var distributionSection: some View {
        Section {
            ForEach(LinuxDistroCatalog.all) { candidate in
                Button {
                    selectedDistroID = candidate.id
                    // A distribution without a desktop image must not leave the
                    // kind picker sitting on a choice that has nothing behind it.
                    if candidate.images(of: selectedKind).isEmpty {
                        selectedKind = availableKinds.first ?? .commandLine
                    }
                    downloader.cancel()
                } label: {
                    HStack(alignment: .top, spacing: MadeiraTheme.gap) {
                        Image(systemName: selectedDistroID == candidate.id
                              ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selectedDistroID == candidate.id
                                             ? MadeiraTheme.accent : Color.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(candidate.name).font(MadeiraTheme.heading())
                            Text(candidate.summary)
                                .font(MadeiraTheme.caption())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Distribution")
        }
    }

    private var sessionSection: some View {
        Section {
            Picker("Session", selection: $selectedKind) {
                ForEach(availableKinds) { kind in
                    Label(kind.title, systemImage: kind.symbol).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedKind) { _, _ in downloader.cancel() }

            Text(selectedKind.summary)
                .font(MadeiraTheme.caption())
                .foregroundStyle(.secondary)

            if let image {
                LabeledContent("Download") {
                    Text(image.sizeDescription).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Session")
        } footer: {
            Text("The image is downloaded by Madeira and verified against the checksum "
                 + "the distribution publishes. Nothing is fetched from anywhere else.")
        }
    }

    private var engineSection: some View {
        Section {
            Picker("Engine", selection: $engineKind) {
                ForEach(LinuxEngineKind.allCases) { kind in
                    Text(kind.shortTitle).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            Text(engineKind.summary)
                .font(MadeiraTheme.caption())
                .foregroundStyle(.secondary)

            if plan.jitWouldHelp {
                Label("Enabling JIT would let this environment use the faster engine.",
                      systemImage: "bolt.badge.clock")
                    .font(MadeiraTheme.caption())
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Engine")
        } footer: {
            Text("QEMU runs a Linux guest. With JIT it compiles guest code; without JIT it "
                 + "interprets it. The interpreter is slower and needs no debugger, which is "
                 + "why it is the default here.")
        }
    }

    private var planSection: some View {
        Section {
            LabeledContent("Will run with") {
                Text(plan.kind.title).foregroundStyle(.secondary)
            }

            if let blocker = plan.blocker {
                Text(blocker)
                    .font(MadeiraTheme.caption())
                    .foregroundStyle(MadeiraTheme.warning)
            }

            switch downloader.state {
            case .idle:
                Button {
                    start()
                } label: {
                    Label("Download and create", systemImage: "arrow.down.circle.fill")
                }
                .disabled(!plan.canStart)

            case .downloading:
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: downloader.state.fraction ?? 0)
                    Text(downloader.state.detail ?? "")
                        .font(MadeiraTheme.mono())
                        .foregroundStyle(.secondary)
                    Button("Cancel download", role: .destructive) { downloader.cancel() }
                }

            case .verifying:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Checking the download against the published checksum…")
                        .font(MadeiraTheme.caption())
                        .foregroundStyle(.secondary)
                }

            case let .finished(url):
                Label("Downloaded and verified: \(url.lastPathComponent)", systemImage: "checkmark.seal.fill")
                    .font(MadeiraTheme.caption())
                    .foregroundStyle(.green)
                Text("Press Done. The environment is in the list.")
                    .font(MadeiraTheme.caption())
                    .foregroundStyle(.secondary)

            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(MadeiraTheme.caption())
                    .foregroundStyle(MadeiraTheme.danger)
                Button("Try again") { start() }
            }
        } header: {
            Text("Plan")
        }
    }

    // MARK: Action

    /// Create the environment record, then fetch its image into it.
    ///
    /// The record is written first and deliberately: a download that is
    /// interrupted then leaves an environment the user can retry, rather than
    /// several gigabytes of orphaned file with nothing pointing at them.
    private func start() {
        guard let distro, let image else { return }
        do {
            let environment = try store.create(named: distro.name)
            var stored = environment
            stored.distroID = distro.id
            stored.imageID = image.id
            stored.imageKind = image.kind.rawValue
            stored.requiresJIT = (engineKind == .utm)
            store.update(stored)

            createdEnvironmentID = stored.id
            let directory = LinuxEnvironmentStore.directory(for: stored)
                .appendingPathComponent("image", isDirectory: true)
            downloader.download(image, into: directory)
        } catch {
            banner = "Could not create the environment: \(error.localizedDescription)"
        }
    }
}
