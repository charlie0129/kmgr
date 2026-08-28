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
        .library(name: "KmgrProto", targets: ["KmgrProto"]),
        .library(name: "KmgrIPC", targets: ["KmgrIPC"])
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
        // SwiftProtobuf 1.38 declares the traits required by gRPC under
        // SwiftPM 6.2.
        .package(
            url: "https://github.com/grpc/grpc-swift-protobuf.git",
            exact: "2.4.1"
        ),
        .package(
            url: "https://github.com/apple/swift-protobuf.git",
            exact: "1.38.1"
        ),
        .package(
            url: "https://github.com/migueldeicaza/SwiftTerm.git",
            exact: "1.18.0"
        ),
        .package(
            url: "https://github.com/jpsim/Yams.git",
            exact: "6.2.2"
        )
    ],
    targets: [
        .target(
            name: "KmgrCore",
            path: "KmgrCore"
        ),
        // Test-only UserDefaults replacement shared by the Core and AppKit
        // suites; it is intentionally not part of a production target.
        .target(
            name: "KmgrTestSupport",
            path: "KmgrTestSupport"
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
        .target(
            name: "KmgrIPC",
            dependencies: [
                "KmgrCore",
                "KmgrProto",
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(
                    name: "GRPCNIOTransportHTTP2Posix",
                    package: "grpc-swift-nio-transport"
                )
            ],
            path: "KmgrIPC",
            linkerSettings: [
                .linkedFramework("OSLog"),
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "Kmgr",
            dependencies: [
                "KmgrCore",
                "KmgrProto",
                "KmgrIPC",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Yams", package: "Yams")
            ],
            path: "Kmgr",
            exclude: ["Resources"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("OSLog")
            ]
        ),
        .testTarget(
            name: "KmgrCoreTests",
            dependencies: ["KmgrCore", "KmgrTestSupport"],
            path: "KmgrTests"
        ),
        .testTarget(
            name: "KmgrIPCTests",
            dependencies: [
                "KmgrIPC",
                .product(name: "GRPCCore", package: "grpc-swift-2")
            ],
            path: "KmgrIPCTests"
        ),
        .testTarget(
            name: "KmgrAppTests",
            dependencies: ["Kmgr", "KmgrIPC", "KmgrTestSupport"],
            path: "KmgrAppTests"
        )
    ]
)
