//
//  GatewayRegistry.swift
//  printparty-relay
//
//  Thread-safe registry of gateways that are allowed to connect.
//  Persists to a JSON file so registrations survive restarts.
//

import Foundation
import Crypto
import NIOConcurrencyHelpers
import Vapor

// MARK: - StoredGateway

struct StoredGateway: Codable, Sendable {
    let gatewayId: String
    let apiKey: String
    let name: String
    let registeredAt: Date
}

// MARK: - GatewayRegistry

final class GatewayRegistry: Sendable {

    private let _lock = NIOLock()
    nonisolated(unsafe) private var _gateways: [String: StoredGateway] = [:]
    private let persistencePath: String
    private let logger: Logger

    init(persistencePath: String = "/data/gateway-registry.json", logger: Logger) {
        self.persistencePath = persistencePath
        self.logger = logger
    }

    // MARK: - Registration

    /// Registers a gateway and returns its API key. Idempotent: if the
    /// gateway is already registered, returns the existing key.
    func register(gatewayId: String, name: String) -> String {
        return _lock.withLock {
            if let existing = _gateways[gatewayId] {
                return existing.apiKey
            }
            let apiKey = Self.generateAPIKey()
            let entry = StoredGateway(
                gatewayId: gatewayId,
                apiKey: apiKey,
                name: name,
                registeredAt: Date()
            )
            _gateways[gatewayId] = entry
            _saveLocked()
            logger.info("[Registry] Registered gateway \(gatewayId) (\(name))")
            return apiKey
        }
    }

    // MARK: - Validation

    /// Returns true if the gatewayId is registered and the apiKey matches.
    func validate(gatewayId: String, apiKey: String) -> Bool {
        return _lock.withLock {
            guard let stored = _gateways[gatewayId] else { return false }
            // Constant-time compare to avoid timing oracle.
            return constantTimeEqual(stored.apiKey, apiKey)
        }
    }

    // MARK: - Persistence

    func load() {
        _lock.withLock {
            guard FileManager.default.fileExists(atPath: persistencePath),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: persistencePath)) else {
                logger.info("[Registry] No saved registry at \(persistencePath)")
                return
            }
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let entries = try decoder.decode([StoredGateway].self, from: data)
                for entry in entries {
                    _gateways[entry.gatewayId] = entry
                }
                logger.info("[Registry] Loaded \(entries.count) gateway(s) from \(persistencePath)")
            } catch {
                logger.error("[Registry] Failed to decode registry: \(error)")
            }
        }
    }

    func save() {
        _lock.withLock { _saveLocked() }
    }

    /// Must be called with _lock held.
    private func _saveLocked() {
        let entries = Array(_gateways.values)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)

            // Ensure parent directory exists.
            let dir = (persistencePath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true
            )

            try data.write(to: URL(fileURLWithPath: persistencePath), options: .atomic)
            logger.debug("[Registry] Saved \(entries.count) gateway(s) to \(persistencePath)")
        } catch {
            logger.error("[Registry] Failed to save registry: \(error)")
        }
    }

    // MARK: - Helpers

    /// Generates a 32-byte random API key, hex-encoded (64 characters).
    static func generateAPIKey() -> String {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { bytes in
            bytes.map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Constant-time string comparison to avoid timing side-channels.
    /// Iterates over the longer of the two inputs so that differing
    /// lengths do not produce a measurably shorter execution.
    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        let length = max(aBytes.count, bBytes.count)
        var diff: UInt8 = 0
        for i in 0..<length {
            let aByte: UInt8 = i < aBytes.count ? aBytes[i] : 0
            let bByte: UInt8 = i < bBytes.count ? bBytes[i] : 0
            diff |= aByte ^ bByte
        }
        // Also fold in a length mismatch so equal-content prefixes don't pass.
        diff |= UInt8(truncatingIfNeeded: aBytes.count ^ bBytes.count)
        return diff == 0
    }
}

// MARK: - Vapor Storage

struct GatewayRegistryKey: StorageKey {
    typealias Value = GatewayRegistry
}

extension Application {
    var gatewayRegistry: GatewayRegistry { storage[GatewayRegistryKey.self]! }
}

extension Request {
    var gatewayRegistry: GatewayRegistry { application.gatewayRegistry }
}
