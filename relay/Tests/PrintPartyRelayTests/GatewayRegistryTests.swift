//
//  GatewayRegistryTests.swift
//  printparty-relay
//
//  Tests for GatewayRegistry: registration, validation, idempotency,
//  and JSON persistence round-trip.
//

import XCTest
import Logging
@testable import PrintPartyRelay

final class GatewayRegistryTests: XCTestCase {

    private func makeRegistry(path: String? = nil) -> (GatewayRegistry, String) {
        let dir = NSTemporaryDirectory() + "printparty-tests-\(UUID().uuidString)"
        let filePath = path ?? (dir + "/gateway-registry.json")
        let logger = Logger(label: "test")
        let registry = GatewayRegistry(persistencePath: filePath, logger: logger)
        return (registry, filePath)
    }

    // MARK: - Registration

    func testRegistrationReturns64CharHexKey() {
        let (registry, _) = makeRegistry()
        let key = registry.register(gatewayId: "gw-1", name: "Test Gateway")
        XCTAssertEqual(key.count, 64, "API key should be 64 hex characters")
        // Verify all characters are valid hex.
        let hexChars = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertTrue(
            key.unicodeScalars.allSatisfy { hexChars.contains($0) },
            "API key should contain only hex characters"
        )
    }

    func testIdempotentRegistration() {
        let (registry, _) = makeRegistry()
        let key1 = registry.register(gatewayId: "gw-1", name: "Test Gateway")
        let key2 = registry.register(gatewayId: "gw-1", name: "Test Gateway Updated")
        XCTAssertEqual(key1, key2, "Re-registering same gatewayId should return same key")
    }

    func testDifferentGatewaysGetDifferentKeys() {
        let (registry, _) = makeRegistry()
        let key1 = registry.register(gatewayId: "gw-1", name: "Gateway 1")
        let key2 = registry.register(gatewayId: "gw-2", name: "Gateway 2")
        XCTAssertNotEqual(key1, key2, "Different gateways should have different keys")
    }

    // MARK: - Validation

    func testValidationSucceedsWithCorrectKey() {
        let (registry, _) = makeRegistry()
        let key = registry.register(gatewayId: "gw-1", name: "Test")
        XCTAssertTrue(registry.validate(gatewayId: "gw-1", apiKey: key))
    }

    func testValidationFailsWithWrongKey() {
        let (registry, _) = makeRegistry()
        _ = registry.register(gatewayId: "gw-1", name: "Test")
        XCTAssertFalse(registry.validate(gatewayId: "gw-1", apiKey: "wrong-key"))
    }

    func testValidationFailsForUnregisteredGateway() {
        let (registry, _) = makeRegistry()
        XCTAssertFalse(registry.validate(gatewayId: "nonexistent", apiKey: "any-key"))
    }

    func testValidationFailsWithEmptyKey() {
        let (registry, _) = makeRegistry()
        _ = registry.register(gatewayId: "gw-1", name: "Test")
        XCTAssertFalse(registry.validate(gatewayId: "gw-1", apiKey: ""))
    }

    // MARK: - Persistence

    func testSaveAndLoadRoundTrip() {
        let dir = NSTemporaryDirectory() + "printparty-tests-\(UUID().uuidString)"
        let filePath = dir + "/gateway-registry.json"
        let logger = Logger(label: "test")

        // Register gateways and let save happen automatically.
        let registry1 = GatewayRegistry(persistencePath: filePath, logger: logger)
        let key1 = registry1.register(gatewayId: "gw-1", name: "Gateway One")
        let key2 = registry1.register(gatewayId: "gw-2", name: "Gateway Two")

        // Create a new registry instance and load from the same file.
        let registry2 = GatewayRegistry(persistencePath: filePath, logger: logger)
        registry2.load()

        // Validate that both gateways survived the round-trip.
        XCTAssertTrue(registry2.validate(gatewayId: "gw-1", apiKey: key1))
        XCTAssertTrue(registry2.validate(gatewayId: "gw-2", apiKey: key2))
        XCTAssertFalse(registry2.validate(gatewayId: "gw-1", apiKey: "tampered"))

        // Cleanup.
        try? FileManager.default.removeItem(atPath: dir)
    }

    func testLoadFromEmptyPath() {
        let logger = Logger(label: "test")
        let registry = GatewayRegistry(
            persistencePath: "/tmp/nonexistent-\(UUID().uuidString)/registry.json",
            logger: logger
        )
        // Should not crash, just log and remain empty.
        registry.load()
        XCTAssertFalse(registry.validate(gatewayId: "anything", apiKey: "anything"))
    }

    // MARK: - API Key generation

    func testGenerateAPIKeyUniqueness() {
        let keys = (0..<100).map { _ in GatewayRegistry.generateAPIKey() }
        let unique = Set(keys)
        XCTAssertEqual(unique.count, keys.count, "Generated API keys should be unique")
    }
}
