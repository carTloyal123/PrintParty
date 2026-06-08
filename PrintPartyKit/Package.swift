// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PrintPartyKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .watchOS(.v10),
    ],
    products: [
        .library(name: "PrintPartyKit", targets: ["PrintPartyKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "PrintPartyKit",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "PrintPartyKitTests",
            dependencies: ["PrintPartyKit"]
        ),
    ]
)
