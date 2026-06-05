//
//  PrinterService.swift
//  printparty-gateway
//
//  Manages registered printers: stores their config, runs adapters,
//  broadcasts state to all connected WebSocket clients and optionally
//  pushes to the APNs relay.
//

import Foundation
import Crypto
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Vapor

actor PrinterService {

    struct PrinterConfig: Codable, Sendable {
        let id: UUID
        let displayName: String
        let modelName: String
        let host: String
        let serial: String
        let accessCode: String
    }

    private var printers: [UUID: PrinterConfig] = [:]
    private var states: [UUID: PrintJobState] = [:]
    private var mqttClients: [UUID: NIOMQTTClient] = [:]
    private var wsClients: [UUID: WebSocket] = [:]
    private var pushTokens: [UUID: Set<String>] = [:]
    private var deviceSharedKeys: [String: String] = [:]
    private var relayURL: String?
    private let eventLoopGroup: EventLoopGroup
    private let logger: Logger
    private var tunnelClient: RelayTunnelClient?
    private var pairingService: PairingService?

    /// Per-printer reconnect attempt counter for exponential backoff.
    private var reconnectAttempts: [UUID: Int] = [:]
    /// Per-printer reconnect tasks so we can cancel them.
    private var reconnectTasks: [UUID: Task<Void, Never>] = [:]
    /// Per-printer pushall retry tasks so we can cancel them on unregister.
    private var pushallRetryTasks: [UUID: Task<Void, Never>] = [:]
    private let store: PrinterStore

    init(eventLoopGroup: EventLoopGroup, logger: Logger, relayURL: String? = nil, tunnelClient: RelayTunnelClient? = nil, pairingService: PairingService? = nil) {
        self.eventLoopGroup = eventLoopGroup
        self.logger = logger
        self.relayURL = relayURL ?? Environment.get("RELAY_URL")
        self.store = PrinterStore(logger: logger)
        self.tunnelClient = tunnelClient
        self.pairingService = pairingService
    }

    func setPairingService(_ service: PairingService) {
        self.pairingService = service
    }

    /// Load saved printers from disk and start their MQTT connections.
    /// Called once at startup from Configure.swift.
    func loadSavedPrinters() async {
        let saved = store.load()
        for config in saved {
            await register(config: config, persist: false)
        }
    }

    // MARK: - Printer registration

    func register(config: PrinterConfig, persist: Bool = true) async {
        printers[config.id] = config
        let initial = PrintJobState.idle(
            printerId: config.id,
            displayName: config.displayName,
            model: config.modelName
        )
        states[config.id] = initial
        reconnectAttempts[config.id] = 0

        let printerId = config.id
        let reportTopic = "device/\(config.serial)/report"

        let client = NIOMQTTClient(
            eventLoopGroup: eventLoopGroup,
            logger: logger,
            onMessage: { [weak self] topic, payload in
                guard topic == reportTopic else { return }
                Task { await self?.handleTelemetry(printerId: printerId, payload: payload) }
            },
            onStateChange: { [weak self] mqttState in
                Task { await self?.handleMQTTState(printerId: printerId, state: mqttState) }
            }
        )
        mqttClients[printerId] = client

        await connectPrinter(printerId: printerId, config: config, client: client)

        if persist {
            store.save(Array(printers.values))
        }
    }

    func unregister(printerId: UUID) async {
        printers[printerId] = nil
        states[printerId] = nil
        reconnectAttempts[printerId] = nil
        reconnectTasks[printerId]?.cancel()
        reconnectTasks[printerId] = nil
        pushallRetryTasks[printerId]?.cancel()
        pushallRetryTasks[printerId] = nil
        if let client = mqttClients[printerId] {
            await client.stop(reason: "unregistered")
            mqttClients[printerId] = nil
        }
        store.save(Array(printers.values))
    }

    func allStates() -> [UUID: PrintJobState] { states }
    func state(for printerId: UUID) -> PrintJobState? { states[printerId] }
    func registeredPrinters() -> [PrinterConfig] { Array(printers.values) }
    func hasRegisteredPrinter(id: UUID) -> Bool { printers[id] != nil }

    // MARK: - Printer commands

    /// Send a command (pause/resume/cancel) to a printer via MQTT.
    /// Throws if the printer is not registered or the command is invalid.
    func sendCommand(printerId: UUID, command: String) async throws {
        guard let config = printers[printerId] else {
            throw PrinterCommandError.printerNotFound(printerId)
        }
        guard let client = mqttClients[printerId] else {
            throw PrinterCommandError.notConnected(printerId)
        }

        let mqttPayload: [String: Any]
        switch command {
        case "pause":
            mqttPayload = ["print": ["command": "pause", "sequence_id": "0"]]
        case "resume":
            mqttPayload = ["print": ["command": "resume", "sequence_id": "0"]]
        case "cancel":
            mqttPayload = ["print": ["command": "stop", "sequence_id": "0"]]
        default:
            throw PrinterCommandError.invalidCommand(command)
        }

        let requestTopic = "device/\(config.serial)/request"
        guard let data = try? JSONSerialization.data(withJSONObject: mqttPayload) else {
            throw PrinterCommandError.encodingFailed
        }

        logger.info("[\(config.displayName)] Sending command '\(command)' via MQTT")
        await client.publish(topic: requestTopic, payload: data)
    }

    // MARK: - Graceful shutdown (H-16)

    /// Cleanly shuts down all MQTT connections, WebSockets, and pending tasks.
    /// Called from the Vapor LifecycleHandler on application shutdown.
    func shutdown() async {
        logger.info("PrinterService shutting down...")

        // Cancel all reconnect and pushall retry tasks
        for (_, task) in reconnectTasks { task.cancel() }
        reconnectTasks.removeAll()
        for (_, task) in pushallRetryTasks { task.cancel() }
        pushallRetryTasks.removeAll()

        // Disconnect all MQTT clients gracefully
        for (id, client) in mqttClients {
            let name = printers[id]?.displayName ?? id.uuidString
            logger.info("[\(name)] Sending MQTT DISCONNECT...")
            await client.stop(reason: "gateway shutdown")
        }
        mqttClients.removeAll()

        // Close all WebSocket connections — dispatch through each WS's
        // event loop to avoid NIOLoopBound precondition failures.
        for (id, ws) in wsClients {
            do {
                let closeFuture: EventLoopFuture<Void> = ws.eventLoop.flatSubmit {
                    guard !ws.isClosed else {
                        return ws.eventLoop.makeSucceededVoidFuture()
                    }
                    return ws.close()
                }
                try await closeFuture.get()
                logger.debug("Closed WebSocket (\(id))")
            } catch {
                logger.debug("Error closing WebSocket (\(id)): \(error)")
            }
        }
        wsClients.removeAll()

        // Stop the relay tunnel client
        if let tunnelClient {
            await tunnelClient.stop()
            self.tunnelClient = nil
        }

        logger.info("PrinterService shutdown complete.")
    }

    // MARK: - MQTT connection

    private func connectPrinter(printerId: UUID, config: PrinterConfig, client: NIOMQTTClient) async {
        let mqttConfig = NIOMQTTClient.Config(
            host: config.host,
            port: 8883,
            clientId: "ppgw-\(UUID().uuidString.prefix(8))",
            username: "bblp",
            password: config.accessCode
        )

        logger.info("[\(config.displayName)] Connecting to \(config.host):8883...")
        do {
            try await client.start(config: mqttConfig)
            // .connected callback handles subscribe + pushall
        } catch {
            logger.error("[\(config.displayName)] MQTT connect failed: \(error)")
            // Treat as a disconnect for retry purposes
            scheduleReconnect(printerId: printerId)
        }
    }

    // MARK: - MQTT event handling

    private func handleMQTTState(printerId: UUID, state: NIOMQTTClient.State) async {
        let name = printers[printerId]?.displayName ?? printerId.uuidString

        switch state {
        case .connecting:
            logger.info("[\(name)] MQTT connecting...")

        case .connected:
            logger.info("[\(name)] MQTT connected!")
            reconnectAttempts[printerId] = 0
            reconnectTasks[printerId]?.cancel()
            reconnectTasks[printerId] = nil

            guard let config = printers[printerId] else { return }
            let reportTopic = "device/\(config.serial)/report"
            let requestTopic = "device/\(config.serial)/request"

            await mqttClients[printerId]?.subscribe(topic: reportTopic)

            // pushall to get full state
            let pushall: [String: Any] = ["pushing": ["sequence_id": "1", "command": "pushall"]]
            if let data = try? JSONSerialization.data(withJSONObject: pushall) {
                await mqttClients[printerId]?.publish(topic: requestTopic, payload: data)
                // H-08: Track the retry task so it can be cancelled on unregister
                pushallRetryTasks[printerId]?.cancel()
                pushallRetryTasks[printerId] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, !Task.isCancelled else { return }
                    // Verify the printer is still registered before publishing
                    guard await self.printers[printerId] != nil else { return }
                    await self.mqttClients[printerId]?.publish(topic: requestTopic, payload: data)
                }
            }

            // Update state to show we're connected
            if var s = states[printerId], s.stage == .offline {
                s.stage = .idle
                s.errorMessage = nil
                s.updatedAt = Date()
                states[printerId] = s
                broadcastState(s)
            }

        case .disconnected(let reason):
            logger.warning("[\(name)] MQTT disconnected: \(reason)")

            if var s = states[printerId] {
                s.stage = .offline
                s.errorMessage = "Disconnected: \(reason)"
                s.updatedAt = Date()
                states[printerId] = s
                broadcastState(s)
            }

            // Only reconnect if the printer is still registered
            if printers[printerId] != nil {
                scheduleReconnect(printerId: printerId)
            }

        case .idle:
            break
        }
    }

    // MARK: - Reconnect with exponential backoff

    private func scheduleReconnect(printerId: UUID) {
        // Cancel any existing reconnect task
        reconnectTasks[printerId]?.cancel()

        let attempt = reconnectAttempts[printerId] ?? 0
        let nextAttempt = min(attempt + 1, 7)  // cap at 2^7 = 128s
        reconnectAttempts[printerId] = nextAttempt
        let delay = min(120, 2 * (1 << attempt))  // 2, 4, 8, 16, 32, 64, 120, 120...
        let name = printers[printerId]?.displayName ?? printerId.uuidString

        logger.info("[\(name)] Reconnecting in \(delay)s (attempt \(nextAttempt))")

        reconnectTasks[printerId] = Task { [weak self] in
            defer { Task { await self?.clearReconnectTask(printerId: printerId) } }
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            guard let config = await self.printers[printerId],
                  let client = await self.mqttClients[printerId] else { return }
            // H-07: connectPrinter already calls scheduleReconnect on failure,
            // so the backoff chain continues automatically.
            await self.connectPrinter(printerId: printerId, config: config, client: client)
        }
    }

    /// Clean up completed reconnect task references to avoid accumulation.
    private func clearReconnectTask(printerId: UUID) {
        // Only clear if the task is the one that just finished (avoid clearing a newer task)
        if reconnectTasks[printerId]?.isCancelled == true || reconnectTasks[printerId] == nil {
            reconnectTasks[printerId] = nil
        }
    }

    // MARK: - Telemetry

    private func handleTelemetry(printerId: UUID, payload: Data) {
        guard var current = states[printerId] else { return }
        if current.stage == .offline {
            current.stage = .idle
            current.errorMessage = nil
        }
        let merged = BambuTelemetryMapper.merge(payload: payload, into: current)
        states[printerId] = merged
        broadcastState(merged)
    }

    // MARK: - WebSocket management

    func addWebSocket(_ ws: WebSocket) -> UUID {
        let id = UUID()
        wsClients[id] = ws
        logger.info("WebSocket client connected (\(id))")
        // Send current states immediately as envelope-formatted messages
        for (_, state) in states {
            sendStateEnvelope(to: ws, state: state)
        }
        return id
    }

    func removeWebSocket(id: UUID) {
        wsClients[id] = nil
        logger.info("WebSocket client removed (\(id))")
    }

    /// Send a state to one WS client as a MessageEnvelope event.
    /// Must dispatch through the WebSocket's event loop to avoid
    /// NIOLoopBound precondition failures.
    private func sendStateEnvelope(to ws: WebSocket, state: PrintJobState) {
        logger.debug("[WS] Sending state envelope for printer \(state.printerId) to client")
        if let payloadData = try? JSONEncoder().encode(state) {
            let envelope = MessageEnvelope.event(method: "stream.state", payload: payloadData)
            if let envData = try? JSONEncoder().encode(envelope),
               let envJson = String(data: envData, encoding: .utf8) {
                ws.eventLoop.execute {
                    ws.send(envJson)
                }
            }
        }
    }

    private func broadcastState(_ state: PrintJobState) {
        logger.debug("[WS] Broadcasting state for printer \(state.printerId) to \(wsClients.count) client(s)")
        // Prepare envelope JSON once for all clients.
        guard let payloadData = try? JSONEncoder().encode(state) else { return }
        let envelope = MessageEnvelope.event(method: "stream.state", payload: payloadData)
        guard let envData = try? JSONEncoder().encode(envelope),
              let envJson = String(data: envData, encoding: .utf8) else { return }

        // WebSocket broadcast — dispatch through each WS's event loop to
        // avoid NIOLoopBound precondition failures (actor context != NIO EL).
        for (id, ws) in wsClients {
            ws.eventLoop.execute { [weak self, logger] in
                if ws.isClosed {
                    logger.debug("[WS] Client \(id) found closed during broadcast, removing")
                    Task { await self?.removeWebSocket(id: id) }
                } else {
                    ws.send(envJson)
                }
            }
        }

        // Tunnel relay: send encrypted event via tunnel.
        if let tunnelClient {
            Task { [pairingService, logger] in
                if let pairingService,
                   let groupKey = await pairingService.getGroupKey() {
                    // Encrypt the event envelope with the group key and prepend broadcast tag.
                    if let payloadData = try? JSONEncoder().encode(state) {
                        let envelope = MessageEnvelope.event(method: "stream.state", payload: payloadData)
                        if let frame = try? FrameCrypto.encryptFrame(envelope: envelope, key: groupKey) {
                            await tunnelClient.send(text: "*:" + frame)
                        } else {
                            logger.warning("[Tunnel] Failed to encrypt broadcast frame")
                        }
                    }
                } else {
                    // No group key (no paired devices yet) — skip tunnel broadcast.
                    // Relay tunnel should only carry encrypted data.
                    logger.warning("[Tunnel] No group key available, skipping tunnel broadcast (no paired devices?)")
                }
            }
        }

        // APNs relay push
        if let tokens = pushTokens[state.printerId], !tokens.isEmpty, let relay = relayURL {
            logger.debug("Relay push: \(tokens.count) token(s) for printer \(state.printerId), relay=\(relay)")
            Task { await pushToRelay(relay: relay, tokens: tokens, state: state) }
        } else {
            // Log why we're NOT pushing — helps diagnose silent relay
            let tokenCount = pushTokens[state.printerId]?.count ?? 0
            if tokenCount == 0 {
                logger.trace("No push tokens registered for printer \(state.printerId) — skipping relay push")
            } else if relayURL == nil {
                logger.trace("No RELAY_URL configured — skipping relay push")
            }
        }
    }

    // MARK: - Push token management

    func registerPushToken(printerId: UUID, token: String, sharedKeyBase64: String? = nil) {
        pushTokens[printerId, default: []].insert(token)
        if let key = sharedKeyBase64 {
            deviceSharedKeys[token] = key
        }
        logger.info("Push token registered for printer \(printerId): \(token.prefix(16))... (e2ee: \(sharedKeyBase64 != nil))")
    }

    func unregisterPushToken(printerId: UUID, token: String) {
        pushTokens[printerId]?.remove(token)
    }

    // MARK: - Relay forwarding

    // H-18: Send relay pushes concurrently using TaskGroup
    private func pushToRelay(relay: String, tokens: Set<String>, state: PrintJobState) async {
        guard let url = URL(string: relay)?.appendingPathComponent("v1/push") else { return }
        let event = state.stage.isTerminal ? "end" : "update"

        await withTaskGroup(of: Void.self) { group in
            for token in tokens {
                group.addTask { [logger, deviceSharedKeys] in
                    let contentStateJSON: Any
                    if let sharedKey = deviceSharedKeys[token],
                       let envelope = try? ContentStateEncryptor.encrypt(state: state, sharedKeyBase64: sharedKey),
                       let envelopeData = try? JSONEncoder().encode(envelope),
                       let envelopeObj = try? JSONSerialization.jsonObject(with: envelopeData) {
                        contentStateJSON = envelopeObj
                    } else if let plainData = try? JSONEncoder().encode(state),
                              let plainObj = try? JSONSerialization.jsonObject(with: plainData) {
                        contentStateJSON = plainObj
                    } else {
                        return
                    }

                    let body: [String: Any] = [
                        "deviceToken": token,
                        "contentState": contentStateJSON,
                        "event": event,
                        "timestamp": Int(Date().timeIntervalSince1970)
                    ]
                    guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }

                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.timeoutInterval = 10
                    req.httpBody = bodyData

                    do {
                        let (_, response) = try await URLSession.shared.data(for: req)
                        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                            logger.warning("Relay push returned \(http.statusCode) for token \(token.prefix(16))...")
                        }
                    } catch {
                        logger.error("Relay push failed for token \(token.prefix(16))...: \(error)")
                    }
                }
            }
        }
    }
}

// MARK: - Vapor storage

struct PrinterServiceKey: StorageKey {
    typealias Value = PrinterService
}

extension Application {
    var printerService: PrinterService { storage[PrinterServiceKey.self]! }
}

extension Request {
    var printerService: PrinterService { application.printerService }
}

// MARK: - Command errors

enum PrinterCommandError: Error, LocalizedError {
    case printerNotFound(UUID)
    case notConnected(UUID)
    case invalidCommand(String)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .printerNotFound(let id): return "Printer not found: \(id)"
        case .notConnected(let id): return "Printer not connected: \(id)"
        case .invalidCommand(let cmd): return "Invalid command: \(cmd)"
        case .encodingFailed: return "Failed to encode MQTT payload"
        }
    }
}
