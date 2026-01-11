// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "iDeinterlace",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "iDeinterlace", targets: ["iDeinterlace"]),
        .executable(name: "iDeinterlaceWorker", targets: ["iDeinterlaceWorker"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "iDeinterlace",
            dependencies: ["iDeinterlaceShared"],
            path: "iDeinterlace",
            exclude: ["Resources/Info.plist"],
            resources: [
                .process("Resources/Assets.xcassets")
            ]
        ),
        .executableTarget(
            name: "iDeinterlaceWorker",
            dependencies: ["iDeinterlaceShared"],
            path: "iDeinterlaceWorker",
            resources: [
                .copy("Templates")
            ]
        ),
        .target(
            name: "iDeinterlaceShared",
            path: "Shared"
        ),
        .testTarget(
            name: "iDeinterlaceTests",
            dependencies: ["iDeinterlaceShared"],
            path: "Tests/iDeinterlaceTests"
        )
    ]
)
