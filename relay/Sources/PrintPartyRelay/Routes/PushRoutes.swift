//
//  PushRoutes.swift
//  printparty-relay
//
//  POST /v1/push — receives a Live Activity content-state from
//  a self-hosted gateway and forwards it to APNs using the liveactivity
//  push type. The relay NEVER decrypts the payload.
//

import Vapor
import APNS
import APNSCore
import Foundation

struct PushRoutes: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let v1 = routes.grouped("v1")
        v1.post("push", use: push)
    }

    struct PushRequest: Content {
        /// Hex-encoded APNs device token for this Live Activity.
        let deviceToken: String
        /// The content-state JSON object (opaque to the relay).
        let contentState: AnyCodable
        /// "update" or "end"
        let event: String
        /// Unix timestamp for stale-date.
        let timestamp: Int?
    }

    struct PushResponse: Content {
        let status: String
    }

    @Sendable
    func push(req: Request) async throws -> PushResponse {
        let body = try req.content.decode(PushRequest.self)
        req.logger.info("Push received: event=\(body.event) token=\(body.deviceToken.prefix(16))...")

        guard body.event == "update" || body.event == "end" else {
            throw Abort(.badRequest, reason: "event must be 'update' or 'end'")
        }

        guard let apnsClient = req.apnsClient else {
            req.logger.error("APNs client not available — cannot forward push")
            throw Abort(.serviceUnavailable, reason: "APNs not configured. Set APNS_KEY_ID, APNS_TEAM_ID, and APNS_KEY_PATH environment variables.")
        }

        let topic = req.apnsTopic
        req.logger.debug("Sending to APNs: topic=\(topic).push-type.liveactivity token=\(body.deviceToken.prefix(16))...")

        let notification = APNSLiveActivityNotification(
            expiration: .none,
            priority: .immediately,
            appID: topic,
            contentState: body.contentState,
            event: body.event == "end"
                ? .end
                : .update,
            timestamp: body.timestamp ?? Int(Date().timeIntervalSince1970)
        )

        do {
            _ = try await apnsClient.sendLiveActivityNotification(
                notification,
                deviceToken: body.deviceToken
            )
            req.logger.info("APNs push sent successfully for token \(body.deviceToken.prefix(16))...")
            return PushResponse(status: "ok")
        } catch {
            req.logger.error("APNs push failed: \(error)")
            throw Abort(.badGateway, reason: "apns_error: \(error.localizedDescription)")
        }
    }
}

/// Type-erased Codable wrapper so the relay can forward any JSON structure
/// as the content-state without knowing its shape.
struct AnyCodable: Codable, Sendable {
    let value: AnySendableValue

    enum AnySendableValue: Sendable {
        case dict([String: AnyCodable])
        case array([AnyCodable])
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
        case null
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let d = try? container.decode([String: AnyCodable].self) {
            value = .dict(d)
        } else if let a = try? container.decode([AnyCodable].self) {
            value = .array(a)
        } else if let s = try? container.decode(String.self) {
            value = .string(s)
        // H-23: Decode Bool before Int — JSON booleans can decode as Int(0/1)
        // in Swift, causing silent type coercion.
        } else if let b = try? container.decode(Bool.self) {
            value = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            value = .int(i)
        } else if let d = try? container.decode(Double.self) {
            value = .double(d)
        } else if container.decodeNil() {
            value = .null
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case .dict(let d):   try container.encode(d)
        case .array(let a):  try container.encode(a)
        case .string(let s): try container.encode(s)
        case .int(let i):    try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b):   try container.encode(b)
        case .null:          try container.encodeNil()
        }
    }
}
