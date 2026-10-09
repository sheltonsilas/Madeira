// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// MadeiraComponents.swift - the parts the new interface is assembled from.
//
// WHY A FILE OF PIECES AND NOT JUST VIEWS
// The old screens grew by each one inventing its own row, its own tile, its own
// badge. That is why they read as assembled rather than designed: three
// different greys, two corner radii, four ways to say "this is not installed".
// Everything the new interface draws comes from here, so a change to the
// corner radius or the accent is one edit and not twenty.
//
// WHAT IS DELIBERATELY NOT HERE
// Anything that touches the guest. These are presentation only: no session
// state, no engine calls, no store writes. A component that starts something is
// a screen, and screens live in their own files.

import SwiftUI

// MARK: - Palette

extension MadeiraTheme {
    /// The brand wash, used behind the wordmark and on a running machine's
    /// tile. Two stops rather than a colour so the interface has a light source
    /// instead of a flat fill.
    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [accent, Color(red: 0x4C / 255.0, green: 0x3A / 255.0, blue: 0xC8 / 255.0)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// A machine tile's background when nothing is running: quiet, so the
    /// running one is the only bright thing on the screen.
    static var idleGradient: LinearGradient {
        LinearGradient(
            colors: [Color.primary.opacity(0.10), Color.primary.opacity(0.04)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// The surface a sidebar row is drawn on when selected.
    static var selectedFill = accent.opacity(0.16)

    /// Green for "running", amber for "needs attention", grey for "off".
    static let running = Color(red: 0.30, green: 0.82, blue: 0.52)
    static let idle = Color.primary.opacity(0.45)

    /// A wider rhythm than `gap`, for the space between sections rather than
    /// between things inside one.
    static let sectionGap: CGFloat = 22

    static func title() -> Font { .system(.largeTitle, design: .rounded).weight(.bold) }
    static func wordmark() -> Font { .system(.title3, design: .rounded).weight(.heavy) }

    /// Small caps used on section headers. `tracking` is what makes it read as a
    /// label rather than as a heading that lost its size.
    static func label() -> Font { .system(.caption, design: .rounded).weight(.semibold) }
}

// MARK: - Section header

/// A heading with an optional count and an optional action on the right.
///
/// The action is a `Button`, not a closure returning a view, because the only
/// thing any of these need is "go there" or "add one".
struct MadeiraSectionHeader: View {
    let title: String
    var count: Int?
    var actionTitle: String?
    var actionSymbol: String = "plus"
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(MadeiraTheme.label())
                .tracking(0.9)
                .foregroundStyle(.secondary)
            if let count {
                Text("\(count)")
                    .font(MadeiraTheme.label())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(action: action) {
                    Label(actionTitle, systemImage: actionSymbol)
                        .font(MadeiraTheme.label())
                }
                .buttonStyle(.plain)
                .foregroundStyle(MadeiraTheme.accent)
            }
        }
        .padding(.horizontal, 2)
    }
}

// MARK: - Status

/// A machine's state, as a dot and a word.
///
/// A dot rather than a coloured word because colour alone is not a state: it
/// says nothing to a reader who cannot tell amber from green, and it says
/// nothing at all in a screenshot.
struct MadeiraStatusChip: View {
    enum Level {
        case running
        case ready
        case attention
        case off

        var tint: Color {
            switch self {
            case .running: return MadeiraTheme.running
            case .ready: return MadeiraTheme.accent
            case .attention: return MadeiraTheme.warning
            case .off: return MadeiraTheme.idle
            }
        }
    }

    let level: Level
    let text: String
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(level.tint)
                .frame(width: 7, height: 7)
            Text(text)
                .font(MadeiraTheme.label())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 3 : 5)
        .background(Capsule().fill(level.tint.opacity(0.14)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

// MARK: - Icon tile

/// The square that stands in for a program's icon.
///
/// It draws the first letter over a gradient derived from the name, because a
/// library entry often has no cover and a grid of identical grey squares reads
/// as a bug. Deriving the colour from the name means the same program is always
/// the same colour without storing one.
struct MadeiraIconTile: View {
    let name: String
    var systemImage: String?
    var size: CGFloat = 44

    /// A hue from the name. Cheap, stable, and deliberately not the accent:
    /// the accent is for actions, and an icon that uses it looks like a button.
    private var hue: Double {
        var hash: UInt64 = 5381
        for byte in name.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return Double(hash % 360) / 360.0
    }

    private var gradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.55, brightness: 0.85),
                Color(hue: hue, saturation: 0.70, brightness: 0.55),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(gradient)
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                Text(initial)
                    .font(.system(size: size * 0.44, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }

    private var initial: String {
        for character in name where character.isLetter || character.isNumber {
            return String(character).uppercased()
        }
        return "?"
    }
}

// MARK: - Machine tile

/// The large picture on a machine card: a gradient field with the guest's
/// glyph in it.
///
/// There is no live thumbnail. A real screenshot of a running guest would be a
/// second render of a framebuffer that already has a whole view hierarchy
/// attached to it, and the point of this screen is to start one, not to watch
/// one. When there is nothing to show, showing nothing honestly is better than
/// showing a stale frame.
struct MadeiraMachineCanvas: View {
    let symbol: String
    var running: Bool
    var height: CGFloat = 132

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: MadeiraTheme.corner, style: .continuous)
                .fill(running ? AnyShapeStyle(MadeiraTheme.brandGradient) : AnyShapeStyle(MadeiraTheme.idleGradient))
            Image(systemName: symbol)
                .font(.system(size: height * 0.30, weight: .light))
                .foregroundStyle(running ? Color.white.opacity(0.92) : Color.secondary)
            if running {
                // A single sweep of light, so a running machine looks alive in a
                // still screenshot. Static, not animated: an animation here
                // would cost a frame's worth of the GPU the guest is using.
                RoundedRectangle(cornerRadius: MadeiraTheme.corner, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Detail row

/// One "label - value" line, used by the machine pages.
struct MadeiraStatRow: View {
    let label: String
    let value: String
    var symbol: String?
    var tint: Color?

    var body: some View {
        HStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint ?? MadeiraTheme.accent)
                    .frame(width: 20)
            }
            Text(label)
                .font(MadeiraTheme.body())
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(MadeiraTheme.body())
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Empty state

/// A block that says what is missing and offers the one thing to do about it.
struct MadeiraEmptyState: View {
    let title: String
    let message: String
    let symbol: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(MadeiraTheme.accent.opacity(0.85))
            Text(title)
                .font(MadeiraTheme.heading())
            Text(message)
                .font(MadeiraTheme.caption())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let actionTitle, let action {
                MadeiraPill(title: actionTitle, systemImage: "plus", action: action)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .background(MadeiraTheme.surface, in: RoundedRectangle(cornerRadius: MadeiraTheme.corner, style: .continuous))
    }
}

// MARK: - Sidebar row

/// One row in the shell's sidebar. Selection is the accent wash plus a weight
/// change, because on a large screen a single colour difference is easy to miss.
struct MadeiraSidebarRow: View {
    let title: String
    let symbol: String
    var badge: Int?
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 22)
                .foregroundStyle(selected ? MadeiraTheme.accent : .secondary)
            Text(title)
                .font(MadeiraTheme.body())
                .fontWeight(selected ? .semibold : .regular)
            Spacer(minLength: 6)
            if let badge, badge > 0 {
                Text("\(badge)")
                    .font(MadeiraTheme.label())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? MadeiraTheme.selectedFill : Color.clear)
        )
        .contentShape(Rectangle())
    }
}
