//
//  Configure.swift
//  printparty-relay
//

import Vapor
import APNS
import APNSCore

/// Concrete APNs client type used throughout the relay.
typealias RelayAPNSClient = APNSClient<JSONDecoder, JSONEncoder>

func configurerelay(_ app: Application) async throws {
    app.http.server.configuration.hostname = Environment.get("HOST") ?? "0.0.0.0"
    app.http.server.configuration.port = Int(Environment.get("PORT") ?? "8090") ?? 8090
    app.routes.defaultMaxBodySize = "16kb"

    // APNs configuration — reads from environment variables.
    //   APNS_KEY_PATH   = path to the .p8 file
    //   APNS_KEY_ID     = 10-character key identifier from Apple
    //   APNS_TEAM_ID    = your Apple Developer Team ID
    //   APNS_TOPIC      = your app's bundle ID (e.g. com.clengineering.PrintParty)
    //   APNS_SANDBOX    = "true" for development, "false" for production

    let keyPath = Environment.get("APNS_KEY_PATH") ?? "AuthKey.p8"
    let keyId = Environment.get("APNS_KEY_ID") ?? ""
    let teamId = Environment.get("APNS_TEAM_ID") ?? ""
    let topic = Environment.get("APNS_TOPIC") ?? "com.clengineering.PrintParty"
    let isSandbox = Environment.get("APNS_SANDBOX") != "false"

    var apnsClient: RelayAPNSClient? = nil

    if !keyId.isEmpty && !teamId.isEmpty && FileManager.default.fileExists(atPath: keyPath) {
        do {
            let keyData = try Data(contentsOf: URL(fileURLWithPath: keyPath))
            let key = String(data: keyData, encoding: .utf8) ?? ""
            let apnsConfig = APNSClientConfiguration(
                authenticationMethod: .jwt(
                    privateKey: try .loadFrom(string: key),
                    keyIdentifier: keyId,
                    teamIdentifier: teamId
                ),
                environment: isSandbox ? .development : .production
            )
            apnsClient = RelayAPNSClient(
                configuration: apnsConfig,
                eventLoopGroupProvider: .shared(app.eventLoopGroup),
                responseDecoder: JSONDecoder(),
                requestEncoder: JSONEncoder()
            )
            app.logger.info("APNs client initialized with key \(keyId)")
        } catch {
            app.logger.error("Failed to initialize APNs client: \(error). Push will not work.")
        }
    } else {
        if keyId.isEmpty || teamId.isEmpty {
            app.logger.warning("APNs not configured (APNS_KEY_ID / APNS_TEAM_ID missing). Set environment variables to enable push.")
        } else {
            app.logger.warning("APNs .p8 key not found at '\(keyPath)'. Push will not work.")
        }
    }

    app.storage[APNSClientKey.self] = apnsClient
    app.storage[APNSTopicKey.self] = topic

    // Tunnel broker for WebSocket relay between gateways and iOS clients.
    app.storage[TunnelBrokerKey.self] = TunnelBroker(logger: app.logger)

    // Register lifecycle handler for graceful APNs client shutdown.
    app.lifecycle.use(RelayLifecycleHandler())

    try app.register(collection: RelayHealthRoutes())
    try app.register(collection: PushRoutes())
    try app.register(collection: TunnelRoutes())

    let bindHost = app.http.server.configuration.hostname
    let bindPort = app.http.server.configuration.port
    let keyStatus = apnsClient != nil ? keyId : "NOT CONFIGURED"
    app.logger.notice("""

    ╔═══════════════════════════════════════════════════════════════╗
       PrintParty Relay

       Listening on http://\(bindHost):\(bindPort)
       APNs topic  : \(topic)
       APNs sandbox: \(isSandbox)
       APNs key    : \(keyStatus)
    ╚═══════════════════════════════════════════════════════════════╝
    """)
}

struct APNSClientKey: StorageKey { typealias Value = RelayAPNSClient? }
struct APNSTopicKey: StorageKey { typealias Value = String }

extension Application {
    var apnsClient: RelayAPNSClient? { storage[APNSClientKey.self] ?? nil }
    var apnsTopic: String { storage[APNSTopicKey.self]! }
}
extension Request {
    var apnsClient: RelayAPNSClient? { application.apnsClient }
    var apnsTopic: String { application.apnsTopic }
}

// MARK: - Graceful shutdown

struct RelayLifecycleHandler: LifecycleHandler {
    func shutdownAsync(_ app: Application) async {
        app.logger.info("Relay lifecycle: shutting down...")
        if let client = app.apnsClient {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                client.shutdown { error in
                    if let error {
                        app.logger.warning("Relay lifecycle: APNs client shutdown error: \(error)")
                    } else {
                        app.logger.info("Relay lifecycle: APNs client shut down.")
                    }
                    continuation.resume()
                }
            }
        }
        app.logger.info("Relay lifecycle: shutdown complete.")
    }
}
