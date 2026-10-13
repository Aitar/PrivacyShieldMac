// swift-tools-version: 5.9
import PackageDescription

// Unit-test harness for PrivacyShield's pure-logic modules.
// The GUI app itself builds from PrivacyShield.xcodeproj; this package
// compiles the same sources as a library target for `swift test`.
let package = Package(
    name: "PrivacyShieldCore",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "PrivacyShieldCore",
            path: "PrivacyShield",
            exclude: ["PrivacyShieldApp.swift"]
        ),
        .testTarget(
            name: "PrivacyShieldCoreTests",
            dependencies: ["PrivacyShieldCore"],
            path: "Tests/PrivacyShieldCoreTests"
        )
    ]
)
