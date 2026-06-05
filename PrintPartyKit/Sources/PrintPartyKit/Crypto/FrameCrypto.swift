//
//  FrameCrypto.swift
//  printparty-gateway
//
//  AES-256-GCM encryption/decryption for MessageEnvelope frames.
//  Wire format: "<base64(nonce)>.<base64(ciphertext+tag)>"
//
//  Uses CryptoKit on Apple platforms, swift-crypto elsewhere.
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum FrameCryptoError: Error, CustomStringConvertible {
    case invalidFrameFormat
    case invalidBase64
    case invalidNonceSize
    case decryptionFailed
    case encodingFailed

    public var description: String {
        switch self {
        case .invalidFrameFormat: return "Frame must be <base64>.<base64>"
        case .invalidBase64: return "Invalid base64 encoding in frame"
        case .invalidNonceSize: return "Nonce must be 12 bytes"
        case .decryptionFailed: return "AES-GCM decryption/authentication failed"
        case .encodingFailed: return "Failed to encode envelope to JSON"
        }
    }
}

public enum FrameCrypto {

    /// Encrypt an envelope into the wire format: "<base64(nonce)>.<base64(ciphertext+tag)>"
    public static func encryptFrame(envelope: MessageEnvelope, key: SymmetricKey) throws -> String {
        let plaintext = try JSONEncoder().encode(envelope)
        let (ciphertext, nonce) = try encrypt(data: plaintext, key: key)
        return "\(nonce.base64EncodedString()).\(ciphertext.base64EncodedString())"
    }

    /// Decrypt a wire frame back into a MessageEnvelope.
    public static func decryptFrame(frame: String, key: SymmetricKey) throws -> MessageEnvelope {
        let parts = frame.split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else {
            throw FrameCryptoError.invalidFrameFormat
        }

        guard let nonceData = Data(base64Encoded: String(parts[0])),
              let ciphertextData = Data(base64Encoded: String(parts[1])) else {
            throw FrameCryptoError.invalidBase64
        }

        let plaintext = try decrypt(ciphertext: ciphertextData, nonce: nonceData, key: key)
        return try JSONDecoder().decode(MessageEnvelope.self, from: plaintext)
    }

    /// Encrypt raw data using AES-256-GCM with a random 12-byte nonce.
    /// Returns (ciphertext + tag, nonce).
    public static func encrypt(data: Data, key: SymmetricKey) throws -> (ciphertext: Data, nonce: Data) {
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(data, using: key, nonce: nonce)
        // ciphertext + tag combined
        let combined = sealed.ciphertext + sealed.tag
        return (ciphertext: combined, nonce: Data(nonce))
    }

    /// Decrypt raw data using AES-256-GCM.
    public static func decrypt(ciphertext: Data, nonce: Data, key: SymmetricKey) throws -> Data {
        guard nonce.count == 12 else {
            throw FrameCryptoError.invalidNonceSize
        }
        let gcmNonce = try AES.GCM.Nonce(data: nonce)
        // ciphertext contains ciphertext + tag (last 16 bytes)
        let tagSize = 16
        guard ciphertext.count >= tagSize else {
            throw FrameCryptoError.decryptionFailed
        }
        let ct = ciphertext.prefix(ciphertext.count - tagSize)
        let tag = ciphertext.suffix(tagSize)
        let sealedBox = try AES.GCM.SealedBox(nonce: gcmNonce, ciphertext: ct, tag: tag)
        do {
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw FrameCryptoError.decryptionFailed
        }
    }
}
