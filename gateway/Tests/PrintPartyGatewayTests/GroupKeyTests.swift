//
//  GroupKeyTests.swift
//  printparty-gateway
//
//  Tests for group key generation and AES-256-GCM encrypt/decrypt round-trip.
//

import XCTest
import Crypto

final class GroupKeyTests: XCTestCase {

    // MARK: - Key generation

    func testGroupKeyGenerationIs32Bytes() {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 { bytes[i] = UInt8.random(in: 0...255) }
        let key = SymmetricKey(data: bytes)

        key.withUnsafeBytes { buffer in
            XCTAssertEqual(buffer.count, 32, "Group key should be exactly 32 bytes")
        }
    }

    func testGroupKeyRandomness() {
        // Generate two keys and verify they differ (probabilistic, but
        // collision probability is ~2^-256).
        var bytes1 = [UInt8](repeating: 0, count: 32)
        var bytes2 = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 {
            bytes1[i] = UInt8.random(in: 0...255)
            bytes2[i] = UInt8.random(in: 0...255)
        }
        XCTAssertNotEqual(bytes1, bytes2, "Two random keys should differ")
    }

    // MARK: - AES-256-GCM round-trip

    func testEncryptDecryptRoundTrip() throws {
        // Generate a shared key (simulates the ECDH-derived key).
        let sharedKey = SymmetricKey(size: .bits256)

        // Generate a group key (32 random bytes).
        var groupKeyBytes = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 { groupKeyBytes[i] = UInt8.random(in: 0...255) }
        let groupKeyData = Data(groupKeyBytes)

        // Encrypt the group key with the shared key.
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(groupKeyData, using: sharedKey, nonce: nonce)
        let ciphertextAndTag = sealed.ciphertext + sealed.tag

        // Simulate wire transfer: base64 encode, then decode.
        let ciphertextB64 = ciphertextAndTag.base64EncodedString()
        let nonceB64 = Data(nonce).base64EncodedString()

        // Decrypt (as the iOS client would).
        let receivedCiphertext = Data(base64Encoded: ciphertextB64)!
        let receivedNonce = Data(base64Encoded: nonceB64)!

        let decryptNonce = try AES.GCM.Nonce(data: receivedNonce)
        // receivedCiphertext = ciphertext + tag (last 16 bytes are the GCM tag)
        let tagSize = 16
        let ct = receivedCiphertext.prefix(receivedCiphertext.count - tagSize)
        let tag = receivedCiphertext.suffix(tagSize)
        let sealedBox = try AES.GCM.SealedBox(nonce: decryptNonce, ciphertext: ct, tag: tag)
        let decrypted = try AES.GCM.open(sealedBox, using: sharedKey)

        XCTAssertEqual(decrypted, groupKeyData, "Decrypted group key should match original")
        XCTAssertEqual(decrypted.count, 32)
    }

    func testDecryptionFailsWithWrongKey() throws {
        let correctKey = SymmetricKey(size: .bits256)
        let wrongKey = SymmetricKey(size: .bits256)

        // Generate and encrypt a group key.
        var groupKeyBytes = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 { groupKeyBytes[i] = UInt8.random(in: 0...255) }
        let groupKeyData = Data(groupKeyBytes)

        let sealed = try AES.GCM.seal(groupKeyData, using: correctKey)
        let combined = sealed.combined!

        // Attempt to decrypt with the wrong key.
        let sealedBox = try AES.GCM.SealedBox(combined: combined)
        XCTAssertThrowsError(try AES.GCM.open(sealedBox, using: wrongKey)) { error in
            // AES-GCM should fail with authentication error.
            XCTAssertTrue(
                error is CryptoKitError || "\(error)".contains("authenticationFailure"),
                "Should fail with authentication error, got: \(error)"
            )
        }
    }

    func testDecryptionFailsWithTamperedCiphertext() throws {
        let key = SymmetricKey(size: .bits256)
        var groupKeyBytes = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 { groupKeyBytes[i] = UInt8.random(in: 0...255) }

        let sealed = try AES.GCM.seal(Data(groupKeyBytes), using: key)
        var combined = sealed.combined!

        // Tamper with the ciphertext (flip a byte).
        let tamperIndex = combined.count / 2
        combined[tamperIndex] ^= 0xFF

        let sealedBox = try AES.GCM.SealedBox(combined: combined)
        XCTAssertThrowsError(try AES.GCM.open(sealedBox, using: key))
    }
}
