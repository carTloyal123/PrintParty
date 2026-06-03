//
//  GatewaySyncService.swift
//  PrintParty
//
//  Fetches the list of printers registered on a gateway and creates local
//  Printer records for any that don't already exist. Called after pairing
//  a new gateway and on app launch for existing gateways.
//

import Foundation
import SwiftData
import os

@MainActor
enum GatewaySyncService {

    private static let log = Logger(subsystem: "com.clengineering.PrintParty", category: "GatewaySync")

    struct RemotePrinter: Decodable {
        let id: UUID
        let displayName: String
        let modelName: String
        let stage: String
        let progressPercent: Double
    }

    /// Fetch printers from a gateway and create local Printer records for
    /// any that aren't already tracked. Returns the number of new printers added.
    @discardableResult
    static func syncPrinters(
        gateway: Gateway,
        modelContext: ModelContext
    ) async -> Int {
        guard let baseURL = URL(string: gateway.baseURL) else {
            log.error("GatewaySync: invalid base URL for \(gateway.displayName)")
            return 0
        }

        let url = baseURL.appendingPathComponent("v1/printers")
        var req = URLRequest(url: url)
        req.timeoutInterval = 10

        let remotePrinters: [RemotePrinter]
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                log.warning("GatewaySync: \(gateway.displayName) returned non-200")
                return 0
            }
            remotePrinters = try JSONDecoder().decode([RemotePrinter].self, from: data)
        } catch {
            log.warning("GatewaySync: failed to fetch printers from \(gateway.displayName): \(error.localizedDescription)")
            return 0
        }

        guard !remotePrinters.isEmpty else {
            log.info("GatewaySync: \(gateway.displayName) has no printers registered")
            return 0
        }

        // Fetch existing local printers for this gateway to avoid duplicates.
        let gatewayId = gateway.gatewayId
        let existingPrinters: [Printer]
        do {
            let descriptor = FetchDescriptor<Printer>(
                predicate: #Predicate { $0.gatewayId == gatewayId }
            )
            existingPrinters = (try? modelContext.fetch(descriptor)) ?? []
        }
        let existingRemoteIds = Set(existingPrinters.compactMap(\.remotePrinterId))

        var added = 0
        for remote in remotePrinters {
            guard !existingRemoteIds.contains(remote.id) else { continue }

            let printer = Printer(
                displayName: remote.displayName,
                modelName: remote.modelName,
                adapterKind: .gateway,
                gatewayId: gateway.gatewayId,
                remotePrinterId: remote.id
            )
            modelContext.insert(printer)
            added += 1
            log.info("GatewaySync: added '\(remote.displayName)' from \(gateway.displayName)")
        }

        if added > 0 {
            // Cache the gateway URL so the adapter can find it.
            if let url = URL(string: gateway.baseURL) {
                AdapterRegistry.shared.cacheGatewayURL(gatewayId: gateway.gatewayId, baseURL: url)
            }
        }

        log.info("GatewaySync: \(gateway.displayName) — \(remotePrinters.count) remote, \(added) new")
        return added
    }

    /// Sync all paired gateways. Called on app launch.
    static func syncAllGateways(
        gateways: [Gateway],
        modelContext: ModelContext
    ) async {
        for gateway in gateways {
            await syncPrinters(gateway: gateway, modelContext: modelContext)
        }
    }
}
