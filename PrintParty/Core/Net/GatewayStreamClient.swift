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
//  1. Try LAN WebSocket first (baseURL → ws://host:port/v1/stream?protocol=envelope) with a 5s timeout.
//  2. On LAN failure, if relayURL and gatewayId are available, try relay tunnel:
//     ws://<relayURL>/v1/tunnel/<gatewayId>/stream
//  3. On relay failure, schedule reconnect with exponential backoff.
//  4. When on relay and Wi-Fi returns, probe LAN in the background and switch if successful.
//
//  Dual mode:
//  - LAN: send/receive plaintext JSON envelopes (MessageEnvelope)
//  - Relay: send/receive encrypted frames (<nonce>.<ciphertext>) using E2EE keys
//

import Foundation
import Network
import UIKit
import CryptoKit
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

    /// E2EE keys for relay mode. Optional — only needed when connecting via relay.
    private let sharedKey: SymmetricKey?
    private var groupKey: SymmetricKey?
    /// Device ID for this paired device (included in request envelopes).
    private let deviceId: String?

    private var task: URLSessionWebSocketTask?
    private let session: URLSession
    private var reconnectAttempt = 0
    private var started = false
    private var continuations: [UUID: AsyncStream<PrintJobState>.Continuation] = [:]

    /// Pending request/response continuations keyed by request UUID.
    private var pendingRequests: [String: CheckedContinuation<Data, Error>] = [:]

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

    // MARK: - Connection phase (single source of truth)

    /// The canonical connection phase. All UI reads ultimately derive from this.
    /// Transition rules:
    ///   - `.connecting` only from `.disconnected` (never from a connected state)
    ///   - `.connectedLAN` / `.connectedRelay` on first successful message
    ///   - `.disconnected` on network loss, stop(), or all reconnect paths exhausted
    ///   - During background LAN probes while on relay, phase stays `.connectedRelay`
    private(set) var connectionPhase: ConnectionPhase = .disconnected() {
        didSet {
            guard connectionPhase != oldValue else { return }
            onPhaseChange?()
        }
    }

    /// Called whenever `connectionPhase` changes. The GatewayAdapter uses this
    /// to re-emit state so the AdapterRegistry pump loop picks up the change.
    var onPhaseChange: (() -> Void)?

    init(
        baseURL: URL,
        relayURL: URL? = nil,
        gatewayId: String? = nil,
        sharedKey: SymmetricKey? = nil,
        groupKey: SymmetricKey? = nil,
        deviceId: String? = nil
    ) {
        self.baseURL = baseURL
        self.relayURL = relayURL
        self.gatewayId = gatewayId
        self.sharedKey = sharedKey
        self.groupKey = groupKey
        self.deviceId = deviceId

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
        connectionPhase = .connecting
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
        connectionPhase = .disconnected()
        for (_, c) in continuations { c.finish() }
        continuations.removeAll()
        // Fail all pending requests.
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: CancellationError())
        }
        pendingRequests.removeAll()
    }

    // MARK: - Request/Response API

    /// Send a request over the WebSocket and await the response.
    /// On LAN: sends a plaintext JSON envelope.
    /// On relay: encrypts with the device shared key.
    /// Timeout: 10 seconds.
    func request(_ method: String, payload: any Encodable) async throws -> Data {
        guard isConnected, let ws = task else {
            throw GatewayStreamError.notConnected
        }

        let requestId = UUID().uuidString
        let payloadData = try JSONEncoder().encode(payload)

        let envelope = MessageEnvelope.request(
            id: requestId,
            method: method,
            deviceId: deviceId,
            payload: payloadData
        )

        let frameString: String
        if connectionMode == .relay, let sharedKey {
            // Encrypt with device shared key for relay mode.
            frameString = try FrameCrypto.encryptFrame(envelope: envelope, key: sharedKey)
        } else {
            // Plaintext JSON envelope for LAN mode.
            let jsonData = try JSONEncoder().encode(envelope)
            guard let json = String(data: jsonData, encoding: .utf8) else {
                throw GatewayStreamError.encodingFailed
            }
            frameString = json
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestId] = continuation
            ws.send(.string(frameString)) { [weak self] error in
                if let error {
                    Task { @MainActor [weak self] in
                        if let pending = self?.pendingRequests.removeValue(forKey: requestId) {
                            pending.resume(throwing: error)
                        }
                    }
                }
            }

            // Timeout after 10 seconds.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                if let pending = self.pendingRequests.removeValue(forKey: requestId) {
                    pending.resume(throwing: GatewayStreamError.requestTimeout)
                }
            }
        }
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
        transitionToConnecting()
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
            transitionToConnecting()
            connect()
        } else if path.status == .satisfied && previous == .satisfied && connectionMode == .relay {
            // Wi-Fi may have changed while on relay — probe LAN in background.
            // Phase stays .connectedRelay during the probe.
            probeLANInBackground()
        } else if path.status != .satisfied && previous == .satisfied {
            // Network went away — mark disconnected immediately
            Self.log.info("GatewayStream: network lost")
            markDisconnected(reason: "Network lost")
        }
    }

    // MARK: - Connection

    private func connect() {
        guard started else { return }

        // Step 1: Try LAN first with a 5-second timeout.
        // Use ?protocol=envelope so the gateway sends plaintext envelopes.
        let lanURL = buildWebSocketURL(base: baseURL, path: "v1/stream", queryItems: [
            URLQueryItem(name: "protocol", value: "envelope")
        ])
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
                        // Update phase to reflect actual connection mode.
                        self.connectionPhase = mode == .lan ? .connectedLAN : .connectedRelay
                    }
                    self.reconnectAttempt = 0
                    self.handleMessage(message)
                    self.receiveLoop(ws, mode: mode, onFirstMessage: nil)

                case .failure(let error):
                    Self.log.warning("GatewayStream: receive error — \(error.localizedDescription, privacy: .public)")
                    self.task?.cancel(with: .goingAway, reason: nil)
                    self.task = nil

                    let wasConnected = self.isConnected
                    self.isConnected = false
                    self.connectionMode = .disconnected

                    if wasConnected && mode == .lan {
                        // LAN dropped while connected — immediately try relay.
                        // Go to .connecting since we lost the live connection.
                        self.connectionPhase = .connecting
                        self.tryRelayOrReconnect()
                    } else if !wasConnected && mode == .lan {
                        // LAN never connected (first message failed) — try relay.
                        // Phase stays .connecting (already set before connect()).
                        onFirstMessage?() // cancel timeout if still running
                        self.tryRelayOrReconnect()
                    } else {
                        // Relay failed — schedule exponential backoff reconnect.
                        self.connectionPhase = .connecting
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
    ///
    /// IMPORTANT: connectionPhase stays `.connectedRelay` throughout the probe.
    /// We only update it on success (→ `.connectedLAN`) or if relay drops independently.
    private func probeLANInBackground() {
        lanProbeTask?.cancel()
        guard started, connectionMode == .relay else { return }

        lanProbeTask = Task { @MainActor [weak self] in
            guard let self, self.started, self.connectionMode == .relay else { return }

            guard let lanURL = self.buildWebSocketURL(base: self.baseURL, path: "v1/stream", queryItems: [
                URLQueryItem(name: "protocol", value: "envelope")
            ]) else { return }

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

                // Tear down relay connection. Don't update connectionPhase yet —
                // connect() will transition to .connectedLAN on first message.
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

    // MARK: - Phase transitions

    /// Transition to `.connecting` only if currently disconnected.
    /// This prevents flashing the "connecting" banner when we're already
    /// connected and just doing a background probe or network re-check.
    private func transitionToConnecting() {
        if case .disconnected = connectionPhase {
            connectionPhase = .connecting
        }
        // If we're already .connecting, .connectedLAN, .connectedRelay, or .push,
        // don't change. The connected states will be updated by receiveLoop on
        // successful connection; disconnected will be set by markDisconnected.
    }

    /// Mark the connection as fully disconnected with a reason.
    private func markDisconnected(reason: String? = nil) {
        lanProbeTask?.cancel()
        lanProbeTask = nil
        isConnected = false
        connectionMode = .disconnected
        connectionPhase = .disconnected(reason: reason)
        // Fail all pending requests on disconnect.
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: GatewayStreamError.notConnected)
        }
        pendingRequests.removeAll()
    }

    // MARK: - Helpers

    private func buildWebSocketURL(base: URL, path: String, queryItems: [URLQueryItem]? = nil) -> URL? {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.scheme = base.scheme == "https" ? "wss" : "ws"
        if let queryItems, !queryItems.isEmpty {
            var existing = components?.queryItems ?? []
            existing += queryItems
            components?.queryItems = existing
        }
        return components?.url
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let text: String
        switch message {
        case .string(let t):
            text = t
        case .data(let d):
            text = String(data: d, encoding: .utf8) ?? ""
        @unknown default:
            return
        }

        guard !text.isEmpty else { return }

        // Route based on connection mode rather than content-sniffing.
        switch connectionMode {
        case .relay:
            // Relay mode: all frames are encrypted (<nonce>.<ciphertext>).
            handleEncryptedFrame(text)
        case .lan:
            // LAN mode: all frames are plaintext JSON envelopes.
            handlePlaintextJSON(text)
        case .disconnected:
            Self.log.warning("GatewayStream: received message while disconnected")
        }
    }

    /// Handle an encrypted relay frame: try group key (events), then shared key (responses).
    private func handleEncryptedFrame(_ frame: String) {
        // Try group key first (broadcast events are more frequent).
        if let groupKey {
            if let envelope = try? FrameCrypto.decryptFrame(frame: frame, key: groupKey) {
                processEnvelope(envelope)
                return
            }
        }
        // Try device shared key (responses to our requests).
        if let sharedKey {
            if let envelope = try? FrameCrypto.decryptFrame(frame: frame, key: sharedKey) {
                processEnvelope(envelope)
                return
            }
        }
        Self.log.warning("GatewayStream: failed to decrypt frame with either key")
    }

    /// Handle a plaintext JSON message (LAN envelope or legacy PrintJobState).
    private func handlePlaintextJSON(_ text: String) {
        let data = Data(text.utf8)

        // Try as MessageEnvelope first.
        if let envelope = try? JSONDecoder().decode(MessageEnvelope.self, from: data) {
            processEnvelope(envelope)
            return
        }

        // Legacy fallback: raw PrintJobState (from old gateways without envelope support).
        if let state = try? JSONDecoder().decode(PrintJobState.self, from: data) {
            for (_, c) in continuations {
                c.yield(state)
            }
            return
        }

        Self.log.warning("GatewayStream: failed to decode plaintext JSON message")
    }

    /// Process a decoded MessageEnvelope — route by type.
    private func processEnvelope(_ envelope: MessageEnvelope) {
        switch envelope.type {
        case .event:
            handleEventEnvelope(envelope)
        case .response:
            handleResponseEnvelope(envelope)
        case .error:
            handleErrorEnvelope(envelope)
        case .request:
            // Clients don't receive requests — log and ignore.
            Self.log.warning("GatewayStream: received unexpected request envelope")
        }
    }

    /// Handle an event envelope (e.g. stream.state with PrintJobState payload).
    private func handleEventEnvelope(_ envelope: MessageEnvelope) {
        switch envelope.method {
        case "stream.state":
            guard let state: PrintJobState = envelope.decodePayload(PrintJobState.self) else {
                Self.log.warning("GatewayStream: failed to decode PrintJobState from event payload")
                return
            }
            for (_, c) in continuations {
                c.yield(state)
            }
        case "key.rotate":
            handleKeyRotation(envelope)
        default:
            Self.log.info("GatewayStream: unhandled event method '\(envelope.method, privacy: .public)'")
        }
    }

    /// Handle a key.rotate event: decrypt the new group key with our shared key
    /// and persist it to Keychain.
    private func handleKeyRotation(_ envelope: MessageEnvelope) {
        struct KeyRotatePayload: Decodable {
            let encryptedGroupKey: String
            let groupKeyNonce: String
        }

        guard let payload = envelope.decodePayload(KeyRotatePayload.self) else {
            Self.log.warning("GatewayStream: failed to decode key.rotate payload")
            return
        }

        guard let sharedKey else {
            Self.log.warning("GatewayStream: received key.rotate but no shared key available")
            return
        }

        guard let ciphertext = Data(base64Encoded: payload.encryptedGroupKey),
              let nonceData = Data(base64Encoded: payload.groupKeyNonce) else {
            Self.log.warning("GatewayStream: key.rotate has invalid base64")
            return
        }

        do {
            let decrypted = try FrameCrypto.decrypt(ciphertext: ciphertext, nonce: nonceData, key: sharedKey)
            guard decrypted.count == 32 else {
                Self.log.warning("GatewayStream: rotated group key is not 32 bytes (\(decrypted.count))")
                return
            }

            // Update in-memory group key.
            self.groupKey = SymmetricKey(data: decrypted)
            Self.log.info("GatewayStream: group key rotated successfully")

            // Persist to Keychain if we have a gatewayId.
            if let gatewayId {
                let base64Key = decrypted.base64EncodedString()
                KeychainStore.set(base64Key, for: KeychainStore.gatewayGroupKeyAccount(gatewayId: gatewayId))
                Self.log.info("GatewayStream: persisted rotated group key to Keychain")
            }
        } catch {
            Self.log.error("GatewayStream: failed to decrypt rotated group key: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Handle a response envelope — route to pending request by id.
    private func handleResponseEnvelope(_ envelope: MessageEnvelope) {
        guard let id = envelope.id else {
            Self.log.warning("GatewayStream: response envelope missing id")
            return
        }
        guard let continuation = pendingRequests.removeValue(forKey: id) else {
            Self.log.warning("GatewayStream: no pending request for id \(id, privacy: .public)")
            return
        }
        if let data = envelope.payloadData() {
            continuation.resume(returning: data)
        } else {
            continuation.resume(throwing: GatewayStreamError.invalidPayload)
        }
    }

    /// Handle an error envelope — route to pending request by id.
    private func handleErrorEnvelope(_ envelope: MessageEnvelope) {
        guard let id = envelope.id else {
            Self.log.warning("GatewayStream: error envelope missing id")
            return
        }
        guard let continuation = pendingRequests.removeValue(forKey: id) else {
            Self.log.warning("GatewayStream: no pending request for error id \(id, privacy: .public)")
            return
        }
        let message = envelope.decodePayload(ErrorPayloadResponse.self)?.message ?? "Unknown error"
        continuation.resume(throwing: GatewayStreamError.serverError(code: envelope.method, message: message))
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

// MARK: - Error types

enum GatewayStreamError: Error, LocalizedError {
    case notConnected
    case encodingFailed
    case requestTimeout
    case invalidPayload
    case serverError(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "WebSocket not connected"
        case .encodingFailed: return "Failed to encode request"
        case .requestTimeout: return "Request timed out (10s)"
        case .invalidPayload: return "Invalid response payload"
        case .serverError(let code, let message): return "Server error [\(code)]: \(message)"
        }
    }
}

/// For decoding error response payloads.
private struct ErrorPayloadResponse: Decodable {
    let code: String?
    let message: String
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
