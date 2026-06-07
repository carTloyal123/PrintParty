//
//  MDNSResponder.swift
//  printparty-gateway
//
//  Pure-Swift, cross-platform (macOS + Linux) mDNS/Bonjour responder built on
//  SwiftNIO — no Apple Network.framework, no Avahi/system daemon. It advertises
//  a `_printparty._tcp` service so the iOS app's NWBrowser can auto-discover the
//  gateway on the LAN.
//
//  Why this replaces the old NWListener-based BonjourAdvertiser: NWListener is
//  Apple-only, so in a Linux container (the primary Docker deployment) it was a
//  no-op and discovery never worked. This implementation speaks the mDNS wire
//  protocol directly over a NIO multicast datagram socket, so it runs anywhere
//  Swift does.
//
//  How it works:
//   1. Bind a UDP socket to 0.0.0.0:5353 (SO_REUSEADDR + SO_REUSEPORT so we can
//      coexist with the host's mDNSResponder/avahi) and join 224.0.0.251.
//   2. Send gratuitous announcements on startup and every ~60s (RFC 6762 §8.3),
//      and answer inbound PTR/SRV/TXT/A queries for our service.
//   3. Publish PTR + SRV + TXT + A records so the client can both discover and
//      resolve us to a concrete IP:port.
//
//  SECURITY: the TXT record deliberately contains NO pairing code. Discovery
//  only reveals that a gateway exists and where to reach it; pairing still
//  requires the code (typed, QR-scanned, or deep-linked).
//
//  Limitations: multicast can't cross a Docker bridge network — discovery needs
//  `network_mode: host` (Linux) or the `ADVERTISE_HOST` + QR fallback. Docker
//  Desktop (Mac/Windows) runs the container in a VM, so mDNS won't reach the LAN
//  there at all; use QR pairing.
//

import Foundation
import NIOCore
import NIOPosix
import Logging
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

