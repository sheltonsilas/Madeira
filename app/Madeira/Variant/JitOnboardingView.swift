// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// JitOnboardingView.swift - the screen a new user sees when JIT is off.
//
// WHY THIS EXISTS
// JIT on a stock iPad is not a setting you flip. iOS only lets an app create
// executable memory while a debugger is attached, and only if the app is signed
// debuggable. That means four separate things have to be true, and a user who
// fails any one of them gets the same symptom: everything runs, slowly, because
// it is being interpreted. This screen names each step, shows whether it is
// satisfied, and gives the one action that fixes it.
//
// The actual pairing / VPN / DDI work is upstream's (JITSetup.swift,
// JITNetwork.swift, JITPairing.swift). This view is the entry point to it and
// the plain-language status around it; it does not reimplement any of it.
//
// UNTESTED: no device was available.

import SwiftUI

/// One prerequisite, and how to satisfy it.
struct JITPrerequisite: Identifiable {
    enum State {
        case ok
        case todo(String)     // what is still needed, in plain words
        case unknown
    }

    let id: String
    let title: String
    let detail: String
    let state: State
    var symbol: String {
        switch state {
        case .ok: return "checkmark.circle.fill"
        case .todo, .unknown: return "exclamationmark.circle.fill"
        }
    }
    var tint: Color {
        switch state {
        case .ok: return .green
        case .todo, .unknown: return .orange
        }
    }
}

@MainActor
struct JitOnboardingView: View {
    @StateObject private var jit = JitManager()
    @Environment(\.dismiss) private var dismiss
    /// Upstream's own wizard, shown as a sheet when the user wants the detail.
    @State private var showUpstreamSetup = false

    var body: some View {
        NavigationStack {
            List {
                statusSection
                actionsSection
                prerequisitesSection
                fallbackSection
                alternativesSection
            }
            .navigationTitle("JIT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .task { jit.refresh() }
            .sheet(isPresented: $showUpstreamSetup) { JITSetupView() }
        }
    }

    // MARK: Status

    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: jit.status.symbol)
                    .font(.title2)
                    .foregroundStyle(jit.status.isOn ? .green : .orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(jit.status.isOn ? "JIT is on" : "JIT is off")
                        .font(.headline)
                    Text(jit.status.isOn
                         ? "Code is compiled to native instructions. This is full speed."
                         : "Code is interpreted. Everything still runs, but games and video are much slower.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

            if case .off(let reason) = jit.status {
                Text(reason.explanation)
                    .font(.footnote).foregroundStyle(.secondary)
            }

            LabeledContent("Executable memory", value: formatBytes(jit.availableMemory))
        }
    }

    // MARK: Actions

    private var actionsSection: some View {
        Section {
            Button {
                jit.enableJIT()
                jit.startPolling()
            } label: {
                Label(jit.isEnabling ? "Enabling…" : "Enable JIT",
                      systemImage: "bolt.fill")
            }
            .disabled(jit.isEnabling || jit.status.isOn)

            Button {
                jit.openStikDebug()
                jit.startPolling()
            } label: {
                Label("Open StikDebug", systemImage: "safari")
            }

            Button("Setup guide") { showUpstreamSetup = true }

            if jit.isEnabling || jit.status == .transitioning {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Waiting for a debugger to attach…").font(.footnote).foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Enable JIT sends the request to Madeira's own helper first. "
                 + "If that fails it offers StikDebug instead. You must be on Wi-Fi or in "
                 + "Airplane Mode — the connection does not route over cellular data.")
        }
    }

    // MARK: Prerequisites

    private var prerequisitesSection: some View {
        Section("What has to be true") {
            ForEach(prerequisites) { item in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: item.symbol).foregroundStyle(item.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.subheadline.weight(.medium))
                        Text(item.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var prerequisites: [JITPrerequisite] {
        [
            JITPrerequisite(
                id: "debuggable",
                title: "Signed as debuggable",
                detail: jit.debuggableSignature
                    ? "OK. The app carries get-task-allow."
                    : "Missing. iOS will not allow executable memory. Re-sign with Sideloadly or SideStore.",
                state: jit.debuggableSignature ? .ok : .todo("re-sign")),
            JITPrerequisite(
                id: "helper",
                title: "JIT helper installed",
                detail: jit.helperIsInstalled
                    ? "OK. Madeira's helper extension is present."
                    : "Missing. Your sideloader dropped app extensions. Re-install and keep them.",
                state: jit.helperIsInstalled ? .ok : .todo("re-install")),
            JITPrerequisite(
                id: "pairing",
                title: "Pairing file",
                detail: JITPairingFileStore.isImported
                    ? "Stored in the Keychain for this device."
                    : "Not set up yet. Madeira can make one itself on iOS 27, or you can import one.",
                state: JITPairingFileStore.isImported ? .ok : .todo("set up")),
            JITPrerequisite(
                id: "vpn",
                title: "LocalDevVPN connected",
                detail: "Madeira talks to this device through a local tunnel. Cellular data will not carry it.",
                state: .unknown),
        ]
    }

    // MARK: Fallback

    private var fallbackSection: some View {
        Section {
            Toggle("Interpreter only", isOn: $jit.forceInterpreter)
            if jit.forceInterpreter {
                InterpreterFallbackNotice(isActive: true)
                    .padding(.horizontal, 0)
            }
        } header: {
            Text("If JIT cannot be enabled")
        } footer: {
            Text("This is the UTM SE approach: drop the JIT and interpret everything. "
                 + "It works on any device and needs no setup, but expect large slowdowns. "
                 + "Turn it off to let FEX use the JIT whenever one is available.")
        }
    }

    // MARK: Alternatives

    private var alternativesSection: some View {
        Section("Other ways to sign and enable JIT") {
            // Each of these is a real, documented route. The brief asked for
            // them to be supported and described, not to be reimplemented.
            LabeledContent("SideStore") {
                Text("Refreshes over Wi-Fi, so no weekly re-signing").foregroundStyle(.secondary)
            }
            LabeledContent("AltStore") {
                Text("Sideloader; keep app extensions when asked").foregroundStyle(.secondary)
            }
            LabeledContent("AltJIT") {
                Text("Runs the StikJIT framework itself").foregroundStyle(.secondary)
            }
            LabeledContent("StikDebug") {
                Text("Standalone; the button above opens it").foregroundStyle(.secondary)
            }
        }
    }
}

private func formatBytes(_ bytes: UInt64) -> String {
    bytes == 0 ? "none yet" : ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
}