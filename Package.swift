// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MRNG",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MRNGCore", targets: ["MRNGCore"]),
        .executable(name: "mrngprobe", targets: ["mrngprobe"]),
    ],
    targets: [
        .target(name: "MRNGCore"),
        .executableTarget(name: "mrngprobe", dependencies: ["MRNGCore"]),
        .testTarget(name: "MRNGCoreTests", dependencies: ["MRNGCore"]),
    ]
)
