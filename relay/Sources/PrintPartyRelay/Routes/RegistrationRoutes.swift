//
//  RegistrationRoutes.swift
//  printparty-relay
//
//  POST /v1/gateways/register — gateways self-register to obtain an API key
//  for tunnel access. Idempotent: re-registering the same gatewayId returns
//  the existing key. Rate-limited to 10 registrations per IP per hour.
//

import Vapor
import NIOConcurrencyHelpers

// MARK: - Rate Limiter

/// Simple in-memory rate limiter: max N requests per IP within a sliding window.
final class RegistrationRateLimiter: Sendable {
    private let lock = NIOLock()
    private let maxRequests: Int
    private let windowSeconds: TimeInterval
    nonisolated(unsafe) private var attempts: [String: [Date]] = [:]

    init(maxRequests: Int = 10, windowSeconds: TimeInterval = 3600) {
        self.maxRequests = maxRequests
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
            if history.count >= maxRequests {
                return false
            }
            history.append(now)
            attempts[ip] = history
            return true
        }
    }
}

struct RegistrationRateLimiterKey: StorageKey {
    typealias Value = RegistrationRateLimiter
}

extension Application {
    var registrationRateLimiter: RegistrationRateLimiter { storage[RegistrationRateLimiterKey.self]! }
}

// MARK: - Routes

struct RegistrationRoutes: RouteCollection {

    func boot(routes: any RoutesBuilder) throws {
        let v1 = routes.grouped("v1", "gateways")
        v1.post("register", use: register)
    }

    struct RegisterRequest: Content {
        let gatewayId: String
        let gatewayName: String
    }

    struct RegisterResponse: Content {
        let apiKey: String
    }

    @Sendable
    func register(req: Request) throws -> RegisterResponse {
        let clientIP = req.remoteAddress?.ipAddress ?? "unknown"
        let limiter = req.application.registrationRateLimiter
        guard limiter.checkAndRecord(ip: clientIP) else {
            throw Abort(.tooManyRequests, reason: "rate_limit_exceeded")
        }

        let body = try req.content.decode(RegisterRequest.self)
        let apiKey = req.gatewayRegistry.register(
            gatewayId: body.gatewayId,
            name: body.gatewayName
        )
        return RegisterResponse(apiKey: apiKey)
    }
}
