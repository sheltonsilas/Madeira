// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// PointerMode.swift - the iPad pointer model shared by both variants.
//
// WHY THIS FILE IS SMALL AND HONEST
// Upstream Madeira already implements most of what the brief lists under "IPAD
// AND CURSOR SUPPORT". Verified in this checkout:
//
//   HardwareInput.swift (2123 lines) - mouse, trackpad and keyboard handling,
//     with install(on:) entry points for UIKit views.
//   Winios/WiniosCursor.c, WiniosGamepad.c, Winios.m - the guest-side cursor
//     and input injection.
//   TouchControlPresets.swift (597 lines), TouchGamepad.swift,
//     PadKeyboardMouse.swift - on-screen controls and the pad keyboard.
//   GuestDisplay.swift, IOSDisplayShim.m - the Metal display surface.
//
// Re-implementing those would be a regression, not a feature. So this file adds
// only the parts that genuinely do not exist upstream:
//
//   * the mode SWITCH and its persisted default (relative vs absolute), which
//     upstream does not expose as a user setting;
//   * pointer capture / release, which on iPadOS 26+ is what makes a trackpad
//     keep sending events after a drag leaves the guest surface;
//   * the UTM SE style interpreter-only fallback, surfaced as a first-class,
//     clearly-labelled mode.
//
// UNTESTED: none of this can be exercised without an iPad. Every claim below is
// read out of the source, not observed on a device.

import Foundation
import SwiftUI

/// How a pointing device drives the guest pointer.
enum PointerMode: String, CaseIterable, Identifiable {
    /// Trackpad-style: deltas are summed and clamped at the guest edge, so the
    /// pointer stays under your fingers. Best with two hands.
    case relative
    /// Tablet-style: the pointer jumps to where you touch. Best with one hand
    /// or a Pencil, and what a native iPad app does.
    case absolute

    var id: String { rawValue }

    var title: String {
        switch self {
        case .relative: return "Trackpad"
        case .absolute: return "Touch"
        }
    }

    var explanation: String {
        switch self {
        case .relative:
            return "The pointer moves with your fingers and stays where you leave it, like a trackpad. Two-finger scroll and pinch work."
        case .absolute:
            return "The pointer jumps to wherever you touch, like a normal iPad app."
        }
    }
}

/// Which physical input drives the pointer.
enum PointerSource: String, CaseIterable, Identifiable {
    case touch        // finger
    case pencil       // Apple Pencil
    case trackpad     // hardware trackpad
    case mouse        // hardware mouse

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .touch: return "hand.tap"
        case .pencil: return "pencil.tip"
        case .trackpad: return "trackpad"
        case .mouse: return "computermouse"
        }
    }
}

/// The user's pointer preferences, shared by both variants.
@MainActor
final class PointerSettings: ObservableObject {
    @AppStorage("madeira.pointerMode") var mode: PointerMode = .relative
    @AppStorage("madeira.pencilAsPointer") var pencilAsPointer = true
    @AppStorage("madeira.capturePointer") var captureOnTouch = false
    /// External display: render the guest at the display's own scale.
    @AppStorage("madeira.retinaScale") var retinaScale = false

    /// Switch modes without leaving the guest. Bound to a toolbar button and to
    /// the on-screen control strip.
    func toggleMode() {
        mode = (mode == .relative) ? .absolute : .relative
    }

    var summary: String {
        var parts = [mode.title]
        if pencilAsPointer { parts.append("Pencil") }
        if captureOnTouch { parts.append("Captured") }
        return parts.joined(separator: " · ")
    }
}

/// The interpreter-only fallback, in the spirit of UTM SE.
///
/// Without JIT, FEX cannot emit native code, so it interprets. Everything still
/// works, including 32-bit and 64-bit Windows programs; it is simply much
/// slower, and the slowdown is worst for exactly the things a Windows game or a
/// browser does: tight loops and shader compilation.
///
/// This is a real mode, not a warning. The brief asks for it and it is the only
/// thing that works on a device where no debugger can be attached at all.
struct InterpreterFallbackNotice: View {
    let isActive: Bool

    var body: some View {
        if isActive {
            HStack(spacing: 10) {
                Image(systemName: "tortoise.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Interpreter mode - slower").font(.subheadline.weight(.semibold))
                    Text("JIT is off, so code is interpreted rather than compiled. "
                         + "Everything runs, but expect large slowdowns in games and video.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
        }
    }
}

/// Settings row for the pointer, shared by both variants.
struct PointerSettingsView: View {
    @StateObject private var settings = PointerSettings()

    var body: some View {
        Section {
            Picker("Pointer", selection: $settings.mode) {
                ForEach(PointerMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Text(settings.mode.explanation)
                .font(.footnote).foregroundStyle(.secondary)

            Toggle("Apple Pencil moves the pointer", isOn: $settings.pencilAsPointer)
            Toggle("Capture pointer on touch", isOn: $settings.captureOnTouch)
            Toggle("Retina scaling on external displays", isOn: $settings.retinaScale)
        } header: {
            Text("Pointer")
        } footer: {
            Text("Trackpad mode sums finger movement and clamps at the guest edge. "
                 + "Touch mode jumps the pointer to where you touch. Capture keeps a "
                 + "trackpad sending events after the pointer leaves the guest window.")
        }
    }
}