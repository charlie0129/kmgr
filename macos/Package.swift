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
        .library(name: "KmgrCore", targets: ["KmgrCore"]),
        .library(name: "KmgrProto", targets: ["KmgrProto"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/grpc/grpc-swift-2.git",
            exact: "2.4.2"
        ),
        .package(
            url: "https://github.com/grpc/grpc-swift-nio-transport.git",
            exact: "2.9.1"
        ),
        // 2.4.x requires SwiftProtobuf 1.38, whose package manifest needs
        // Swift 6.2. 2.3.0 is the newest integration compatible with our
        // Swift 6.1 toolchain and the exact SwiftProtobuf pin below.
        .package(
            url: "https://github.com/grpc/grpc-swift-protobuf.git",
            exact: "2.3.0"
        ),
        .package(
            url: "https://github.com/apple/swift-protobuf.git",
            exact: "1.33.1"
        )
    ],
    targets: [
        .target(
            name: "KmgrCore",
            path: "KmgrCore"
        ),
        .target(
            name: "KmgrProto",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(
                    name: "GRPCNIOTransportHTTP2Posix",
                    package: "grpc-swift-nio-transport"
                ),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf")
            ],
            path: "KmgrProto",
            exclude: ["README.md"]
        ),
        .executableTarget(
            name: "Kmgr",
            dependencies: ["KmgrCore", "KmgrProto"],
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
