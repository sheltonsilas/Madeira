// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// JitManager.swift - one place that answers "is JIT on?", shared by both
// variants.
//
// WHY THIS EXISTS SEPARATELY FROM JITSetup.swift
// Upstream already contains everything needed to turn JIT on:
//   * app/Frameworks/StikJIT.xcframework (StikJIT 1.9.0, MPL-2.0)
//   * MadeiraJITHelper.appex - a separate process, because a process cannot
//     synchronously debug itself
//   * build/rppairing-ios -> libmadeira_rppairing.a - on-device pairing
//   * JITSetup.swift - the pairing file, LocalDevVPN and DDI wizard
//   * JITAllocator.c - the dual-mapped RW/RX JIT pool and the C probes below
//
// So Section 6 of the brief ("embed StikDebug rather than deep-link to it") is
// ALREADY SATISFIED UPSTREAM, and by the MPL-2.0 StikJIT framework rather than
// by AGPL StikDebug code. That matters for licensing: StikDebug the *app* is
// AGPL-3.0, but the embeddable StikJIT framework is MPL-2.0, so embedding it
// does not drag the whole fork into AGPL. This file adds only the thin layer
// the brief asks for on top of that: a status object both variants read, and a
// StikDebug deep link as the secondary path.
//
// The probes come straight from app/Madeira/JITAllocator.h, which is already in
// Madeira-Bridging-Header.h.
//
// OVERLAP WITH UPSTREAM, STATED PLAINLY
// ContentView.swift already has its own `JITStatus` enum, an
// `isDebuggerAttached()` probe and a `JITCoordinator`. This type does not
// replace any of that: it is the variant-shared layer that sits on top of the
// same C probes, so the browser screen and the Linux environment manager can
// read JIT state without reaching into ContentView's private state. If upstream
// later promotes its own status to a shared type, this file should collapse
// into it rather than live alongside it.

import Foundation
import os.log
import Security
import UIKit

/// Live JIT status for this process.
enum JITStatus: Equatable {
    /// A debugger is attached and the MAP_JIT pool works. FEX will JIT.
    case ready
    /// No debugger attached, but the pool still maps and runs code.
    /// Seen briefly when a helper enables JIT and then detaches.
    case transitioning
    /// No JIT. FEX must fall back to its interpreter.
    case off(reason: JITOffReason)

    var isOn: Bool { self == .ready }

    var symbol: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .transitioning: return "arrow.triangle.2.circlepath"
        case .off: return "xmark.circle.fill"
        }
    }
}

/// Why JIT is unavailable, so the UI can say something useful instead of "off".
enum JITOffReason: Equatable {
    /// Not signed `get-task-allow`. Sideloaders that strip it can cause this.
    case notDebuggable
    /// The app extension that attaches the debugger is missing. Some sideloaders
    /// drop app extensions unless you tell them to keep them.
    case helperMissing
    /// Signed correctly, but no debugger is attached and none could be started.
    case debuggerNotAttached
    /// The MAP_JIT pool could not be created even though we are debuggable.
    case poolUnavailable

    var explanation: String {
        switch self {
        case .notDebuggable:
            return "This build is not signed as debuggable (no get-task-allow entitlement), so iOS will not let it create executable memory. Re-sign it with Sideloadly or SideStore and keep the entitlements."
        case .helperMissing:
            return "The JIT helper extension was not installed. Your sideloader probably dropped app extensions - re-install and choose to keep them."
        case .debuggerNotAttached:
            return "No debugger is attached, so iOS has not allowed executable memory. Open StikDebug (or use the built-in helper) to enable JIT."
        case .poolUnavailable:
            return "The app is debuggable but the JIT memory pool could not be created. The device may be low on memory, or the Developer Disk Image may be stale."
        }
    }
}

/// Observes JIT state and coordinates enabling it.
///
/// Deliberately a plain `@MainActor` observable object rather than a singleton
/// with hidden state, so a test can drive it and so the environment manager and
/// the game library can both read the same status.
@MainActor
final class JitManager: ObservableObject {
    @Published private(set) var status: JITStatus = .off(reason: .debuggerNotAttached)
    @Published private(set) var isEnabling = false

    /// When the user has explicitly chosen the interpreter-only fallback.
    /// UTM SE does the same thing: it drops the JIT and runs an interpreter,
    /// which works everywhere but is much slower.
    @AppStorage("madeira.forceInterpreter") private(set) var forceInterpreter = false

    private let log = Logger(subsystem: "com.madeira.emulator", category: "jit")
    private var pollTask: Task<Void, Never>?

    // MARK: Detection

