//
//  TunnelRoutes.swift
//  printparty-relay
//
//  WebSocket tunnel broker: gateways connect on /v1/tunnel/:gatewayId/connect
//  and iOS clients connect on /v1/tunnel/:gatewayId/stream.  Text frames
//  from the gateway are fanned-out to all downstream iOS clients.
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
    private var _upstreams: [String: WebSocket] = [:]
    private var _downstreams: [String: [UUID: WebSocket]] = [:]

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

    // MARK: - Fan-out

    func forward(gatewayId: String, text: String) {
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
                ws.send(text)
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

    /// iOS clients connect here to receive fanned-out state frames.
    @Sendable
    func handleStream(req: Request, ws: WebSocket) {
        guard let gatewayId = req.parameters.get("gatewayId") else {
            _ = ws.close(code: .policyViolation)
            return
        }

        let broker = req.tunnelBroker
        let clientId = broker.registerDownstream(gatewayId: gatewayId, ws: ws)

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
        }
    }
}
