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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4")
    ],
    targets: [
        .executableTarget(
            name: "Pausely",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Pausely",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        )
    ]
)
