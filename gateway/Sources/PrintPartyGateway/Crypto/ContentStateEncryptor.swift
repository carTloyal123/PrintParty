//
//  ContentStateEncryptor.swift
//  printparty-gateway
//
//  Encrypts a PrintJobState into the E2EE envelope that the relay forwards
//  to APNs and the iOS widget extension decrypts.
//
//  Envelope shape (matches the iOS EncryptedContentState):
//    {
//      "printerId": "UUID string",
//      "v": 1,
//      "nonce": "base64 (12 bytes)",
//      "ciphertext": "base64 (encrypted JSON + 16-byte Poly1305 tag)"
//    }
//
//  Cipher: ChaCha20-Poly1305 (IETF / RFC 7539)
//  Key: 256-bit SymmetricKey derived during X25519 pairing (HKDF-SHA256).
//

import Foundation
import Crypto

enum ContentStateEncryptor {

    struct EncryptedEnvelope: Codable, Sendable {
        let printerId: String
        let v: Int
        let nonce: String       // base64
        let ciphertext: String  // base64
    }

    /// Encrypt a PrintJobState for a specific device using its shared key.
    /// Returns the envelope ready for JSON encoding into the APNs content-state.
    ///
    /// The ciphertext field contains the combined representation (ciphertext + tag)
    /// that ChaChaPoly.SealedBox expects on the decryption side.
    static func encrypt(
        state: PrintJobState,
        sharedKeyBase64: String
    ) throws -> EncryptedEnvelope {
        guard let keyData = Data(base64Encoded: sharedKeyBase64), keyData.count == 32 else {
            throw EncryptionError.invalidKey
        }
        let key = SymmetricKey(data: keyData)

        let plaintext = try JSONEncoder().encode(state)
        let nonce = ChaChaPoly.Nonce()
        let sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce)

        // combined = ciphertext + tag (what the decryptor needs alongside the nonce)
        return EncryptedEnvelope(
            printerId: state.printerId.uuidString,
            v: 1,
            nonce: Data(nonce).base64EncodedString(),
            ciphertext: sealed.combined.base64EncodedString()
        )
    }

    enum EncryptionError: Error {
        case invalidKey
    }
}
