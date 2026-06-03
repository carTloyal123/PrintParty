//
//  PrinterAdapter.swift
//  PrintParty (shared between app and widget extension)
//
//  The single contract every printer integration implements. By the v2
//  architecture plan, this is the abstraction that will eventually live in
//  both the iOS app (for LAN adapters running on-device while in-network) and
//  the user-hosted gateway (for cloud adapters running off-device).
//
//  Concrete implementations:
//    • BambuLanAdapter    — Bambu Lab LAN MQTT adapter
//    • GatewayAdapter     — WebSocket adapter for gateway-managed printers
//

import Foundation

/// A read-only event source for one printer.
///
/// Implementations must:
///   - emit at least one state on `start()` (typically `.offline` or `.idle`)
///   - emit a new state whenever anything observable changes
///   - finish the stream when `stop()` is called
@MainActor
public protocol PrinterAdapter: AnyObject {

    var printerId: UUID { get }

    /// Stable description used for diagnostics ("Bambu LAN", "Gateway", etc.).
    var kind: String { get }

    /// Cold stream: only starts producing once `start()` has been called.
    /// Each access returns a new AsyncStream wired to the same source.
    func stateUpdates() -> AsyncStream<PrintJobState>

    /// Begin connecting / reading from the underlying source. Idempotent.
    func start()

    /// Stop and release resources. Idempotent.
    func stop()
}
