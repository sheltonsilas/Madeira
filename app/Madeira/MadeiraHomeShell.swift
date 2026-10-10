import SwiftUI

/// The integrated entry point for Madeira's Windows and Linux workspaces.
/// Existing engine screens stay behind this shell so the product has one
/// navigation model instead of presenting separate companion apps.
struct MadeiraHomeShell: View {
    @State private var selection: MadeiraHomeSection = .home
    @State private var showWindows = false
    @State private var openWindowsAfterSheetDismissal = false
    @State private var activeSheet: MadeiraHomeSheet?
    @State private var jitAttached = isDebuggerAttached()

    private let ink = Color(red: 0.055, green: 0.075, blue: 0.09)
    private let panel = Color(red: 0.095, green: 0.125, blue: 0.14)
    private let mint = Color(red: 0.45, green: 0.91, blue: 0.72)

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 820

            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.07, green: 0.12, blue: 0.14), ink, ink],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                if wide {
                    HStack(spacing: 0) {
                        sidebar
                            .frame(width: 242)
                        Rectangle()
                            .fill(.white.opacity(0.07))
                            .frame(width: 1)
                        page(wide: wide)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .padding(18)
                } else {
                    VStack(spacing: 0) {
                        compactHeader
                        page(wide: false)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        bottomBar
                    }
                }
            }
            .foregroundStyle(.white)
            .onAppear {
                refreshJIT()
                WindowsInstallerBridge.shared.launchHandler = { relativePath in
                    let executable = LibraryModel.drive.appendingPathComponent(relativePath)
                    let machine = DockInstallers.machine(executable)
                    let bits = machine == 0x14c ? 32 : (machine == 0x8664 ? 64 : 0)
                    var entry = LibraryEntry(
                        title: (relativePath as NSString).lastPathComponent,
                        relativePath: relativePath,
                        bits: bits
                    )
                    entry.arguments = ""
                    LibraryModel.shared.save(entry)
                    ShortcutRouter.shared.pendingExe = relativePath
                    openWindowsAfterSheetDismissal = true
                    activeSheet = nil
                }
                IncomingInstaller.shared.drain()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                refreshJIT()
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showWindows) {
            ContentView()
                .overlay(alignment: .topTrailing) {
                    Button { showWindows = false } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.primary)
                            .frame(width: 36, height: 36)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back to Madeira home")
                    .padding(.top, 6)
                    .padding(.trailing, 14)
                }
        }
        .sheet(item: $activeSheet, onDismiss: {
            refreshJIT()
            if openWindowsAfterSheetDismissal {
                openWindowsAfterSheetDismissal = false
                showWindows = true
            }
        }) { sheet in
            switch sheet {
            case .jit:
                JITSetupView()
            case .browser:
                MadeiraBrowserView()
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand.padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 38)

            Text("WORKSPACES")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.5)
                .foregroundStyle(.white.opacity(0.38))
                .padding(.horizontal, 18)
                .padding(.bottom, 10)

            ForEach(MadeiraHomeSection.allCases) { section in
                navButton(section)
            }

            Spacer(minLength: 18)
            Button { activeSheet = .jit } label: { jitStatusCard }
                .buttonStyle(.plain)
                .padding(12)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 24))
    }

    private var compactHeader: some View {
        HStack {
            brand
            Spacer()
            Button { activeSheet = .jit } label: {
                HStack(spacing: 7) {
                    Circle().fill(jitAttached ? mint : Color.orange).frame(width: 7, height: 7)
                    Text(jitAttached ? "JIT ready" : "JIT setup")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.white.opacity(0.07), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(jitAttached ? "JIT ready. Open JIT setup" : "JIT setup required")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var brand: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(mint.opacity(0.14))
                    .frame(width: 38, height: 38)
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(mint)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("MADEIRA")
                    .font(.system(size: 13, weight: .black, design: .rounded))
                    .tracking(1.6)
                Text("YOUR WORLDS, IN ONE PLACE")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.9)
                    .foregroundStyle(.white.opacity(0.42))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func page(wide: Bool) -> some View {
        Group {
            if selection == .linux {
                NavigationStack {
                    LinuxEnvironmentManagerView()
                }
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 25) {
                        if selection == .home {
                            dashboard(wide: wide)
                        } else {
                            settingsPage
                        }
                    }
                    .frame(maxWidth: 1040, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 22)
                    .padding(.top, 24)
                    .padding(.bottom, 30)
                }
            }
        }
    }

    private func dashboard(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 25) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(Date.now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()).uppercased())
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1.5)
                        .foregroundStyle(mint)
                    Text("Make it your world.")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .tracking(-1.1)
                    Text("Choose an environment and pick up where you left off.")
                        .font(.system(size: 15, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.57))
                }
                Spacer(minLength: 12)
                if wide {
                    Button { activeSheet = .jit } label: { jitStatusCard }
                        .buttonStyle(.plain)
                        .frame(maxWidth: 250)
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "sparkle")
                    .foregroundStyle(mint)
            Text("One app. Windows and Linux machines, with launch options based on the engines in this build.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(mint.opacity(0.17), lineWidth: 1))

            HStack(alignment: .firstTextBaseline) {
                Text("ENVIRONMENTS")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.42))
                Spacer()
                Text("Windows workspace / Linux virtual machines")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.38))
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    windowsCard
                    linuxCard
                }
                VStack(spacing: 14) {
                    windowsCard
                    linuxCard
                }
            }

            HStack(spacing: 14) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(mint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your files stay on your device")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text("Madeira keeps your files on this device.")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.white.opacity(0.49))
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private var windowsCard: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                engineIcon("pc", color: Color(red: 0.45, green: 0.72, blue: 1))
                Spacer()
                statusPill(jitAttached ? "JIT READY" : "JIT REQUIRED", tint: jitAttached ? mint : .orange)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Windows")
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                Text("Run Windows apps and games with Wine and FEX.")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 10) {
                Button {
                    selection = .home
                    showWindows = true
                } label: {
                    HStack {
                        Text("Open Windows")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(ink)
                    .padding(.horizontal, 16)
                    .frame(height: 46)
                    .background(mint, in: RoundedRectangle(cornerRadius: 13))
                }
                .buttonStyle(.plain)

                Button { activeSheet = .browser } label: {
                    Label("Browse and install Windows apps", systemImage: "safari")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Color(red: 0.12, green: 0.23, blue: 0.25), panel], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 23)
        )
        .overlay(RoundedRectangle(cornerRadius: 23).stroke(.white.opacity(0.08), lineWidth: 1))
    }

    private var linuxCard: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                engineIcon("terminal", color: Color(red: 0.8, green: 0.62, blue: 1))
                Spacer()
                statusPill(linuxEngineBadge, tint: linuxEngineReady ? mint : .orange)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Linux")
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                Text("Create virtual machines, choose a distribution, and check QEMU boot requirements.")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button { selection = .linux } label: {
                HStack {
                    Text("View Linux setup")
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 46)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panel, in: RoundedRectangle(cornerRadius: 23))
        .overlay(RoundedRectangle(cornerRadius: 23).stroke(.white.opacity(0.08), lineWidth: 1))
    }

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            pageEyebrow("MADEIRA SETTINGS")
            Text("Device and runtime")
                .font(.system(size: 31, weight: .bold, design: .rounded))
                .tracking(-0.8)
            Button { activeSheet = .jit } label: {
                HStack(spacing: 14) {
                    engineIcon("bolt.fill", color: jitAttached ? mint : .orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("JIT and pairing")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                        Text(jitAttached ? "Debugger detected" : "Check setup and enable JIT")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(.white.opacity(0.53))
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.36))
                }
                .padding(16)
                .background(panel, in: RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 8) {
                Text("About Madeira")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text("One iPad app for Windows software and Linux virtual machines. Engines and system images stay separate so each feature can be verified before Madeira offers it.")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.white.opacity(0.57))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(17)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private var jitStatusCard: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle().fill((jitAttached ? mint : Color.orange).opacity(0.14)).frame(width: 34, height: 34)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(jitAttached ? mint : Color.orange)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(jitAttached ? "JIT available" : "JIT setup needed")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text(jitAttached ? "Windows acceleration ready" : "Required for Windows apps")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.white.opacity(0.48))
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
        .contentShape(Rectangle())
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            ForEach(MadeiraHomeSection.allCases) { section in
                Button { select(section) } label: {
                    VStack(spacing: 5) {
                        Image(systemName: section.icon)
                            .font(.system(size: 16, weight: .semibold))
                        Text(section.title)
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(selection == section ? mint : .white.opacity(0.46))
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 7)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
    }

    private func navButton(_ section: MadeiraHomeSection) -> some View {
        Button { select(section) } label: {
            HStack(spacing: 13) {
                Image(systemName: section.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 21)
                Text(section.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
            }
            .foregroundStyle(selection == section ? mint : .white.opacity(0.65))
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(selection == section ? mint.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 13))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    private func select(_ section: MadeiraHomeSection) {
        switch section {
        case .windows, .library:
            selection = .home
            showWindows = true
        case .home, .linux, .settings:
            selection = section
        }
    }

    private func engineIcon(_ name: String, color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(color.opacity(0.13)).frame(width: 42, height: 42)
            Image(systemName: name).font(.system(size: 17, weight: .semibold)).foregroundStyle(color)
        }
        .accessibilityHidden(true)
    }

    private func statusPill(_ title: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(title).font(.system(size: 9, weight: .bold, design: .rounded)).tracking(0.8)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(tint.opacity(0.1), in: Capsule())
    }

    private func pageEyebrow(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(1.6)
            .foregroundStyle(mint)
    }

    private func refreshJIT() {
        jitAttached = isDebuggerAttached()
    }

    private var linuxEngineReady: Bool {
        LinuxEngineSupport.hasQEMUCore && LinuxEngineSupport.hasLauncher
    }

    private var linuxEngineBadge: String {
        guard LinuxEngineSupport.hasQEMUCore else { return "QEMU NOT LINKED" }
        guard LinuxEngineSupport.hasLauncher else { return "LAUNCHER MISSING" }
        return LinuxEngineSupport.hasTCGInterpreter ? "QEMU READY" : "JIT REQUIRED"
    }
}

private enum MadeiraHomeSection: String, CaseIterable, Identifiable {
    case home, windows, linux, library, settings

    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Home"
        case .windows: "Windows"
        case .linux: "Linux"
        case .library: "Library"
        case .settings: "Settings"
        }
    }
    var icon: String {
        switch self {
        case .home: "square.grid.2x2.fill"
        case .windows: "pc"
        case .linux: "terminal.fill"
        case .library: "books.vertical"
        case .settings: "slider.horizontal.3"
        }
    }
}

private enum MadeiraHomeSheet: String, Identifiable {
    case jit, browser
    var id: String { rawValue }
}
