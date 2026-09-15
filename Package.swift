// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "WideCam",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "WideCam",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "WideCamTests",
            dependencies: ["WideCam"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
