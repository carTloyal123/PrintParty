//
//  RelayTunnelClient.swift
//  printparty-gateway
//
//  Outbound WebSocket client that connects to the relay's tunnel endpoint
//  and forwards PrintJobState text frames. Uses Vapor's WebSocketKit
//  (NIO-based) which works on Linux without libcurl WebSocket support.
//

import Foundation
import Vapor
import NIOCore
import NIOPosix

actor RelayTunnelClient {

    private let relayURL: String
    private let gatewayId: String
    private let logger: Logger
    private let eventLoopGroup: EventLoopGroup

    nonisolated(unsafe) private var ws: WebSocket?
    private var isRunning = false
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?

    init(relayURL: String, gatewayId: String, eventLoopGroup: EventLoopGroup, logger: Logger) {
        self.relayURL = relayURL.hasSuffix("/") ? String(relayURL.dropLast()) : relayURL
        self.gatewayId = gatewayId
        self.eventLoopGroup = eventLoopGroup
        self.logger = logger
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        logger.info("[Tunnel] Starting relay tunnel client → \(relayURL)")
        scheduleConnect(delay: 0)
    }

    func stop() {
        isRunning = false
        reconnectTask?.cancel()
        reconnectTask = nil
        if let ws, !ws.isClosed {
            _ = ws.close()
        }
        ws = nil
        logger.info("[Tunnel] Relay tunnel client stopped")
    }

    // MARK: - Send

    nonisolated func send(text: String) {
        guard let ws, !ws.isClosed else { return }
        ws.send(text)
    }

    // MARK: - Connection

    private func scheduleConnect(delay: Int) {
        guard isRunning else { return }
        reconnectTask?.cancel()

        if delay > 0 {
            logger.info("[Tunnel] Reconnecting in \(delay)s (attempt \(reconnectAttempt))")
        }

        reconnectTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard let self, !Task.isCancelled else { return }
            await self.doConnect()
        }
    }

    private func doConnect() {
        guard isRunning else { return }

        // Build the WebSocket URL
        let wsURLString: String
        if relayURL.hasPrefix("https://") {
            wsURLString = "wss://" + relayURL.dropFirst("https://".count) + "/v1/tunnel/\(gatewayId)/connect"
        } else if relayURL.hasPrefix("http://") {
            wsURLString = "ws://" + relayURL.dropFirst("http://".count) + "/v1/tunnel/\(gatewayId)/connect"
        } else {
            wsURLString = "ws://\(relayURL)/v1/tunnel/\(gatewayId)/connect"
        }

        logger.info("[Tunnel] Connecting to \(wsURLString)...")

        // WebSocket.connect's future resolves when the connection is
        // established (not when it closes). We handle the full lifecycle
        // via the ws.onClose callback registered in the setup closure.
        let future = WebSocket.connect(to: wsURLString, on: eventLoopGroup) { [weak self, logger] ws in
            logger.info("[Tunnel] Connected to relay tunnel")
            self?.ws = ws
            Task { [weak self] in await self?.resetReconnectCounter() }

            ws.onClose.whenComplete { [weak self] _ in
                logger.info("[Tunnel] Tunnel WebSocket closed")
                Task { [weak self] in await self?.handleDisconnect() }
            }
        }

        future.whenFailure { [weak self, logger] error in
            logger.warning("[Tunnel] Connection failed: \(error)")
            Task { [weak self] in await self?.handleDisconnect() }
        }
    }

    private func resetReconnectCounter() {
        reconnectAttempt = 0
    }

    private func handleDisconnect() {
        guard isRunning else { return }
        ws = nil
        reconnectAttempt = min(reconnectAttempt + 1, 7)
        let delay = min(120, 2 * (1 << (reconnectAttempt - 1)))
        scheduleConnect(delay: delay)
    }
}
