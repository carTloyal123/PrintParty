// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "printparty-gateway",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "printparty-gateway", targets: ["PrintPartyGateway"]),
    ],
    dependencies: [
        // Web framework — provides routing, JSON Codable bodies, async/await, WebSocket support
        // for later milestones.
        .package(url: "https://github.com/vapor/vapor.git", from: "4.92.0"),
        // X25519 / HKDF — same API as iOS CryptoKit so the shared-secret derivation is
        // byte-for-byte identical on both sides.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        // Pure-Swift QR code generation (MIT, no C deps) for terminal + HTTP
        // pairing QR codes.
        .package(url: "https://github.com/fwcd/swift-qrcode-generator.git", from: "2.0.0"),
        // SwiftNIO — already in the graph via Vapor; declared directly so the
        // mDNS responder (MDNSResponder.swift) can use NIOCore/NIOPosix
        // (DatagramBootstrap, MulticastChannel, System.enumerateDevices)
        // without relying on Vapor's re-export.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.100.0"),
        .package(path: "../PrintPartyKit"),
    ],
    targets: [
        .executableTarget(
            name: "PrintPartyGateway",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "QRCodeGenerator", package: "swift-qrcode-generator"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                "PrintPartyKit",
            ],
            swiftSettings: [
                .enableUpcomingFeature("BareSlashRegexLiterals"),
            ]
        ),
        .testTarget(
            name: "PrintPartyGatewayTests",
            dependencies: [
                "PrintPartyGateway",
                .product(name: "Crypto", package: "swift-crypto"),
                "PrintPartyKit",
            ]
        ),
    ]
)
