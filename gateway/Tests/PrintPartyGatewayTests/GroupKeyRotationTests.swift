//
//  GroupKeyRotationTests.swift
//  printparty-gateway
//
//  Tests for group key rotation: verifies that rotateGroupKey() produces a
//  new key, creates per-device pending rotations, and that the encrypted
//  group key can only be decrypted with the correct device's shared key.
//

import XCTest
import Crypto
import NIOPosix
import PrintPartyKit
@testable import PrintPartyGateway

final class GroupKeyRotationTests: XCTestCase {

    // Helper: create a PairingService, pair two devices, return
    // (service, device1Id, device1SharedKey, device2Id, device2SharedKey).
    private func makePairedService() async throws -> (
        service: PairingService,
        device1Id: String,
        device1Key: SymmetricKey,
        device2Id: String,
        device2Key: SymmetricKey
    ) {
        let store = GatewayIdentityStore(logger: .init(label: "test"))
        let gatewayPrivateKey = Curve25519.KeyAgreement.PrivateKey()

        let service = PairingService(
            gatewayId: "test-gw",
            gatewayName: "Test Gateway",
            privateKey: gatewayPrivateKey,
            identityStore: store,
            logger: .init(label: "test")
        )

        // Pair device 1.
        let device1PrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let code1 = await service.currentPairingCode()
        let _ = try await service.completePairing(
            code: code1,
            deviceId: "device-1",
            deviceName: "iPhone 1",
            devicePublicKeyBase64: device1PrivateKey.publicKey.rawRepresentation.base64EncodedString()
        )
        // Derive device 1's shared key (same ECDH + HKDF as the gateway).
        let shared1 = try device1PrivateKey.sharedSecretFromKeyAgreement(with: gatewayPrivateKey.publicKey)
        let device1Key = shared1.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("printparty-pairing-v1".utf8),
            sharedInfo: Data(),
            outputByteCount: 32
        )

        // Pair device 2.
        let device2PrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let code2 = await service.currentPairingCode()
        let _ = try await service.completePairing(
            code: code2,
            deviceId: "device-2",
            deviceName: "iPhone 2",
            devicePublicKeyBase64: device2PrivateKey.publicKey.rawRepresentation.base64EncodedString()
        )
        let shared2 = try device2PrivateKey.sharedSecretFromKeyAgreement(with: gatewayPrivateKey.publicKey)
        let device2Key = shared2.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("printparty-pairing-v1".utf8),
            sharedInfo: Data(),
            outputByteCount: 32
        )

        return (service, "device-1", device1Key, "device-2", device2Key)
    }

    // MARK: - Tests

    func testRotateGroupKeyProducesNewKey() async throws {
        let (service, _, _, _, _) = try await makePairedService()

        let oldKey = await service.getGroupKey()
        XCTAssertNotNil(oldKey, "Group key should exist after pairing")

        await service.rotateGroupKey()
        let newKey = await service.getGroupKey()
        XCTAssertNotNil(newKey, "Group key should exist after rotation")

        // Compare key data — they should differ.
        let oldData = oldKey!.withUnsafeBytes { Data($0) }
        let newData = newKey!.withUnsafeBytes { Data($0) }
        XCTAssertNotEqual(oldData, newData, "Rotated group key should differ from the old one")
    }

    func testPendingRotationsCreatedForEachDevice() async throws {
        let (service, _, _, _, _) = try await makePairedService()

        await service.rotateGroupKey()
        let rotations = await service.pendingKeyRotations

        XCTAssertEqual(rotations.count, 2, "Should have pending rotations for both devices")
        XCTAssertNotNil(rotations["device-1"], "device-1 should have a pending rotation")
        XCTAssertNotNil(rotations["device-2"], "device-2 should have a pending rotation")
    }

    func testPendingRotationDecryptableWithCorrectKey() async throws {
        let (service, _, device1Key, _, _) = try await makePairedService()

        await service.rotateGroupKey()
        let rotations = await service.pendingKeyRotations
        let newGroupKey = await service.getGroupKey()!

        guard let rotation = rotations["device-1"] else {
            XCTFail("No pending rotation for device-1")
            return
        }

        // Decrypt the encrypted group key with device 1's shared key.
        let decrypted = try FrameCrypto.decrypt(
            ciphertext: rotation.encryptedKey,
            nonce: rotation.nonce,
            key: device1Key
        )

        let expectedData = newGroupKey.withUnsafeBytes { Data($0) }
        XCTAssertEqual(decrypted, expectedData, "Decrypted group key should match the new group key")
        XCTAssertEqual(decrypted.count, 32)
    }

    func testPendingRotationFailsWithWrongKey() async throws {
        let (service, _, _, _, device2Key) = try await makePairedService()

        await service.rotateGroupKey()
        let rotations = await service.pendingKeyRotations

        guard let rotation = rotations["device-1"] else {
            XCTFail("No pending rotation for device-1")
            return
        }

        // Attempt to decrypt device-1's rotation with device-2's key.
        XCTAssertThrowsError(
            try FrameCrypto.decrypt(
                ciphertext: rotation.encryptedKey,
                nonce: rotation.nonce,
                key: device2Key
            ),
            "Decryption should fail with a different device's key"
        )
    }

    func testUnpairDeviceTriggersRotation() async throws {
        let (service, _, _, _, _) = try await makePairedService()

        let oldKey = await service.getGroupKey()!
        let oldKeyData = oldKey.withUnsafeBytes { Data($0) }

        // Unpair device-1 — should rotate the group key.
        await service.unpairDevice(deviceId: "device-1")

        let newKey = await service.getGroupKey()!
        let newKeyData = newKey.withUnsafeBytes { Data($0) }
        XCTAssertNotEqual(oldKeyData, newKeyData, "Group key should change after unpair")

        // Only device-2 should have a pending rotation (device-1 was removed).
        let rotations = await service.pendingKeyRotations
        XCTAssertEqual(rotations.count, 1)
        XCTAssertNotNil(rotations["device-2"])
        XCTAssertNil(rotations["device-1"], "Unpaired device should not get a rotation")
    }

    func testConsumePendingRotationClearsEntry() async throws {
        let (service, _, _, _, _) = try await makePairedService()

        await service.rotateGroupKey()

        // Consume device-1's rotation.
        let rotation = await service.consumePendingKeyRotation(forDevice: "device-1")
        XCTAssertNotNil(rotation, "Should return the pending rotation")

        // It should be cleared now.
        let second = await service.consumePendingKeyRotation(forDevice: "device-1")
        XCTAssertNil(second, "Should be nil after consumption")

        // device-2 should still be pending.
        let remaining = await service.pendingKeyRotations
        XCTAssertEqual(remaining.count, 1)
        XCTAssertNotNil(remaining["device-2"])
    }
}
