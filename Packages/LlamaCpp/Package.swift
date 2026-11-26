// swift-tools-version: 5.9
// Pins llama.cpp's official Apple XCFramework, which includes libmtmd for image input.
// LFM3-VL needs b12088 or newer (older builds print garbage); b12719 also has the Metal fix for LFM3 (llama.cpp #32296).
// Its XCFramework has only macOS and iOS device slices (b10456 was the last with an iOS Simulator
// slice), so pull-request.yml builds one with scripts/ci/llama_simulator_slice.sh.
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
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b12719/llama-b12719-xcframework.zip",
            checksum: "660fa59211acd47e51f403dbdb25a38d4ce3b82fb42f7e0f683e4808e9331d2b"
        )
    ]
)
