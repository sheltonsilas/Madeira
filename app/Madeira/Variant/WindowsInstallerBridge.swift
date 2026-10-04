// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// WindowsInstallerBridge.swift - the path from "I downloaded an .exe" to "it is
// installed and in the launcher".
//
// Three jobs:
//   1. Stage a browser download INSIDE drive_c, so Wine can see it. A file in
//      the app's Documents/Downloads is outside the prefix and invisible to
//      every Windows program, including the installer itself.
//   2. Run it, using the same launch path the game library already uses.
//   3. Enumerate what got installed, for a start-menu / launcher screen.
//
// The seam into the existing app is deliberate: `launchHandler` is set once by
// ContentView. The bridge does not own the Wine session, because upstream
// already does (ContentView.swift: launchLibraryEntry -> wine_process_start),
// and two owners of one session is how you get a wedged wineserver.

import Foundation
import SwiftUI

@MainActor
final class WindowsInstallerBridge: ObservableObject {
    static let shared = WindowsInstallerBridge()

    /// Set by ContentView. Takes a drive_c-relative slash path and starts it in
    /// the current session, exactly as a library entry would.
    var launchHandler: ((String) -> Void)?

    /// Folders inside drive_c that a Windows installer can write a program to.
    /// Order matters: the first hit wins if a program exists in two of them.
    private static let programRoots = [
        "Program Files",
        "Program Files (x86)",
        "ProgramData/Microsoft/Windows/Start Menu/Programs",
    ]

    /// Where downloads are staged inside the prefix. `C:\downloads` inside the
    /// guest, `Documents/wine/drive_c/downloads` on the iOS side.
    static var stagedDownloads: URL {
        LibraryModel.drive.appendingPathComponent("downloads", isDirectory: true)
    }

    // MARK: 1. Stage

    /// Copy a finished browser download into the prefix and return its
    /// drive_c-relative slash path.
    ///
    /// Copies rather than moves: the original stays visible to the iOS Files app
    /// under "On My iPhone > Madeira > Downloads", which is the Files bridge the
    /// brief asks for. If the name already exists we suffix rather than
    /// overwrite, so downloading `setup.exe` twice does not destroy the first.
    @discardableResult
    func stage(_ download: BrowserDownload) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.stagedDownloads, withIntermediateDirectories: true)

        var target = Self.stagedDownloads.appendingPathComponent(download.filename)
        if fm.fileExists(atPath: target.path) {
            let stem = download.filename.deletingPathExtension
            let ext = download.filename.pathExtension
            var n = 2
            repeat {
                target = Self.stagedDownloads.appendingPathComponent("\(stem) (\(n)).\(ext)")
                n += 1
            } while fm.fileExists(atPath: target.path)
        }
        try fm.copyItem(at: download.localURL, to: target)
        return "downloads/" + target.lastPathComponent
    }

    // MARK: 2. Run

    /// Turn a slash path relative to drive_c into the `C:\...` form the Wine
    /// session expects, and hand it to the app's launcher.
    func run(relativePath: String) {
        launchHandler?(relativePath)
    }

    /// Called from the browser's Install button. Stages, then runs.
    ///
    /// `silent` appends the usual quiet switches for the two installer types we
    /// can recognise. We do NOT guess for everything: an unknown installer is
    /// run bare so the user sees its own UI, which is the least surprising
    /// behaviour and the only one that is safe.
    func offer(_ download: BrowserDownload, source: DownloadStore) {
        guard download.finished, download.isInstaller else { return }
        do {
            let staged = try stage(download)
            switch Self.pathExtension(of: download.filename) {
            case "msi":
                // Only use msiexec when it is actually installed. The arm64ec
                // farm shipped without it until build/wine-pe/build-universal.sh,
                // and launching a program that does not exist silently does
                // nothing at all - which looks exactly like a hung install.
                if Self.moduleExists("windows/system32/msiexec.exe") {
                    run(relativePath: "windows/system32/msiexec.exe",
                        arguments: ["/i", "C:\\(staged.windowsPath)", "/quiet", "/norestart"])
                } else {
                    // Run the package itself and let Wine's association or the
                    // program's own UI handle it.
                    run(relativePath: staged)
                }
            case "msix", "msixbundle", "appx":
                // App packages are installed by the shell, not msiexec. A bare
                // launch under Wine is the shell path.
                run(relativePath: staged)
            default:
                run(relativePath: staged)
            }
        } catch {
            source.add(BrowserDownload(filename: download.filename,
                                       sourceURL: download.sourceURL,
                                       localURL: download.localURL,
                                       byteCount: download.byteCount,
                                       finished: false,
                                       failure: "Could not stage into the prefix: \(error.localizedDescription)"))
        }
    }

    /// Launch a program with extra arguments (used for the msiexec path).
    ///
    /// The session takes its command line from `MADEIRA_ARGS`, the same
    /// mechanism upstream uses for a desktop or a Steam game, so quoting is the
    /// only real concern and we reject arguments containing a double quote.
    func run(relativePath: String, arguments: [String]) {
        guard arguments.allSatisfy({ !$0.contains("\"") }) else { return }
        setenv("MADEIRA_EXE", ("C:\\" + relativePath.windowsPath).cString, 1)
        setenv("MADEIRA_ARGS", arguments.joined(separator: " ").cString, 1)
        launchHandler?(relativePath)
    }

    static func pathExtension(of name: String) -> String {
        let lower = name.lowercased()
        guard let dot = lower.lastIndex(of: "."), dot != lower.index(before: lower.endIndex) else { return "" }
        return String(lower[lower.index(after: dot)...])
    }

    /// Is a Wine module present in the prefix? Used before launching a helper
    /// program whose absence would otherwise fail silently.
    static func moduleExists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(
            atPath: LibraryModel.drive.appendingPathComponent(relativePath).path)
    }
}

