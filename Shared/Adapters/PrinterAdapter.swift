//
//  PrinterAdapter.swift
//  PrintParty (shared between app and widget extension)
//
//  The single contract every printer integration implements.
//
//  Concrete implementations:
//    • GatewayAdapter     — WebSocket adapter for gateway-managed printers
//

import Foundation
import PrintPartyKit

/// A read-only event source for one printer.
///
/// Implementations must:
///   - emit at least one state on `start()` (typically `.offline` or `.idle`)
///   - emit a new state whenever anything observable changes
///   - finish the stream when `stop()` is called
@MainActor
public protocol PrinterAdapter: AnyObject {

    var printerId: UUID { get }

    /// Stable description used for diagnostics ("Gateway", etc.).
    var kind: String { get }

    /// Current connection phase. Adapters update this as the underlying
    /// transport connects, disconnects, or transitions between paths.
    var connectionPhase: ConnectionPhase { get }

    /// Cold stream: only starts producing once `start()` has been called.
    /// Each access returns a new AsyncStream wired to the same source.
    func stateUpdates() -> AsyncStream<PrintJobState>

    /// Begin connecting / reading from the underlying source. Idempotent.
    func start()

    /// Stop and release resources. Idempotent.
    func stop()
}
