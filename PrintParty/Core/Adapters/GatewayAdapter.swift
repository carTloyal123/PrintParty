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

@MainActor
final class GatewayAdapter: PrinterAdapter {

    let printerId: UUID
    let kind: String = "Gateway"

    /// Exposed so LiveActivityCoordinator can forward push tokens.
    let gatewayBaseURL: URL
    private let relayURL: URL?
    private let gatewayId: String?
    private let printerDisplayName: String
    private let printerModelName: String
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
        gatewayId: String? = nil
    ) {
        self.printerId = printerId
        self.printerDisplayName = printerDisplayName
        self.printerModelName = printerModelName
        self.gatewayBaseURL = gatewayBaseURL
        self.relayURL = relayURL
        self.gatewayId = gatewayId

        var idle = PrintJobState.idle(
            printerId: printerId,
            displayName: printerDisplayName,
            model: printerModelName
        )
        idle.stage = .offline
        idle.errorMessage = "Connecting to gateway…"
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
            gatewayId: gatewayId
        )
        self.streamClient = client

        // When the WebSocket disconnects, immediately emit an offline state
        // so the UI shows the printer is disconnected instead of frozen.
        client.onDisconnect = { [weak self] in
            guard let self else { return }
            var offline = self.currentState
            offline.stage = .offline
            offline.errorMessage = "Gateway disconnected"
            offline.updatedAt = Date()
            self.currentState = offline
            for (_, c) in self.continuations {
                c.yield(offline)
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
}