// MARK: - Installed apps

/// One program found inside the prefix.
struct InstalledApp: Identifiable, Hashable {
    var id: String { relativePath }
    let title: String
    /// Slash path relative to drive_c, the same convention LibraryEntry uses.
    let relativePath: String
    let sizeBytes: Int64

    var windowsPath: String { "C:\\" + relativePath.windowsPath }
    var symbol: String {
        switch relativePath.lowercased() {
        case let p where p.hasSuffix("browser.exe"): return "safari"
        default: return "app.dashed"
        }
    }
}

/// Scans the prefix for installed programs, for the launcher screen.
///
/// Deliberately shallow and cached: a full walk of drive_c is slow on iOS and
/// the answer changes only when the user installs something, so we rescan on
/// demand and when a session ends rather than on every view update.
@MainActor
final class InstalledAppsStore: ObservableObject {
    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var isScanning = false

    private var lastScan: Date?

    func refreshIfStale(after seconds: TimeInterval = 30) {
        if let lastScan, Date().timeIntervalSince(lastScan) < seconds { return }
        refresh()
    }

    func refresh() {
        isScanning = true
        let found = Self.scan()
        apps = found.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        lastScan = Date()
        isScanning = false
    }

    private static func scan() -> [InstalledApp] {
        let fm = FileManager.default
        var results: [InstalledApp] = []
        var seen = Set<String>()

        for root in WindowsInstallerBridge.programRoots {
            let base = LibraryModel.drive.appendingPathComponent(root)
            guard let walker = fm.enumerator(at: base,
                                             includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker {
                // Not Self.pathExtension: Self here is InstalledAppsStore, which
                // has no such member. The helper lives on WindowsInstallerBridge.
                guard WindowsInstallerBridge.pathExtension(of: url.lastPathComponent) == "exe" else { continue }
                let relative = url.path.replacingOccurrences(of: LibraryModel.drive.path + "/", with: "")
                guard !seen.insert(relative).inserted else { continue }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                results.append(InstalledApp(title: url.deletingPathExtension().lastPathComponent,
                                            relativePath: relative,
                                            sizeBytes: size))
            }
        }
        return results
    }
}

// MARK: - Launcher UI

/// A simple start menu: everything found in the prefix, plus the browser.
struct AppLauncherView: View {
    @StateObject private var store = InstalledAppsStore()
    @Environment(\.dismiss) private var dismiss

    private let bridge = WindowsInstallerBridge.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        bridge.run(relativePath: WindowsBrowser.programPath)
                        dismiss()
                    } label: {
                        Label("Browser", systemImage: "safari")
                    }
                } footer: {
                    Text("The preinstalled browser. Download an .exe or .msi here, then tap Install.")
                }

                Section("Installed") {
                    if store.apps.isEmpty && !store.isScanning {
                        ContentUnavailableView("Nothing installed yet",
                                               systemImage: "shippingbox",
                                               description: Text("Install something from the Browser and it will appear here."))
                    }
                    ForEach(store.apps) { app in
                        Button {
                            bridge.run(relativePath: app.relativePath)
                            dismiss()
                        } label: {
                            Label(app.title, systemImage: app.symbol)
                        }
                    }
                }
            }
            .navigationTitle("Apps")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { store.refresh() }
        }
    }
}

// MARK: - Path helpers

extension String {
    /// Slash path -> backslash path.
    var windowsPath: String { replacingOccurrences(of: "/", with: "\\") }
}