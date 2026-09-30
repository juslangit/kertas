// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Kertas",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Kertas",
            path: "Sources/Kertas",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
