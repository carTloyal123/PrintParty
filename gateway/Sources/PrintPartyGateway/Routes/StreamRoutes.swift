//
//  StreamRoutes.swift
//  printparty-gateway
//
//  GET /v1/stream (WebSocket) — real-time PrintJobState updates.
//
//  On connect the gateway pushes the current state of all registered
//  printers. As new telemetry arrives, each PrintJobState is JSON-encoded
//  and sent as a text WebSocket frame.
//

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
        // Vapor's WebSocket supports onPing/onPong; we send pings on a timer.
        let pingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, !ws.isClosed else { break }
                try? await ws.sendPing()
            }
        }

        ws.onClose.whenComplete { _ in
            pingTask.cancel()
            req.logger.info("WebSocket stream disconnected (\(id))")
            Task { await req.printerService.removeWebSocket(id: id) }
        }
    }
}
