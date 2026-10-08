// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// AppVariant.swift - the single switch that turns one shared codebase into two
// ships.
//
// Both variants link the same FEX + Wine + DXMT core and the same JIT plumbing.
// They differ only in what they launch on first run and which environment
// manager is presented:
//
//   .windows  "Madeira Windows" - a persistent Wine prefix with a preinstalled
//             browser; extra apps are installed from .exe/.msi downloads.
//   .linux    "Madeira Linux"   - the FEX-backed Linux environment manager.
//
// The variant is chosen at compile time (see VARIANT below) so a single Xcode
// target can build either flavour by flipping one preprocessor define, and the
// two share every file in this directory. Nothing in here forks the UI model.

import Foundation

/// Which flavour of Madeira this build is.
enum AppVariant: String, CaseIterable, Identifiable {
    /// Wine-based Windows with a preinstalled browser and an installer flow.
    case windows
    /// FEX-backed Linux environments with a UTM-style manager.
    case linux

    var id: String { rawValue }

    /// Shown in Settings and in the environment manager's title.
    var displayName: String {
        switch self {
        case .windows: return "Madeira Windows"
        case .linux: return "Madeira Linux"
        }
    }

    var tagline: String {
        switch self {
        case .windows:
            return "Windows apps, installed from a browser"
        case .linux:
            return "Linux environments, managed like a virtual machine"
        }
    }

    /// SF Symbol used in the variant picker.
    var symbol: String {
        switch self {
        case .windows: return "display"
        case .linux: return "terminal"
        }
    }

    /// The program the app starts automatically on first run.
    ///
    /// Windows boots straight into the preinstalled browser so the very first
    /// thing a new user sees is a working desktop with a web browser in it.
    /// Linux boots into the environment manager, because there is no single
    /// "default program" until an environment has been created or imported.
    var firstRunProgram: String? {
        switch self {
        case .windows: return WindowsBrowser.programPath   // "windows/system32/browser.exe"
        case .linux: return nil
        }
    }

    /// Whether this variant shows the UTM-style environment manager as its
    /// root screen instead of the game library.
    var usesEnvironmentManager: Bool { self == .linux }
}

// MARK: - Compile-time selection

/// The variant this particular binary was compiled as.
///
/// `MADEIRA_VARIANT` is an active compilation condition set in
/// `project.pbxproj`. When it is absent (a stock checkout, or someone building
/// upstream's own target) we fall back to `.windows`, which is the variant that
/// matches Madeira's existing behaviour: a Wine prefix and a program list.
enum VariantBuild {
    static let current: AppVariant = {
        #if MADEIRA_VARIANT_LINUX
        return .linux
        #else
        return .windows
        #endif
    }()
}

/// Convenience for SwiftUI: the variant this binary was built as.
///
/// This is the DEFAULT, not the final answer. One binary now presents either
/// variant, so UI code reads the user's choice and falls back to this. See
/// `AppVariant.selectionKey`.
let activeVariant = VariantBuild.current

extension AppVariant {
    /// The UserDefaults key holding the user's chosen variant.
    ///
    /// WHY THIS EXISTS, AND WHAT IT REPLACES
    /// The two variants used to be chosen at compile time, with
    /// `MADEIRA_VARIANT_LINUX` set as a compilation condition for one of them.
    /// A search of the whole app shows that condition used in exactly ONE
    /// place - `VariantBuild.current` below. Every file in `Variant/` is
    /// compiled into the single Madeira target either way. So the "two apps"
    /// were one app built twice with a constant flipped, and neither build
    /// could present the other.
    ///
    /// Reading the choice at run time is what turns them into one app with a
    /// switch in it, which is what the brief asks for. `VariantBuild` still
    /// supplies the initial value, so an IPA built for Linux still opens as
    /// Linux and nothing changes for anyone who never touches the switch.
    static let selectionKey = "madeira.variant"

    /// The variant to present, given whatever is stored.
    ///
    /// Falls back rather than force-unwrapping: a value written by a future
    /// build, or a corrupt default, must not leave the app with no variant to
    /// show at all.
    static func resolve(storedRawValue: String) -> AppVariant {
        AppVariant(rawValue: storedRawValue) ?? VariantBuild.current
    }
}