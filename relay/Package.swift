// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "printparty-relay",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "printparty-relay", targets: ["PrintPartyRelay"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.92.0"),
        // APNs HTTP/2 client with token-based (.p8) auth.
        .package(url: "https://github.com/swift-server-community/APNSwift.git", from: "5.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "PrintPartyRelay",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "APNSCore", package: "APNSwift"),
                .product(name: "APNS", package: "APNSwift"),
            ]
        ),
    ]
)
