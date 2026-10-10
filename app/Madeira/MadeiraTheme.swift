// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// MadeiraTheme.swift - the colour, type and spacing both variants are dressed
// in.
//
// WHY ONE FILE
// A palette spread across view files drifts: the accent in the SideStore
// source, the accent in the browser, and the accent in the environment manager
// quietly become three different blues. `tools/make_source.py` already ships
// 7B68EE as the store tint, so that is the accent, and it is named once here.
//
// DELIBERATELY BORING API
// Everything is a `static let` or a small factory. No property wrappers, no
// environment keys, no view storage: this file is read by four screens and
// compiled by a build nobody can watch, so the goal is that nothing in it can
// surprise the compiler.

import SwiftUI

enum MadeiraTheme {
    // MARK: Colour

    /// The brand accent. Must match `tintColor` in tools/make_source.py.
    static let accent = Color(red: 0x7B / 255.0, green: 0x68 / 255.0, blue: 0xEE / 255.0)

    /// The accent behind washes and selection fills, where full strength would
    /// shout next to body text.
    static let accentSoft = accent.opacity(0.18)

    /// A raised surface: cards, the download shelf, environment rows. Dark mode
    /// gets it by inverting `primary`, so one definition works in both.
    static let surface = Color.primary.opacity(0.05)

    /// One pixel of separation that reads as a line without drawing one.
    static let hairline = Color.primary.opacity(0.10)

    static let warning = Color(red: 1.00, green: 0.72, blue: 0.30)
    static let danger = Color(red: 1.00, green: 0.42, blue: 0.42)

    // MARK: Shape and spacing

    /// One corner radius. Cards that each invent their own is what makes a
    /// screen feel assembled rather than designed.
    static let corner: CGFloat = 14

    /// The vertical rhythm: section gaps, card padding, row spacing.
    static let gap: CGFloat = 12

    // MARK: Type

    /// Rounded, because the guest windows are rectangular: the contrast between
    /// the chrome and what it hosts is the whole visual idea.
    static func screenTitle() -> Font { .system(.title2, design: .rounded).weight(.bold) }
    static func heading() -> Font { .system(.headline, design: .rounded) }
    static func body() -> Font { .system(.body, design: .rounded) }
    static func caption() -> Font { .system(.caption, design: .rounded) }
    static func mono() -> Font { .system(.caption2, design: .monospaced) }

    // MARK: Applying it

    /// The accent and the surface, applied once at a screen's root.
    ///
    /// Only tint and background: navigation titles, list styling and bar items
    /// are left to SwiftUI, because overriding them here would fight the
    /// system's own adaptive behaviour instead of colouring it.
    static func chrome<Content: View>(_ content: Content) -> some View {
        content
            .tint(accent)
            .font(body())
    }
}

/// A card: the same surface, radius and padding everywhere one appears.
struct MadeiraCard<Content: View>: View {
    var padding: CGFloat = MadeiraTheme.gap
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(MadeiraTheme.surface, in: RoundedRectangle(cornerRadius: MadeiraTheme.corner))
            .overlay(
                RoundedRectangle(cornerRadius: MadeiraTheme.corner)
                    .strokeBorder(MadeiraTheme.hairline, lineWidth: 1)
            )
    }
}

/// A pill button that is not the system default, so primary actions across the
/// two variants look like one product.
struct MadeiraPill: View {
    let title: String
    let systemImage: String
    var prominent = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(MadeiraTheme.heading())
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    prominent ? MadeiraTheme.accent : MadeiraTheme.surface,
                    in: Capsule()
                )
                .foregroundStyle(prominent ? Color.white : MadeiraTheme.accent)
        }
        .buttonStyle(.plain)
    }
}
