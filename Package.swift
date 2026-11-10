// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Logcatnip",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LogcatKit", targets: ["LogcatKit"]),
        .executable(name: "Logcatnip", targets: ["Logcatnip"]),
    ],
    targets: [
        .target(name: "LogcatKit"),
        .executableTarget(
            name: "Logcatnip",
            dependencies: ["LogcatKit"]
        ),
        .testTarget(
            name: "LogcatKitTests",
            dependencies: ["LogcatKit"]
        ),
        .testTarget(
            name: "LogcatnipTests",
            dependencies: ["Logcatnip", "LogcatKit"],
            exclude: ["__Snapshots__"]
        ),
    ]
)
