//
//  ConnectionPhase.swift
//  PrintParty
//
//  Describes how the iOS app is currently connected to a printer or gateway.
//  This is a UI-layer type — it does not affect the wire-format types
//  (PrinterStage, PrintJobState) which are shared with the gateway/relay.
//

import Foundation
import SwiftUI

/// The current connection phase for a printer adapter or gateway.
public enum ConnectionPhase: Equatable, Sendable {

    /// No connection; optionally carries a human-readable reason.
    case disconnected(reason: String? = nil)

    /// Actively attempting to connect (WebSocket upgrade, handshake, etc.).
    case connecting

    /// Live connection over the local network (LAN WebSocket to gateway).
    case connectedLAN

    /// Live connection via the remote relay tunnel.
    case connectedRelay

    /// No live connection; showing data delivered via APNs push.
    case push

    // MARK: - Convenience

    public var isConnected: Bool {
        switch self {
        case .connectedLAN, .connectedRelay: return true
        default: return false
        }
    }

    public var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }

    public var displayName: String {
        switch self {
        case .disconnected:  return "Offline"
        case .connecting:    return "Connecting\u{2026}"
        case .connectedLAN:  return "Connected"
        case .connectedRelay: return "Remote"
        case .push:          return "Push"
        }
    }

    public var symbolName: String {
        switch self {
        case .disconnected:   return "wifi.slash"
        case .connecting:     return "arrow.triangle.2.circlepath"
        case .connectedLAN:   return "wifi"
        case .connectedRelay: return "globe"
        case .push:           return "antenna.radiowaves.left.and.right"
        }
    }

    public var tint: Color {
        switch self {
        case .disconnected:   return .red
        case .connecting:     return .secondary
        case .connectedLAN:   return .green
        case .connectedRelay: return .blue
        case .push:           return .orange
        }
    }
}
