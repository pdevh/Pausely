// swift-tools-version: 5.7
import PackageDescription

var package = Package(
    name: "Pausely",
    platforms: [
        .macOS(.v13)
    ],
    products: [],
    dependencies: [],
    targets: [
        .target(name: "PauselyCore"),
        .testTarget(name: "PauselyCoreTests", dependencies: ["PauselyCore"],
                    resources: [.copy("Fixtures")])
    ]
)

// The schedule and editor tests also run on Linux without Apple frameworks.
#if os(macOS)
package.products.append(.executable(name: "Pausely", targets: ["Pausely"]))
package.dependencies.append(.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4"))
package.targets.append(
    .executableTarget(
        name: "Pausely",
        dependencies: ["PauselyCore", .product(name: "Sparkle", package: "Sparkle")],
        path: "Sources/Pausely",
        linkerSettings: [
            .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
        ]
    )
)
package.targets.append(.testTarget(name: "PauselyAppTests", dependencies: ["Pausely"]))
#endif
