// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "RootshellPushKit",
    platforms: [.iOS("18.0"), .macOS("15.0"), .macCatalyst("18.0"), .visionOS("2.0")],
    products: [
        .library(name: "RootshellPushKit", targets: ["RootshellPushKit"]),
    ],
    dependencies: [
        // Pinned to the version already resolved by Citadel: CXWing links
        // against private symbols of this release's vendored BoringSSL.
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1"),
    ],
    targets: [
        .target(name: "CXWing"),
        .target(
            name: "RootshellPushKit",
            dependencies: [
                "CXWing",
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ],
            resources: [
                .copy("Resources/ClaudeLogo.png"),
                .copy("Resources/CodexLogo.png"),
            ]
        ),
        .testTarget(
            name: "RootshellPushKitTests",
            dependencies: ["RootshellPushKit"]
        ),
    ]
)
