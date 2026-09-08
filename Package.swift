// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "posture-continuity-kit",
    // Only platforms CI actually builds are declared. Linux needs no
    // declaration; the demo app's CI builds for `generic/platform=iOS Simulator`.
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "PostureContinuity", targets: ["PostureContinuity"]),
        .library(name: "PostureContinuityUI", targets: ["PostureContinuityUI"])
    ],
    targets: [
        .target(name: "PostureContinuity"),
        .target(name: "PostureContinuityUI", dependencies: ["PostureContinuity"]),
        .testTarget(name: "PostureContinuityTests", dependencies: ["PostureContinuity"])
    ]
)
