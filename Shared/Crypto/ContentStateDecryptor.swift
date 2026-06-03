//
//  ContentStateDecryptor.swift
//  PrintParty (Shared — compiled into both the app and widget extension)
//
//  Decrypts an EncryptedContentState envelope back into a PrintJobState
//  using the shared key stored in the App Group Keychain during pairing.
//
//  The encrypted envelope shape:
//    {
//      "printerId": "UUID string",
//      "v": 1,
//      "nonce": "base64 (12 bytes)",
//      "ciphertext": "base64 (combined: nonce + ciphertext + Poly1305 tag)"
//    }
//
//  If the incoming ContentState is NOT encrypted (no `ciphertext` field),
//  the decryptor returns it as-is. This enables graceful fallback for
//  pre-E2EE gateways.
//

import Foundation
import CryptoKit

/// The encrypted envelope that may arrive as ContentState via APNs.
/// When `v == 1` and `ciphertext` is non-nil, the widget must decrypt.
/// Otherwise the ContentState is a plain PrintJobState already.
public struct EncryptedContentState: Codable, Sendable, Hashable {
    public let printerId: String
    public let v: Int
    public let nonce: String       // base64
    public let ciphertext: String  // base64 (combined representation)
}

public enum ContentStateDecryptor {

    public enum DecryptionError: Error {
        case invalidKey
        case invalidNonce
        case invalidCiphertext
        case decryptionFailed
        case decodingFailed
    }

    /// Attempt to decrypt an EncryptedContentState. Returns the plaintext
    /// PrintJobState on success.
    public static func decrypt(
        envelope: EncryptedContentState,
        sharedKeyBase64: String
    ) throws -> PrintJobState {
        guard let keyData = Data(base64Encoded: sharedKeyBase64), keyData.count == 32 else {
            throw DecryptionError.invalidKey
        }
        let key = SymmetricKey(data: keyData)

        guard let nonceData = Data(base64Encoded: envelope.nonce) else {
            throw DecryptionError.invalidNonce
        }
        guard let combinedData = Data(base64Encoded: envelope.ciphertext) else {
            throw DecryptionError.invalidCiphertext
        }

        // Reconstruct the sealed box from the nonce + combined data.
        // ChaChaPoly.SealedBox(combined:) expects nonce (12) + ciphertext + tag (16).
        let sealedBox = try ChaChaPoly.SealedBox(
            nonce: ChaChaPoly.Nonce(data: nonceData),
            ciphertext: combinedData.dropFirst(12).dropLast(16),
            tag: combinedData.suffix(16)
        )
        let plaintext = try ChaChaPoly.open(sealedBox, using: key)

        guard let state = try? JSONDecoder().decode(PrintJobState.self, from: plaintext) else {
            throw DecryptionError.decodingFailed
        }
        return state
    }
}
