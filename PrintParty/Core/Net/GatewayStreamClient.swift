//
//  GatewayStreamClient.swift
//  PrintParty
//
//  WebSocket client that subscribes to ws://<gateway>/v1/stream and yields
//  decoded PrintJobState values as an AsyncStream. Reconnects automatically
//  on disconnect with exponential backoff. Uses NWPathMonitor to detect
//  network changes and trigger immediate reconnect when Wi-Fi returns.
//
//  LAN-first with relay fallback:
//  1. Try LAN WebSocket first (baseURL → ws://host:port/v1/stream) with a 5s timeout.
//  2. On LAN failure, if relayURL and gatewayId are available, try relay tunnel:
//     ws://<relayURL>/v1/tunnel/<gatewayId>/stream
//  3. On relay failure, schedule reconnect with exponential backoff.
//  4. When on relay and Wi-Fi returns, probe LAN in the background and switch if successful.
//

import Foundation
import Network
import UIKit
import os

@MainActor
final class GatewayStreamClient {

    private static let log = Logger(subsystem: "com.clengineering.PrintParty", category: "GatewayStream")

    /// How this client is currently connected.
    enum ConnectionMode: Equatable {
        case lan
        case relay
        case disconnected
    }

    private let baseURL: URL
    private let relayURL: URL?
    private let gatewayId: String?

    private var task: URLSessionWebSocketTask?
    private let session: URLSession
    private var reconnectAttempt = 0
    private var started = false
    private var continuations: [UUID: AsyncStream<PrintJobState>.Continuation] = [:]

    /// Network path monitor — triggers immediate reconnect on network changes.
    private let pathMonitor = NWPathMonitor()
    private var lastPathStatus: NWPath.Status?
    private var reconnectTask: Task<Void, Never>?
    /// Background task that probes LAN while connected via relay.
    private var lanProbeTask: Task<Void, Never>?
    /// Foreground notification observer token.
    private var foregroundObserver: NSObjectProtocol?

    /// Whether we currently have a live WebSocket connection receiving data.
    private(set) var isConnected = false

    /// Current connection mode (LAN, relay, or disconnected).
    private(set) var connectionMode: ConnectionMode = .disconnected

    /// Called when the WebSocket disconnects. The GatewayAdapter uses this
    /// to emit an offline state to the UI immediately.
    var onDisconnect: (() -> Void)?

    /// Called when the WebSocket successfully receives its first message
    /// after a (re)connect.
    var onConnect: (() -> Void)?

    init(baseURL: URL, relayURL: URL? = nil, gatewayId: String? = nil) {
        self.baseURL = baseURL
        self.relayURL = relayURL
        self.gatewayId = gatewayId

        // Use a short timeout so connection attempts to unreachable hosts
        // fail quickly instead of hanging for 60s.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 10
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)

        // Observe network path changes on a background queue.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.handlePathUpdate(path)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.clengineering.PrintParty.pathMonitor"))

