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
    /// Not private: InstalledAppsStore scans the same folders, and could not.
    static let programRoots = [
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
        try stage(fileAt: download.localURL, filename: download.filename)
    }

    /// The same thing for a file the app was handed rather than downloaded:
    /// anything iOS opened with Madeira. See `IncomingInstaller`.
    @discardableResult
    func stage(fileAt source: URL, filename: String? = nil) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.stagedDownloads, withIntermediateDirectories: true)

        let name = filename ?? source.lastPathComponent
        var target = Self.stagedDownloads.appendingPathComponent(name)
        if fm.fileExists(atPath: target.path) {
            // String has no deletingPathExtension/pathExtension -- those are
            // NSString's. pathExtension(of:) above is the helper this file
            // already uses for exactly this, so use it.
            let ext = Self.pathExtension(of: name)
            let stem = ext.isEmpty
                ? name
                : String(name.dropLast(ext.count + 1))
            var n = 2
            repeat {
                let candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
                target = Self.stagedDownloads.appendingPathComponent(candidate)
                n += 1
            } while fm.fileExists(atPath: target.path)
        }
        try fm.copyItem(at: source, to: target)
        return "downloads/" + target.lastPathComponent
    }

    // MARK: 2. Run

    /// Turn a slash path relative to drive_c into the `C:\...` form the Wine
    /// session expects, and hand it to the app's launcher.
    func run(relativePath: String) {
        launchHandler?(relativePath)
    }

    /// Called from the browser's Install button. Stages, then runs.
    func offer(_ download: BrowserDownload, source: DownloadStore) {
        guard download.finished, download.isInstaller else { return }
        do {
            try runInstaller(stagedPath: try stage(download), filename: download.filename)
        } catch {
            source.add(BrowserDownload(filename: download.filename,
                                       sourceURL: download.sourceURL,
                                       localURL: download.localURL,
                                       byteCount: download.byteCount,
                                       finished: false,
                                       failure: "Could not stage into the prefix: \(error.localizedDescription)"))
        }
    }

    /// Stage and run a file the app was handed by iOS: a download opened from
    /// Files, a share sheet target, "Open in Madeira".
    ///
    /// The staged path is returned so the caller can say which file it started.
    /// Throws rather than reporting, because there is no download row to put a
    /// message in: the caller is `IncomingInstaller`, which has its own answer.
    @discardableResult
    func offer(fileAt url: URL) throws -> String {
        let staged = try stage(fileAt: url)
        try runInstaller(stagedPath: staged, filename: url.lastPathComponent)
        return staged
    }

    /// The launch itself, once the file is inside the prefix.
    ///
    /// A quiet switch for the one installer type that has a documented one, and
    /// nothing for the rest. We do NOT guess: an unknown installer is run bare
    /// so the user sees its own UI, which is the least surprising behaviour and
    /// the only one that is safe.
    private func runInstaller(stagedPath staged: String, filename: String) throws {
        switch Self.pathExtension(of: filename) {
        case "msi":
            // Only use msiexec when it is actually installed. The arm64ec farm
            // shipped without it until build/wine-pe/build-universal.sh, and
            // launching a program that does not exist silently does nothing at
            // all - which looks exactly like a hung install.
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
    }

    /// Launch a program with extra arguments (used for the msiexec path).
    ///
    /// The session takes its command line from `MADEIRA_ARGS`, the same
    /// mechanism upstream uses for a desktop or a Steam game, so quoting is the
    /// only real concern and we reject arguments containing a double quote.
    func run(relativePath: String, arguments: [String]) {
        guard arguments.allSatisfy({ !$0.contains("\"") }) else { return }
        // cString(using:) is a method, not a pointer: passing it unapplied is
        // exactly what the compiler rejected. withCString hands out the pointer.
        _ = ("C:\\" + relativePath.windowsPath).withCString { setenv("MADEIRA_EXE", $0, 1) }
        _ = arguments.joined(separator: " ").withCString { setenv("MADEIRA_ARGS", $0, 1) }
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

// MARK: - A file opened with Madeira

/// An installer iOS handed to the app instead of one the browser downloaded.
///
/// WHY THIS EXISTS
/// There are two ways to get an .exe in front of the user and only one of them
/// worked. The browser's download shelf is the one that worked. The other is
/// every other way iOS can give an app a file - tapping a download in the Files
/// app, "Share > Madeira", Safari's Downloads list - and it did not work at all,
/// for two reasons that both had to be fixed:
///
///   * Info.plist declared no document types, so iOS did not know Madeira could
///     open an .exe and never offered it. That is the half in Info.plist.
///   * The app's one URL handler routed every URL to the JIT network shortcut,
///     so a file URL that did arrive went nowhere. That is this class.
///
/// It also has to remember the file: an app launched BY the open has not run
/// `ContentView.startup()` yet, and that is where the launch handler is bound,
/// so there is a window in which the app knows about the file and cannot run it.
/// `drain()` is called again from `startup()` for exactly that reason.
///
/// Deliberately not an ObservableObject: nothing draws from it. What it has is a
/// log file, because an installer that does not start leaves no other trace on a
/// device, and "nothing happened" and "it ran and failed quietly" are otherwise
/// the same report.
@MainActor
final class IncomingInstaller {
    static let shared = IncomingInstaller()

    /// A public read-only answer to "did it work", for a caller that wants to
    /// report it. Nil when nothing has been opened yet.
    private(set) var problem: String?
    private(set) var started: String?

    private var pending: URL?

    /// The app's URL handler. `madeira://` is the JIT shortcut's and is handled
    /// before this is reached; this takes file URLs, and ignores anything else
    /// rather than guessing what it is.
    func handle(_ url: URL) {
        guard url.isFileURL else { return }
        pending = url
        drain()
    }

    /// Start the pending file, if there is one and the app can start anything.
    ///
    /// A no-op while `launchHandler` is nil: the file stays pending and startup()
    /// calls this again. Dropping it here instead would be a silent loss, which
    /// is the bug this whole type is the fix for.
    func drain() {
        guard let url = pending, WindowsInstallerBridge.shared.launchHandler != nil else { return }
        pending = nil
        // A file from another app's container or from iCloud needs an explicit
        // security scope; a file in Madeira's own Documents does not, and the
        // call is harmless then.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let staged = try WindowsInstallerBridge.shared.offer(fileAt: url)
            started = url.lastPathComponent
            problem = nil
            log("started \(url.lastPathComponent) as C:\\\(staged)")
        } catch {
            started = nil
            problem = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
            log(problem ?? "unknown failure")
        }
    }

    /// Kept because an installer that does not start leaves no trace anywhere
    /// else on a device, and the log is the only way to tell "nothing happened"
    /// apart from "it ran and failed quietly".
    private func log(_ message: String) {
        guard let data = ("[Installer] " + message + "\n").data(using: .utf8) else { return }
        // Documents, not the prefix: this has to be readable from the Files app
        // when the install does not start, and drive_c is Wine's.
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent("incoming-installer.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
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
                                             includingPropertiesForKeys: [URLResourceKey.isRegularFileKey, URLResourceKey.fileSizeKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker {
                // Not Self.pathExtension: Self here is InstalledAppsStore, which
                // has no such member. The helper lives on WindowsInstallerBridge.
                guard WindowsInstallerBridge.pathExtension(of: url.lastPathComponent) == "exe" else { continue }
                let relative = url.path.replacingOccurrences(of: LibraryModel.drive.path + "/", with: "")
                guard !seen.insert(relative).inserted else { continue }
                let size = (try? url.resourceValues(forKeys: [URLResourceKey.fileSizeKey]).fileSize).map(Int64.init) ?? 0
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