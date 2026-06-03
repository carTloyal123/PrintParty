//
//  TunnelRoutes.swift
//  printparty-relay
//
//  WebSocket tunnel broker: gateways connect on /v1/tunnel/:gatewayId/connect
//  and iOS clients connect on /v1/tunnel/:gatewayId/stream.
//
//  Bidirectional routing:
//  - Gateway → Relay: tagged frames "<tag>:<payload>". Tag "*" = broadcast,
//    UUID tag = route to specific client only.
//  - Client → Relay → Gateway: client sends raw frame, relay prepends
//    "<clientId>:" and forwards upstream to the gateway.
//

import Vapor
import Foundation
import NIOConcurrencyHelpers

// MARK: - TunnelBroker

/// Thread-safe broker using a lock instead of an actor to avoid
/// NIOLoopBound precondition failures when accessing WebSockets
/// from a different executor.
final class TunnelBroker: Sendable {

    /// One gateway WebSocket per gatewayId.
    private let _lock = NIOLock()
    nonisolated(unsafe) private var _upstreams: [String: WebSocket] = [:]
    nonisolated(unsafe) private var _downstreams: [String: [UUID: WebSocket]] = [:]

    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    // MARK: - Upstream (gateway) management

    func registerUpstream(gatewayId: String, ws: WebSocket) {
        _lock.withLock {
            if let old = _upstreams[gatewayId], !old.isClosed {
                _ = old.close()
            }
            _upstreams[gatewayId] = ws
        }
        logger.info("[Tunnel] Gateway \(gatewayId) connected (upstreams: \(_lock.withLock { _upstreams.count }))")
    }

    func unregisterUpstream(gatewayId: String, ws: WebSocket) {
        var clients: [UUID: WebSocket]?
        _lock.withLock {
            // Only unregister if the stored upstream is the same WebSocket
            // that's closing. Prevents a stale close from removing a newer connection.
            guard _upstreams[gatewayId] === ws else { return }
            _upstreams[gatewayId] = nil
            clients = _downstreams.removeValue(forKey: gatewayId)
        }
        logger.info("[Tunnel] Gateway \(gatewayId) disconnected")

        if let clients {
            for (_, ws) in clients {
                if !ws.isClosed { _ = ws.close() }
            }
        }
    }

    // MARK: - Downstream (iOS client) management

    func registerDownstream(gatewayId: String, ws: WebSocket) -> UUID {
        let clientId = UUID()
        _lock.withLock {
            _downstreams[gatewayId, default: [:]][clientId] = ws
        }
        let count = _lock.withLock { _downstreams[gatewayId]?.count ?? 0 }
        logger.info("[Tunnel] Client \(clientId) connected to gateway \(gatewayId) (downstream: \(count))")
        return clientId
    }

    func unregisterDownstream(gatewayId: String, clientId: UUID) {
        _lock.withLock {
            _downstreams[gatewayId]?[clientId] = nil
            if _downstreams[gatewayId]?.isEmpty == true {
                _downstreams[gatewayId] = nil
            }
        }
        logger.info("[Tunnel] Client \(clientId) disconnected from gateway \(gatewayId)")
    }

    // MARK: - Downstream routing (gateway → clients)

    /// Route a tagged frame from the gateway to downstream client(s).
    ///
    /// Frame format: `<tag>:<payload>`
    /// - `*` tag: broadcast payload to all downstream clients.
    /// - UUID tag: send payload to that specific client only.
    /// - Unrecognized tag: log warning and drop.
    func forward(gatewayId: String, text: String) {
        // Split on first ":" to extract the routing tag.
        guard let colonIndex = text.firstIndex(of: ":") else {
            logger.warning("[Tunnel] Frame from gateway \(gatewayId) has no routing tag — dropped")
            return
        }
        let tag = String(text[text.startIndex..<colonIndex])
        let payload = String(text[text.index(after: colonIndex)...])

        if tag == "*" {
            // Broadcast to all downstream clients.
            broadcastToAll(gatewayId: gatewayId, payload: payload)
        } else if let clientUUID = UUID(uuidString: tag) {
            // Route to a specific client.
            sendToClient(gatewayId: gatewayId, clientId: clientUUID, payload: payload)
        } else {
            logger.warning("[Tunnel] Unrecognized routing tag '\(tag)' from gateway \(gatewayId) — dropped")
        }
    }

    /// Send payload to all downstream clients for a gateway.
    private func broadcastToAll(gatewayId: String, payload: String) {
        var clients: [UUID: WebSocket]?
        _lock.withLock {
            clients = _downstreams[gatewayId]
        }
        guard let clients else { return }
        var closedIds: [UUID] = []
        for (id, ws) in clients {
            if ws.isClosed {
                closedIds.append(id)
            } else {
                ws.send(payload)
            }
        }
        if !closedIds.isEmpty {
            _lock.withLock {
                for id in closedIds {
                    _downstreams[gatewayId]?[id] = nil
                }
                if _downstreams[gatewayId]?.isEmpty == true {
                    _downstreams[gatewayId] = nil
                }
            }
        }
    }

