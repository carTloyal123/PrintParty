//
//  Printer.swift
//  PrintParty
//
//  Persisted registration of a printer the user has added.
//  Live state (PrintJobState) is NOT persisted here — that comes from
//  the adapter at runtime.
//

import Foundation
import SwiftData

@Model
final class Printer {

    /// Stable identifier used everywhere (matches PrintJobState.printerId).
    @Attribute(.unique)
    var id: UUID

    var displayName: String

    /// Marketing model name, e.g. "Bambu Lab A1 Mini".
    var modelName: String

    /// Adapter kind.
    var adapterKindRaw: String

    var createdAt: Date

    // MARK: - Adapter-specific configuration
    //
    // Optional so existing rows don't need to populate them.
    // Secrets (the LAN access code) live in Keychain, NOT here.

    /// Hostname or IP address (e.g. "192.168.1.42" or "printer.local").
    /// Used by network adapters (Bambu LAN, etc.).
    var host: String?

    /// Device serial number reported by the printer (e.g. Bambu device ID).
    /// Used as part of the MQTT topic for Bambu printers.
    var serial: String?

    /// For gateway-backed printers: the gateway's stable ID (UUID string).
    /// Used to look up the Gateway record and derive the base URL.
    var gatewayId: String?

    /// For gateway-backed printers: the printerId assigned by the gateway
    /// when the printer was registered via POST /v1/printers.
    var remotePrinterId: UUID?

    init(
        id: UUID = UUID(),
        displayName: String,
        modelName: String,
        adapterKind: AdapterKind,
        host: String? = nil,
        serial: String? = nil,
        gatewayId: String? = nil,
        remotePrinterId: UUID? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.displayName = displayName
        self.modelName = modelName
        self.adapterKindRaw = adapterKind.rawValue
        self.host = host
        self.serial = serial
        self.gatewayId = gatewayId
        self.remotePrinterId = remotePrinterId
        self.createdAt = createdAt
    }

    var adapterKind: AdapterKind {
        AdapterKind(rawValue: adapterKindRaw) ?? .gateway
    }
}

enum AdapterKind: String, Codable, CaseIterable, Sendable {
    /// Bambu Lab A1 Mini — direct LAN MQTT from the iOS device.
    case bambuLabA1Mini
    /// Printer managed by a paired gateway (any brand; gateway runs the adapter).
    case gateway

    var displayName: String {
        switch self {
        case .bambuLabA1Mini:  return "Bambu Lab A1 Mini"
        case .gateway:         return "Gateway-Managed Printer"
        }
    }
}
