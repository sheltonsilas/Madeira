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
            // Same accent and type as the two variant screens, so the wizard
            // that stands between a user and their first session looks like it
            // belongs to the app it is setting up.
            .tint(MadeiraTheme.accent)
            .font(MadeiraTheme.body())
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
                    .foregroundStyle(jit.status.isOn ? Color.green : MadeiraTheme.danger)
                VStack(alignment: .leading, spacing: 3) {
                    Text(jit.status.isOn ? "JIT is on" : "JIT is off")
                        .font(MadeiraTheme.heading())
                    // This used to read "Code is interpreted. Everything still
                    // runs", which is the same false promise the fallback
                    // notice made. There is no interpreter in this build, so
                    // off means nothing will run, and saying otherwise sends
                    // the user off to debug a game that was never started.
                    Text(jit.status.isOn
                         ? ("Code is compiled to native instructions. This is full speed.")
                         : ("No guest will run in this state. This build has only the ARM64 "
                            + "JIT core, so there is no interpreter to fall back to — tap "
                            + "Enable JIT below."))
                        .font(MadeiraTheme.caption()).foregroundStyle(.secondary)
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
                // The detail comes from LocalDevVPNRequirement, which knows about
                // the iOS 26.4 change: on those versions the single tunnel is not
                // enough, and telling someone to connect it anyway is how they
                // end up staring at two VPN icons and a launch that does nothing.
                detail: LocalDevVPNRequirement.explanation,
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
            // Read here as well as at the launch gate, so this screen and the
            // session that follows it are answering the same question of the
            // same source. It used to be possible for this screen to promise
            // a fallback that ContentView had no idea had been requested.
            Label(jit.shouldUseJIT
                  ? "FEX will compile this session to native code."
                  : "FEX will not compile this session.",
                  systemImage: jit.shouldUseJIT ? "bolt.fill" : "bolt.slash.fill")
                .font(.footnote)
                .foregroundStyle(jit.shouldUseJIT ? Color.secondary : Color.orange)
        } header: {
            Text("If JIT cannot be enabled")
        } footer: {
            Text("This build of FEX ships only the ARM64 JIT core — no interpreter — so "
                 + "interpreter-only cannot make a session run without a debugger; it records "
                 + "the choice and the session will say so instead of failing silently. Turn it "
                 + "off to let FEX use the JIT whenever one is available.")
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