        // Re-evaluate connection when the app returns to foreground.
        // iOS kills WebSocket connections while suspended, so we need
        // to reconnect promptly rather than waiting for NWPathMonitor
        // (which may not fire if the network didn't change).
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleForeground()
            }
        }
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    func stateUpdates() -> AsyncStream<PrintJobState> {
        AsyncStream { continuation in
            let token = UUID()
            continuations[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.continuations[token] = nil
                }
            }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        reconnectAttempt = 0
        Self.log.info("GatewayStream: starting for \(self.baseURL.absoluteString, privacy: .public)")
        connect()
    }

    func stop() {
        Self.log.info("GatewayStream: stopping")
        started = false
        reconnectTask?.cancel()
        reconnectTask = nil
        lanProbeTask?.cancel()
        lanProbeTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connectionMode = .disconnected
        for (_, c) in continuations { c.finish() }
        continuations.removeAll()
    }

    // MARK: - Foreground recovery

    /// Called when the app returns to foreground. If the WebSocket is dead
    /// (which it almost certainly is after iOS suspended us), tear it down
    /// and run the full LAN-first → relay connect flow.
    private func handleForeground() {
        guard started else { return }

        if isConnected {
            // Connection might be stale — the OS likely killed it while
            // suspended. If we're on relay, also try upgrading to LAN
            // in case we came home while the app was backgrounded.
            if connectionMode == .relay {
                Self.log.info("GatewayStream: foregrounded on relay — probing LAN")
                probeLANInBackground()
            }
            // If on LAN and still "connected", the next receive will
            // fail quickly if the socket is dead, triggering reconnect.
            return
        }

        // Not connected — reconnect immediately.
        Self.log.info("GatewayStream: foregrounded while disconnected — reconnecting")
        reconnectAttempt = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connect()
    }

    // MARK: - Network change detection

    private func handlePathUpdate(_ path: NWPath) {
        let previous = lastPathStatus
        lastPathStatus = path.status

        guard started else { return }

        // If we transitioned to satisfied (network became available),
        // cancel any pending backoff timer and reconnect immediately.
        if path.status == .satisfied && previous != .satisfied {
            Self.log.info("GatewayStream: network became available — reconnecting immediately")
            reconnectAttempt = 0
            reconnectTask?.cancel()
            reconnectTask = nil

            // Tear down any stale connection attempt
            if let existing = task {
                existing.cancel(with: .goingAway, reason: nil)
                self.task = nil
            }
            connect()
        } else if path.status == .satisfied && previous == .satisfied && connectionMode == .relay {
            // Wi-Fi may have changed while on relay — probe LAN in background.
            probeLANInBackground()
        } else if path.status != .satisfied && previous == .satisfied {
            // Network went away — mark disconnected immediately
            Self.log.info("GatewayStream: network lost")
            markDisconnected()
        }
    }

    // MARK: - Connection

    private func connect() {
        guard started else { return }

        // Step 1: Try LAN first with a 5-second timeout.
        let lanURL = buildWebSocketURL(base: baseURL, path: "v1/stream")
        guard let lanURL else {
            Self.log.error("GatewayStream: invalid LAN WebSocket URL")
            tryRelayOrReconnect()
            return
        }

        Self.log.info("GatewayStream: trying LAN at \(lanURL.absoluteString, privacy: .public)")

        let lanConfig = URLSessionConfiguration.default
        lanConfig.timeoutIntervalForResource = 5
        lanConfig.waitsForConnectivity = false
        let lanSession = URLSession(configuration: lanConfig)

        let ws = lanSession.webSocketTask(with: lanURL)
        self.task = ws
        ws.resume()

        // Use a 5-second deadline for the first message. If we don't
        // receive anything within that window, consider LAN unreachable.
        let lanTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.started, self.connectionMode == .disconnected else { return }
            // Still haven't connected via LAN — cancel and try relay.
            Self.log.info("GatewayStream: LAN timeout — falling back to relay")
            ws.cancel(with: .goingAway, reason: nil)
            if self.task === ws { self.task = nil }
            self.tryRelayOrReconnect()
        }

        // Start receive loop; on first message, cancel the timeout.
        receiveLoop(ws, mode: .lan, onFirstMessage: {
            lanTimeoutTask.cancel()
        })
    }

    /// Attempt relay connection, or schedule reconnect if relay unavailable.
    private func tryRelayOrReconnect() {
        guard started else { return }

        guard let relayURL, let gatewayId else {
            Self.log.info("GatewayStream: no relay configured — scheduling reconnect")
            scheduleReconnect()
            return
        }

        let relayPath = "v1/tunnel/\(gatewayId)/stream"
        guard let wsURL = buildWebSocketURL(base: relayURL, path: relayPath) else {
            Self.log.error("GatewayStream: invalid relay WebSocket URL")
            scheduleReconnect()
            return
        }

        Self.log.info("GatewayStream: trying relay at \(wsURL.absoluteString, privacy: .public)")
        let ws = session.webSocketTask(with: wsURL)
        self.task = ws
        ws.resume()

        receiveLoop(ws, mode: .relay, onFirstMessage: nil)
    }

    private func receiveLoop(
        _ ws: URLSessionWebSocketTask,
        mode: ConnectionMode,
        onFirstMessage: (() -> Void)?
    ) {
        guard started else { return }
        ws.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.started else { return }
                switch result {
                case .success(let message):
                    if !self.isConnected {
                        self.isConnected = true
                        self.connectionMode = mode
                        Self.log.info("GatewayStream: connected via \(mode == .lan ? "LAN" : "relay", privacy: .public)")
                        onFirstMessage?()
                        self.onConnect?()
                    }
                    self.reconnectAttempt = 0
                    self.handleMessage(message)
                    self.receiveLoop(ws, mode: mode, onFirstMessage: nil)

                case .failure(let error):
                    Self.log.warning("GatewayStream: receive error — \(error.localizedDescription, privacy: .public)")
                    self.task?.cancel(with: .goingAway, reason: nil)
                    self.task = nil

                    let wasConnected = self.isConnected
                    self.markDisconnected()

                    if wasConnected && mode == .lan {
                        // LAN dropped while connected — immediately try relay.
                        self.tryRelayOrReconnect()
                    } else if !wasConnected && mode == .lan {
                        // LAN never connected (first message failed) — try relay.
                        onFirstMessage?() // cancel timeout if still running
                        self.tryRelayOrReconnect()
                    } else {
                        // Relay failed — schedule exponential backoff reconnect.
                        self.scheduleReconnect()
                    }
                }
            }
        }
    }

    // MARK: - LAN probe (triggered by NWPathMonitor while on relay)

    /// Probe the LAN WebSocket when a network change is detected while on relay.
    /// If the LAN is reachable, tear down the relay and switch back to LAN.
    /// Called only by `handlePathUpdate` — no periodic polling.
    private func probeLANInBackground() {
        lanProbeTask?.cancel()
        guard started, connectionMode == .relay else { return }

        lanProbeTask = Task { @MainActor [weak self] in
            guard let self, self.started, self.connectionMode == .relay else { return }

            guard let lanURL = self.buildWebSocketURL(base: self.baseURL, path: "v1/stream") else { return }

            Self.log.info("GatewayStream: probing LAN at \(lanURL.absoluteString, privacy: .public)")

            let probeConfig = URLSessionConfiguration.default
            probeConfig.timeoutIntervalForResource = 5
            probeConfig.waitsForConnectivity = false
            let probeSession = URLSession(configuration: probeConfig)
            let probeWs = probeSession.webSocketTask(with: lanURL)
            probeWs.resume()

            // Try to receive one message within 5s.
            do {
                let _ = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
                    group.addTask {
                        try await probeWs.receive(from: probeWs)
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(5))
                        throw CancellationError()
                    }
                    let result = try await group.next()!
                    group.cancelAll()
                    return result
                }

                // LAN is reachable! Switch over.
                guard self.started, self.connectionMode == .relay else {
                    probeWs.cancel(with: .goingAway, reason: nil)
                    return
                }

                Self.log.info("GatewayStream: LAN probe succeeded — switching from relay to LAN")

                // Tear down relay connection.
                self.task?.cancel(with: .goingAway, reason: nil)
                self.task = nil
                self.isConnected = false
                self.connectionMode = .disconnected

                // Reconnect via normal LAN-first path.
                self.reconnectAttempt = 0
                self.connect()

            } catch {
                // LAN not reachable — stay on relay. NWPathMonitor will
                // trigger another probe if the network changes again.
                Self.log.info("GatewayStream: LAN probe failed — staying on relay")
                probeWs.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    // MARK: - Helpers

    private func buildWebSocketURL(base: URL, path: String) -> URL? {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.scheme = base.scheme == "https" ? "wss" : "ws"
        return components?.url
    }

    private func markDisconnected() {
        lanProbeTask?.cancel()
        lanProbeTask = nil
        guard isConnected else { return }
        isConnected = false
        connectionMode = .disconnected
        onDisconnect?()
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let d):
            data = d
        @unknown default:
            return
        }

        guard let state = try? JSONDecoder().decode(PrintJobState.self, from: data) else {
            Self.log.warning("GatewayStream: failed to decode PrintJobState from message")
            return
        }
        for (_, c) in continuations {
            c.yield(state)
        }
    }

    private func scheduleReconnect() {
        guard started else { return }
        reconnectAttempt = min(reconnectAttempt + 1, 6)
        let delay = min(60, 1 << reconnectAttempt) // 2, 4, 8, 16, 32, 60
        Self.log.info("GatewayStream: reconnecting in \(delay)s (attempt \(self.reconnectAttempt))")
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.started else { return }
            self.connect()
        }
    }
}

// MARK: - URLSessionWebSocketTask async receive helper

private extension URLSessionWebSocketTask {
    func receive(from task: URLSessionWebSocketTask) async throws -> Message {
        try await withCheckedThrowingContinuation { continuation in
            task.receive { result in
                continuation.resume(with: result)
            }
        }
    }
}
