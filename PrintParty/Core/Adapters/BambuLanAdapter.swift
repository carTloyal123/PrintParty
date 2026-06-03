//
//  BambuLanAdapter.swift
//  PrintParty
//
//  Connects to a Bambu Lab printer's local MQTT broker over TLS.
//
//  Auth (from printer screen → Settings → General → LAN Only Mode):
//    host       : printer IP / .local hostname
//    port       : 8883
//    username   : "bblp"
//    password   : LAN access code
//    topic      : device/<serial>/report
//
//  Strategy:
//    • Open MQTT connection via the shared MQTTClient.
//    • On CONNACK ok → SUBSCRIBE to the report topic, then PUBLISH a
//      "pushall" request so the printer sends us the full current state
//      (otherwise we only receive deltas).
//    • Pipe every incoming PUBLISH payload through BambuTelemetryMapper.
//    • On disconnect → emit a .offline state and reconnect with exponential
//      backoff (2s → 4s → 8s → … up to 60s).
//

import Foundation
import os

@MainActor
final class BambuLanAdapter: PrinterAdapter {

    struct Config: Sendable {
        let host: String
        let serial: String
        let accessCode: String
        let displayName: String
        let modelName: String
    }

    let printerId: UUID
    let kind: String = "Bambu LAN"

    // MARK: - Private state

    private static let log = Logger(subsystem: "com.clengineering.PrintParty", category: "BambuLanAdapter")

    private let config: Config
    private let client = MQTTClient()
    private var currentState: PrintJobState
    private var continuations: [UUID: AsyncStream<PrintJobState>.Continuation] = [:]
    private var started = false
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt: Int = 0
    private var pushallTask: Task<Void, Never>?

    private var reportTopic: String { "device/\(config.serial)/report" }
    private var requestTopic: String { "device/\(config.serial)/request" }

    // MARK: - Init

    init(printerId: UUID, config: Config) {
        self.printerId = printerId
        self.config = config
        self.currentState = {
            var s = PrintJobState.idle(
                printerId: printerId,
                displayName: config.displayName,
                model: config.modelName
            )
            s.stage = .offline
            s.errorMessage = "Not yet connected."
            return s
        }()

        client.onStateChange = { [weak self] state in
            self?.handle(mqttState: state)
        }
        client.onMessage = { [weak self] topic, payload in
            self?.handle(topic: topic, payload: payload)
        }
    }

    // MARK: - PrinterAdapter

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
        reconnectAttempt = 0

        guard validateConfig() else {
            updateState { s in
                s.stage = .offline
                s.errorMessage = "Missing host, serial, or access code."
            }
            return
        }

        connect()
    }

    func stop() {
        started = false
        reconnectTask?.cancel()
        reconnectTask = nil
        pushallTask?.cancel()
        pushallTask = nil
        client.stop(reason: "adapter stopped")
        for (_, c) in continuations { c.finish() }
        continuations.removeAll()
    }

    // MARK: - Connection

    private func connect() {
        updateState { s in
            s.stage = .offline
            s.errorMessage = "Connecting to \(self.config.host)…"
        }
        let mqttConfig = MQTTClient.Config(
            host: config.host,
            port: 8883,
            clientId: "printparty-\(UUID().uuidString.prefix(8))",
            username: "bblp",
            password: config.accessCode,
            keepAliveSeconds: 60,
            allowSelfSignedTLS: true
        )
        client.start(config: mqttConfig)
    }

    private func handle(mqttState: MQTTClient.State) {
        switch mqttState {
        case .idle, .connecting:
            break

        case .connected:
            Self.log.info("Bambu LAN connected; subscribing to \(self.reportTopic, privacy: .public)")
            reconnectAttempt = 0
            updateState { s in
                s.stage = .offline
                s.errorMessage = "Connected; waiting for telemetry…"
            }
            client.subscribe(topic: reportTopic)
            schedulePushAll()

        case .disconnected(let reason):
            Self.log.info("Bambu LAN disconnected: \(reason, privacy: .public)")
            pushallTask?.cancel()
            pushallTask = nil
            updateState { s in
                s.stage = .offline
                s.errorMessage = "Disconnected: \(reason)"
            }
            if started {
                scheduleReconnect()
            }
        }
    }

    /// Asks the printer for its current full state. Without this, we'd only
    /// receive deltas — so if no state changes happen for a while after
    /// connect we'd render an empty Live Activity. Repeat once at +2s in
    /// case the first request is lost.
    private func schedulePushAll() {
        pushallTask?.cancel()
        pushallTask = Task { [weak self] in
            await self?.sendPushAll()
            try? await Task.sleep(for: .seconds(2))
            await self?.sendPushAll()
        }
    }

    private func sendPushAll() async {
        let body: [String: Any] = [
            "pushing": [
                "sequence_id": "1",
                "command": "pushall",
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        client.publish(topic: requestTopic, payload: data)
    }

    // MARK: - Reconnect with backoff

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectAttempt = min(reconnectAttempt + 1, 6) // cap at 64s ceiling
        let delay = min(60, 1 << reconnectAttempt) // 2, 4, 8, 16, 32, 60
        Self.log.info("Bambu LAN reconnect in \(delay)s (attempt \(self.reconnectAttempt))")
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.started else { return }
            self.connect()
        }
    }

    // MARK: - Telemetry

    private func handle(topic: String, payload: Data) {
        guard topic == reportTopic else { return }
        let previous = currentState
        let merged = BambuTelemetryMapper.merge(payload: payload, into: ensureIdentity(currentState))
        if merged.stage != previous.stage {
            Self.log.info("Bambu LAN telemetry: stage \(previous.stage.rawValue, privacy: .public) → \(merged.stage.rawValue, privacy: .public) progress=\(Int(merged.progressPercent))%")
        } else {
            Self.log.debug("Bambu LAN telemetry: progress=\(Int(merged.progressPercent))% layer=\(merged.currentLayer ?? -1)")
        }
        emit(merged)
    }

    /// Make sure the snapshot we hand the mapper has the right identity
    /// fields (the mapper preserves them; we just need to recover from any
    /// .offline sentinel state).
    private func ensureIdentity(_ state: PrintJobState) -> PrintJobState {
        var s = state
        s.printerDisplayName = config.displayName
        s.printerModel = config.modelName
        if s.stage == .offline {
            // Promote to .idle so the mapper's transition logic works as
            // expected when telemetry comes in.
            s.stage = .idle
            s.errorMessage = nil
        }
        return s
    }

    // MARK: - State propagation

    private func updateState(_ mutate: (inout PrintJobState) -> Void) {
        var s = currentState
        mutate(&s)
        s.updatedAt = .now
        emit(s)
    }

    private func emit(_ state: PrintJobState) {
        currentState = state
        for (_, c) in continuations { c.yield(state) }
    }

    private func validateConfig() -> Bool {
        !config.host.isEmpty && !config.serial.isEmpty && !config.accessCode.isEmpty
    }
}
