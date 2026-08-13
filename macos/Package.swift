// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Kmgr",
    platforms: [
        // gRPC Swift 2's maintained NIO transport requires macOS 15.
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Kmgr", targets: ["Kmgr"]),
        .library(name: "KmgrCore", targets: ["KmgrCore"])
    ],
    targets: [
        .target(
            name: "KmgrCore",
            path: "KmgrCore"
        ),
        .executableTarget(
            name: "Kmgr",
            dependencies: ["KmgrCore"],
            path: "Kmgr",
            exclude: ["Resources"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("OSLog")
            ]
        ),
        .testTarget(
            name: "KmgrCoreTests",
            dependencies: ["KmgrCore"],
            path: "KmgrTests"
        )
    ]
)
