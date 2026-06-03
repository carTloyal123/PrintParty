//
//  Configure.swift
//  printparty-gateway
//

import Vapor
import Crypto

func configure(_ app: Application) async throws {
    // Bind to all interfaces by default so the iOS device on the same Wi-Fi
    // can reach us at <mac-ip>:8080. Override with PORT / HOST env vars.
    app.http.server.configuration.hostname = Environment.get("HOST") ?? "0.0.0.0"
    app.http.server.configuration.port = Int(Environment.get("PORT") ?? "8080") ?? 8080

    // Reasonably generous body limit; pairing bodies are <1 KB.
    app.routes.defaultMaxBodySize = "64kb"

    // Wire up application services.
    let identityStore = GatewayIdentityStore(logger: app.logger)

    let gatewayId: String
    let gatewayPrivateKey: Curve25519.KeyAgreement.PrivateKey

    if let saved = identityStore.load(),
       let keyData = Data(base64Encoded: saved.privateKeyBase64),
       let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keyData) {
        gatewayId = saved.gatewayId
        gatewayPrivateKey = key
        app.logger.info("Restored gateway identity: \(gatewayId)")
    } else {
        gatewayId = UUID().uuidString
        gatewayPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        identityStore.save(id: gatewayId, privateKey: gatewayPrivateKey)
        app.logger.info("Generated new gateway identity: \(gatewayId)")
    }

    let gatewayName = Environment.get("GATEWAY_NAME")
        ?? Host.current().localizedName
        ?? "PrintParty Gateway"

    // Read relay URL early so it can be passed to multiple services.
    let relayURL = Environment.get("RELAY_URL")

    let pairingService = PairingService(
        gatewayId: gatewayId,
        gatewayName: gatewayName,
        privateKey: gatewayPrivateKey,
        identityStore: identityStore,
        logger: app.logger,
        relayURL: relayURL
    )
    app.storage[PairingServiceKey.self] = pairingService
    await pairingService.loadSavedPairings()

    // Create relay tunnel client if RELAY_URL is configured.
    var tunnelClient: RelayTunnelClient? = nil
    if let relayURL, !relayURL.isEmpty {
        tunnelClient = RelayTunnelClient(relayURL: relayURL, gatewayId: gatewayId, eventLoopGroup: app.eventLoopGroup, logger: app.logger)
    }

    let printerService = PrinterService(
        eventLoopGroup: app.eventLoopGroup,
        logger: app.logger,
        relayURL: relayURL,
        tunnelClient: tunnelClient
    )
    app.storage[PrinterServiceKey.self] = printerService

    // Load any previously registered printers from disk and reconnect.
    await printerService.loadSavedPrinters()

    // Start the tunnel client after PrinterService is ready.
    if let tunnelClient {
        Task { await tunnelClient.start() }
    }

    // H-16: Register a lifecycle handler for graceful shutdown of MQTT
    // connections, WebSockets, and pending tasks.
    app.lifecycle.use(GatewayLifecycleHandler(printerService: printerService))

    try app.register(collection: HealthRoutes(gatewayId: gatewayId, gatewayName: gatewayName, relayURL: relayURL))
    try app.register(collection: PairingRoutes())
    try app.register(collection: PrinterRoutes())
    try app.register(collection: StreamRoutes())

    // Print a friendly banner with the current pairing code.
    // The code auto-rotates every 5 minutes; each rotation is printed
    // to the console at NOTICE level so the user can always see it.
    let code = await pairingService.currentPairingCode()

    // Background task: periodically touch the pairing code so it rotates
    // and prints the new code to the console. Without this, rotation only
    // happens when someone hits the pairing endpoint.
    Task {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(300))
            _ = await pairingService.currentPairingCode()
        }
    }
    let bindHost = app.http.server.configuration.hostname
    let bindPort = app.http.server.configuration.port
    app.logger.notice("""

    ╔═══════════════════════════════════════════════════════════════╗
       PrintParty Gateway

       Listening on http://\(bindHost):\(bindPort)
       Gateway ID  : \(gatewayId)
       Gateway name: \(gatewayName)

       PAIRING CODE: \(code)   (valid 5 minutes)

       In the iOS app:
         Settings → Gateways → +
         URL  : http://localhost:\(bindPort) (Simulator)
                http://<mac-ip>:\(bindPort)  (real device)
         Code : \(code)
    ╚═══════════════════════════════════════════════════════════════╝
    """)
}

struct PairingServiceKey: StorageKey {
    typealias Value = PairingService
}

extension Application {
    var pairing: PairingService { storage[PairingServiceKey.self]! }
}

extension Request {
    var pairing: PairingService { application.pairing }
}

// MARK: - Graceful shutdown (H-16)

struct GatewayLifecycleHandler: LifecycleHandler {
    let printerService: PrinterService

    func shutdownAsync(_ app: Application) async {
        app.logger.info("Gateway lifecycle: shutting down...")
        await printerService.shutdown()
        app.logger.info("Gateway lifecycle: shutdown complete.")
    }
}
