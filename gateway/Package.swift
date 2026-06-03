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
    ],
    targets: [
        .executableTarget(
            name: "PrintPartyGateway",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("BareSlashRegexLiterals"),
            ]
        ),
    ]
)
