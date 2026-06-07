//
//  NetworkInterfaces.swift
//  printparty-gateway
//
//  Cross-platform (macOS + Linux) host/IP discovery helpers shared by the
//  startup banner / QR host resolution (Configure.swift) and the mDNS
//  responder (MDNSResponder.swift). Uses POSIX getifaddrs/gethostname so it
//  works identically in a Linux container and a native macOS process.
//

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Returns every host the gateway can plausibly be reached at, for the startup
/// banner and the pairing QR. We don't try to be clever about which of these
/// are "really" useful — we enumerate everything we can find and let the human
/// (or an explicit ADVERTISE_HOST override) pick the right one. Includes:
///   - Every non-loopback IPv4 address from local network interfaces.
///     In Docker bridge mode this returns the container's internal IP
///     (e.g. 172.18.x.x), not the host's LAN IP — use `network_mode: host`
///     or set `ADVERTISE_HOST` for that case.
///   - `<hostname>.local` if the container hostname looks like a real name.
///   - `localhost` as a last-resort entry.
func resolvePairingHosts() -> [String] {
    var hosts: [String] = []

    hosts.append(contentsOf: enumerateLocalIPv4Addresses())

    if let mdns = mDNSHostname(), !hosts.contains(mdns) {
        hosts.append(mdns)
    }

    if !hosts.contains("localhost") {
        hosts.append("localhost")
    }
    return hosts
}

/// Heuristic: does this look like a Docker/bridge container where the only
/// reachable address is the unroutable container IP? Used to nudge the operator
/// to set ADVERTISE_HOST. True if `/.dockerenv` exists or the first resolved
/// host is in the 172.16.0.0/12 Docker-default range.
func isLikelyContainerized(firstHost: String?) -> Bool {
    if FileManager.default.fileExists(atPath: "/.dockerenv") { return true }
    guard let firstHost, let octets = firstHost.split(separator: ".").first.flatMap({ Int($0) }),
          let second = firstHost.split(separator: ".").dropFirst().first.flatMap({ Int($0) })
    else { return false }
    // 172.16.0.0 – 172.31.255.255 is Docker's default bridge subnet range.
    return octets == 172 && (16...31).contains(second)
}

/// Returns `<hostname>.local` if the system hostname looks like a real name.
/// Returns nil for Docker-default container IDs (12 hex chars), already-qualified
/// names, or empty hostnames. This lets users reach the gateway via mDNS/avahi.
func mDNSHostname() -> String? {
    var buffer = [CChar](repeating: 0, count: 256)
    guard gethostname(&buffer, buffer.count) == 0 else { return nil }
    let host = String(cString: buffer)
    guard !host.isEmpty else { return nil }
    // Skip Docker default container IDs (12-char lowercase hex).
    if host.count == 12, host.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) {
        return nil
    }
    // If the hostname already contains a dot, treat as fully qualified.
    if host.contains(".") { return host }
    return host + ".local"
}

/// Enumerate non-loopback IPv4 addresses from local network interfaces.
/// In Docker bridge mode this only returns the container's internal IP,
/// which is why ADVERTISE_HOST exists as an override.
func enumerateLocalIPv4Addresses() -> [String] {
    var results: [String] = []
    var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
    defer { freeifaddrs(ifaddrPtr) }

    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let ptr = cursor {
        defer { cursor = ptr.pointee.ifa_next }

        guard let addr = ptr.pointee.ifa_addr else { continue }
        guard Int32(addr.pointee.sa_family) == AF_INET else { continue }

        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            addr,
            socklen_t(MemoryLayout<sockaddr_in>.size),
            &hostBuffer,
            socklen_t(hostBuffer.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard result == 0 else { continue }

        let address = String(cString: hostBuffer)
        // Skip loopback (handled separately) and link-local autoconfig.
        if address == "127.0.0.1" || address.hasPrefix("169.254.") { continue }
        if !results.contains(address) {
            results.append(address)
        }
    }
    return results
}
