// swift-tools-version:6.0
//
// Build with the Swift WASI SDK, see build.sh. The product is a single
// executable .wasm file targeting WASI Preview 1.

import PackageDescription

let package = Package(
    name: "wasm-demo-swift",
    targets: [
        .executableTarget(
            name: "wasm-demo-swift",
            path: "Sources/wasm-demo-swift",
            swiftSettings: [
                // `@_extern(wasm, module:, name:)` is gated behind an
                // experimental feature flag in Swift 6.0.
                .enableExperimentalFeature("Extern"),
            ]
        ),
    ]
)
