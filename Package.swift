// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "QuotaSwap",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "QuotaSwap",
            path: "Sources/QuotaSwap",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ]
)
