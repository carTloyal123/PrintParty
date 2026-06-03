//
//  GatewayConnectionStatus.swift
//  PrintParty
//
//  Shared enum describing the reachability of a paired gateway.
//  Used by GatewayRow (SettingsView), GatewayDetailView, and
//  GatewayHealthMonitor. Replaces the duplicated private
//  ConnectionStatus enums that previously lived in each view.
//

import Foundation
import SwiftUI

enum GatewayConnectionStatus: Equatable {

    /// Not yet checked.
    case unknown

    /// Health check in progress.
    case checking

    /// Reachable directly over LAN.
    case lanOnline(version: String)

    /// LAN unreachable, but the relay tunnel path is alive.
    case lanOfflineRelayOnline

    /// LAN unreachable; relay status not yet determined or no relay configured.
    case lanOfflineRelayUnknown

    /// Both LAN and relay are unreachable.
    case offline(reason: String)

    // MARK: - Convenience

    var isOnline: Bool {
        switch self {
        case .lanOnline, .lanOfflineRelayOnline: return true
        default: return false
        }
    }

    var dotColor: Color {
        switch self {
        case .unknown, .checking, .lanOfflineRelayUnknown:
            return .gray
        case .lanOnline:
            return .green
        case .lanOfflineRelayOnline:
            return .blue
        case .offline:
            return .red
        }
    }

    var statusLabel: String {
        switch self {
        case .unknown:                    return "Unknown"
        case .checking:                   return "Checking\u{2026}"
        case .lanOnline(let v):           return "Online (v\(v))"
        case .lanOfflineRelayOnline:      return "Via Relay"
        case .lanOfflineRelayUnknown:     return "Checking relay\u{2026}"
        case .offline(let r):             return r
        }
    }

    var statusSymbol: String {
        switch self {
        case .unknown, .checking, .lanOfflineRelayUnknown:
            return "questionmark.circle"
        case .lanOnline:
            return "checkmark.circle.fill"
        case .lanOfflineRelayOnline:
            return "globe"
        case .offline:
            return "wifi.slash"
        }
    }
}
