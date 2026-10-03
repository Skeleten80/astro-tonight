// swift-tools-version: 5.9
import PackageDescription

// AstroTonight: "what's worth imaging tonight" for the AstroCapture rig.
// macOS-only (SwiftUI) — open this folder in Xcode on a Mac and run the
// AstroTonight scheme. Zero third-party dependencies; the 5,045-object
// night-sky catalog is vendored under Sources/AstroTonight/Resources.
let package = Package(
    name: "AstroTonight",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AstroTonight", targets: ["AstroTonight"]),
    ],
    targets: [
        .executableTarget(
            name: "AstroTonight",
            path: "Sources/AstroTonight",
            resources: [.process("Resources")]),
    ]
)