actor MDNSResponder {

    private let gatewayId: String
    private let gatewayName: String
    private let version: String
    /// The real Vapor HTTP port advertised in the SRV record + TXT `port`.
    private let port: UInt16
    /// Optional operator-supplied LAN IP (ADVERTISE_HOST). When it parses as an
    /// IPv4 address it becomes the sole A record — the escape hatch for Docker
    /// bridge mode where interface enumeration only sees the container IP.
    private let advertiseHost: String?
    private let eventLoopGroup: EventLoopGroup
    private let logger: Logger

    private var channel: Channel?
    private var announceTask: Task<Void, Never>?

    /// Precomputed announcement (TTL 120) and goodbye (TTL 0) packets, built in
    /// `start()` once the host IPs are known.
    private var announceBytes: [UInt8] = []
    private var goodbyeBytes: [UInt8] = []

    private let groupAddress: SocketAddress

    init(
        gatewayId: String,
        gatewayName: String,
        version: String,
        port: UInt16,
        advertiseHost: String?,
        eventLoopGroup: EventLoopGroup,
        logger: Logger
    ) {
        self.gatewayId = gatewayId
        self.gatewayName = gatewayName
        self.version = version
        self.port = port
        self.advertiseHost = advertiseHost
        self.eventLoopGroup = eventLoopGroup
        self.logger = logger
        // Safe to force-try: this is a fixed, valid literal address.
        self.groupAddress = try! SocketAddress(ipAddress: MDNSConstants.multicastIPv4, port: Int(MDNSConstants.port))
    }

    // MARK: - Lifecycle

    func start() async {
        guard channel == nil else { return }

        // Resolve the IPv4 addresses to publish in A records.
        let addresses = resolveAdvertisedIPv4s()
        guard !addresses.isEmpty else {
            logger.notice("mDNS: no LAN IPv4 interface found; not advertising _printparty._tcp")
            return
        }

        // A stable host label, independent of the machine's real hostname so we
        // never collide with the host's own mDNS/avahi records.
        let hostLabel = "printparty-\(String(gatewayId.prefix(8)).lowercased())"
        let serviceLabels = ["_printparty", "_tcp", "local"]
        let instanceLabels = [String(gatewayName.prefix(63)), "_printparty", "_tcp", "local"]
        let hostLabels = [hostLabel, "local"]

        let txtPairs: [(String, String)] = [
            ("gid", String(gatewayId.prefix(8))),
            ("name", gatewayName),
            ("ver", version),
            ("path", "/"),
            ("port", String(port)),
        ]

        announceBytes = MDNSWire.responsePacket(ttl: MDNSConstants.ttl) {
            records(serviceLabels: serviceLabels, instanceLabels: instanceLabels,
                    hostLabels: hostLabels, txtPairs: txtPairs, addresses: addresses, ttl: MDNSConstants.ttl)
        }
        goodbyeBytes = MDNSWire.responsePacket(ttl: 0) {
            records(serviceLabels: serviceLabels, instanceLabels: instanceLabels,
                    hostLabels: hostLabels, txtPairs: txtPairs, addresses: addresses, ttl: 0)
        }

        // The handler responds to inbound queries for our service/instance with
        // the same full record set. It holds only immutable precomputed bytes.
        let handler = MDNSQueryHandler(
            responseBytes: announceBytes,
            serviceName: serviceLabels.joined(separator: ".").lowercased(),
            instanceName: instanceLabels.joined(separator: ".").lowercased(),
            groupAddress: groupAddress,
            logger: logger
        )

        let reusePort = NIOBSDSocket.Option(rawValue: SO_REUSEPORT)
        let bootstrap = DatagramBootstrap(group: eventLoopGroup)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelOption(.socketOption(reusePort), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }

        let boundChannel: Channel
        do {
            boundChannel = try await bootstrap.bind(host: "0.0.0.0", port: Int(MDNSConstants.port)).get()
        } catch {
            // Degrade gracefully — discovery is a convenience, not load-bearing.
            // QR + manual pairing still work.
            logger.warning("mDNS: failed to bind :\(MDNSConstants.port) (\(error)); discovery disabled. Pair via QR or manual entry.")
            return
        }
        self.channel = boundChannel

        await joinMulticastGroups(on: boundChannel)

        // Gratuitous announcement burst, then periodic re-announce.
        announceTask = Task { [weak self] in
            for _ in 0..<3 {
                if Task.isCancelled { return }
                await self?.sendAnnounce()
                try? await Task.sleep(for: .seconds(1))
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { return }
                await self?.sendAnnounce()
            }
        }

        logger.notice("mDNS advertising _printparty._tcp on port \(port) (addresses: \(addresses.joined(separator: ", ")))")
    }

    func stop() async {
        announceTask?.cancel()
        announceTask = nil

        if let channel {
            // Best-effort goodbye so browsers prune us promptly.
            if channel.isActive, !goodbyeBytes.isEmpty {
                var buf = channel.allocator.buffer(capacity: goodbyeBytes.count)
                buf.writeBytes(goodbyeBytes)
                channel.writeAndFlush(AddressedEnvelope(remoteAddress: groupAddress, data: buf), promise: nil)
            }
            channel.close().whenFailure { [logger] error in
                logger.debug("mDNS: channel close failed: \(error)")
            }
            self.channel = nil
        }
    }

    // MARK: - Announce / records

    /// Warn at most once when multicast egress is blocked, to avoid spamming the
    /// log every announce interval on a host that can't send multicast.
    private var announceFailureLogged = false

    private func sendAnnounce() {
        guard let channel, !announceBytes.isEmpty else { return }
        var buf = channel.allocator.buffer(capacity: announceBytes.count)
        buf.writeBytes(announceBytes)
        let promise = channel.eventLoop.makePromise(of: Void.self)
        channel.writeAndFlush(AddressedEnvelope(remoteAddress: groupAddress, data: buf), promise: promise)
        promise.futureResult.whenFailure { [weak self] error in
            Task { await self?.noteAnnounceFailure(error) }
        }
    }

    private func noteAnnounceFailure(_ error: Error) {
        guard !announceFailureLogged else { return }
        announceFailureLogged = true
        logger.warning("""
        mDNS: multicast send failed (\(error)) — auto-discovery is unavailable on this host. \
        Pair via the QR code or manual entry. Common causes: on macOS, the Local Network privacy \
        permission is denied for this process (System Settings → Privacy & Security → Local Network — \
        note an unsigned binary run from Terminal often can't be granted it; this gate does not exist \
        in a Linux container); a VPN/firewall blocking multicast; or Docker bridge networking \
        (use `network_mode: host` on Linux).
        """)
    }

    /// Build the ordered PTR, SRV, TXT, A record set for the given TTL.
    private func records(
        serviceLabels: [String],
        instanceLabels: [String],
        hostLabels: [String],
        txtPairs: [(String, String)],
        addresses: [String],
        ttl: UInt32
    ) -> [[UInt8]] {
        var recs: [[UInt8]] = [
            MDNSWire.ptr(owner: serviceLabels, target: instanceLabels, ttl: ttl),
            MDNSWire.srv(owner: instanceLabels, port: port, target: hostLabels, ttl: ttl),
            MDNSWire.txt(owner: instanceLabels, pairs: txtPairs, ttl: ttl),
        ]
        for addr in addresses {
            if let rec = MDNSWire.a(owner: hostLabels, ipv4: addr, ttl: ttl) {
                recs.append(rec)
            }
        }
        return recs
    }

    /// True for RFC1918 private-LAN IPv4 addresses (10/8, 172.16-31, 192.168/16).
    /// Used to pick a real LAN egress interface and avoid CGNAT/Tailscale tunnels.
    private static func isPrivateLAN(_ addr: in_addr) -> Bool {
        // s_addr is network byte order: the first octet is the low byte.
        let raw = UInt32(addr.s_addr)
        let o0 = UInt8(raw & 0xFF)
        let o1 = UInt8((raw >> 8) & 0xFF)
        switch o0 {
        case 10: return true
        case 172: return (16...31).contains(o1)
        case 192: return o1 == 168
        default: return false
        }
    }

    /// IPv4 addresses to advertise. An ADVERTISE_HOST that parses as IPv4 wins
    /// (Docker bridge override); otherwise every enumerated LAN IPv4.
    private func resolveAdvertisedIPv4s() -> [String] {
        if let advertiseHost, MDNSWire.ipv4Bytes(advertiseHost) != nil {
            return [advertiseHost]
        }
        return enumerateLocalIPv4Addresses()
    }

    // MARK: - Multicast join

    private func joinMulticastGroups(on channel: Channel) async {
        guard let multicast = channel as? MulticastChannel else {
            logger.debug("mDNS: channel is not a MulticastChannel; skipping group join")
            return
        }

        let devices = (try? System.enumerateDevices()) ?? []
        var egressV4: in_addr?   // preferred real-LAN interface for outbound sends
        var joinedAny = false

        for device in devices {
            guard device.multicastSupported else { continue }
            guard case .some(.v4(let v4)) = device.address else { continue }
            // Skip loopback (lo/lo0) — mDNS belongs on real LAN interfaces.
            if device.name.hasPrefix("lo") { continue }

            do {
                try await multicast.joinGroup(groupAddress, device: device).get()
                joinedAny = true
                // Prefer an RFC1918 LAN interface as the egress for announcements.
                // Skip CGNAT/Tailscale (100.64/10) and other non-LAN interfaces —
                // sending multicast out a point-to-point tunnel yields EHOSTUNREACH.
                if egressV4 == nil, Self.isPrivateLAN(v4.address.sin_addr) {
                    egressV4 = v4.address.sin_addr
                }
            } catch {
                logger.debug("mDNS: joinGroup failed on \(device.name): \(error)")
            }
        }

        if !joinedAny {
            logger.debug("mDNS: no multicast interface joined; relying on default routing")
        }

        // Best-effort: pin egress to a real LAN interface + set mDNS TTL/loop.
        // If we found no RFC1918 interface, leave IP_MULTICAST_IF unset so the OS
        // picks the default multicast route rather than a tunnel.
        guard let provider = channel as? SocketOptionProvider else { return }
        if let egressV4 {
            _ = try? await provider.setIPMulticastIF(egressV4).get()
        }
        _ = try? await provider.setIPMulticastTTL(255).get()
        _ = try? await provider.setIPMulticastLoop(1).get()
    }
}

