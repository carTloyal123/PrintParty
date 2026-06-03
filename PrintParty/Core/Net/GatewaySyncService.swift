//
//
//  GatewaySyncService.swift
//  PrintParty
//
//  Fetches the list of printers registered on a gateway via the WebSocket
//  `printers.list` request and creates local Printer records for any that
//  don't already exist. Called after pairing a new gateway and on app launch.
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

    /// Empty payload for WS requests that need no parameters.
    private struct EmptyPayload: Encodable {}

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

        let remotePrinters = await fetchRemotePrinters(gateway: gateway, baseURL: baseURL)
        guard let remotePrinters else { return 0 }

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

    // MARK: - Private

    /// Fetch printers via the WebSocket `printers.list` request.
    private static func fetchRemotePrinters(
        gateway: Gateway,
        baseURL: URL
    ) async -> [RemotePrinter]? {
        guard let adapter = AdapterRegistry.shared.gatewayAdapter(for: gateway.gatewayId),
              adapter.connectionMode != .disconnected else {
            log.info("GatewaySync: no connected adapter for \(gateway.displayName) — skipping sync")
            return nil
        }

        do {
            let data = try await adapter.request("printers.list", payload: EmptyPayload())
            let printers = try JSONDecoder().decode([RemotePrinter].self, from: data)
            log.info("GatewaySync: fetched \(printers.count) printers via WS for \(gateway.displayName)")
            return printers
        } catch {
            log.warning("GatewaySync: printers.list failed for \(gateway.displayName): \(error.localizedDescription)")
            return nil
        }
    }
}
