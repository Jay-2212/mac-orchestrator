// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MacOrchestrator",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MacOrchestrator", targets: ["MacOrchestrator"])
    ],
    targets: [
        .executableTarget(
            name: "MacOrchestrator",
            path: "Sources/MacOrchestrator"
        )
    ]
)