// MARK: - Constants

private enum MDNSConstants {
    static let multicastIPv4 = "224.0.0.251"
    static let port: UInt16 = 5353
    static let ttl: UInt32 = 120
}

// MARK: - Inbound query handler

/// Answers inbound mDNS queries for our service/instance by multicasting the
/// full precomputed record set. Holds only immutable value-typed state, so it's
/// safe to share across the event loop.
private final class MDNSQueryHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private let responseBytes: [UInt8]
    private let serviceName: String   // lowercased "_printparty._tcp.local"
    private let instanceName: String  // lowercased "<name>._printparty._tcp.local"
    private let groupAddress: SocketAddress
    private let logger: Logger

    init(responseBytes: [UInt8], serviceName: String, instanceName: String, groupAddress: SocketAddress, logger: Logger) {
        self.responseBytes = responseBytes
        self.serviceName = serviceName
        self.instanceName = instanceName
        self.groupAddress = groupAddress
        self.logger = logger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        var buffer = envelope.data
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        guard MDNSWire.queryMatches(bytes, service: serviceName, instance: instanceName) else { return }

        var out = context.channel.allocator.buffer(capacity: responseBytes.count)
        out.writeBytes(responseBytes)
        context.channel.writeAndFlush(AddressedEnvelope(remoteAddress: groupAddress, data: out), promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // A malformed datagram must never tear down the responder.
        logger.debug("mDNS: inbound error: \(error)")
    }
}

