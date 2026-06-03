//
//  MQTTClient.swift
//  PrintParty
//
//  Minimal MQTT 3.1.1 client built on Network.framework.
//
//  Responsibilities:
//    • Open a TCP+TLS connection to host:port.
//    • Optionally accept self-signed certs (Bambu printers ship one).
//    • Send CONNECT and wait for CONNACK.
//    • Send SUBSCRIBE and surface incoming PUBLISH messages via callback.
//    • Keepalive with PINGREQ; disconnect on PINGRESP timeout.
//    • Surface state transitions and errors via callback.
//
//  The client does NOT do reconnection on its own — the caller (BambuLanAdapter)
//  decides whether and when to retry, and with what backoff. Keeping reconnect
//  policy outside the client keeps this layer protocol-pure and testable.
//

import Foundation
import Network
import os

@MainActor
final class MQTTClient {

    // MARK: - Types

    enum State: Equatable, Sendable {
        case idle
        case connecting
        case connected
        case disconnected(reason: String)
    }

    struct Config: Sendable {
        var host: String
        var port: UInt16 = 8883
        var clientId: String
        var username: String?
        var password: String?
        var keepAliveSeconds: UInt16 = 60
        var allowSelfSignedTLS: Bool = true
    }

    // MARK: - Callbacks (all invoked on MainActor)

    var onStateChange: ((State) -> Void)?
    var onMessage: ((_ topic: String, _ payload: Data) -> Void)?

    // MARK: - State

    private static let log = Logger(subsystem: "com.clengineering.PrintParty", category: "MQTTClient")
    private static let queue = DispatchQueue(label: "com.clengineering.PrintParty.mqtt", qos: .userInitiated)

    private(set) var state: State = .idle {
        didSet {
            guard oldValue != state else { return }
            onStateChange?(state)
        }
    }

    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var keepaliveTask: Task<Void, Never>?
    private var pingResponseTask: Task<Void, Never>?
    private var nextPacketId: UInt16 = 1
    private var config: Config?

    init() {}

    // MARK: - Public API

