// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// MadeiraStoreView.swift - where installing lives, and the settings screen.
//
// WHY THERE IS A STORE TAB IN AN APP WITH NO STORE
// Because the honest answer to "how do I get a program in here" is a chain of
// four other tools, and until now it was spread across a setup guide, a
// settings sheet and a launch error. SideStore installs the app and re-signs it
// every seven days; StikDebug (or Madeira's own built-in helper) attaches the
// debugger that turns JIT on; LocalDevVPN is how the debugger reaches the
// device. All four are separate downloads and all four have to be right before
// anything runs.
//
// So this screen states the chain, checks which links are present, and links to
// the ones that are not. It does not pretend to install them: an app store
// listing is not something a sandboxed app can act on.

import SwiftUI

/// The install path and the tools it needs.
struct MadeiraStoreView: View {
    @State private var copied = false

    /// The side-loading source. `latest/download` rather than a tag, so the URL
    /// keeps working after the next build: a source URL that pins a tag stops
    /// offering updates the day after it is written.
    private let sourceURL = "https://github.com/sheltonsilas/Madeira/releases/latest/download/source.json"

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Getting a program in")
                        .font(MadeiraTheme.title())
                    Text("Madeira runs the program you bring it. There is no catalogue to buy from, and nothing is uploaded: a program arrives as a file you downloaded, and it runs where it lands.")
                        .font(MadeiraTheme.body())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
                .listRowBackground(Color.clear)
            }

            Section("How it works") {
                step(1, "Install Madeira", "SideStore installs and re-signs it. Without a paid developer account a signature lasts seven days; SideStore refreshes it before it expires.")
                step(2, "Turn on JIT", "Either StikDebug, or Madeira's own helper. Both attach a debugger, which is the only way iOS grants an app executable memory.")
                step(3, "Bring a program", "Download an .exe or .msi in the browser from the classic screen. It installs into the same Wine prefix the program list runs from.")
                step(4, "Start a Linux machine", "Or skip Windows entirely: a machine is a distribution image and a disk, downloaded and checked from this app.")
            }

            Section {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.app")
                        .foregroundStyle(MadeiraTheme.accent)
                    Text(sourceURL)
                        .font(MadeiraTheme.mono())
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Button {
                    UIPasteboard.general.string = sourceURL
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy the SideStore source URL", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Button {
                    if let url = URL(string: sourceURL) { UIApplication.shared.open(url) }
                } label: {
                    Label("Open the source JSON", systemImage: "safari")
                }
            } header: {
                Text("SideStore source")
            } footer: {
                Text("Paste this into SideStore › Sources › +. SideStore then offers an update here on every new build, and re-signs it for you.")
                    .font(MadeiraTheme.caption())
            }

            Section {
                tool(
                    name: "SideStore",
                    scheme: "sidestore://",
                    detail: "Installs and re-signs this app without a computer."
                )
                tool(
                    name: "StikDebug",
                    scheme: "stikdebug://",
                    detail: "Attaches a debugger, which is what enables JIT.",
                    fallbackAvailable: StikJITHelper.isAvailable
                )
                tool(
                    name: "LocalDevVPN",
                    scheme: "localdevvpn://",
                    // The single-tunnel sentence stopped being true in iOS 26.4,
                    // so it is not written down as if it still were.
                    detail: LocalDevVPNRequirement.needsSecondTunnel
                        ? "Gives the debugger a route to this device. On iOS 26.4 and later it only works once an IKEv2 VPN is connected first; pairing in Madeira removes that need."
                        : "Gives the debugger a route to this device when there is no other network.",
                    appStore: LocalDevVPN.appStore
                )
            } header: {
                Text("Tools on this device")
            } footer: {
                Text("A tool Madeira cannot see is one it cannot use. Detection is by URL scheme, so a tool that is installed but has no scheme registered will show as absent.")
                    .font(MadeiraTheme.caption())
            }

            Section {
                if MadeiraBuiltInJIT.isAvailable {
                    Label("Madeira's built-in JIT helper is available", systemImage: "checkmark.seal")
                        .foregroundStyle(MadeiraTheme.running)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Madeira's built-in JIT helper is unavailable", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(MadeiraTheme.warning)
                        Text(MadeiraBuiltInJIT.unavailableReason ?? "")
                            .font(MadeiraTheme.caption())
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Built-in JIT")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Store")
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(MadeiraTheme.heading())
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(MadeiraTheme.brandGradient, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(MadeiraTheme.heading())
                Text(detail)
                    .font(MadeiraTheme.caption())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    /// A row for one of the four external tools.
    private func tool(
        name: String,
        scheme: String,
        detail: String,
        fallbackAvailable: Bool? = nil,
        appStore: URL? = nil
    ) -> some View {
        let installed = UIApplication.shared.canOpenURL(URL(string: scheme)!)
        let present = installed || (fallbackAvailable ?? false)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: present ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(present ? MadeiraTheme.running : Color.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(name)
                        .font(MadeiraTheme.heading())
                    MadeiraStatusChip(level: present ? .running : .off, text: present ? "Found" : "Not found", compact: true)
                }
                Text(detail)
                    .font(MadeiraTheme.caption())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !present, let appStore {
                    Link("Open the App Store page", destination: appStore)
                        .font(MadeiraTheme.label())
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Settings

/// The app's own settings. Deliberately short: the parts that need a manual are
/// on the screens they affect.
struct MadeiraSettingsView: View {
    var variant: AppVariant
    var chooseVariant: (AppVariant) -> Void
    @Binding var showClassic: Bool
    var goToLinux: () -> Void

    @State private var debuggerAttached = isDebuggerAttached()
    @ObservedObject private var linux = LinuxEnvironmentStore()

    var body: some View {
        List {
            Section {
                ForEach(AppVariant.allCases) { candidate in
                    Button {
                        chooseVariant(candidate)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: candidate.symbol)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(candidate == variant ? MadeiraTheme.accent : .secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.displayName)
                                    .font(MadeiraTheme.heading())
                                    .foregroundStyle(.primary)
                                Text(candidate.tagline)
                                    .font(MadeiraTheme.caption())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            if candidate == variant {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(MadeiraTheme.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Front screen")
            } footer: {
                Text("Which of the two this app opens on. Both are in this one install, so switching changes what you see, not what is installed.")
                    .font(MadeiraTheme.caption())
            }

            Section {
                LabeledContent("Debugger", value: debuggerAttached ? "Attached" : "Not attached")
                LabeledContent("QEMU core", value: LinuxEngineSupport.hasQEMUCore ? "Linked in" : "Not in this build")
                LabeledContent("TCG interpreter", value: LinuxEngineSupport.hasTCGInterpreter ? "Built in" : "Not built in")
                LabeledContent("Guest launcher", value: LinuxEngineSupport.hasLauncher ? "Present" : "Not written")
                // The 32-bit Windows farm is a payload like the engine: a build
                // either shipped it or did not, and that is the whole explanation
                // for a 32-bit setup program that will not start. Read from the
                // same answer the install path uses (DockInstallers.bundleHas32Bit)
                // rather than a second copy of the check, so this row cannot
                // promise something the launcher will refuse.
                LabeledContent("32-bit Windows",
                               value: DockInstallers.bundleHas32Bit ? "Supported" : "Not in this build")
                LabeledContent("Machines", value: "\(linux.environments.count)")
            } header: {
                Text("This build")
            } footer: {
                Text(engineFooter)
                    .font(MadeiraTheme.caption())
            }

            // The JIT section is the one that already existed, reused rather
            // than rebuilt: it knows about the pairing file, the shortcut and
            // the method picker, and a second copy would drift from it.
            JITSettingsSection()

            Section {
                Button {
                    showClassic = true
                } label: {
                    Label("Open the classic screen", systemImage: "rectangle.on.rectangle")
                }
                Button {
                    goToLinux()
                } label: {
                    Label("Manage Linux machines", systemImage: "shippingbox")
                }
            } header: {
                Text("More")
            }

            Section {
                LabeledContent("Storage", value: "Documents/environments")
                LabeledContent("Licence", value: "GPL-3.0-or-later")
            } footer: {
                Text("Madeira includes Wine, FEX-Emu, QEMU, DXMT and StikJIT. Their notices are in the app's licences, and the source for this build is in the repository named on the SideStore source.")
                    .font(MadeiraTheme.caption())
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .onAppear { debuggerAttached = isDebuggerAttached() }
    }

    private var engineFooter: String {
        if !LinuxEngineSupport.hasQEMUCore {
            return "No emulator core is linked into this build, so a Linux machine cannot start. Windows programs are unaffected: they run through FEX and Wine. The engine build itself now succeeds - see the Linux engine notes in the repository - so this is the linking step, not the hard part."
        }
        if !LinuxEngineSupport.hasLauncher {
            return "QEMU is linked in, and nothing here can start a machine with it yet: the launcher that turns a machine into QEMU's arguments, with a display and a serial console, is the part still to be written."
        }
        if !LinuxEngineSupport.hasTCGInterpreter {
            return "QEMU is linked in without its interpreter, so a Linux machine needs a debugger attached."
        }
        return "QEMU is linked in with both configurations, so a Linux machine runs whether or not a debugger is attached."
    }
}