// MARK: - DNS wire format

/// Minimal mDNS response encoder + just-enough query parser. All integers are
/// big-endian (network byte order). See RFC 1035 (record format) and RFC 6762
/// (mDNS specifics: cache-flush bit, TTLs).
enum MDNSWire {

    // Record type codes.
    private static let typeA: UInt16 = 1
    private static let typePTR: UInt16 = 12
    private static let typeTXT: UInt16 = 16
    private static let typeSRV: UInt16 = 33
    private static let typeANY: UInt16 = 255

    private static let classIN: UInt16 = 0x0001
    /// IN class with the mDNS cache-flush bit set (unique records).
    private static let classFlush: UInt16 = 0x8001

    // MARK: Encoding helpers

    private static func append16(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8(value >> 8)); bytes.append(UInt8(value & 0xFF))
    }
    private static func append32(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8((value >> 24) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }

    /// Encode a name as length-prefixed labels terminated by a root byte. No
    /// compression (keeps the encoder trivial; packets stay well under MTU).
    /// Labels are truncated to the 63-byte DNS limit.
    private static func encodeName(_ labels: [String]) -> [UInt8] {
        var bytes: [UInt8] = []
        for label in labels {
            var labelBytes = Array(label.utf8)
            if labelBytes.count > 63 { labelBytes = Array(labelBytes.prefix(63)) }
            bytes.append(UInt8(labelBytes.count))
            bytes.append(contentsOf: labelBytes)
        }
        bytes.append(0) // root
        return bytes
    }

    private static func record(owner: [String], type: UInt16, recordClass: UInt16, ttl: UInt32, rdata: [UInt8]) -> [UInt8] {
        var bytes = encodeName(owner)
        append16(type, to: &bytes)
        append16(recordClass, to: &bytes)
        append32(ttl, to: &bytes)
        append16(UInt16(rdata.count), to: &bytes)
        bytes.append(contentsOf: rdata)
        return bytes
    }

    // MARK: Records

    /// PTR is a shared record — no cache-flush bit.
    static func ptr(owner: [String], target: [String], ttl: UInt32) -> [UInt8] {
        record(owner: owner, type: typePTR, recordClass: classIN, ttl: ttl, rdata: encodeName(target))
    }

    static func srv(owner: [String], port: UInt16, target: [String], ttl: UInt32) -> [UInt8] {
        var rdata: [UInt8] = []
        append16(0, to: &rdata)        // priority
        append16(0, to: &rdata)        // weight
        append16(port, to: &rdata)     // port
        rdata.append(contentsOf: encodeName(target))
        return record(owner: owner, type: typeSRV, recordClass: classFlush, ttl: ttl, rdata: rdata)
    }

    static func txt(owner: [String], pairs: [(String, String)], ttl: UInt32) -> [UInt8] {
        var rdata: [UInt8] = []
        for (key, value) in pairs {
            var entry = Array("\(key)=\(value)".utf8)
            if entry.count > 255 { entry = Array(entry.prefix(255)) }
            rdata.append(UInt8(entry.count))
            rdata.append(contentsOf: entry)
        }
        // An empty TXT must still carry a single zero-length string.
        if rdata.isEmpty { rdata = [0] }
        return record(owner: owner, type: typeTXT, recordClass: classFlush, ttl: ttl, rdata: rdata)
    }

    static func a(owner: [String], ipv4: String, ttl: UInt32) -> [UInt8]? {
        guard let octets = ipv4Bytes(ipv4) else { return nil }
        return record(owner: owner, type: typeA, recordClass: classFlush, ttl: ttl, rdata: octets)
    }

    /// Assemble a full response packet: 12-byte header (QR=1, AA=1) + all records
    /// in the Answer section. Used for both announcements and query responses.
    static func responsePacket(ttl: UInt32, records build: () -> [[UInt8]]) -> [UInt8] {
        let records = build()
        var bytes: [UInt8] = []
        append16(0, to: &bytes)            // ID
        append16(0x8400, to: &bytes)       // flags: QR=1, AA=1
        append16(0, to: &bytes)            // QDCOUNT
        append16(UInt16(records.count), to: &bytes) // ANCOUNT
        append16(0, to: &bytes)            // NSCOUNT
        append16(0, to: &bytes)            // ARCOUNT
        for record in records { bytes.append(contentsOf: record) }
        return bytes
    }

    // MARK: Parsing (inbound queries)

    /// Parse just enough of an inbound packet to decide whether it's a query for
    /// our service or instance. Defensive: any malformed input returns false.
    static func queryMatches(_ bytes: [UInt8], service: String, instance: String) -> Bool {
        guard bytes.count >= 12 else { return false }
        // QR bit (high bit of flags byte) must be 0 → it's a query.
        if bytes[2] & 0x80 != 0 { return false }
        let qdCount = (UInt16(bytes[12 - 8]) << 8) | UInt16(bytes[12 - 7]) // bytes[4],[5]
        guard qdCount >= 1 else { return false }

        guard let name = readName(bytes, at: 12) else { return false }
        let lower = name.lowercased()
        return lower == service || lower == instance
    }

    /// Read a DNS name starting at `offset`, returning the dotted form. Bails on
    /// compression pointers (rare in queries) and on any bounds violation.
    private static func readName(_ bytes: [UInt8], at offset: Int) -> String? {
        var labels: [String] = []
        var i = offset
        while i < bytes.count {
            let len = Int(bytes[i])
            if len == 0 { return labels.joined(separator: ".") }
            if len & 0xC0 != 0 { return nil } // compression pointer — bail
            let start = i + 1
            let end = start + len
            guard end <= bytes.count else { return nil }
            labels.append(String(decoding: bytes[start..<end], as: UTF8.self))
            i = end
        }
        return nil
    }

    // MARK: Shared utility

    /// Parse a dotted IPv4 string into 4 network-order octets, or nil.
    static func ipv4Bytes(_ string: String) -> [UInt8]? {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard let value = UInt8(part) else { return nil }
            octets.append(value)
        }
        return octets
    }
}
