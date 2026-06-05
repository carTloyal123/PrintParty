//
//  StreamRoutes.swift
//  printparty-gateway
//
//  GET /v1/stream (WebSocket) — real-time PrintJobState updates.
//
//  All direct WebSocket clients speak the envelope protocol and receive
//  plaintext MessageEnvelope JSON. The relay/tunnel path handles
//  encryption separately via RelayTunnelClient.
//
//  On connect the gateway pushes the current state of all registered
//  printers. As new telemetry arrives, each state is broadcast as
//  MessageEnvelope events.
//

import Foundation
import Vapor

struct StreamRoutes: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let v1 = routes.grouped("v1")
        v1.webSocket("stream", onUpgrade: handleStream)
    }

    @Sendable
    func handleStream(req: Request, ws: WebSocket) async {
        let id = await req.printerService.addWebSocket(ws)
        req.logger.info("WebSocket stream connected (\(id))")

        // H-13: Enable periodic ping to detect dead connections.
        let pingTask = Task { [eventLoop = ws.eventLoop] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                let isClosed = try? await eventLoop.submit { ws.isClosed }.get()
                guard isClosed != true else { break }
                eventLoop.execute { ws.sendPing() }
            }
        }

        // Register onText handler to receive envelope requests.
        let printerService = req.printerService
        let messageRouter = req.messageRouter
        let pairingService = req.application.pairing
        let logger = req.logger

        ws.onText { ws, text in
            Task {
                await handleEnvelopeRequest(
                    text: text, ws: ws,
                    messageRouter: messageRouter,
                    printerService: printerService,
                    pairingService: pairingService,
                    logger: logger
                )
            }
        }

        ws.onClose.whenComplete { _ in
            pingTask.cancel()
            req.logger.info("WebSocket stream disconnected (\(id))")
            Task { await req.printerService.removeWebSocket(id: id) }
        }
    }
}

// MARK: - Envelope request handler (plaintext JSON envelopes)

private func handleEnvelopeRequest(
    text: String,
    ws: WebSocket,
    messageRouter: MessageRouter,
    printerService: PrinterService,
    pairingService: PairingService?,
    logger: Logger
) async {
    guard let data = text.data(using: .utf8) else {
        logger.warning("[Stream] Failed to decode text as UTF-8")
        return
    }

    do {
        let envelope = try JSONDecoder().decode(MessageEnvelope.self, from: data)

        // Check for pending key rotation for this device. On LAN the
        // envelope is plaintext so we can read deviceId directly.
        if let deviceId = envelope.deviceId, let pairingService {
            if let rotation = await pairingService.consumePendingKeyRotation(forDevice: deviceId) {
                struct KeyRotatePayload: Encodable {
                    let encryptedGroupKey: String
                    let groupKeyNonce: String
                }
                let rotatePayload = KeyRotatePayload(
                    encryptedGroupKey: rotation.encryptedKey.base64EncodedString(),
                    groupKeyNonce: rotation.nonce.base64EncodedString()
                )
                let payloadData = try JSONEncoder().encode(rotatePayload)
                let rotateEnvelope = MessageEnvelope.event(method: "key.rotate", payload: payloadData)
                let rotateData = try JSONEncoder().encode(rotateEnvelope)
                if let rotateJson = String(data: rotateData, encoding: .utf8) {
                    ws.eventLoop.execute { ws.send(rotateJson) }
                    logger.info("[Stream] Sent key.rotate to device \(deviceId) (LAN)")
                }
            }
        }

        let response = await messageRouter.route(envelope: envelope, printerService: printerService)
        let responseData = try JSONEncoder().encode(response)
        if let responseJson = String(data: responseData, encoding: .utf8) {
            ws.eventLoop.execute { ws.send(responseJson) }
        }
    } catch {
        logger.warning("[Stream] Failed to decode envelope: \(error)")
    }
}
