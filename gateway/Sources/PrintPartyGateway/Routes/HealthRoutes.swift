//
//  HealthRoutes.swift
//  printparty-gateway
//
//  GET /healthz — liveness probe and identity advertisement so the iOS app
//  can confirm a gateway is reachable before attempting a pairing handshake.
//

import Vapor

struct HealthRoutes: RouteCollection {

    let gatewayId: String
    let gatewayName: String
    let relayURL: String?

    func boot(routes: any RoutesBuilder) throws {
        routes.get("healthz", use: health)
    }

    @Sendable
    func health(req: Request) async throws -> HealthResponse {
        // H-24: Include per-printer connection status in health response.
        let allStates = await req.printerService.allStates()
        let configs = await req.printerService.registeredPrinters()

        let printerStatuses = configs.map { config -> PrinterHealth in
            let state = allStates[config.id]
            return PrinterHealth(
                id: config.id,
                displayName: config.displayName,
                stage: state?.stage.rawValue ?? "unknown"
            )
        }

        let allOffline = !printerStatuses.isEmpty && printerStatuses.allSatisfy { $0.stage == "offline" }
        let status = allOffline ? "degraded" : "ok"

        return HealthResponse(
            status: status,
            version: "0.1.0",
            gatewayId: gatewayId,
            gatewayName: gatewayName,
            relayURL: relayURL,
            time: Date(),
            printers: printerStatuses
        )
    }
}

struct PrinterHealth: Content {
    let id: UUID
    let displayName: String
    let stage: String
}

struct HealthResponse: Content {
    let status: String
    let version: String
    let gatewayId: String
    let gatewayName: String
    let relayURL: String?
    let time: Date
    let printers: [PrinterHealth]
}