    /// Tear down any prior connection and open a new one.
    ///
    /// IMPORTANT: silently dismantles the previous connection without
    /// emitting a `.disconnected` state event. Otherwise the adapter's
    /// disconnect handler would schedule a reconnect that races with the
    /// connect attempt we're starting *right now* — a self-inflicted loop
    /// that briefly worked, then killed itself every couple of seconds.
    func start(config: Config) {
        teardown()
        self.config = config
        self.receiveBuffer = Data()
        self.state = .connecting

        Self.log.info("MQTT: connecting to \(config.host, privacy: .public):\(config.port, privacy: .public) as \(config.clientId, privacy: .public)")

        let host = NWEndpoint.Host(config.host)
        guard let port = NWEndpoint.Port(rawValue: config.port) else {
            transition(to: .disconnected(reason: "invalid port"))
            return
        }

        let tlsOptions = NWProtocolTLS.Options()
        if config.allowSelfSignedTLS {
            sec_protocol_options_set_verify_block(
                tlsOptions.securityProtocolOptions,
                { _, _, completion in
                    completion(true)
                },
                Self.queue
            )
        }

        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        let conn = NWConnection(host: host, port: port, using: parameters)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] nwState in
            Task { @MainActor [weak self] in
                self?.handle(nwState: nwState)
            }
        }
        conn.start(queue: Self.queue)
    }

    func subscribe(topic: String) {
        guard case .connected = state, let conn = connection else { return }
        let packetId = takePacketId()
        let data = MQTTPacket.subscribe(packetId: packetId, topic: topic)
        Self.log.debug("MQTT: SUBSCRIBE id=\(packetId) topic=\(topic, privacy: .public)")
        send(conn, data)
    }

    func publish(topic: String, payload: Data) {
        guard case .connected = state, let conn = connection else { return }
        let data = MQTTPacket.publish(topic: topic, payload: payload)
        send(conn, data)
    }

    func stop(reason: String = "client requested") {
        teardown()
        if case .disconnected = state {
            // already in terminal state
        } else {
            transition(to: .disconnected(reason: reason))
        }
    }

    /// Cancel tasks and the underlying connection without emitting any state
    /// change. Called by both `start(config:)` (silent restart) and `stop()`
    /// (which emits its own .disconnected after).
    private func teardown() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
        pingResponseTask?.cancel()
        pingResponseTask = nil

        if let conn = connection {
            if case .connected = state {
                conn.send(content: MQTTPacket.disconnect, completion: .contentProcessed { _ in })
            }
            // Detach our handlers so the cancellation we trigger below doesn't
            // bounce back through stateUpdateHandler → handle(nwState:) →
            // transition(to: .disconnected) and undo our silent teardown.
            conn.stateUpdateHandler = nil
            conn.cancel()
        }
        connection = nil
        receiveBuffer.removeAll(keepingCapacity: false)
    }

    // MARK: - Connection state handling

    private func handle(nwState: NWConnection.State) {
        switch nwState {
        case .setup, .preparing:
            break
        case .ready:
            Self.log.info("MQTT: TLS ready; sending CONNECT")
            sendConnect()
            startReceiveLoop()
        case .waiting(let error):
            Self.log.error("MQTT: waiting — \(String(describing: error), privacy: .public)")
            transition(to: .disconnected(reason: "waiting: \(error.localizedDescription)"))
            connection?.cancel()
            connection = nil
        case .failed(let error):
            Self.log.error("MQTT: failed — \(String(describing: error), privacy: .public)")
            transition(to: .disconnected(reason: "failed: \(error.localizedDescription)"))
            connection?.cancel()
            connection = nil
        case .cancelled:
            if case .disconnected = state {
                // already noted
            } else {
                transition(to: .disconnected(reason: "cancelled"))
            }
        @unknown default:
            break
        }
    }

    private func sendConnect() {
        guard let conn = connection, let config else { return }
        let packet = MQTTPacket.connect(
            clientId: config.clientId,
            username: config.username,
            password: config.password,
            keepAliveSeconds: config.keepAliveSeconds
        )
        send(conn, packet)
    }

    private func startReceiveLoop() {
        guard let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.appendAndDispatch(data)
                }
                if let error {
                    Self.log.error("MQTT: receive error — \(String(describing: error), privacy: .public)")
                    self.transition(to: .disconnected(reason: "receive: \(error.localizedDescription)"))
                    self.connection?.cancel()
                    self.connection = nil
                    return
                }
                if isComplete {
                    self.transition(to: .disconnected(reason: "remote closed"))
                    self.connection?.cancel()
                    self.connection = nil
                    return
                }
                self.startReceiveLoop()
            }
        }
    }

    private func appendAndDispatch(_ data: Data) {
        receiveBuffer.append(data)
        while let (packet, consumed) = MQTTPacket.tryDecode(receiveBuffer) {
            receiveBuffer.removeFirst(consumed)
            handle(packet: packet)
        }
    }

    private func handle(packet: MQTTPacket.Decoded) {
        switch packet {
        case .connack(let returnCode):
            if returnCode == 0 {
                Self.log.info("MQTT: CONNACK ok")
                transition(to: .connected)
                startKeepalive()
            } else {
                let reason = connackReasonName(returnCode)
                Self.log.error("MQTT: CONNACK refused — \(reason, privacy: .public)")
                transition(to: .disconnected(reason: "connack \(returnCode): \(reason)"))
                connection?.cancel()
                connection = nil
            }

        case .suback(let packetId):
            Self.log.debug("MQTT: SUBACK id=\(packetId)")

        case .publish(let topic, let payload):
            onMessage?(topic, payload)

        case .pingresp:
            pingResponseTask?.cancel()
            pingResponseTask = nil

        case .unknown(let type):
            Self.log.warning("MQTT: unknown packet type \(type)")
        }
    }

    // MARK: - Keepalive

    private func startKeepalive() {
        keepaliveTask?.cancel()
        let interval = max(5, Int(config?.keepAliveSeconds ?? 60) / 2)
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self else { return }
                self.sendPing()
            }
        }
    }

    private func sendPing() {
        guard case .connected = state, let conn = connection else { return }
        conn.send(content: MQTTPacket.pingreq, completion: .contentProcessed { _ in })
        // Expect a PINGRESP within 2× the ping interval; otherwise we're toast.
        pingResponseTask?.cancel()
        let timeout = max(5, Int(config?.keepAliveSeconds ?? 60))
        pingResponseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, !Task.isCancelled else { return }
            Self.log.warning("MQTT: PINGRESP timeout")
            self.transition(to: .disconnected(reason: "ping timeout"))
            self.connection?.cancel()
            self.connection = nil
        }
    }

    // MARK: - Send wrapper

    private func send(_ conn: NWConnection, _ data: Data) {
        let log = Self.log
        conn.send(content: data, completion: .contentProcessed { error in
            if let error {
                log.error("MQTT: send error — \(String(describing: error), privacy: .public)")
            }
        })
    }

    // MARK: - Plumbing

    private func transition(to newState: State) {
        state = newState
    }

    private func takePacketId() -> UInt16 {
        defer { nextPacketId = nextPacketId &+ 1 }
        return nextPacketId == 0 ? 1 : nextPacketId
    }

    private func connackReasonName(_ code: UInt8) -> String {
        switch code {
        case 1: return "unacceptable protocol version"
        case 2: return "identifier rejected"
        case 3: return "server unavailable"
        case 4: return "bad username or password"
        case 5: return "not authorized"
        default: return "code \(code)"
        }
    }
}

