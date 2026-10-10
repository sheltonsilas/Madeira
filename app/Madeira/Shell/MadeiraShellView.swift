// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// MadeiraShellView.swift - the front screen the app now opens on.
//
// WHAT THIS REPLACES, AND WHY IT IS A SHELL RATHER THAN A RESKIN
// Madeira grew a game-launcher interface: one screen that was a library, a
// settings pane and a session window at once, with the thing you actually came
// for - a machine - reached through a toolbar button. That is not what this app
// is any more. It runs two kinds of guest, Windows programs and Linux machines,
// and the first question a screen should answer is "which of mine are there and
// which is running".
//
// So the front screen is a shell: a sidebar of the places you can be, and a
// detail pane for the one you are in. Home is a summary; Windows and Linux are
// the two libraries; Store is where the side-loading story is explained; and
// Settings is settings. The old interface is not deleted - it is one row down
// the sidebar, called "Classic screen" - because it still owns the parts of the
// app that are genuinely session-shaped (touch controls, the joystick, the
// per-game settings), and rebuilding those to arrive at the same thing would be
// work with no user on the other end of it.
//
// WHERE THE DATA COMES FROM
// Every screen reads the real stores: LibraryModel for Windows programs,
// LinuxEnvironmentStore for machines, the engine plan for what a machine can
// actually do. Nothing here is a mock, and nothing here invents state it cannot
// get. Where a thing is not known - a machine's disk usage, a guest's live
// frame - the screen says so rather than showing a plausible zero.

import SwiftUI

/// The sidebar's destinations.
enum MadeiraShellTab: String, CaseIterable, Identifiable {
    case home
    case windows
    case linux
    case store
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .windows: return "Windows"
        case .linux: return "Linux"
        case .store: return "Store"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "square.grid.2x2"
        case .windows: return "display"
        case .linux: return "terminal"
        case .store: return "arrow.down.app"
        case .settings: return "slider.horizontal.3"
        }
    }
}

/// The front screen.
///
/// `play`, `enableJIT` and `showClassic` are handed in by ContentView rather
/// than reached for here, because the session engine and the JIT gate live on
/// ContentView and there is exactly one of it. Passing closures keeps this
/// screen a view of the app's state instead of a second owner of it.
struct MadeiraShellView: View {
    var play: (LibraryEntry) -> Void
    var enableJIT: () -> Void
    @Binding var showClassic: Bool
    /// The variant on screen. A value, not a binding: the shell reads it to
    /// label itself and to tick the right row in Settings, and changes it
    /// through `chooseVariant` so the write goes through one place.
    var variant: AppVariant
    var chooseVariant: (AppVariant) -> Void

