//
//  Configure.swift
//  printparty-gateway
//

import Vapor
import Crypto
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

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

    // mDNS advertisement is on by default; disable it (BONJOUR_ENABLED=false) for
    // deployments where mDNS can't escape the bridge network (see docker-compose).
    let mdnsEnabled = Environment.get("BONJOUR_ENABLED")?.lowercased() != "false"

    // Optional operator-supplied LAN host (e.g. the Mac/host IP behind a Docker
    // bridge). When set it's preferred for the pairing QR and the mDNS A record,
    // since interface enumeration inside a container only sees the container IP.
    let advertiseHost = Environment.get("ADVERTISE_HOST").flatMap { $0.isEmpty ? nil : $0 }

    // Printing a scannable pairing QR in the terminal is on by default; disable
    // it (QR_IN_TERMINAL=false) for log scrapers or terminals that mangle it.
    let qrInTerminal = Environment.get("QR_IN_TERMINAL")?.lowercased() != "false"

    let pairingService = PairingService(
        gatewayId: gatewayId,
        gatewayName: gatewayName,
        privateKey: gatewayPrivateKey,
        identityStore: identityStore,
        logger: app.logger,
        relayURL: relayURL
    )
    app.storage[PairingServiceKey.self] = pairingService
    app.storage[PairingRateLimiterKey.self] = PairingRateLimiter()
    await pairingService.loadSavedPairings()
    await pairingService.loadGroupKey()

    // Create relay tunnel client if RELAY_URL is configured.
    var tunnelClient: RelayTunnelClient? = nil
    if let relayURL, !relayURL.isEmpty {
        tunnelClient = RelayTunnelClient(relayURL: relayURL, gatewayId: gatewayId, gatewayName: gatewayName, eventLoopGroup: app.eventLoopGroup, logger: app.logger)
    }

    // Create MessageRouter for WebSocket request/response dispatch.
    let messageRouter = MessageRouter(
        gatewayId: gatewayId,
        gatewayName: gatewayName,
        relayURL: relayURL,
        logger: app.logger
    )
    app.storage[MessageRouterKey.self] = messageRouter

    let printerService = PrinterService(
        eventLoopGroup: app.eventLoopGroup,
        logger: app.logger,
        relayURL: relayURL,
        tunnelClient: tunnelClient,
        pairingService: pairingService
    )
    app.storage[PrinterServiceKey.self] = printerService

    // Load any previously registered printers from disk and reconnect.
    await printerService.loadSavedPrinters()

    // Inject dependencies into tunnel client and start it.
    if let tunnelClient {
        await tunnelClient.setDependencies(
            messageRouter: messageRouter,
            printerService: printerService,
            pairingService: pairingService
        )
        Task { await tunnelClient.start() }
    }

    // Start cross-platform mDNS advertisement so the iOS app can auto-discover
    // us on the LAN (works on macOS and Linux — see MDNSResponder).
    var mdnsResponder: MDNSResponder? = nil
    if mdnsEnabled {
        let responder = MDNSResponder(
            gatewayId: gatewayId,
            gatewayName: gatewayName,
            version: "0.1.0",
            port: UInt16(app.http.server.configuration.port),
            advertiseHost: advertiseHost,
            eventLoopGroup: app.eventLoopGroup,
            logger: app.logger
        )
        mdnsResponder = responder
        app.mdnsResponder = responder
        Task { await responder.start() }
    }

    // H-16: Register a lifecycle handler for graceful shutdown of MQTT
    // connections, WebSockets, and pending tasks.
    app.lifecycle.use(GatewayLifecycleHandler(printerService: printerService, mdnsResponder: mdnsResponder))

    try app.register(collection: HealthRoutes(gatewayId: gatewayId, gatewayName: gatewayName, relayURL: relayURL))
    try app.register(collection: PairingRoutes())
    try app.register(collection: PrinterRoutes())
    try app.register(collection: StreamRoutes())

    let bindHost = app.http.server.configuration.hostname
    let bindPort = app.http.server.configuration.port

    // Build the list of URLs the iOS app can use to reach this gateway.
    // See `resolvePairingHosts()` for the full discovery logic. Store it so the
    // /v1/pair/qr endpoint can build the QR payload with a real LAN host. An
    // explicit ADVERTISE_HOST wins so the QR is phone-reachable behind Docker.
    var pairingHosts = resolvePairingHosts()
    if let advertiseHost { pairingHosts = [advertiseHost] + pairingHosts.filter { $0 != advertiseHost } }
    app.storage[PairingHostsKey.self] = pairingHosts

    // If we look containerized and no host was provided, the enumerated IP is the
    // unreachable container address — warn the operator how to make pairing work.
    if advertiseHost == nil, isLikelyContainerized(firstHost: pairingHosts.first) {
        app.logger.warning("""
        mDNS/QR may be unreachable from a phone: this looks like a container with no ADVERTISE_HOST set. \
        Set ADVERTISE_HOST=<your LAN IP> (e.g. 192.168.1.42) so the pairing QR points at a reachable address, \
        and use `network_mode: host` (Linux) for mDNS discovery.
        """)
    }
    let pairingURLs = pairingHosts.map { "http://\($0):\(bindPort)" }
    let pairingURLList = pairingURLs.map { "   \($0)" }.joined(separator: "\n")

    // The best host to encode in a QR is the first LAN address (not localhost).
    let qrHost = pairingHosts.first ?? "localhost"

    // Print a friendly banner with the current pairing code.
    // The code auto-rotates every 5 minutes; each rotation is printed
    // to the console at NOTICE level so the user can always see it.
    let code = await pairingService.currentPairingCode()

    app.logger.notice("""

    ╔═══════════════════════════════════════════════════════════════╗
       PrintParty Gateway

       Listening on http://\(bindHost):\(bindPort)
       Gateway ID  : \(gatewayId)
       Gateway name: \(gatewayName)
       mDNS        : \(mdnsEnabled ? "advertising as _printparty._tcp" : "disabled")

       PAIRING CODE: \(code)   (valid 5 minutes)

       In the iOS app go to Settings → Gateways → + and enter one of:
    \(pairingURLList)
         Code : \(code)
    ╚═══════════════════════════════════════════════════════════════╝
    """)

    // Render a scannable QR for the current code so the user can pair with zero
    // typing straight from the terminal.
    if qrInTerminal {
        let payload = QRTerminalRenderer.pairingURL(baseURL: "http://\(qrHost):\(bindPort)", code: code)
        let qrArt = QRTerminalRenderer.renderToTerminal(payload: payload)
        app.logger.notice("\n📱 Scan to pair:\n\n\(qrArt)\n")
    }

    // Background task: periodically touch the pairing code so it rotates and
    // prints the new code (and a fresh QR) to the console. Without this,
    // rotation only happens when someone hits the pairing endpoint.
    Task {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(300))
            let newCode = await pairingService.currentPairingCode()
            if qrInTerminal {
                let payload = QRTerminalRenderer.pairingURL(baseURL: "http://\(qrHost):\(bindPort)", code: newCode)
                let qrArt = QRTerminalRenderer.renderToTerminal(payload: payload)
                app.logger.notice("\n📱 New pairing code \(newCode) — scan to pair:\n\n\(qrArt)\n")
            }
        }
    }
}

