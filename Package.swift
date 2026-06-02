// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "Pausely",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Pausely", targets: ["Pausely"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "Pausely",
            dependencies: [],
            path: "Sources/Pausely"
        )
    ]
)
