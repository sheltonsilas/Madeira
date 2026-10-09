// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// JitNetworkAdvice.swift - what LocalDevVPN needs on iOS 26.4 and later.
//
// THE BREAKAGE THIS DESCRIBES
// Everything in this app that turns JIT on ends at the same place: a TCP
// connection to this device's lockdownd at 10.7.0.1:62078, which arrives
// through LocalDevVPN's loopback tunnel (see JITNetwork.swift, which is where
// the route is actually verified). Until iOS 26.4, connecting LocalDevVPN was
// enough for that route to exist.
//
// From 26.4 it is not. The loopback route is only installed once another
// IKEv2/IPSec tunnel is already up, so LocalDevVPN reports itself connected and
// the traffic goes nowhere. That is the failure people describe as "it says I
// am not connected to Wi-Fi and/or StosVPN" while two VPN icons are visible in
// the status bar, and it is not something LocalDevVPN can fix: the SideStore
// maintainers' own position, in the issue thread where this was worked out
// (SideStore/SideStore#1222), is that the VPN app is not the problem.
//
// THE THREE WAYS OUT, IN THE ORDER THIS APP SHOULD SUGGEST THEM
//  1. Pair in Madeira. Madeira can produce its own pairing file on iOS 27 and
//     later (OnDevicePairing), which is the replacement handshake SideStore is
//     moving to. With a pairing file the single tunnel is enough again, so this
//     is not a workaround - it is the fix.
//  2. Two tunnels, in sequence: an IKEv2/IPSec VPN first, then LocalDevVPN.
//     The order is load-bearing; connecting them the other way round leaves the
//     route uninstalled and looks identical to doing nothing.
//  3. The Madeira JIT shortcut (JITNetworkShortcut), which performs the
//     sequence automatically. It exists for a user on 26.4 or 26.5 who has no
//     pairing file yet.
//
// WHAT IS DELIBERATELY NOT HERE
// No attempt to reconfigure the device's VPNs. An app cannot add a VPN
// configuration without the NetworkExtension entitlement and a signed profile,
// and pretending otherwise would be the same class of lie as a Start button
// that does not start.

import Foundation

/// When a single VPN tunnel is enough, and what to do when it is not.
enum LocalDevVPNRequirement {
    /// The version where the loopback route stopped being installed on its own.
    static let twoTunnelVersion = OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 0)

    /// True on the iOS versions where LocalDevVPN by itself carries nothing.
    ///
    /// Read from the running system rather than from a build constant, because
    /// the same binary is installed on both sides of the change.
    static var needsSecondTunnel: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(twoTunnelVersion)
    }

    /// VPNs that have been reported to work as the first tunnel. Named
    /// because "connect another VPN" is not an instruction anyone can follow,
    /// and because the requirement is narrower than that: it has to be
    /// IKEv2 or IPSec (a WireGuard or OpenVPN tunnel does not install the route
    /// the same way) and it should be IPv4, which is what the community
    /// reports as working.
    ///
    /// They are listed as reports, not as endorsements: Madeira has no
    /// relationship with any of them and receives nothing for naming them.
    static let reportedFirstTunnels = [
        "Super Unlimited Proxy (VPN Super)",
        "hide.me VPN",
        "AdGuard VPN",
    ]

    /// One line for a status row.
    static var shortRequirement: String {
        if needsSecondTunnel {
            return "Needs a second IKEv2 tunnel on iOS 26.4 or later"
        }
        return "LocalDevVPN on its own is enough on this version"
    }

    /// The full explanation, for the prerequisites section and the setup screen.
    static var explanation: String {
        if needsSecondTunnel {
            return "On iOS 26.4 and later, LocalDevVPN's loopback route is only installed once another IKEv2 tunnel is already up. Connect an IKEv2 VPN (see the list) and then LocalDevVPN, in that order, or pair in Madeira so one tunnel is enough."
        }
        return "Madeira reaches this device through LocalDevVPN's loopback. Cellular data will not carry it, and the tunnel has to be connected before Enable JIT is pressed."
    }

    /// The steps, in order, for whichever path this device can take.
    ///
    /// `pairingAvailable` comes from `OnDevicePairing.isSupported`, which is
    /// MainActor-isolated and so is read at the call site rather than here.
    static func steps(pairingAvailable: Bool) -> [(title: String, detail: String)] {
        guard needsSecondTunnel else {
            return [
                ("Connect LocalDevVPN", "Open LocalDevVPN and connect. Madeira reaches this device through its tunnel."),
                ("Enable JIT", "Press Enable JIT. StikDebug or Madeira's own helper attaches a debugger and JIT comes on."),
            ]
        }

        var steps: [(String, String)] = []
        if pairingAvailable {
            steps.append((
                "Pair in Madeira",
                "Settings, JIT, then Pair in Madeira. This makes the pairing file that replaces the two-tunnel workaround, and once it is stored one tunnel is enough."
            ))
        }
        steps.append((
            "Connect an IKEv2 VPN first",
            "One of: \(reportedFirstTunnels.joined(separator: ", ")). Turn IPv6 off if the app offers the choice. Leave it connected."
        ))
        steps.append((
            "Then connect LocalDevVPN",
            "In this order, with the first tunnel already up. The other order leaves the route uninstalled and looks exactly like doing nothing."
        ))
        steps.append((
            "Enable JIT",
            "Press Enable JIT while both are connected. The Madeira JIT shortcut in Settings, JIT does this sequence for you."
        ))
        return steps
    }
}
