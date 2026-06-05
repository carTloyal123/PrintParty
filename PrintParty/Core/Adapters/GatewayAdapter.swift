//
//  GatewayAdapter.swift
//  PrintParty
//
//  PrinterAdapter implementation that reads state from a paired gateway's
//  WebSocket stream rather than connecting directly to the printer.
//
//  This is the adapter that enables "works anywhere" — the gateway talks to
//  the printer on the user's LAN, and this adapter talks to the gateway
//  from wherever the phone happens to be.
//
//  The underlying GatewayStreamClient is shared across all adapters for the
//  same gateway (owned by AdapterRegistry). This adapter filters the shared
//  stream to only yield states for its specific printer.
//

import Foundation
import CryptoKit

@MainActor
final class GatewayAdapter: PrinterAdapter {

    let printerId: UUID
    let kind: String = "Gateway"
    let gatewayId: String?

    /// Connection phase, forwarded from the GatewayStreamClient (single source of truth).
    var connectionPhase: ConnectionPhase {
        streamClient.connectionPhase
    }

    /// Current connection mode of the underlying stream client.
    var connectionMode: GatewayStreamClient.ConnectionMode {
        streamClient.connectionMode
    }

    private let streamClient: GatewayStreamClient
    private let printerDisplayName: String
    private let printerModelName: String
    private var pumpTask: Task<Void, Never>?
    private var phaseObservation: NSObjectProtocol?
    private var started = false
    private var currentState: PrintJobState
    private var continuations: [UUID: AsyncStream<PrintJobState>.Continuation] = [:]

    init(
        printerId: UUID,
        printerDisplayName: String,
        printerModelName: String,
        gatewayId: String?,
        streamClient: GatewayStreamClient
    ) {
        self.printerId = printerId
        self.printerDisplayName = printerDisplayName
        self.printerModelName = printerModelName
        self.gatewayId = gatewayId
        self.streamClient = streamClient

        var idle = PrintJobState.idle(
            printerId: printerId,
            displayName: printerDisplayName,
            model: printerModelName
        )
        idle.stage = .offline
        idle.errorMessage = "Connecting to gateway\u{2026}"
        self.currentState = idle
    }

    func stateUpdates() -> AsyncStream<PrintJobState> {
        AsyncStream { continuation in
            let token = UUID()
            continuations[token] = continuation
            continuation.yield(currentState)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.continuations[token] = nil
                }
            }
        }
    }

    func start() {
        guard !started else { return }
        started = true

        // Listen for phase changes on the shared stream client so we can
        // re-emit state to our continuations (triggers AdapterRegistry pump).
        let previousOnPhaseChange = streamClient.onPhaseChange
        streamClient.onPhaseChange = { [weak self] in
            previousOnPhaseChange?()
            guard let self else { return }
            let phase = self.streamClient.connectionPhase
            if case .disconnected(let reason) = phase {
                var offline = self.currentState
                offline.stage = .offline
                offline.errorMessage = reason ?? "Gateway disconnected"
                offline.updatedAt = Date()
                self.currentState = offline
            }
            for (_, c) in self.continuations {
                c.yield(self.currentState)
            }
        }

        // Pump states from the shared stream, filtering for our printer.
        let myPrinterId = printerId
        let stream = streamClient.stateUpdates()
        pumpTask = Task { [weak self] in
            for await state in stream {
                guard let self else { return }
                guard state.printerId == myPrinterId else { continue }
                self.currentState = state
                for (_, c) in self.continuations {
                    c.yield(state)
                }
            }
        }
    }

    func stop() {
        started = false
        pumpTask?.cancel()
        pumpTask = nil
        // Don't stop the shared streamClient — it's owned by AdapterRegistry.
        for (_, c) in continuations { c.finish() }
        continuations.removeAll()
    }

    // MARK: - Request/Response pass-through

    /// Send a request over the WebSocket and await the response.
    /// Delegates to the shared GatewayStreamClient.
    func request(_ method: String, payload: any Encodable) async throws -> Data {
        return try await streamClient.request(method, payload: payload)
    }
}
