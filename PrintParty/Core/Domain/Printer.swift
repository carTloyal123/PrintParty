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
import PrintPartyKit

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

    // MARK: - Gateway configuration

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
        adapterKind: AdapterKind = .gateway,
        gatewayId: String? = nil,
        remotePrinterId: UUID? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.displayName = displayName
        self.modelName = modelName
        self.adapterKindRaw = adapterKind.rawValue
        self.gatewayId = gatewayId
        self.remotePrinterId = remotePrinterId
        self.createdAt = createdAt
    }

    var adapterKind: AdapterKind {
        AdapterKind(rawValue: adapterKindRaw) ?? .gateway
    }
}

enum AdapterKind: String, Codable, CaseIterable, Sendable {
    /// Printer managed by a paired gateway (any brand; gateway runs the adapter).
    case gateway

    var displayName: String {
        switch self {
        case .gateway: return "Gateway-Managed Printer"
        }
    }
}