    /// Re-read the real JIT state from the kernel.
    ///
    /// Two independent probes, because either can lie on its own:
    ///   1. `jit_check_debugged()` - csops CS_DEBUGGED on our own pid.
    ///   2. `jit_test_mapping()`  - can we actually create a MAP_JIT region?
    /// Only the second proves iOS will give us executable memory. A debugger
    /// can be attached and still not have granted it, and a pool can outlive
    /// the debugger that created it for a moment before it is torn down.
    @discardableResult
    func refresh() -> JITStatus {
        let debugged = jit_check_debugged()
        let mappable = jit_test_mapping()

        let newStatus: JITStatus
        if debugged && mappable {
            newStatus = .ready
        } else if debugged {
            // Attached but the pool will not map: the debugger is there but has
            // not done its job yet. This is the normal in-between state while
            // the helper script is running.
            newStatus = .transitioning
        } else if !debuggableSignature {
            newStatus = .off(reason: .notDebuggable)
        } else if !helperIsInstalled {
            newStatus = .off(reason: .helperMissing)
        } else if !mappable {
            newStatus = .off(reason: .poolUnavailable)
        } else {
            newStatus = .off(reason: .debuggerNotAttached)
        }

        if newStatus != status {
            log.info("JIT status -> \(String(describing: newStatus), privacy: .public)")
        }
        status = newStatus
        return newStatus
    }

    /// True when the running binary carries `get-task-allow`. Without it iOS
    /// refuses executable memory no matter what else is true.
    ///
    /// Read from the embedded provisioning profile / code signature. Upstream
    /// also has EntitlementChecker.swift for the full matrix; this is the one
    /// bit that gates JIT.
    var debuggableSignature: Bool {
        if let task = SecTaskCreateFromSelf(nil) {
            let value = SecTaskCopyValueForEntitlement(
                task, "get-task-allow" as CFString, nil
            ) as? Bool
            return value ?? false
        }
        return false
    }

    /// The JIT helper app extension has to be installed next to us, because a
    /// process cannot debug itself synchronously.
    var helperIsInstalled: Bool { StikJITHelper.isAvailable }

    /// Bytes of executable memory the kernel will currently let us map.
    /// Shown in Settings so a user can tell "no JIT" from "JIT but no room".
    var availableMemory: UInt64 { jit_available_memory() }

    /// Whether FEX should compile to native code, or interpret.
    ///
    /// This is the single value the environment layer reads before starting
    /// FEX. `true` means full speed; `false` means the UTM SE style fallback.
    var shouldUseJIT: Bool { status.isOn && !forceInterpreter }

    // MARK: Enabling

    /// Try to turn JIT on, preferring the in-app helper and falling back to
    /// StikDebug. Never silently changes method after a failure: the error is
    /// surfaced so the pairing/VPN/DDI problem can actually be fixed.
    func enableJIT(preferStikDebug: Bool = false) {
        guard !isEnabling else { return }
        isEnabling = true
        defer { isEnabling = false }

        refresh()
        guard case .off = status else { return }   // already on, or coming up

        let method: JITMethod = preferStikDebug ? .stikDebug
            : (helperIsInstalled ? .builtIn : .stikDebug)

        switch method {
        case .builtIn:
            log.info("Enabling JIT through the bundled StikJIT helper")
            StikJITHelper.enableJIT { [weak self] result in
                Task { @MainActor in
                    switch result {
                    case .success: self?.refresh()
                    case .failure(let error):
                        self?.log.error("Built-in helper failed: \(error.localizedDescription)")
                        self?.refresh()
                    }
                }
            }
        case .stikDebug, .automatic:
            openStikDebug()
        }
    }

    /// Secondary path: hand off to the standalone StikDebug app.
    ///
    /// The URL format below is verified against upstream's own caller in
    /// app/Madeira/StikJITHelper.swift: scheme `stikdebug`, host `enable-jit`,
    /// carrying our bundle id, our pid and Madeira's JIT script base64-encoded.
    /// The pid targets THIS running process; it is not a request to launch a
    /// replacement instance by bundle id.
    func openStikDebug() {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let script = Bundle.main.url(forResource: "madeira-jit", withExtension: "js"),
              let scriptData = try? Data(contentsOf: script) else {
            log.error("Cannot build the StikDebug URL: bundle id or JIT script missing")
            return
        }
        var components = URLComponents()
        components.scheme = "stikdebug"
        components.host = "enable-jit"
        components.queryItems = [
            URLQueryItem(name: "bundle-id", value: bundleID),
            URLQueryItem(name: "pid", value: String(getpid())),
            URLQueryItem(name: "script-data", value: scriptData.base64EncodedString()),
        ]
        guard let url = components.url else { return }
        UIApplication.shared.open(url)
        // StikDebug attaches and then returns to us; poll so the indicator
        // turns green without the user having to pull to refresh.
        startPolling()
    }

    // MARK: Polling

    /// Watch for JIT coming up, then stop. Used after handing off to StikDebug
    /// and after launching the in-app helper.
    func startPolling(interval: Duration = .seconds(2), timeout: Duration = .seconds(90)) {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                if self.refresh().isOn { return }
                // The user may have backgrounded us; stop burning cycles.
                if Task.isCancelled { return }
            }
            _ = self?.refresh()
        }
    }

    func stopPolling() { pollTask?.cancel(); pollTask = nil }
}

// MARK: - Small accessors

/// CS_DEBUGGED and friends, for diagnostics.
func jitCSFlags() -> UInt32 {
    var flags: UInt32 = 0
    _ = jit_cs_status(&flags)
    return flags
}