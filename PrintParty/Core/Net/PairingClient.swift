//
//  PairingClient.swift
//  PrintParty
//
//  Performs the X25519 pairing handshake with a self-hosted gateway.
//
//  Wire format (must match gateway's PairingRoutes.swift exactly):
//    POST /v1/pair  body: { code, deviceId, deviceName, devicePublicKey }
//    200            body: { gatewayId, gatewayName, gatewayPublicKey, pairedAt }
//
//  Key derivation is identical on both sides:
//    sharedSecret = X25519(ourPrivate, theirPublic)
//    sharedKey    = HKDF-SHA256(sharedSecret, salt="printparty-pairing-v1", info="", L=32)
//

import Foundation
import CryptoKit

enum PairingError: Error, LocalizedError {
    case invalidURL
    case transport(String)
    case server(status: Int, reason: String?)
    case invalidResponse(String)
    case invalidGatewayKey

    var errorDescription: String? {
        switch self {
        case .invalidURL:                       return "Invalid gateway URL."
        case .transport(let m):                 return "Network error: \(m)"
        case .server(_, let reason?):
            return Self.humanReason(reason)
        case .server(let status, nil):          return "Gateway returned HTTP \(status)."
        case .invalidResponse(let m):           return "Gateway responded with unexpected data: \(m)"
        case .invalidGatewayKey:                return "Gateway sent an invalid public key."
        }
    }

    private static func humanReason(_ raw: String) -> String {
        switch raw {
        case "invalid_or_expired_code": return "Pairing code is incorrect or has expired. If using a QR code, refresh it on the gateway and scan again."
        case "invalid_device_public_key": return "iOS sent an invalid public key (bug)."
        default: return raw
        }
    }
}

/// Result of a successful pairing.
struct PairingResult {
    let gatewayId: String
    let gatewayName: String
    /// Shared 256-bit symmetric key derived via X25519 + HKDF.
    let sharedKey: SymmetricKey
    /// Relay URL returned by the gateway for remote (non-LAN) access.
    let relayURL: String?
    /// 32-byte group key for decrypting broadcast events (AES-256-GCM).
    /// Nil if the gateway doesn't support group keys (older version).
    let groupKey: Data?
}

enum PairingClient {

    // MARK: - Health

    struct HealthResponse: Decodable {
        let status: String
        let version: String
        let gatewayId: String
        let gatewayName: String
    }

    static func ping(baseURL: URL) async throws -> HealthResponse {
        let url = baseURL.appendingPathComponent("healthz")
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        let (data, response) = try await dataTask(req)
        guard let http = response as? HTTPURLResponse else {
            throw PairingError.invalidResponse("not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PairingError.server(status: http.statusCode, reason: nil)
        }
        do {
            return try JSONDecoder().decode(HealthResponse.self, from: data)
        } catch {
            throw PairingError.invalidResponse("could not decode /healthz response")
        }
    }

    // MARK: - Pairing handshake

    private struct PairRequest: Encodable {
        let code: String
        let deviceId: String
        let deviceName: String
        let devicePublicKey: String
    }

    private struct PairResponse: Decodable {
        let gatewayId: String
        let gatewayName: String
        let gatewayPublicKey: String
        let relayURL: String?
        let encryptedGroupKey: String?
        let groupKeyNonce: String?
    }

    private struct ErrorResponse: Decodable {
        let error: Bool
        let reason: String?
    }

    static func pair(
        baseURL: URL,
        code: String,
        deviceId: String,
        deviceName: String
    ) async throws -> PairingResult {
        // 1. Generate ephemeral X25519 keypair for this pairing.
        let devicePrivate = Curve25519.KeyAgreement.PrivateKey()
        let devicePublic = devicePrivate.publicKey.rawRepresentation

        // 2. Build request body.
        let body = PairRequest(
            code: code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            deviceId: deviceId,
            deviceName: deviceName,
            devicePublicKey: devicePublic.base64EncodedString()
        )
        let url = baseURL.appendingPathComponent("v1/pair")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10
        req.httpBody = try JSONEncoder().encode(body)

        // 3. Send.
        let (data, response) = try await dataTask(req)
        guard let http = response as? HTTPURLResponse else {
            throw PairingError.invalidResponse("not an HTTP response")
        }

        // 4. Surface server errors with their reason string.
        guard (200..<300).contains(http.statusCode) else {
            let reason = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.reason
            throw PairingError.server(status: http.statusCode, reason: reason)
        }

        // 5. Decode + derive.
        let pairResp: PairResponse
        do {
            pairResp = try JSONDecoder().decode(PairResponse.self, from: data)
        } catch {
            throw PairingError.invalidResponse("could not decode /v1/pair response")
        }

        guard let gatewayPublicKeyData = Data(base64Encoded: pairResp.gatewayPublicKey),
              let gatewayPublic = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: gatewayPublicKeyData)
        else {
            throw PairingError.invalidGatewayKey
        }

        let sharedSecret = try devicePrivate.sharedSecretFromKeyAgreement(with: gatewayPublic)
        let sharedKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("printparty-pairing-v1".utf8),
            sharedInfo: Data(),
            outputByteCount: 32
        )

        // Decrypt group key if provided by the gateway.
        var groupKey: Data? = nil
        if let encryptedGroupKeyB64 = pairResp.encryptedGroupKey,
           let nonceB64 = pairResp.groupKeyNonce,
           let ciphertextAndTag = Data(base64Encoded: encryptedGroupKeyB64),
           let nonceData = Data(base64Encoded: nonceB64) {
            do {
                let nonce = try AES.GCM.Nonce(data: nonceData)
                let tagSize = 16
                let ct = ciphertextAndTag.prefix(ciphertextAndTag.count - tagSize)
                let tag = ciphertextAndTag.suffix(tagSize)
                let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
                groupKey = try AES.GCM.open(sealedBox, using: sharedKey)
            } catch {
                // Non-fatal: gateway may have sent an older format.
            }
        }

        return PairingResult(
            gatewayId: pairResp.gatewayId,
            gatewayName: pairResp.gatewayName,
            sharedKey: sharedKey,
            relayURL: pairResp.relayURL,
            groupKey: groupKey
        )
    }

    // MARK: - URLSession helper

    private static func dataTask(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            throw PairingError.transport(error.localizedDescription)
        }
    }
}
