// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Northy",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Northy",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        )
    ]
)
