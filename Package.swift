// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChargeKeeperProbe",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "ChargeKeeperProbe", path: "Sources/ChargeKeeperProbe")]
)
