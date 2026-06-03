//
//  AdapterRegistry.swift
//  PrintParty
//
//  Runtime registry of running PrinterAdapters keyed by printerId.
//
//  Owns one adapter per registered Printer, pumps its `stateUpdates()` stream
//  into an @Observable dict, and is the single source of truth for current
//  PrintJobState across the UI and the LiveActivityCoordinator.
//
//  Lifecycle is driven from PrintPartyApp on launch (initial sync) and from
//  the PrintersListView when users add/delete printers.
//

import Foundation
import Observation

@MainActor
@Observable
final class AdapterRegistry {

    static let shared = AdapterRegistry()

    /// Latest state for every registered printer. SwiftUI views read from
    /// here; changes flip the @Observable graph and re-render.
    private(set) var states: [UUID: PrintJobState] = [:]

    /// Tracks how each printer's current state was obtained.
    enum StateSource: Equatable {
        /// State from the live WebSocket/MQTT adapter connection (LAN).
        case adapter
        /// State from the live WebSocket connection via relay tunnel.
        case relay
        /// Fallback state delivered via APNs push (WebSocket offline).
        case push
    }
    private(set) var stateSources: [UUID: StateSource] = [:]

    private var adapters: [UUID: PrinterAdapter] = [:]
    private var pumpTasks: [UUID: Task<Void, Never>] = [:]
    /// Reverse map: remotePrinterId → local Printer.id, for gateway printers.
    /// The LiveActivityCoordinator tracks by remotePrinterId but adapters are
    /// keyed by local Printer.id.
    private var remoteToLocalId: [UUID: UUID] = [:]
    private init() {}

    // MARK: - Lifecycle

    /// Register a printer if not already registered. Safe to call repeatedly.
    func register(printer: Printer) {
        guard adapters[printer.id] == nil else { return }
        guard let adapter = makeAdapter(for: printer) else { return }

        adapters[printer.id] = adapter
        adapter.start()

        // Track the remote → local ID mapping for gateway printers
        // so lookups by remotePrinterId work.
        if let remoteId = printer.remotePrinterId {
            remoteToLocalId[remoteId] = printer.id
        }

        let stream = adapter.stateUpdates()
        let printerId = printer.id
        pumpTasks[printerId] = Task { [weak self] in
            for await newState in stream {
                guard let self else { return }
                self.states[printerId] = newState

                // Determine source based on connection mode for gateway adapters.
                if let gwAdapter = adapter as? GatewayAdapter {
                    switch gwAdapter.connectionMode {
                    case .relay:
                        self.stateSources[printerId] = .relay
                    case .lan, .disconnected:
                        self.stateSources[printerId] = .adapter
                    }
                } else {
                    self.stateSources[printerId] = .adapter
                }

                // Push directly into the Live Activity coordinator so updates
                // land in the lock-screen banner / Dynamic Island as soon as
                // telemetry arrives — no 1Hz polling latency.
                LiveActivityCoordinator.shared.notify(state: newState)
            }
        }
    }

    /// Ingest a push-delivered state from the Live Activity coordinator.
    /// Called whenever APNs delivers a content state update. If the adapter
    /// is currently offline for this printer, the push state replaces the
    /// offline state in the UI. If the adapter is online, the push is
    /// ignored (adapter data is authoritative).
    func ingestPushState(_ state: PrintJobState) {
        // Map from the push printerId (remotePrinterId for gateway printers)
        // to the local Printer.id used as the key in `states`.
        let localId: UUID
        if let mapped = remoteToLocalId[state.printerId] {
            localId = mapped
        } else if adapters[state.printerId] != nil {
            localId = state.printerId
        } else {
            print("[AdapterRegistry] ingestPushState: unknown printer \(state.printerId) — ignoring")
            return
        }

        // Only replace if the adapter is offline or we're already in push mode.
        let currentSource = stateSources[localId] ?? .adapter
        let currentState = states[localId]
        let isOffline = currentState?.stage == .offline

        if isOffline || currentSource == .push {
            print("[AdapterRegistry] ingestPushState: using push data for \(localId) (stage=\(state.stage.rawValue), wasOffline=\(isOffline))")
            states[localId] = state
            stateSources[localId] = .push
        } else {
            print("[AdapterRegistry] ingestPushState: adapter is live (stage=\(currentState?.stage.rawValue ?? "nil")) — push ignored for \(localId)")
        }
    }

