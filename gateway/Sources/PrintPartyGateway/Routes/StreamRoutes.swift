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
        // Capture everything we need BEFORE any `await`, while we are
        // still on the NIO event loop that owns this WebSocket.
        let printerService = req.printerService
        let messageRouter = req.messageRouter
        let pairingService = req.application.pairing
        let logger = req.logger

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

        // Register WebSocket handlers BEFORE any `await` — we are still
        // on the NIO event loop here, so onText/onClose are safe to call.
        logger.debug("[Stream] Registering WebSocket handlers (on NIO EL)")

        ws.onText { ws, text in
            logger.debug("[Stream] Received text frame (\(text.prefix(80))...)")
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

        // Use a Sendable box so onClose can read the id once addWebSocket
        // completes below. The box is only mutated before onClose fires
        // (WebSocket is still open), so no data race is possible.
        final class WebSocketIdBox: @unchecked Sendable {
            var id: UUID?
        }
        let idBox = WebSocketIdBox()

        ws.onClose.whenComplete { _ in
            pingTask.cancel()
            let id = idBox.id
            if let id {
                logger.info("WebSocket stream disconnected (\(id))")
                Task { await printerService.removeWebSocket(id: id) }
            } else {
                logger.info("WebSocket stream disconnected (before registration completed)")
            }
        }

        // NOW it is safe to await — handler registration is done.
        let id = await printerService.addWebSocket(ws)
        idBox.id = id
        logger.info("WebSocket stream connected (\(id))")
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
        logger.debug("[Stream] Routing envelope: method=\(envelope.method), id=\(envelope.id ?? "nil")")

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
            logger.debug("[Stream] Sent response for method=\(envelope.method), id=\(envelope.id ?? "nil")")
        }
    } catch {
        logger.warning("[Stream] Failed to decode envelope: \(error)")
    }
}