// MARK: - Storage keys

struct PairingServiceKey: StorageKey {
    typealias Value = PairingService
}

struct MDNSResponderKey: StorageKey {
    typealias Value = MDNSResponder
}

struct PairingHostsKey: StorageKey {
    typealias Value = [String]
}

extension Application {
    var pairing: PairingService { storage[PairingServiceKey.self]! }

    var mdnsResponder: MDNSResponder? {
        get { storage[MDNSResponderKey.self] }
        set { storage[MDNSResponderKey.self] = newValue }
    }

    /// Hosts the gateway can be reached at, resolved at startup. Used by the
    /// QR endpoint to build a pairing URL with a real LAN address.
    var pairingHosts: [String] { storage[PairingHostsKey.self] ?? ["localhost"] }
}

extension Request {
    var pairing: PairingService { application.pairing }
}

// MARK: - Graceful shutdown (H-16)

struct GatewayLifecycleHandler: LifecycleHandler {
    let printerService: PrinterService
    let mdnsResponder: MDNSResponder?

    func shutdownAsync(_ app: Application) async {
        app.logger.info("Gateway lifecycle: shutting down...")
        await mdnsResponder?.stop()
        await printerService.shutdown()
        app.logger.info("Gateway lifecycle: shutdown complete.")
    }
}
