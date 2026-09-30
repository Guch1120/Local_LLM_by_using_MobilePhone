// swift-tools-version: 5.9
// Pins llama.cpp's official Apple XCFramework, which includes libmtmd for image input.
// b10456 is the last release whose XCFramework still ships the iOS Simulator slice
// (later releases build only macOS and iOS device), which the unit tests need.
// To update: change the build tag and checksum (`swift package compute-checksum <zip>`).

import PackageDescription

let package = Package(
    name: "LlamaCpp",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "LlamaFramework", targets: ["LlamaFramework"])
    ],
    targets: [
        .binaryTarget(
            name: "LlamaFramework",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b10456/llama-b10456-xcframework.zip",
            checksum: "0223bedd0a01232399d943dcb72bc227882bc90df98e29d7a92343531a88cc02"
        )
    ]
)
