// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RecorteCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "RecorteCore", targets: ["RecorteCore"]),
    ],
    targets: [
        .target(name: "RecorteCore"),
        .testTarget(name: "RecorteCoreTests", dependencies: ["RecorteCore"]),
    ]
)