    /// Stop and forget an adapter. Called when a printer is deleted.
    /// Also ends any associated Live Activity to prevent orphaned activities.
    func unregister(printerId: UUID) {
        // Capture the state's printerId before clearing — for gateway printers
        // this is the remotePrinterId (gateway-assigned UUID), which is the key
        // the LiveActivityCoordinator uses for tracking activities.
        let activityPrinterId = states[printerId]?.printerId ?? printerId

        // Clean up the remote → local mapping.
        remoteToLocalId = remoteToLocalId.filter { $0.value != printerId }

        pumpTasks[printerId]?.cancel()
        pumpTasks[printerId] = nil
        adapters[printerId]?.stop()
        adapters[printerId] = nil
        states[printerId] = nil
        stateSources[printerId] = nil

        // End any Live Activity for this printer so it doesn't linger
        // on the lock screen after the printer is removed.
        Task {
            await LiveActivityCoordinator.shared.endActivity(for: activityPrinterId)
        }
    }

    /// Replay registration for a set of printers (e.g. on app launch).
    /// Idempotent.
    func sync(with printers: [Printer]) {
        let currentIds = Set(printers.map(\.id))
        // Unregister anything that's gone.
        for id in adapters.keys where !currentIds.contains(id) {
            unregister(printerId: id)
        }
        // Register anything new.
        for printer in printers {
            register(printer: printer)
        }
    }

    // MARK: - Lookup

    func adapter(for printerId: UUID) -> PrinterAdapter? {
        // Direct lookup (by local Printer.id)
        if let a = adapters[printerId] { return a }
        // Reverse lookup (by remotePrinterId, used by LiveActivityCoordinator)
        if let localId = remoteToLocalId[printerId] { return adapters[localId] }
        return nil
    }

    /// Convenience: returns the registered state or, failing that, a synthesized
    /// idle state derived from the Printer record.
    func state(for printer: Printer) -> PrintJobState {
        if let existing = states[printer.id] {
            return existing
        }
        return .idle(
            printerId: printer.id,
            displayName: printer.displayName,
            model: printer.modelName
        )
    }

    /// How the current state for a printer was obtained.
    func stateSource(for printer: Printer) -> StateSource {
        stateSources[printer.id] ?? .adapter
    }

    // MARK: - Factory

    private func makeAdapter(for printer: Printer) -> PrinterAdapter? {
        switch printer.adapterKind {
        case .bambuLabA1Mini:
            let accessCode = KeychainStore.get(
                KeychainStore.bambuAccessCodeAccount(printerId: printer.id)
            ) ?? ""
            let config = BambuLanAdapter.Config(
                host: printer.host ?? "",
                serial: printer.serial ?? "",
                accessCode: accessCode,
                displayName: printer.displayName,
                modelName: printer.modelName
            )
            return BambuLanAdapter(printerId: printer.id, config: config)

        case .gateway:
            guard let gatewayId = printer.gatewayId,
                  let remotePrinterId = printer.remotePrinterId else { return nil }
            // Look up the gateway's base URL from SwiftData via a simple
            // scan of all Gateway records. (This is fine at small scale;
            // a lookup cache can come later.)
            guard let baseURL = gatewayBaseURL(gatewayId: gatewayId) else { return nil }
            return GatewayAdapter(
                printerId: remotePrinterId,
                printerDisplayName: printer.displayName,
                printerModelName: printer.modelName,
                gatewayBaseURL: baseURL,
                relayURL: gatewayRelayURL(gatewayId: gatewayId),
                gatewayId: gatewayId
            )
        }
    }

    /// Resolve a gateway's base URL by scanning registered gateways.
    /// A proper lookup table would be better at scale, but we typically
    /// have 1-2 gateways so a linear scan is fine.
    private var gatewayURLCache: [String: URL] = [:]
    private var gatewayRelayURLCache: [String: URL] = [:]

    func cacheGatewayURL(gatewayId: String, baseURL: URL) {
        gatewayURLCache[gatewayId] = baseURL
    }

    func cacheGatewayRelayURL(gatewayId: String, relayURL: URL) {
        gatewayRelayURLCache[gatewayId] = relayURL
    }

    /// Read-only snapshot for the LiveActivityCoordinator to look up shared keys.
    var gatewayURLCacheSnapshot: [String: URL] { gatewayURLCache }

    private func gatewayBaseURL(gatewayId: String) -> URL? {
        gatewayURLCache[gatewayId]
    }

    private func gatewayRelayURL(gatewayId: String) -> URL? {
        gatewayRelayURLCache[gatewayId]
    }
}
