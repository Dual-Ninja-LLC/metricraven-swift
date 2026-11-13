// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MetricRaven",
    platforms: [.iOS(.v15), .macOS(.v12), .tvOS(.v15), .watchOS(.v8), .visionOS(.v1)],
    products: [
        .library(name: "MetricRaven", targets: ["MetricRaven"]),
    ],
    targets: [
        .target(name: "MetricRaven", resources: [.copy("PrivacyInfo.xcprivacy")]),
        .testTarget(
            name: "MetricRavenTests",
            dependencies: ["MetricRaven"],
            resources: [.copy("contract-payloads.json")]
        ),
    ]
)
