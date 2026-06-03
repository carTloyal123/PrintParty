//
//  NIOMQTTClient.swift
//  printparty-gateway
//
//  MQTT 3.1.1 client using SwiftNIO + NIOSSL for TLS with self-signed
//  cert tolerance. Gateway-side equivalent of the iOS MQTTClient.
//
//  Uses a ChannelInboundHandler to receive data events from NIO's pipeline
//  and dispatches decoded MQTT packets to the owning service via callbacks.
//

import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import Logging

/// A callback-driven MQTT client. Thread-safe via the NIO event loop;
/// public methods are `async` for ergonomic usage from structured concurrency.
final class NIOMQTTClient: Sendable {

    enum State: Sendable, Equatable {
        case idle, connecting, connected, disconnected(reason: String)
    }

    struct Config: Sendable {
        var host: String
        var port: Int = 8883
        var clientId: String
        var username: String?
        var password: String?
        var keepAliveSeconds: UInt16 = 60
    }

    private let eventLoopGroup: EventLoopGroup
    private let logger: Logger
    let onMessage: @Sendable (String, Data) -> Void
    let onStateChange: @Sendable (State) -> Void

    /// Mutable state lives behind this NIO-managed channel handler.
    private final class Handler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer

        let client: NIOMQTTClient
        var receiveBuffer = Data()
        var logger: Logger
        /// Set to false during teardown so channelInactive doesn't fire a
        /// phantom disconnect callback after we've already cleaned up.
        var active = true

        init(client: NIOMQTTClient) {
            self.client = client
            self.logger = client.logger
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buf = unwrapInboundIn(data)
            let bytes = buf.readBytes(length: buf.readableBytes) ?? []
            receiveBuffer.append(contentsOf: bytes)
            drainBuffer()
        }

        func channelInactive(context: ChannelHandlerContext) {
            guard active else { return }
            logger.info("MQTT: channel inactive (remote closed or network lost)")
            client.onStateChange(.disconnected(reason: "connection lost"))
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            guard active else { return }
            logger.error("MQTT: channel error — \(error)")
            context.close(promise: nil)
            client.onStateChange(.disconnected(reason: "error: \(error.localizedDescription)"))
        }

        private func drainBuffer() {
            while let (packet, consumed) = MQTTPacket.tryDecode(receiveBuffer) {
                receiveBuffer.removeFirst(consumed)
                handle(packet: packet)
            }
        }

