// swift-tools-version: 5.9
import PackageDescription

// AstroTonight: "what's worth imaging tonight" for the AstroCapture rig.
// Universal SwiftUI codebase: macOS 14 + iOS/iPadOS 17 (one iOS target
// covers iPhone and iPad). Open this folder in Xcode on a Mac and run the
// AstroTonight scheme; see docs/iOS-setup.md for the iPhone/iPad path.
// Zero third-party dependencies; the 12,823-object night-sky catalog is
// vendored under Sources/AstroTonight/Resources.
let package = Package(
    name: "AstroTonight",
    platforms: [.macOS(.v14), .iOS(.v17)],
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