    /// Send payload to a specific downstream client.
    private func sendToClient(gatewayId: String, clientId: UUID, payload: String) {
        var ws: WebSocket?
        _lock.withLock {
            ws = _downstreams[gatewayId]?[clientId]
        }
        guard let ws else {
            logger.warning("[Tunnel] Client \(clientId) not found for gateway \(gatewayId) — frame dropped")
            return
        }
        if ws.isClosed {
            _lock.withLock {
                _downstreams[gatewayId]?[clientId] = nil
            }
        } else {
            ws.send(payload)
        }
    }

    // MARK: - Upstream forwarding (client → gateway)

    /// Forward a frame from a downstream client to the upstream gateway.
    /// Prepends the client's UUID: `<clientId>:<text>`.
    func forwardUpstream(gatewayId: String, clientId: UUID, text: String) {
        var upstream: WebSocket?
        _lock.withLock {
            upstream = _upstreams[gatewayId]
        }
        guard let upstream, !upstream.isClosed else {
            logger.warning("[Tunnel] No upstream for gateway \(gatewayId) — client \(clientId) frame dropped")
            return
        }
        upstream.send("\(clientId):\(text)")
    }

    var upstreamCount: Int { _lock.withLock { _upstreams.count } }

    func downstreamCount(for gatewayId: String) -> Int {
        _lock.withLock { _downstreams[gatewayId]?.count ?? 0 }
    }
}

// MARK: - Vapor storage

struct TunnelBrokerKey: StorageKey {
    typealias Value = TunnelBroker
}

extension Application {
    var tunnelBroker: TunnelBroker { storage[TunnelBrokerKey.self]! }
}

extension Request {
    var tunnelBroker: TunnelBroker { application.tunnelBroker }
}

// MARK: - TunnelRoutes

struct TunnelRoutes: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let v1 = routes.grouped("v1", "tunnel")
        v1.webSocket(":gatewayId", "connect", onUpgrade: handleConnect)
        v1.webSocket(":gatewayId", "stream", onUpgrade: handleStream)
    }

    /// Gateway connects here to push state frames upstream.
    @Sendable
    func handleConnect(req: Request, ws: WebSocket) {
        guard let gatewayId = req.parameters.get("gatewayId") else {
            _ = ws.close(code: .policyViolation)
            return
        }

        // Validate API key from query string.
        let registry = req.gatewayRegistry
        guard let apiKey = req.query[String.self, at: "apiKey"],
              registry.validate(gatewayId: gatewayId, apiKey: apiKey) else {
            _ = ws.close(code: .init(codeNumber: 4001))
            return
        }

        let broker = req.tunnelBroker

        ws.onText { ws, text in
            broker.forward(gatewayId: gatewayId, text: text)
        }

        ws.onClose.whenComplete { [weak ws] _ in
            // Only unregister if THIS WebSocket is still the active upstream.
            // Prevents a stale onClose from removing a newer connection.
            guard let ws else { return }
            broker.unregisterUpstream(gatewayId: gatewayId, ws: ws)
        }

        broker.registerUpstream(gatewayId: gatewayId, ws: ws)
    }

    /// iOS clients connect here to receive fanned-out state frames
    /// and send requests upstream to the gateway.
    @Sendable
    func handleStream(req: Request, ws: WebSocket) {
        guard let gatewayId = req.parameters.get("gatewayId") else {
            _ = ws.close(code: .policyViolation)
            return
        }

        let broker = req.tunnelBroker

        // Rate-limit downstream connections per gateway.
        if broker.downstreamCount(for: gatewayId) >= 10 {
            _ = ws.close(code: .init(codeNumber: 4029))
            return
        }

        let clientId = broker.registerDownstream(gatewayId: gatewayId, ws: ws)
        let clientIP = req.remoteAddress?.ipAddress ?? "unknown"
        req.logger.info("[Tunnel] Downstream client \(clientId) connected from \(clientIP) for gateway \(gatewayId)")

        // Forward client messages upstream to the gateway.
        // The relay prepends the client's UUID so the gateway can route
        // the response back to this specific client.
        ws.onText { ws, text in
            broker.forwardUpstream(gatewayId: gatewayId, clientId: clientId, text: text)
        }

        // Periodic ping to detect dead connections.
        let pingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, !ws.isClosed else { break }
                try? await ws.sendPing()
            }
        }

        ws.onClose.whenComplete { _ in
            pingTask.cancel()
            broker.unregisterDownstream(gatewayId: gatewayId, clientId: clientId)
            req.logger.info("[Tunnel] Downstream client \(clientId) disconnected from \(clientIP) for gateway \(gatewayId)")
        }
    }
}