    @ObservedObject private var library = LibraryModel.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @StateObject private var linux = LinuxEnvironmentStore()
    @State private var selection: MadeiraShellTab = .home
    @State private var showNewMachine = false
    @State private var showManager = false
    @State private var showDistroPicker = false

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactShell
            } else {
                splitShell
            }
        }
        .sheet(isPresented: $showNewMachine) {
            NavigationStack {
                LinuxDistroOnboardingView(store: linux)
            }
        }
        .sheet(isPresented: $showManager, onDismiss: { linux.reload() }) {
            NavigationStack { LinuxEnvironmentManagerView() }
        }
    }

    // MARK: Layout

    /// iPad and anything else wide enough for two columns.
    private var splitShell: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } detail: {
            NavigationStack {
                detail
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// iPhone: the same five places as tabs, because a sidebar would be a
    /// drawer and a drawer over a machine list is a worse way to move between
    /// two lists.
    private var compactShell: some View {
        TabView(selection: $selection) {
            ForEach(MadeiraShellTab.allCases) { tab in
                NavigationStack {
                    detail(for: tab)
                }
                .tabItem { Label(tab.title, systemImage: tab.symbol) }
                .tag(tab)
            }
        }
    }

    private var sidebar: some View {
        List {
            Section {
                brandHeader
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 10, leading: 8, bottom: 14, trailing: 8))
            }

            Section {
                ForEach(MadeiraShellTab.allCases) { tab in
                    Button {
                        selection = tab
                    } label: {
                        MadeiraSidebarRow(
                            title: tab.title,
                            symbol: tab.symbol,
                            badge: badge(for: tab),
                            selected: selection == tab
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                }
            }

            Section {
                Button {
                    showClassic = true
                } label: {
                    MadeiraSidebarRow(
                        title: "Classic screen",
                        symbol: "rectangle.on.rectangle",
                        selected: false
                    )
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
            } footer: {
                Text("The library, touch controls and per-program settings, as they were before this screen.")
                    .font(MadeiraTheme.caption())
            }
        }
        .listStyle(.sidebar)
    }

    private var brandHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(MadeiraTheme.brandGradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text("Madeira")
                    .font(MadeiraTheme.wordmark())
            }
            Text(variant.tagline)
                .font(MadeiraTheme.caption())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    /// Only the two libraries carry a count; a number next to Settings would be
    /// a number with nothing to count.
    private func badge(for tab: MadeiraShellTab) -> Int? {
        switch tab {
        case .windows: return library.entries.count
        case .linux: return linux.environments.count
        default: return nil
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        detail(for: selection)
    }

    @ViewBuilder
    private func detail(for tab: MadeiraShellTab) -> some View {
        switch tab {
        case .home:
            MadeiraHomeView(
                linux: linux,
                play: play,
                enableJIT: enableJIT,
                showClassic: $showClassic,
                goTo: { selection = $0 },
                newMachine: { showNewMachine = true }
            )
        case .windows:
            MadeiraWindowsView(play: play, goToStore: { selection = .store })
        case .linux:
            MadeiraLinuxView(
                store: linux,
                newMachine: { showNewMachine = true },
                manage: { showManager = true }
            )
        case .store:
            MadeiraStoreView()
        case .settings:
            MadeiraSettingsView(
                variant: variant,
                chooseVariant: chooseVariant,
                showClassic: $showClassic,
                goToLinux: { selection = .linux }
            )
        }
    }
}

// MARK: - Home

/// The summary screen: what is installed, what is running, and the two things
/// worth doing from here.
struct MadeiraHomeView: View {
    @ObservedObject var linux: LinuxEnvironmentStore
    var play: (LibraryEntry) -> Void
    var enableJIT: () -> Void
    @Binding var showClassic: Bool
    var goTo: (MadeiraShellTab) -> Void
    var newMachine: () -> Void

    @ObservedObject private var library = LibraryModel.shared
    @ObservedObject private var jit = JITCoordinator.shared
    @State private var debuggerAttached = isDebuggerAttached()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MadeiraTheme.sectionGap) {
                hero
                statusStrip
                machines
                recentPrograms
                howItRuns
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { debuggerAttached = isDebuggerAttached() }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Two guest systems, one app")
                .font(MadeiraTheme.title())
            Text("Windows programs run through Wine on FEX-Emu. Linux runs as a machine, the way a virtual machine does. Neither needs a second app.")
                .font(MadeiraTheme.body())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                MadeiraPill(title: "New Linux machine", systemImage: "plus") { newMachine() }
                Button {
                    goTo(.windows)
                } label: {
                    Label("Windows programs", systemImage: "display")
                        .font(MadeiraTheme.heading())
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(MadeiraTheme.surface, in: Capsule())
                        .foregroundStyle(MadeiraTheme.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: MadeiraTheme.corner + 4, style: .continuous)
                .fill(MadeiraTheme.accent.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MadeiraTheme.corner + 4, style: .continuous)
                .strokeBorder(MadeiraTheme.accent.opacity(0.22), lineWidth: 1)
        )
    }

    // MARK: Status

    /// The three facts that decide whether anything here will run. A home screen
    /// that does not say whether JIT is available is a home screen whose first
    /// button is a surprise.
    private var statusStrip: some View {
        HStack(spacing: MadeiraTheme.gap) {
            statusCard(
                title: "JIT",
                value: jitValue,
                detail: jitDetail,
                symbol: "bolt.fill",
                level: jitLevel,
                action: debuggerAttached ? nil : { enableJIT() },
                actionTitle: "Enable JIT"
            )
            statusCard(
                title: "Linux engines",
                value: engineValue,
                detail: engineDetail,
                symbol: "cpu",
                level: LinuxEngineSupport.hasQEMUCore ? .ready : .attention,
                action: nil,
                actionTitle: nil
            )
            statusCard(
                title: "Installed",
                value: "\(library.entries.count) program\(library.entries.count == 1 ? "" : "s")",
                detail: "\(linux.environments.count) Linux machine\(linux.environments.count == 1 ? "" : "s")",
                symbol: "shippingbox",
                level: .off,
                action: nil,
                actionTitle: nil
            )
        }
    }

    private func statusCard(
        title: String,
        value: String,
        detail: String,
        symbol: String,
        level: MadeiraStatusChip.Level,
        action: (() -> Void)?,
        actionTitle: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(level.tint)
                Text(title.uppercased())
                    .font(MadeiraTheme.label())
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(MadeiraTheme.heading())
            Text(detail)
                .font(MadeiraTheme.caption())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let action, let actionTitle {
                Button(actionTitle, action: action)
                    .font(MadeiraTheme.label())
                    .buttonStyle(.plain)
                    .foregroundStyle(MadeiraTheme.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(MadeiraTheme.surface, in: RoundedRectangle(cornerRadius: MadeiraTheme.corner, style: .continuous))
    }

    private var jitValue: String { debuggerAttached ? "Ready" : "Not attached" }

    private var jitDetail: String {
        debuggerAttached
            ? "A debugger is attached, so the fast QEMU configuration is available."
            : "Windows programs and the fast Linux engine both need it."
    }

    private var jitLevel: MadeiraStatusChip.Level { debuggerAttached ? .running : .attention }

    private var engineValue: String {
        if !LinuxEngineSupport.hasQEMUCore { return "Not linked" }
        if !LinuxEngineSupport.hasLauncher { return "Linked, no launcher" }
        return LinuxEngineSupport.hasTCGInterpreter ? "JIT and JIT-less" : "JIT only"
    }

    private var engineDetail: String {
        if !LinuxEngineSupport.hasQEMUCore {
            return "This build has no emulator core, so a Linux machine cannot start yet."
        }
        if !LinuxEngineSupport.hasLauncher {
            return "QEMU is in this build. Nothing here knows how to start a machine with it yet."
        }
        if LinuxEngineSupport.hasTCGInterpreter {
            return "Both QEMU configurations are built in."
        }
        return "QEMU was built without its interpreter, so a machine needs a debugger."
    }

    // MARK: Machines

    private var machines: some View {
        VStack(alignment: .leading, spacing: MadeiraTheme.gap) {
            MadeiraSectionHeader(
                title: "Machines",
                count: linux.environments.count,
                actionTitle: "New",
                action: newMachine
            )

            if linux.environments.isEmpty {
                MadeiraEmptyState(
                    title: "No Linux machine yet",
                    message: "Pick a distribution and Madeira downloads it, checks it against the checksum its publisher publishes, and keeps it in a folder you can see in Files.",
                    symbol: "shippingbox",
                    actionTitle: "Choose a distribution",
                    action: newMachine
                )
            } else {
                ForEach(linux.environments) { environment in
                    NavigationLink {
                        MadeiraMachineView(environment: environment, store: linux)
                    } label: {
                        MadeiraMachineRow(environment: environment)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Recent programs

    private var recentPrograms: some View {
        VStack(alignment: .leading, spacing: MadeiraTheme.gap) {
            MadeiraSectionHeader(
                title: "Windows programs",
                count: library.entries.count,
                actionTitle: "All",
                action: { goTo(.windows) }
            )

            if library.entries.isEmpty {
                MadeiraEmptyState(
                    title: "Nothing installed",
                    message: "Open the browser in the classic screen, download an .exe or .msi, and it installs into the same prefix these programs run from.",
                    symbol: "display",
                    actionTitle: "Go to the browser",
                    action: { showClassic = true }
                )
            } else {
                ForEach(recent) { entry in
                    MadeiraProgramRow(entry: entry, play: play)
                }
            }
        }
    }

    /// The five most recently played, then whatever is left, so a fresh install
    /// with no play history still shows its programs rather than an empty list.
    private var recent: [LibraryEntry] {
        library.entries
            .sorted { left, right in
                let a = left.lastPlayed ?? Date.distantPast
                let b = right.lastPlayed ?? Date.distantPast
                if a != b { return a > b }
                return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
            }
            .prefix(5)
            .map { $0 }
    }

    // MARK: Explainer

    /// The one place the app explains itself. Kept here rather than in a
    /// settings pane because the question "why is this fast" is a question you
    /// ask on the way in.
    private var howItRuns: some View {
        VStack(alignment: .leading, spacing: MadeiraTheme.gap) {
            MadeiraSectionHeader(title: "How it runs")
            MadeiraCard {
                VStack(alignment: .leading, spacing: 12) {
                    explainer(
                        symbol: "display",
                        title: "Windows programs",
                        detail: "FEX-Emu translates x86 and x86-64 to ARM64, and Wine supplies the Windows API. FEX has no interpreter, so this path always needs the JIT."
                    )
                    Divider()
                    explainer(
                        symbol: "terminal",
                        title: "Linux machines",
                        detail: "QEMU runs the whole machine. With the JIT it compiles guest code; built as an interpreter it does not, which is how a machine still runs with no debugger attached."
                    )
                    Divider()
                    explainer(
                        symbol: "bolt.slash",
                        title: "Why the debugger",
                        detail: "iOS grants executable memory to a process under a debugger and to nothing else. Attaching StikDebug is what turns JIT on, and it is why the app asks for it."
                    )
                }
            }
        }
    }

    private func explainer(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MadeiraTheme.accent)
                .frame(width: 24, alignment: .center)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(MadeiraTheme.heading())
                Text(detail)
                    .font(MadeiraTheme.caption())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
