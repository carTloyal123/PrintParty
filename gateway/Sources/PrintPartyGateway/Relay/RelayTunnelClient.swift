//
//  RelayTunnelClient.swift
//  printparty-gateway
//
//  Outbound WebSocket client that connects to the relay's tunnel endpoint
//  and forwards PrintJobState text frames. Uses Vapor's WebSocketKit
//  (NIO-based) which works on Linux without libcurl WebSocket support.
//
//  Auto-registers with the relay on first start and stores the API key
//  on disk. Includes the API key in the tunnel connect URL. Re-registers
//  on 4001 close code (invalid/revoked key).
//

import Foundation
import Vapor
import Crypto
import NIOCore
import NIOPosix

actor RelayTunnelClient {

    private let relayURL: String
    private let gatewayId: String
    private let gatewayName: String
    private let logger: Logger
    private let eventLoopGroup: EventLoopGroup

    private var ws: WebSocket?
    private var isRunning = false
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?

    /// Loaded or freshly-obtained API key for relay access.
    private var apiKey: String?

    /// Path to the file where the relay API key is persisted.
    private let apiKeyPath: String

    /// References to MessageRouter and PairingService for handling incoming
    /// client requests forwarded by the relay.
    private var messageRouter: MessageRouter?
    private var printerService: PrinterService?
    private var pairingService: PairingService?

    /// Cache of relay clientId → deviceId mappings to avoid re-trying
    /// all keys on subsequent messages from the same client.
    private var clientDeviceMap: [String: String] = [:]

    init(relayURL: String, gatewayId: String, gatewayName: String, eventLoopGroup: EventLoopGroup, logger: Logger) {
        self.relayURL = relayURL.hasSuffix("/") ? String(relayURL.dropLast()) : relayURL
        self.gatewayId = gatewayId
        self.gatewayName = gatewayName
        self.eventLoopGroup = eventLoopGroup
        self.logger = logger

        let dataDir = ProcessInfo.processInfo.environment["PRINTPARTY_DATA_DIR"]
            ?? (NSHomeDirectory() + "/.printparty")
        self.apiKeyPath = dataDir + "/relay-api-key.txt"
    }

    /// Inject dependencies after init (avoids circular init dependencies).
    func setDependencies(messageRouter: MessageRouter, printerService: PrinterService, pairingService: PairingService) {
        self.messageRouter = messageRouter
        self.printerService = printerService
        self.pairingService = pairingService
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        logger.info("[Tunnel] Starting relay tunnel client → \(relayURL)")

        // Load stored API key from disk.
        if let stored = try? String(contentsOfFile: apiKeyPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty {
            apiKey = stored
            logger.info("[Tunnel] Loaded stored relay API key")
        }

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

    func send(text: String) {
        guard let ws, !ws.isClosed else { return }
        ws.send(text)
    }

    // MARK: - Registration

    /// Calls POST /v1/gateways/register on the relay to obtain an API key.
    /// Stores the key on disk for subsequent starts.
    private func register() async throws -> String {
        let registerURL: String
        if relayURL.hasPrefix("https://") || relayURL.hasPrefix("http://") {
            registerURL = relayURL + "/v1/gateways/register"
        } else {
            registerURL = "http://\(relayURL)/v1/gateways/register"
        }

        guard let url = URL(string: registerURL) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        struct RegisterBody: Encodable {
            let gatewayId: String
            let gatewayName: String
        }
        request.httpBody = try JSONEncoder().encode(
            RegisterBody(gatewayId: gatewayId, gatewayName: gatewayName)
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "Registration failed with HTTP \(status)"
            ])
        }

        struct RegisterResponse: Decodable {
            let apiKey: String
        }
        let decoded = try JSONDecoder().decode(RegisterResponse.self, from: data)
        let key = decoded.apiKey

        // Persist to disk.
        let dir = (apiKeyPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try key.write(toFile: apiKeyPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: apiKeyPath
        )

        logger.info("[Tunnel] Registered with relay, API key stored")
        return key
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

        // If we don't have an API key yet, register first.
        if apiKey == nil {
            Task { [weak self] in
                guard let self else { return }
                do {
                    let key = try await self.register()
                    await self.setApiKey(key)
                    await self.doConnectWithKey()
                } catch {
                    self.logger.warning("[Tunnel] Registration failed: \(error)")
                    await self.handleDisconnect()
                }
            }
            return
        }

        doConnectWithKey()
    }

    private func setApiKey(_ key: String) {
        self.apiKey = key
    }

    private func doConnectWithKey() {
        guard isRunning, let apiKey else { return }

        // Build the WebSocket URL with API key.
        let wsURLString: String
        let base: String
        if relayURL.hasPrefix("https://") {
            base = "wss://" + relayURL.dropFirst("https://".count)
        } else if relayURL.hasPrefix("http://") {
            base = "ws://" + relayURL.dropFirst("http://".count)
        } else {
            base = "ws://\(relayURL)"
        }
        wsURLString = "\(base)/v1/tunnel/\(gatewayId)/connect?apiKey=\(apiKey)"

        logger.info("[Tunnel] Connecting to \(base)/v1/tunnel/\(gatewayId)/connect...")

        let future = WebSocket.connect(to: wsURLString, on: eventLoopGroup) { [weak self, logger] ws in
            logger.info("[Tunnel] Connected to relay tunnel")
            self?.ws = ws
            Task { [weak self] in
                await self?.resetReconnectCounter()
                await self?.setupOnTextHandler(ws: ws)
            }

            ws.onClose.whenComplete { [weak self] _ in
                logger.info("[Tunnel] Tunnel WebSocket closed")
                // Check close code for 4001 (invalid API key).
                let closeCode = ws.closeCode
                Task { [weak self] in
                    if let code = closeCode, code == .init(codeNumber: 4001) {
                        await self?.handleAuthFailure()
                    } else {
                        await self?.handleDisconnect()
                    }
                }
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

    /// On 4001 (invalid API key): clear the stored key, re-register, and retry.
    private func handleAuthFailure() {
        guard isRunning else { return }
        ws = nil
        clientDeviceMap.removeAll()
        logger.warning("[Tunnel] API key rejected (4001). Re-registering...")
        apiKey = nil
        try? FileManager.default.removeItem(atPath: apiKeyPath)
        // Retry with a small delay to avoid hammering.
        reconnectAttempt = 0
        scheduleConnect(delay: 2)
    }

    // MARK: - Incoming request handling

    /// Register `ws.onText` on the tunnel WebSocket to receive client requests
    /// forwarded by the relay. Incoming format: `<clientId>:<nonce>.<ciphertext>`
    private func setupOnTextHandler(ws: WebSocket) {
        ws.onText { [weak self] ws, text in
            guard let self else { return }
            Task { await self.handleIncomingTunnelFrame(text: text) }
        }
    }

    /// Process an incoming frame from the relay tunnel.
    /// Format: `<clientId>:<nonce>.<ciphertext>` — relay prepended the client UUID.
    private func handleIncomingTunnelFrame(text: String) async {
        // Split on first `:` to get clientId and encrypted frame.
        guard let colonIndex = text.firstIndex(of: ":") else {
            logger.warning("[Tunnel] Received frame without clientId prefix, ignoring")
            return
        }

        let clientId = String(text[text.startIndex..<colonIndex])
        let encryptedFrame = String(text[text.index(after: colonIndex)...])

        guard let pairingService, let messageRouter, let printerService else {
            logger.warning("[Tunnel] Dependencies not set, cannot route request")
            return
        }

        // Try to decrypt with known device key (cached mapping) first.
        var decryptedEnvelope: MessageEnvelope?
        var matchedDeviceId: String?
        var matchedKey: SymmetricKey?

        if let cachedDeviceId = clientDeviceMap[clientId],
           let key = await pairingService.sharedKey(forDevice: cachedDeviceId) {
            do {
                decryptedEnvelope = try FrameCrypto.decryptFrame(frame: encryptedFrame, key: key)
                matchedDeviceId = cachedDeviceId
                matchedKey = key
            } catch {
                // Cached mapping stale, try all keys.
                clientDeviceMap[clientId] = nil
            }
        }

        // If cache miss, try each paired device's key.
        if decryptedEnvelope == nil {
            let deviceKeys = await pairingService.pairedDeviceKeys()
            for (deviceId, key) in deviceKeys {
                do {
                    let envelope = try FrameCrypto.decryptFrame(frame: encryptedFrame, key: key)
                    decryptedEnvelope = envelope
                    matchedDeviceId = deviceId
                    matchedKey = key
                    // Cache the mapping.
                    clientDeviceMap[clientId] = deviceId
                    break
                } catch {
                    continue
                }
            }
        }

        guard let envelope = decryptedEnvelope, let responseKey = matchedKey else {
            logger.warning("[Tunnel] Failed to decrypt frame from client \(clientId) with any paired device key")
            return
        }

        logger.debug("[Tunnel] Decrypted request from client \(clientId) (device: \(matchedDeviceId ?? "?")), method: \(envelope.method)")

        // Check for pending key rotation for this device. If one exists,
        // send a key.rotate event BEFORE processing the normal request.
        if let deviceId = matchedDeviceId,
           let rotation = await pairingService.consumePendingKeyRotation(forDevice: deviceId) {
            do {
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
                let rotateFrame = try FrameCrypto.encryptFrame(envelope: rotateEnvelope, key: responseKey)
                send(text: "\(clientId):\(rotateFrame)")
                logger.info("[Tunnel] Sent key.rotate to device \(deviceId) via client \(clientId)")
            } catch {
                logger.error("[Tunnel] Failed to send key.rotate to \(deviceId): \(error)")
            }
        }

        // Route to MessageRouter.
        let response = await messageRouter.route(envelope: envelope, printerService: printerService)

        // Encrypt response with the same device's key and send back tagged.
        do {
            let responseFrame = try FrameCrypto.encryptFrame(envelope: response, key: responseKey)
            // Send back: <clientId>:<nonce>.<ciphertext>
            send(text: "\(clientId):\(responseFrame)")
        } catch {
            logger.error("[Tunnel] Failed to encrypt response for client \(clientId): \(error)")
        }
    }
}
