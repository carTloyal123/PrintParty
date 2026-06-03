//
//  PairingService.swift
//  printparty-gateway
//
//  Holds the gateway's long-lived X25519 keypair and the current pairing
//  code, performs the ECDH + HKDF derivation, and stores completed pairings.
//
//  Identity and pairings are persisted to disk via GatewayIdentityStore so
//  they survive gateway restarts.
//

import Foundation
import Crypto
import Vapor

actor PairingService {

    // MARK: - Identity

    let gatewayId: String
    let gatewayName: String
    let relayURL: String?

    private let gatewayPrivateKey: Curve25519.KeyAgreement.PrivateKey

    private let identityStore: GatewayIdentityStore
    private let logger: Logger

    // MARK: - Pairing state

    private struct CodeEntry {
        let code: String
        let expiresAt: Date
    }

    private struct Pairing {
        let deviceId: String
        let deviceName: String
        let sharedKey: SymmetricKey
        let pairedAt: Date
    }

    private var current: CodeEntry
    private var pairings: [String: Pairing] = [:]

    private static let codeLifetime: TimeInterval = 300 // 5 minutes

    init(
        gatewayId: String,
        gatewayName: String,
        privateKey: Curve25519.KeyAgreement.PrivateKey? = nil,
        identityStore: GatewayIdentityStore,
        logger: Logger,
        relayURL: String? = nil
    ) {
        self.gatewayId = gatewayId
        self.gatewayName = gatewayName
        self.relayURL = relayURL
        self.gatewayPrivateKey = privateKey ?? Curve25519.KeyAgreement.PrivateKey()
        self.identityStore = identityStore
        self.logger = logger
        self.current = CodeEntry(
            code: Self.generateCode(),
            expiresAt: Date().addingTimeInterval(Self.codeLifetime)
        )
    }

    // MARK: - Code management

    func currentPairingCode() -> String {
        rotateIfExpired()
        return current.code
    }

    func currentPairingCodeWithExpiry() -> (code: String, expiresAt: Date) {
        rotateIfExpired()
        return (current.code, current.expiresAt)
    }

    private func rotateIfExpired() {
        if Date() >= current.expiresAt {
            current = CodeEntry(
                code: Self.generateCode(),
                expiresAt: Date().addingTimeInterval(Self.codeLifetime)
            )
            logger.notice("New pairing code: \(current.code)  (valid 5 minutes)")
        }
    }

    private func rotateNow() {
        current = CodeEntry(
            code: Self.generateCode(),
            expiresAt: Date().addingTimeInterval(Self.codeLifetime)
        )
        logger.notice("New pairing code: \(current.code)  (valid 5 minutes)")
    }

    private static func generateCode() -> String {
        // 5 random bytes = 40 bits = exactly 8 base32 characters.
        var bytes = [UInt8](repeating: 0, count: 5)
        for i in 0..<5 { bytes[i] = UInt8.random(in: 0...255) }
        return Base32.encode(bytes)
    }

    // MARK: - Handshake

    func completePairing(
        code: String,
        deviceId: String,
        deviceName: String,
        devicePublicKeyBase64: String
    ) throws -> PairingRoutes.PairResponse {
        // Constant-time compare to defeat timing oracles on the code.
        rotateIfExpired()
        guard codeMatches(code) else {
            throw Abort(.unauthorized, reason: "invalid_or_expired_code")
        }

        guard let devicePubKeyData = Data(base64Encoded: devicePublicKeyBase64),
              let devicePubKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: devicePubKeyData)
        else {
            throw Abort(.badRequest, reason: "invalid_device_public_key")
        }

        // ECDH + HKDF-SHA256 → 32-byte symmetric key. Both sides do the
        // same derivation with the same salt and info, so they end up with
        // identical SymmetricKeys without ever transmitting one.
        let sharedSecret = try gatewayPrivateKey.sharedSecretFromKeyAgreement(with: devicePubKey)
        let derivedKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("printparty-pairing-v1".utf8),
            sharedInfo: Data(),
            outputByteCount: 32
        )

        let pairedAt = Date()
        pairings[deviceId] = Pairing(
            deviceId: deviceId,
            deviceName: deviceName,
            sharedKey: derivedKey,
            pairedAt: pairedAt
        )

        // Persist updated pairings to disk.
        persistPairings()

        // One-shot code: rotate immediately so a captured code can't be reused.
        rotateNow()

        logger.info("Paired device \(deviceName) (\(deviceId))")

        return PairingRoutes.PairResponse(
            gatewayId: gatewayId,
            gatewayName: gatewayName,
            gatewayPublicKey: gatewayPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            relayURL: relayURL,
            pairedAt: Date()
        )
    }

    // MARK: - Persistence

    /// Loads saved pairings from disk and populates the in-memory dict.
    func loadSavedPairings() {
        let stored = identityStore.loadPairings()
        for p in stored {
            guard let keyData = Data(base64Encoded: p.sharedKeyBase64) else {
                logger.warning("Skipping pairing for \(p.deviceId): invalid sharedKeyBase64")
                continue
            }
            pairings[p.deviceId] = Pairing(
                deviceId: p.deviceId,
                deviceName: p.deviceName,
                sharedKey: SymmetricKey(data: keyData),
                pairedAt: p.pairedAt
            )
        }
        if !stored.isEmpty {
            logger.info("Restored \(pairings.count) pairing(s) from disk")
        }
    }

    private func persistPairings() {
        let stored = pairings.values.map { p in
            GatewayIdentityStore.StoredPairing(
                deviceId: p.deviceId,
                deviceName: p.deviceName,
                sharedKeyBase64: p.sharedKey.withUnsafeBytes { Data(Array($0)).base64EncodedString() },
                pairedAt: p.pairedAt
            )
        }
        identityStore.savePairings(stored)
    }

    /// Constant-time-ish comparison. Codes are 8 ASCII chars so the
    /// difference between this and a real CT-compare is negligible.
    private func codeMatches(_ candidate: String) -> Bool {
        let a = Array(current.code.utf8)
        let b = Array(candidate.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}
