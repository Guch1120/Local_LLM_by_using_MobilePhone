// swift-tools-version: 5.9
// Pins llama.cpp's official Apple XCFramework, which includes libmtmd for image input.
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
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11270/llama-b11270-xcframework.zip",
            checksum: "573011fb1296f1c0579c3130392f42289707c35be58a2e8aa84aa4c19e7657dd"
        )
    ]
)
