//
//  FrameCryptoTests.swift
//  printparty-gateway
//
//  Tests for FrameCrypto: encrypt/decrypt round-trip, wrong key, tampering,
//  and frame format validation.
//

import XCTest
import Crypto
@testable import PrintPartyGateway

final class FrameCryptoTests: XCTestCase {

    private let testKey = SymmetricKey(size: .bits256)

    private func makeTestEnvelope() -> MessageEnvelope {
        let payload = Data("{\"status\":\"ok\"}".utf8)
        return MessageEnvelope.response(id: "test-id", method: "health", payload: payload)
    }

    // MARK: - Round-trip

    func testEncryptDecryptRoundTripProducesIdenticalEnvelope() throws {
        let original = makeTestEnvelope()
        let frame = try FrameCrypto.encryptFrame(envelope: original, key: testKey)
        let decrypted = try FrameCrypto.decryptFrame(frame: frame, key: testKey)

        XCTAssertEqual(decrypted.type, original.type)
        XCTAssertEqual(decrypted.id, original.id)
        XCTAssertEqual(decrypted.method, original.method)
        XCTAssertEqual(decrypted.deviceId, original.deviceId)
        XCTAssertEqual(decrypted.payload, original.payload)
    }

    // MARK: - Wrong key

    func testWrongKeyFailsDecryption() throws {
        let original = makeTestEnvelope()
        let frame = try FrameCrypto.encryptFrame(envelope: original, key: testKey)

        let wrongKey = SymmetricKey(size: .bits256)
        XCTAssertThrowsError(try FrameCrypto.decryptFrame(frame: frame, key: wrongKey)) { error in
            XCTAssertTrue(error is FrameCryptoError,
                          "Expected FrameCryptoError, got \(type(of: error))")
        }
    }

    // MARK: - Tampered ciphertext

    func testTamperedCiphertextFails() throws {
        let original = makeTestEnvelope()
        let frame = try FrameCrypto.encryptFrame(envelope: original, key: testKey)

        // Split and tamper with the ciphertext part.
        let parts = frame.split(separator: ".", maxSplits: 1)
        guard parts.count == 2,
              var ciphertextData = Data(base64Encoded: String(parts[1])),
              !ciphertextData.isEmpty else {
            XCTFail("Unexpected frame format")
            return
        }

        // Flip a byte in the ciphertext.
        ciphertextData[ciphertextData.count / 2] ^= 0xFF
        let tampered = "\(parts[0]).\(ciphertextData.base64EncodedString())"

        XCTAssertThrowsError(try FrameCrypto.decryptFrame(frame: tampered, key: testKey))
    }

    // MARK: - Tampered nonce

    func testTamperedNonceFails() throws {
        let original = makeTestEnvelope()
        let frame = try FrameCrypto.encryptFrame(envelope: original, key: testKey)

        let parts = frame.split(separator: ".", maxSplits: 1)
        guard parts.count == 2,
              var nonceData = Data(base64Encoded: String(parts[0])),
              !nonceData.isEmpty else {
            XCTFail("Unexpected frame format")
            return
        }

        // Flip a byte in the nonce.
        nonceData[0] ^= 0xFF
        let tampered = "\(nonceData.base64EncodedString()).\(parts[1])"

        XCTAssertThrowsError(try FrameCrypto.decryptFrame(frame: tampered, key: testKey))
    }

    // MARK: - Frame format

    func testFrameFormatIsTwoBase64PartsWithSingleDot() throws {
        let original = makeTestEnvelope()
        let frame = try FrameCrypto.encryptFrame(envelope: original, key: testKey)

        let parts = frame.split(separator: ".", maxSplits: 1)
        XCTAssertEqual(parts.count, 2, "Frame should have exactly two parts separated by a dot")

        // Both parts should be valid base64.
        XCTAssertNotNil(Data(base64Encoded: String(parts[0])), "Nonce part should be valid base64")
        XCTAssertNotNil(Data(base64Encoded: String(parts[1])), "Ciphertext part should be valid base64")

        // Nonce should decode to 12 bytes.
        let nonceData = Data(base64Encoded: String(parts[0]))!
        XCTAssertEqual(nonceData.count, 12, "Nonce should be 12 bytes")
    }

    // MARK: - Raw encrypt/decrypt

    func testRawEncryptDecryptRoundTrip() throws {
        let plaintext = Data("Hello, World!".utf8)
        let (ciphertext, nonce) = try FrameCrypto.encrypt(data: plaintext, key: testKey)
        let decrypted = try FrameCrypto.decrypt(ciphertext: ciphertext, nonce: nonce, key: testKey)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testRawDecryptWithWrongKeyFails() throws {
        let plaintext = Data("secret".utf8)
        let (ciphertext, nonce) = try FrameCrypto.encrypt(data: plaintext, key: testKey)

        let wrongKey = SymmetricKey(size: .bits256)
        XCTAssertThrowsError(try FrameCrypto.decrypt(ciphertext: ciphertext, nonce: nonce, key: wrongKey))
    }
}
