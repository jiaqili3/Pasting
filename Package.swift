// swift-tools-version: 6.0
// NOTE: This Mac's Command Line Tools have a broken SPM PackageDescription dylib,
// so builds use build_app.sh (swiftc) instead of `swift build`.
import PackageDescription

let package = Package(
    name: "Pasting",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Pasting", targets: ["Pasting"])
    ],
    targets: [
        .executableTarget(
            name: "Pasting",
            path: "Sources/Pasting"
        )
    ]
)
