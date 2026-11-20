// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RecorteIO",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(
            name: "RecorteIO",
            targets: ["RecorteIO"]
        )
    ],
    targets: [
        .target(
            name: "RecorteIO",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "RecorteIOTests",
            dependencies: ["RecorteIO"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
