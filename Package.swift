// swift-tools-version: 6.0
// One Space — native macOS folder search.
// Builds with Swift Package Manager under the Command Line Tools
// (`swift build`). A later Xcode app target can wrap the same sources;
// see README.md.

import PackageDescription

let package = Package(
    name: "OneSpace",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "OneSpace", targets: ["OneSpace"])
    ],
    targets: [
        .executableTarget(
            name: "OneSpace",
            path: "Sources/OneSpace",
            exclude: [
                "Resources/Info.plist",
                "Resources/OneSpace.entitlements"
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
