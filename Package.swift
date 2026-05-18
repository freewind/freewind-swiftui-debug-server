// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "FreewindSwiftUIDebugServer",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "FreewindSwiftUIDebugServer",
            targets: ["FreewindSwiftUIDebugServer"]
        ),
    ],
    targets: [
        .target(
            name: "FreewindSwiftUIDebugServer"
        ),
    ]
)
