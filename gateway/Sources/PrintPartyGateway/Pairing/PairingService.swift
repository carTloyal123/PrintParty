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

    /// 32-byte group key shared with all paired devices for broadcast encryption.
    private var groupKey: SymmetricKey?
    private let groupKeyPath: String

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

    /// Pending group key rotations for each paired device, keyed by deviceId.
    /// Created when a device is unpaired and the group key is rotated.
    /// Consumed when the device next connects (sent as a key.rotate event).
    struct PendingKeyRotation: Sendable {
        let encryptedKey: Data
        let nonce: Data
    }
    private(set) var pendingKeyRotations: [String: PendingKeyRotation] = [:]

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

        let dataDir = ProcessInfo.processInfo.environment["PRINTPARTY_DATA_DIR"]
            ?? (NSHomeDirectory() + "/.printparty")
        self.groupKeyPath = dataDir + "/group-key.bin"
    }

    // MARK: - Group key management

    /// Loads the group key from disk if it exists.
    func loadGroupKey() {
        guard FileManager.default.fileExists(atPath: groupKeyPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: groupKeyPath)),
              data.count == 32 else {
            return
        }
        groupKey = SymmetricKey(data: data)
        logger.info("Loaded group key from disk")
    }

    /// Generates a new 32-byte group key and persists it.
    private func generateGroupKey() -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        groupKey = key
        persistGroupKey(key)
        logger.info("Generated new group key")
        return key
    }

    private func persistGroupKey(_ key: SymmetricKey) {
        let data = key.withUnsafeBytes { Data($0) }
        do {
            let dir = (groupKeyPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: groupKeyPath), options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: groupKeyPath
            )
        } catch {
            logger.error("Failed to persist group key: \(error)")
        }
    }

    /// Encrypts the group key with a device's shared key using AES-256-GCM.
    /// Returns (ciphertext, nonce) both base64-encoded.
    private func encryptGroupKey(with sharedKey: SymmetricKey) throws -> (encryptedGroupKey: String, groupKeyNonce: String) {
        let gk = groupKey ?? generateGroupKey()
        let groupKeyData = gk.withUnsafeBytes { Data($0) }
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(groupKeyData, using: sharedKey, nonce: nonce)
        let ciphertext = sealed.ciphertext + sealed.tag
        return (
            encryptedGroupKey: ciphertext.base64EncodedString(),
            groupKeyNonce: Data(nonce).base64EncodedString()
        )
    }

    // MARK: - Group key rotation

    /// Rotate the group key: generate a new one, persist it, and create
    /// pending rotations for each remaining paired device.
    func rotateGroupKey() async {
        let newKey = generateGroupKey()
        logger.info("Group key rotated")

        // Create encrypted copies for each remaining device.
        pendingKeyRotations.removeAll()
        for (deviceId, pairing) in pairings {
            do {
                let groupKeyData = newKey.withUnsafeBytes { Data($0) }
                let nonce = AES.GCM.Nonce()
                let sealed = try AES.GCM.seal(groupKeyData, using: pairing.sharedKey, nonce: nonce)
                let ciphertextAndTag = sealed.ciphertext + sealed.tag
                pendingKeyRotations[deviceId] = PendingKeyRotation(
                    encryptedKey: ciphertextAndTag,
                    nonce: Data(nonce)
                )
                logger.debug("Queued key rotation for device \(deviceId)")
            } catch {
                logger.error("Failed to encrypt rotated group key for \(deviceId): \(error)")
            }
        }
    }

    /// Unpair a device and rotate the group key so the removed device
    /// cannot decrypt future broadcast events.
    func unpairDevice(deviceId: String) async {
        guard pairings[deviceId] != nil else {
            logger.warning("Attempted to unpair unknown device \(deviceId)")
            return
        }

        let deviceName = pairings[deviceId]?.deviceName ?? deviceId
        pairings[deviceId] = nil
        persistPairings()
        logger.info("Unpaired device \(deviceName) (\(deviceId))")

        // Rotate group key if there are remaining devices.
        if !pairings.isEmpty {
            await rotateGroupKey()
        } else {
            // No devices left — just clear the group key.
            groupKey = nil
            try? FileManager.default.removeItem(atPath: groupKeyPath)
            logger.info("Cleared group key (no remaining devices)")
        }
    }

    /// Returns and clears the pending key rotation for a specific device.
    func consumePendingKeyRotation(forDevice deviceId: String) -> PendingKeyRotation? {
        pendingKeyRotations.removeValue(forKey: deviceId)
    }

    // MARK: - Key accessors (for MessageRouter / RelayTunnelClient)

    /// Returns the group key used for broadcast encryption, or nil if none exists yet.
    func getGroupKey() -> SymmetricKey? {
        groupKey
    }

    /// Returns all paired device shared keys as [(deviceId, sharedKey)].
    /// Used for try-each decryption of incoming relay frames.
    func pairedDeviceKeys() -> [(deviceId: String, sharedKey: SymmetricKey)] {
        pairings.map { ($0.key, $0.value.sharedKey) }
    }

    /// Returns the shared key for a specific device, if paired.
    func sharedKey(forDevice deviceId: String) -> SymmetricKey? {
        pairings[deviceId]?.sharedKey
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
        let key = SymmetricKey(size: .bits128) // smallest standard size; we only use 5 bytes
        let bytes: [UInt8] = key.withUnsafeBytes { Array($0.prefix(5)) }
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

        // Encrypt the group key for this device. Generate one if this is
        // the first pairing.
        var encryptedGroupKey: String? = nil
        var groupKeyNonce: String? = nil
        do {
            let encrypted = try encryptGroupKey(with: derivedKey)
            encryptedGroupKey = encrypted.encryptedGroupKey
            groupKeyNonce = encrypted.groupKeyNonce
        } catch {
            logger.error("Failed to encrypt group key for device \(deviceId): \(error)")
        }

        return PairingRoutes.PairResponse(
            gatewayId: gatewayId,
            gatewayName: gatewayName,
            gatewayPublicKey: gatewayPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            relayURL: relayURL,
            pairedAt: Date(),
            encryptedGroupKey: encryptedGroupKey,
            groupKeyNonce: groupKeyNonce
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

    /// Constant-time comparison. Iterates over the longer of the two
    /// inputs so that differing lengths do not produce a measurably
    /// shorter execution.
    private func codeMatches(_ candidate: String) -> Bool {
        let a = Array(current.code.utf8)
        let b = Array(candidate.utf8)
        let length = max(a.count, b.count)
        var diff: UInt8 = 0
        for i in 0..<length {
            let aByte: UInt8 = i < a.count ? a[i] : 0
            let bByte: UInt8 = i < b.count ? b[i] : 0
            diff |= aByte ^ bByte
        }
        diff |= UInt8(truncatingIfNeeded: a.count ^ b.count)
        return diff == 0
    }
}
