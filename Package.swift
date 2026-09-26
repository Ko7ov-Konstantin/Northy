// swift-tools-version: 6.3
import PackageDescription

// CommandLineTools кладёт Swift Testing в Library/Developer/Frameworks, вне
// дефолтного search path — без этого флага `import Testing` не собирается.
let testingFrameworkPath = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let testingInteropPath = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

let package = Package(
    name: "Northy",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Northy",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "NorthyTests",
            dependencies: ["Northy"],
            swiftSettings: [
                .unsafeFlags(["-F", testingFrameworkPath]),
            ],
            linkerSettings: [
                .linkedFramework("Testing"),
                .unsafeFlags(["-F", testingFrameworkPath]),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", testingFrameworkPath]),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", testingInteropPath]),
            ]
        )
    ]
)
