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

import Foundation
import CryptoKit

@MainActor
final class GatewayAdapter: PrinterAdapter {

    let printerId: UUID
    let kind: String = "Gateway"

    /// Connection phase, forwarded from the GatewayStreamClient (single source of truth).
    var connectionPhase: ConnectionPhase {
        streamClient?.connectionPhase ?? .disconnected()
    }

    /// Exposed so LiveActivityCoordinator can forward push tokens.
    let gatewayBaseURL: URL
    private let relayURL: URL?
    let gatewayId: String?
    private let printerDisplayName: String
    private let printerModelName: String
    /// E2EE keys for relay mode.
    private let sharedKey: SymmetricKey?
    private let groupKey: SymmetricKey?
    /// Device ID for this paired device.
    private let deviceId: String?
    private var streamClient: GatewayStreamClient?
    private var pumpTask: Task<Void, Never>?
    private var started = false
    private var currentState: PrintJobState
    private var continuations: [UUID: AsyncStream<PrintJobState>.Continuation] = [:]

    /// Current connection mode of the underlying stream client.
    var connectionMode: GatewayStreamClient.ConnectionMode {
        streamClient?.connectionMode ?? .disconnected
    }

    init(
        printerId: UUID,
        printerDisplayName: String,
        printerModelName: String,
        gatewayBaseURL: URL,
        relayURL: URL? = nil,
        gatewayId: String? = nil,
        sharedKey: SymmetricKey? = nil,
        groupKey: SymmetricKey? = nil,
        deviceId: String? = nil
    ) {
        self.printerId = printerId
        self.printerDisplayName = printerDisplayName
        self.printerModelName = printerModelName
        self.gatewayBaseURL = gatewayBaseURL
        self.relayURL = relayURL
        self.gatewayId = gatewayId
        self.sharedKey = sharedKey
        self.groupKey = groupKey
        self.deviceId = deviceId

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

        let client = GatewayStreamClient(
            baseURL: gatewayBaseURL,
            relayURL: relayURL,
            gatewayId: gatewayId,
            sharedKey: sharedKey,
            groupKey: groupKey,
            deviceId: deviceId
        )
        self.streamClient = client

        // When the stream client's phase changes, re-emit our current state
        // so the AdapterRegistry pump loop picks up the new phase.
        // Also handle disconnects: emit an offline PrintJobState so the UI
        // shows the printer as disconnected rather than frozen on stale data.
        client.onPhaseChange = { [weak self] in
            guard let self else { return }
            let phase = client.connectionPhase
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

        client.start()

        let myPrinterId = printerId
        let stream = client.stateUpdates()
        pumpTask = Task { [weak self] in
            for await state in stream {
                guard let self else { return }
                // Only consume states for OUR printer; the gateway streams
                // all printers on one WebSocket.
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
        streamClient?.stop()
        streamClient = nil
        for (_, c) in continuations { c.finish() }
        continuations.removeAll()
    }

    // MARK: - Request/Response pass-through

    /// Send a request over the WebSocket and await the response.
    /// Delegates to the underlying GatewayStreamClient.
    func request(_ method: String, payload: any Encodable) async throws -> Data {
        guard let client = streamClient else {
            throw GatewayStreamError.notConnected
        }
        return try await client.request(method, payload: payload)
    }
}
