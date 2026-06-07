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
        v1.get("pair", "qr", use: qrCode)
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
        /// Base64-encoded AES-256-GCM ciphertext+tag of the 32-byte group key.
        let encryptedGroupKey: String?
        /// Base64-encoded 12-byte nonce used for the group key encryption.
        let groupKeyNonce: String?
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

    // MARK: - GET /v1/pair/qr

    struct QRResponse: Content {
        let payload: String
        let expiresAt: Date
    }

    /// Returns the current pairing QR code (terminal art by default, JSON with
    /// `Accept: application/json`). The payload embeds the live pairing code, so
    /// this is restricted to loopback unless QR_ALLOW_REMOTE=true.
    @Sendable
    func qrCode(req: Request) async throws -> Response {
        let allowRemote = Environment.get("QR_ALLOW_REMOTE")?.lowercased() == "true"
        if !allowRemote {
            let ip = req.remoteAddress?.ipAddress ?? ""
            guard ip == "127.0.0.1" || ip == "::1" else {
                throw Abort(.forbidden, reason: "QR endpoint restricted to localhost")
            }
        }

        let (code, expiresAt) = await req.pairing.currentPairingCodeWithExpiry()

        // Use a real LAN host (not 127.0.0.1) so a scanning phone can reach us.
        let host = req.application.pairingHosts.first ?? "localhost"
        let port = req.application.http.server.configuration.port
        let baseURL = "http://\(host):\(port)"
        let payload = QRTerminalRenderer.pairingURL(baseURL: baseURL, code: code)

        // Only return JSON when the client *explicitly* asks for it. A plain
        // `Accept: */*` (curl/browser default) gets the scannable terminal QR,
        // because Vapor's media-type equality treats `*/*` as matching JSON.
        let acceptsJSON = (req.headers.first(name: .accept) ?? "").contains("application/json")
        if acceptsJSON {
            return try await QRResponse(payload: payload, expiresAt: expiresAt).encodeResponse(for: req)
        }

        let qrArt = QRTerminalRenderer.renderToTerminal(payload: payload)
        let body = "\(qrArt)\n\nPayload: \(payload)\nExpires: \(expiresAt)\n"
        return Response(
            status: .ok,
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: .init(string: body)
        )
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
            // Sweep all expired entries to prevent unbounded memory growth.
            let cutoff = now.addingTimeInterval(-windowSeconds)
            for (key, dates) in attempts {
                let valid = dates.filter { $0 > cutoff }
                if valid.isEmpty {
                    attempts[key] = nil
                } else {
                    attempts[key] = valid
                }
            }

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
    var pairingRateLimiter: PairingRateLimiter { storage[PairingRateLimiterKey.self]! }
}
