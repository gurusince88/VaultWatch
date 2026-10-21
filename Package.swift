// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VaultWatch",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "VaultWatch",
            path: "Sources/VaultWatch"
        )
    ]
)
