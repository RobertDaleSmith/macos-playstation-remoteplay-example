// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PSRemotePlayExample",
    platforms: [.macOS(.v13)],
    dependencies: [
        // The only dependency. Takion's control messages are protobuf, and RPTakion.pb.swift is
        // the generated code for them.
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0")
    ],
    targets: [
        .executableTarget(
            name: "PSRemotePlayExample",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")]
        )
    ]
)
