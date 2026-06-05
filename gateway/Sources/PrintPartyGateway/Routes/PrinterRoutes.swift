//
//  PrinterRoutes.swift
//  printparty-gateway
//
//  POST   /v1/printers          — register a new Bambu printer
//  GET    /v1/printers          — list all registered printers and their state
//  GET    /v1/printers/:id/state — get one printer's state
//  DELETE /v1/printers/:id      — unregister a printer (H-22)
//

import PrintPartyKit
import Vapor

struct PrinterRoutes: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        let v1 = routes.grouped("v1")
        v1.post("printers", use: registerPrinter)
        v1.get("printers", use: listPrinters)
        v1.get("printers", ":printerId", "state", use: getState)
        v1.delete("printers", ":printerId", use: deletePrinter)
        v1.post("activities", use: registerActivity)
    }

    // MARK: - POST /v1/printers

    struct RegisterRequest: Content {
        let displayName: String
        let modelName: String
        let host: String
        let serial: String
        let accessCode: String
    }

    struct RegisterResponse: Content {
        let printerId: UUID
        let status: String
    }

    @Sendable
    func registerPrinter(req: Request) async throws -> RegisterResponse {
        let body = try req.content.decode(RegisterRequest.self)
        let printerId = UUID()
        let config = PrinterService.PrinterConfig(
            id: printerId,
            displayName: body.displayName,
            modelName: body.modelName,
            host: body.host,
            serial: body.serial,
            accessCode: body.accessCode
        )
        await req.printerService.register(config: config)
        req.logger.info("Registered printer \(body.displayName) (\(printerId))")
        return RegisterResponse(printerId: printerId, status: "registered")
    }

    // MARK: - GET /v1/printers

    struct PrinterSummary: Content {
        let id: UUID
        let displayName: String
        let modelName: String
        let stage: String
        let progressPercent: Double
    }

    @Sendable
    func listPrinters(req: Request) async throws -> [PrinterSummary] {
        let configs = await req.printerService.registeredPrinters()
        let states = await req.printerService.allStates()
        return configs.map { config in
            let state = states[config.id]
            return PrinterSummary(
                id: config.id,
                displayName: config.displayName,
                modelName: config.modelName,
                stage: state?.stage.rawValue ?? "unknown",
                progressPercent: state?.progressPercent ?? 0
            )
        }
    }

    // MARK: - GET /v1/printers/:printerId/state

    @Sendable
    func getState(req: Request) async throws -> PrintJobState {
        guard let idStr = req.parameters.get("printerId"),
              let id = UUID(uuidString: idStr) else {
            throw Abort(.badRequest, reason: "invalid printerId")
        }
        guard let state = await req.printerService.state(for: id) else {
            throw Abort(.notFound, reason: "printer not found")
        }
        return state
    }

    // MARK: - DELETE /v1/printers/:printerId (H-22)

    struct DeleteResponse: Content {
        let status: String
    }

    @Sendable
    func deletePrinter(req: Request) async throws -> DeleteResponse {
        guard let idStr = req.parameters.get("printerId"),
              let id = UUID(uuidString: idStr) else {
            throw Abort(.badRequest, reason: "invalid printerId")
        }
        guard await req.printerService.hasRegisteredPrinter(id: id) else {
            throw Abort(.notFound, reason: "printer not found")
        }
        await req.printerService.unregister(printerId: id)
        req.logger.info("Unregistered printer \(id)")
        return DeleteResponse(status: "unregistered")
    }

    // MARK: - POST /v1/activities

    struct ActivityRequest: Content {
        let printerId: UUID
        /// Hex-encoded APNs push token from ActivityKit's pushTokenUpdates.
        let pushToken: String
        /// Optional base64-encoded shared key for E2EE. When present, the
        /// gateway encrypts content-state with ChaCha20-Poly1305 before
        /// forwarding to the relay.
        let sharedKey: String?
    }

    struct ActivityResponse: Content {
        let status: String
    }

    @Sendable
    func registerActivity(req: Request) async throws -> ActivityResponse {
        let body = try req.content.decode(ActivityRequest.self)
        await req.printerService.registerPushToken(
            printerId: body.printerId,
            token: body.pushToken,
            sharedKeyBase64: body.sharedKey
        )
        return ActivityResponse(status: "registered")
    }
}

extension PrintJobState: @retroactive Content {}
