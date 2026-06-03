//
//  MessageRouter.swift
//  printparty-gateway
//
//  Dispatches incoming MessageEnvelope requests by `method` string to
//  handler functions. Each handler reuses existing PrinterService and
//  health logic, encoding/decoding JSON payloads.
//

import Foundation
import Vapor

public actor MessageRouter {

    private let logger: Logger

    // Dependencies injected at init — gateway identity for health response.
    private let gatewayId: String
    private let gatewayName: String
    private let relayURL: String?

    init(gatewayId: String, gatewayName: String, relayURL: String?, logger: Logger) {
        self.gatewayId = gatewayId
        self.gatewayName = gatewayName
        self.relayURL = relayURL
        self.logger = logger
    }

    /// Route an incoming request envelope and return a response envelope.
    /// Requires PrinterService to be passed in (avoids storing a reference
    /// to the Vapor Application inside the actor).
    func route(envelope: MessageEnvelope, printerService: PrinterService) async -> MessageEnvelope {
        let requestId = envelope.id ?? UUID().uuidString

        guard envelope.type == .request else {
            return .error(id: requestId, method: envelope.method,
                          code: "invalid_type",
                          message: "Expected type 'request', got '\(envelope.type.rawValue)'")
        }

        do {
            let responseData: Data
            switch envelope.method {
            case "health":
                responseData = try await handleHealth(printerService: printerService)
            case "printers.list":
                responseData = try await handlePrintersList(printerService: printerService)
            case "printers.state":
                responseData = try await handlePrintersState(envelope: envelope, printerService: printerService)
            case "printers.register":
                responseData = try await handlePrintersRegister(envelope: envelope, printerService: printerService)
            case "printers.remove":
                responseData = try await handlePrintersRemove(envelope: envelope, printerService: printerService)
            case "activities.register":
                responseData = try await handleActivitiesRegister(envelope: envelope, printerService: printerService)
            case "printer.command":
                responseData = try await handlePrinterCommand(envelope: envelope, printerService: printerService)
            default:
                return .error(id: requestId, method: envelope.method,
                              code: "unknown_method",
                              message: "Unknown method: \(envelope.method)")
            }
            return .response(id: requestId, method: envelope.method, payload: responseData)
        } catch {
            return .error(id: requestId, method: envelope.method,
                          code: "handler_error",
                          message: error.localizedDescription)
        }
    }

    // MARK: - Handlers

    private func handleHealth(printerService: PrinterService) async throws -> Data {
        let allStates = await printerService.allStates()
        let configs = await printerService.registeredPrinters()

        struct PrinterHealth: Encodable {
            let id: UUID
            let displayName: String
            let stage: String
        }

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

        struct HealthPayload: Encodable {
            let status: String
            let version: String
            let gatewayId: String
            let gatewayName: String
            let relayURL: String?
            let time: Date
            let printers: [PrinterHealth]
        }

        let payload = HealthPayload(
            status: status,
            version: "0.1.0",
            gatewayId: gatewayId,
            gatewayName: gatewayName,
            relayURL: relayURL,
            time: Date(),
            printers: printerStatuses
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    private func handlePrintersList(printerService: PrinterService) async throws -> Data {
        let configs = await printerService.registeredPrinters()
        let states = await printerService.allStates()

        struct PrinterSummary: Encodable {
            let id: UUID
            let displayName: String
            let modelName: String
            let stage: String
            let progressPercent: Double
        }

        let summaries = configs.map { config in
            let state = states[config.id]
            return PrinterSummary(
                id: config.id,
                displayName: config.displayName,
                modelName: config.modelName,
                stage: state?.stage.rawValue ?? "unknown",
                progressPercent: state?.progressPercent ?? 0
            )
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(summaries)
    }

    private func handlePrintersState(envelope: MessageEnvelope, printerService: PrinterService) async throws -> Data {
        struct StateRequest: Decodable {
            let printerId: UUID
        }
        guard let reqPayload = envelope.decodePayload(StateRequest.self) else {
            throw MessageRouterError.invalidPayload("Expected {printerId: UUID}")
        }
        guard let state = await printerService.state(for: reqPayload.printerId) else {
            throw MessageRouterError.notFound("Printer not found: \(reqPayload.printerId)")
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(state)
    }

    private func handlePrintersRegister(envelope: MessageEnvelope, printerService: PrinterService) async throws -> Data {
        struct RegisterRequest: Decodable {
            let displayName: String
            let modelName: String
            let host: String
            let serial: String
            let accessCode: String
        }
        guard let body = envelope.decodePayload(RegisterRequest.self) else {
            throw MessageRouterError.invalidPayload("Expected {displayName, modelName, host, serial, accessCode}")
        }
        let printerId = UUID()
        let config = PrinterService.PrinterConfig(
            id: printerId,
            displayName: body.displayName,
            modelName: body.modelName,
            host: body.host,
            serial: body.serial,
            accessCode: body.accessCode
        )
        await printerService.register(config: config)

        struct RegisterResponse: Encodable {
            let printerId: UUID
            let status: String
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(RegisterResponse(printerId: printerId, status: "registered"))
    }

    private func handlePrintersRemove(envelope: MessageEnvelope, printerService: PrinterService) async throws -> Data {
        struct RemoveRequest: Decodable {
            let printerId: UUID
        }
        guard let body = envelope.decodePayload(RemoveRequest.self) else {
            throw MessageRouterError.invalidPayload("Expected {printerId: UUID}")
        }
        guard await printerService.hasRegisteredPrinter(id: body.printerId) else {
            throw MessageRouterError.notFound("Printer not found: \(body.printerId)")
        }
        await printerService.unregister(printerId: body.printerId)

        struct RemoveResponse: Encodable {
            let status: String
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(RemoveResponse(status: "unregistered"))
    }

    private func handleActivitiesRegister(envelope: MessageEnvelope, printerService: PrinterService) async throws -> Data {
        struct ActivityRequest: Decodable {
            let printerId: UUID
            let pushToken: String
            let sharedKey: String?
        }
        guard let body = envelope.decodePayload(ActivityRequest.self) else {
            throw MessageRouterError.invalidPayload("Expected {printerId, pushToken}")
        }
        await printerService.registerPushToken(
            printerId: body.printerId,
            token: body.pushToken,
            sharedKeyBase64: body.sharedKey
        )

        struct ActivityResponse: Encodable {
            let status: String
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(ActivityResponse(status: "registered"))
    }

    private func handlePrinterCommand(envelope: MessageEnvelope, printerService: PrinterService) async throws -> Data {
        struct CommandRequest: Decodable {
            let printerId: UUID
            let command: String
        }
        guard let body = envelope.decodePayload(CommandRequest.self) else {
            throw MessageRouterError.invalidPayload("Expected {printerId: UUID, command: String}")
        }

        let validCommands = ["pause", "resume", "cancel"]
        guard validCommands.contains(body.command) else {
            throw MessageRouterError.invalidPayload("Invalid command '\(body.command)'. Must be one of: \(validCommands.joined(separator: ", "))")
        }

        try await printerService.sendCommand(printerId: body.printerId, command: body.command)

        struct CommandResponse: Encodable {
            let status: String
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(CommandResponse(status: "sent"))
    }
}

// MARK: - Errors

enum MessageRouterError: Error, LocalizedError {
    case invalidPayload(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidPayload(let msg): return msg
        case .notFound(let msg): return msg
        }
    }
}

// MARK: - Vapor storage

struct MessageRouterKey: StorageKey {
    typealias Value = MessageRouter
}

extension Application {
    var messageRouter: MessageRouter { storage[MessageRouterKey.self]! }
}

extension Request {
    var messageRouter: MessageRouter { application.messageRouter }
}
