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

    // Build the list of URLs the iOS app can use to reach this gateway.
    // See `resolvePairingHosts()` for the full discovery logic.
    let pairingHosts = resolvePairingHosts()
    let pairingURLs = pairingHosts.map { "http://\($0):\(bindPort)" }
    let pairingURLList = pairingURLs.map { "   \($0)" }.joined(separator: "\n")

    app.logger.notice("""

    ╔═══════════════════════════════════════════════════════════════╗
       PrintParty Gateway

       Listening on http://\(bindHost):\(bindPort)
       Gateway ID  : \(gatewayId)
       Gateway name: \(gatewayName)

       PAIRING CODE: \(code)   (valid 5 minutes)

       In the iOS app go to Settings → Gateways → + and enter one of:
    \(pairingURLList)
         Code : \(code)
    ╚═══════════════════════════════════════════════════════════════╝
    """)
}

// MARK: - Pairing host discovery

/// Returns every host the gateway can plausibly be reached at, for use in
/// the startup banner. We don't try to be clever about which of these are
/// "really" useful — we just enumerate everything we can find and let the
/// human pick the right one. Includes:
///   - Every non-loopback IPv4 address from local network interfaces.
///     In Docker bridge mode this returns the container's internal IP
///     (e.g. 172.18.x.x), not the host's LAN IP — use mDNS or set
///     `network_mode: host` in compose for that case.
///   - `<hostname>.local` if the container hostname looks like a real name
///     (most home networks resolve `.local` via mDNS/avahi). Set the
///     container's `hostname:` in docker-compose to match the host's
///     mDNS name (e.g. `hostname: ccc` for `ccc.local`).
///   - `localhost` as a last-resort entry.
private func resolvePairingHosts() -> [String] {
    var hosts: [String] = []

    hosts.append(contentsOf: enumerateLocalIPv4Addresses())

    if let mdns = mDNSHostname(), !hosts.contains(mdns) {
        hosts.append(mdns)
    }

    if !hosts.contains("localhost") {
        hosts.append("localhost")
    }
    return hosts
}

/// Returns `<hostname>.local` if the system hostname looks like a real name.
/// Returns nil for Docker-default container IDs (12 hex chars), already-qualified
/// names, or empty hostnames. This lets users reach the gateway via mDNS/avahi.
private func mDNSHostname() -> String? {
    var buffer = [CChar](repeating: 0, count: 256)
    guard gethostname(&buffer, buffer.count) == 0 else { return nil }
    let host = String(cString: buffer)
    guard !host.isEmpty else { return nil }
    // Skip Docker default container IDs (12-char lowercase hex).
    if host.count == 12, host.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) {
        return nil
    }
    // If the hostname already contains a dot, treat as fully qualified.
    if host.contains(".") { return host }
    return host + ".local"
}

/// Enumerate non-loopback IPv4 addresses from local network interfaces.
/// In Docker bridge mode this only returns the container's internal IP,
/// which is why GATEWAY_HOSTS exists as an override.
private func enumerateLocalIPv4Addresses() -> [String] {
    var results: [String] = []
    var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
    defer { freeifaddrs(ifaddrPtr) }

    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let ptr = cursor {
        defer { cursor = ptr.pointee.ifa_next }

        guard let addr = ptr.pointee.ifa_addr else { continue }
        guard Int32(addr.pointee.sa_family) == AF_INET else { continue }

        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            addr,
            socklen_t(MemoryLayout<sockaddr_in>.size),
            &hostBuffer,
            socklen_t(hostBuffer.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard result == 0 else { continue }

        let address = String(cString: hostBuffer)
        // Skip loopback (handled separately) and link-local autoconfig.
        if address == "127.0.0.1" || address.hasPrefix("169.254.") { continue }
        if !results.contains(address) {
            results.append(address)
        }
    }
    return results
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
