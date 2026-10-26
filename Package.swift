// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChargeKeeper",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "ChargeKeeper", path: "Sources/ChargeKeeper")]
)