        private func handle(packet: MQTTPacket.Decoded) {
            switch packet {
            case .connack(let code):
                if code == 0 {
                    logger.info("MQTT: CONNACK ok")
                    client.onStateChange(.connected)
                } else {
                    logger.error("MQTT: CONNACK refused code=\(code)")
                    client.onStateChange(.disconnected(reason: "connack refused: \(code)"))
                }
            case .suback(let pid):
                logger.debug("MQTT: SUBACK id=\(pid)")
            case .publish(let topic, let payload):
                client.onMessage(topic, payload)
            case .pingresp:
                logger.trace("MQTT: PINGRESP")
            case .unknown(let t):
                logger.warning("MQTT: unknown packet type \(t)")
            }
        }
    }

    private let _channelLock = NSLock()
    nonisolated(unsafe) private var _channelStorage: Channel?
    nonisolated(unsafe) private var _handlerStorage: Handler?
    nonisolated(unsafe) private var _keepaliveTask: Task<Void, Never>?
    private func getChannel() -> Channel? { _channelLock.withLock { _channelStorage } }
    private func setChannel(_ ch: Channel?, handler: Handler? = nil) {
        _channelLock.withLock {
            _channelStorage = ch
            _handlerStorage = handler
        }
    }

    init(
        eventLoopGroup: EventLoopGroup,
        logger: Logger,
        onMessage: @escaping @Sendable (String, Data) -> Void,
        onStateChange: @escaping @Sendable (State) -> Void
    ) {
        self.eventLoopGroup = eventLoopGroup
        self.logger = logger
        self.onMessage = onMessage
        self.onStateChange = onStateChange
    }

    func start(config: Config) async throws {
        // Silently tear down any previous connection without emitting a
        // disconnect event (same pattern as the iOS MQTTClient fix).
        teardown()
        onStateChange(.connecting)

        logger.info("MQTT: connecting to \(config.host):\(config.port) as \(config.clientId)")

        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        tlsConfig.certificateVerification = .none
        let sslContext = try NIOSSLContext(configuration: tlsConfig)
        let handler = Handler(client: self)

        // H-11: Replaced try! with proper error handling to prevent process crash
        // if TLS handler construction fails.
        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .connectTimeout(.seconds(10))
            .channelInitializer { channel in
                do {
                    let hostname: String? = Self.isIPAddress(config.host) ? nil : config.host
                    let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: hostname)
                    return channel.pipeline.addHandlers([sslHandler, handler])
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        let ch = try await bootstrap.connect(host: config.host, port: config.port).get()
        setChannel(ch, handler: handler)

        logger.info("MQTT: TLS ready; sending CONNECT")
        let connectData = MQTTPacket.connect(
            clientId: config.clientId,
            username: config.username,
            password: config.password,
            keepAliveSeconds: config.keepAliveSeconds
        )
        try await send(connectData, on: ch)

        // H-09: Keepalive ping task uses [weak self] to avoid retain cycle.
        let interval = max(5, Int(config.keepAliveSeconds) / 2)
        let keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { break }
                guard let ch = self.getChannel(), ch.isActive else {
                    self.logger.info("MQTT: keepalive detected dead channel")
                    self.onStateChange(.disconnected(reason: "keepalive: channel dead"))
                    break
                }
                var buf = ch.allocator.buffer(capacity: MQTTPacket.pingreq.count)
                buf.writeBytes(MQTTPacket.pingreq)
                ch.writeAndFlush(buf, promise: nil)
                self.logger.trace("MQTT: PINGREQ sent")
            }
        }
        _channelLock.withLock { _keepaliveTask = keepaliveTask }
    }

    func subscribe(topic: String) async {
        guard let ch = getChannel(), ch.isActive else {
            logger.warning("MQTT: subscribe failed — no active channel")
            return
        }
        let data = MQTTPacket.subscribe(packetId: 1, topic: topic)
        logger.info("MQTT: SUBSCRIBE topic=\(topic)")
        try? await send(data, on: ch)
    }

    func publish(topic: String, payload: Data) async {
        guard let ch = getChannel(), ch.isActive else { return }
        let data = MQTTPacket.publish(topic: topic, payload: payload)
        try? await send(data, on: ch)
    }

    func stop(reason: String?) async {
        teardown()
        if let reason {
            onStateChange(.disconnected(reason: reason))
        }
    }

    /// Cancel tasks, deactivate the handler, and close the channel WITHOUT
    /// emitting any state change. Used by both start() and stop().
    private func teardown() {
        _channelLock.withLock {
            _keepaliveTask?.cancel()
            _keepaliveTask = nil
            // Deactivate the handler so channelInactive doesn't fire a
            // phantom disconnect callback during our teardown.
            _handlerStorage?.active = false
            _handlerStorage = nil
        }
        if let ch = getChannel() {
            if ch.isActive {
                var buf = ch.allocator.buffer(capacity: MQTTPacket.disconnect.count)
                buf.writeBytes(MQTTPacket.disconnect)
                ch.writeAndFlush(buf, promise: nil)
                // H-10: Log channel close failures instead of fire-and-forget.
                ch.close().whenFailure { [logger] error in
                    logger.warning("MQTT: channel close failed: \(error)")
                }
            }
            setChannel(nil)
        }
    }

    private func send(_ data: Data, on ch: Channel) async throws {
        var buf = ch.allocator.buffer(capacity: data.count)
        buf.writeBytes(data)
        try await ch.writeAndFlush(buf)
    }

    private static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".")
        if parts.count == 4 && parts.allSatisfy({ UInt8($0) != nil }) { return true }
        return false
    }
}
