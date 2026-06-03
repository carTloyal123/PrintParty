//
//  GatewayIdentityStore.swift
//  printparty-gateway
//
//  Persists the gateway's long-lived identity (ID + X25519 private key) and
//  completed pairings to disk so they survive restarts.
//
//  Files are stored in ~/.printparty/ (override with PRINTPARTY_DATA_DIR).
//

import Foundation
import Crypto
import Logging

struct GatewayIdentityStore {

    // MARK: - Codable models

    struct StoredIdentity: Codable {
        let gatewayId: String
        let privateKeyBase64: String
    }

    struct StoredPairing: Codable {
        let deviceId: String
        let deviceName: String
        let sharedKeyBase64: String
        let pairedAt: Date
    }

    // MARK: - Properties

    private let identityPath: String
    private let pairingsPath: String
    private let logger: Logger

    // MARK: - Init

    init(logger: Logger) {
        self.logger = logger
        let dataDir = ProcessInfo.processInfo.environment["PRINTPARTY_DATA_DIR"]
            ?? (NSHomeDirectory() + "/.printparty")
        self.identityPath = dataDir + "/gateway-identity.json"
        self.pairingsPath = dataDir + "/gateway-pairings.json"

        // Ensure directory exists
        try? FileManager.default.createDirectory(
            atPath: dataDir,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Identity

    func load() -> StoredIdentity? {
        guard FileManager.default.fileExists(atPath: identityPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: identityPath)),
              let identity = try? JSONDecoder().decode(StoredIdentity.self, from: data) else {
            logger.info("No saved gateway identity found at \(identityPath)")
            return nil
        }
        logger.info("Loaded gateway identity \(identity.gatewayId) from \(identityPath)")
        return identity
    }

    func save(id: String, privateKey: Curve25519.KeyAgreement.PrivateKey) {
        let identity = StoredIdentity(
            gatewayId: id,
            privateKeyBase64: privateKey.rawRepresentation.base64EncodedString()
        )
        guard let data = try? JSONEncoder().encode(identity) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: identityPath), options: .atomic)
            // Owner-only permissions (0600)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: identityPath
            )
            logger.info("Saved gateway identity \(id) to \(identityPath)")
        } catch {
            logger.error("Failed to save gateway identity: \(error)")
        }
    }

    // MARK: - Pairings

    func loadPairings() -> [StoredPairing] {
        guard FileManager.default.fileExists(atPath: pairingsPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: pairingsPath)) else {
            logger.info("No saved pairings found at \(pairingsPath)")
            return []
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let pairings = try decoder.decode([StoredPairing].self, from: data)
            logger.info("Loaded \(pairings.count) pairing(s) from \(pairingsPath)")
            return pairings
        } catch {
            logger.error("Failed to decode pairings: \(error)")
            return []
        }
    }

    func savePairings(_ pairings: [StoredPairing]) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(pairings)
            try data.write(to: URL(fileURLWithPath: pairingsPath), options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: pairingsPath
            )
            logger.info("Saved \(pairings.count) pairing(s) to \(pairingsPath)")
        } catch {
            logger.error("Failed to save pairings: \(error)")
        }
    }
}
