// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DevCleanerProCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "DevCleanerProCore", targets: ["DevCleanerProCore"]),
        // Diagnostic CLI. Prints exactly what the app would show, so module totals can be
        // checked against `du -sh` and parser output inspected without launching the GUI.
        // Not linked into the app.
        .executable(name: "dcp-scan", targets: ["dcp-scan"])
    ],
    targets: [
        .target(
            name: "DevCleanerProCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "dcp-scan",
            dependencies: ["DevCleanerProCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
