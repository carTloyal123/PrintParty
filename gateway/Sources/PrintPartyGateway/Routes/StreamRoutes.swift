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
//  IMPORTANT: Vapor's async WebSocket handler may start on a cooperative
//  thread pool thread, NOT the NIO event loop. ALL WebSocket operations
//  (onText, onClose, send, sendPing, isClosed) MUST be dispatched through
//  ws.eventLoop.execute/submit to avoid NIOLoopBound precondition failures.
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
        // Capture everything we need from `req` first.
        let printerService = req.printerService
        let messageRouter = req.messageRouter
        let pairingService = req.application.pairing
        let logger = req.logger
        let eventLoop = ws.eventLoop

        // Use a Sendable box so onClose can read the id once addWebSocket
        // completes. The box is only mutated before onClose fires.
        final class WebSocketIdBox: @unchecked Sendable {
            var id: UUID?
        }
        let idBox = WebSocketIdBox()

        // Register ALL WebSocket handlers through the event loop.
        // Even though handleStream is called during upgrade, Vapor's async
        // handler may resume on a cooperative thread, so we cannot assume
        // we are on the event loop.
        eventLoop.execute {
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

            ws.onClose.whenComplete { _ in
                let id = idBox.id
                if let id {
                    logger.info("WebSocket stream disconnected (\(id))")
                    Task { await printerService.removeWebSocket(id: id) }
                } else {
                    logger.info("WebSocket stream disconnected (before registration)")
                }
            }
        }

        // H-13: Periodic ping to detect dead connections.
        let pingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                let isClosed = try? await eventLoop.submit { ws.isClosed }.get()
                guard isClosed != true else { break }
                eventLoop.execute { ws.sendPing() }
            }
        }

        // NOW register with PrinterService (awaits into actor context).
        let id = await printerService.addWebSocket(ws)
        idBox.id = id
        logger.info("WebSocket stream connected (\(id))")

        // Keep alive until the WebSocket closes (Vapor expects the handler
        // to return only after the connection is done).
        _ = try? await eventLoop.submit { ws.onClose }.get().get()
        pingTask.cancel()
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

        // Check for pending key rotation for this device.
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
