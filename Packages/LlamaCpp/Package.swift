// swift-tools-version: 5.9
// Pins llama.cpp's official Apple XCFramework, which includes libmtmd for image input.
// b12088 is the first release that supports LFM3-VL (older builds load the file but print garbage).
// Its XCFramework has only macOS and iOS device slices (b10456 was the last with an iOS Simulator
// slice), so the Simulator unit tests cannot link it until the CI supplies one.
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
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b12088/llama-b12088-xcframework.zip",
            checksum: "a9d9ea049ed764b73dd0898710f5eb37ffb5c47cb6966a714954b7bdd7a705d7"
        )
    ]
)
