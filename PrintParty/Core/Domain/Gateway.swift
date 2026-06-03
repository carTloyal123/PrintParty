//
//  Gateway.swift
//  PrintParty
//
//  Persisted registration of a paired PrintParty gateway.
//
//  Only non-secret identity / connectivity info lives here. The shared
//  SymmetricKey derived during the X25519 pairing handshake is stored in
//  Keychain at `KeychainStore.gatewaySharedKeyAccount(gatewayId:)`.
//

import Foundation
import SwiftData

@Model
final class Gateway {

    /// Stable local identifier (used as the row primary key).
    @Attribute(.unique)
    var id: UUID

    /// Server-issued gateway identifier (UUID string).
    var gatewayId: String

    /// Human-friendly gateway name (e.g. "Carson's MacBook Pro").
    var displayName: String

    /// Base URL the iOS app connects to, e.g. "http://192.168.1.5:8080" or
    /// "http://localhost:8080" when running in the Simulator on the same Mac
    /// that hosts the gateway.
    var baseURL: String

    var pairedAt: Date

    /// Relay URL for remote access when not on LAN, e.g.
    /// "http://relay.example.com:9090".
    var relayURL: String?

    /// Updated whenever we successfully reach the gateway. nil until a
    /// successful health check after pairing.
    var lastSeenAt: Date?

    init(
        id: UUID = UUID(),
        gatewayId: String,
        displayName: String,
        baseURL: String,
        relayURL: String? = nil,
        pairedAt: Date = .now,
        lastSeenAt: Date? = nil
    ) {
        self.id = id
        self.gatewayId = gatewayId
        self.displayName = displayName
        self.baseURL = baseURL
        self.relayURL = relayURL
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
    }
}
