//
//  PairingRoutes.swift
//  printparty-gateway
//
//  POST /v1/pair — completes the X25519 handshake. The iOS app sends its
//  public key + a pairing code printed by the gateway at startup; the
//  gateway responds with its own public key. Both sides then derive the
//  same SymmetricKey via X25519 ECDH + HKDF (see PairingService).
//

import Vapor

struct PairingRoutes: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        let v1 = routes.grouped("v1")
        v1.post("pair", use: pair)
        v1.get("pair", "code", use: currentCode)
    }

    // MARK: - POST /v1/pair

    struct PairRequest: Content {
        let code: String
        let deviceId: String
        let deviceName: String
        /// Base64-encoded raw X25519 public key (32 bytes).
        let devicePublicKey: String
    }

    struct PairResponse: Content {
        let gatewayId: String
        let gatewayName: String
        /// Base64-encoded raw X25519 public key (32 bytes).
        let gatewayPublicKey: String
        let relayURL: String?
        let pairedAt: Date
    }

    @Sendable
    func pair(req: Request) async throws -> PairResponse {
        // H-19: Simple rate limiting on pairing attempts.
        // Track attempts per IP in application storage.
        let clientIP = req.remoteAddress?.ipAddress ?? "unknown"
        let now = Date()
        let rateLimiter = req.application.pairingRateLimiter
        let allowed = rateLimiter.checkAndRecord(ip: clientIP, now: now)
        guard allowed else {
            throw Abort(.tooManyRequests, reason: "too_many_pairing_attempts")
        }

        let body = try req.content.decode(PairRequest.self)
        return try await req.pairing.completePairing(
            code: body.code,
            deviceId: body.deviceId,
            deviceName: body.deviceName,
            devicePublicKeyBase64: body.devicePublicKey
        )
    }

    // MARK: - GET /v1/pair/code (development convenience)

    struct CodeResponse: Content {
        let code: String
        let expiresAt: Date
    }

    @Sendable
    func currentCode(req: Request) async throws -> CodeResponse {
        // H-03: Only expose the pairing code in development mode.
        guard req.application.environment == .development else {
            throw Abort(.notFound)
        }
        let (code, expiresAt) = await req.pairing.currentPairingCodeWithExpiry()
        return CodeResponse(code: code, expiresAt: expiresAt)
    }
}

// MARK: - Pairing rate limiter (H-19)

/// Simple in-memory rate limiter: max N attempts per IP within a sliding window.
final class PairingRateLimiter: Sendable {
    private let lock = NSLock()
    private let maxAttempts: Int
    private let windowSeconds: TimeInterval
    nonisolated(unsafe) private var attempts: [String: [Date]] = [:]

    init(maxAttempts: Int = 10, windowSeconds: TimeInterval = 60) {
        self.maxAttempts = maxAttempts
        self.windowSeconds = windowSeconds
    }

    func checkAndRecord(ip: String, now: Date = Date()) -> Bool {
        lock.withLock {
            let cutoff = now.addingTimeInterval(-windowSeconds)
            var history = attempts[ip, default: []].filter { $0 > cutoff }
            if history.count >= maxAttempts {
                return false
            }
            history.append(now)
            attempts[ip] = history
            return true
        }
    }
}

struct PairingRateLimiterKey: StorageKey {
    typealias Value = PairingRateLimiter
}

extension Application {
    var pairingRateLimiter: PairingRateLimiter {
        if let existing = storage[PairingRateLimiterKey.self] {
            return existing
        }
        let limiter = PairingRateLimiter()
        storage[PairingRateLimiterKey.self] = limiter
        return limiter
    }
}
