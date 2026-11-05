// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "TouchRecordKit",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "TouchRecordKit", targets: ["TouchRecordKit"]),
    ],
    traits: [
        // Compile the streaming code into Release builds too (e.g. TestFlight demo builds).
        // Off by default: Release builds get empty stubs.
        .trait(name: "AlwaysOn", description: "Include TouchRecordKit in Release builds."),
    ],
    targets: [
        .target(
            name: "TouchRecordKit",
            swiftSettings: [
                .define("TOUCHRECORDKIT_ENABLED", .when(traits: ["AlwaysOn"])),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
