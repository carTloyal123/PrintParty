//
//  RelayHealthRoutes.swift
//  printparty-relay
//

import Vapor

struct RelayHealthRoutes: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("healthz", use: health)
    }

    @Sendable
    func health(req: Request) async throws -> [String: String] {
        ["status": "ok", "service": "printparty-relay", "version": "0.1.0"]
    }
}
