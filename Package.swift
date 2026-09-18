// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "PelicanSentinel", platforms: [.macOS(.v13)],
    products: [.library(name: "PelicanCore", targets: ["PelicanCore"]), .executable(name: "PelicanSentinel", targets: ["PelicanSentinel"])],
    targets: [.target(name: "PelicanCore"), .executableTarget(name: "PelicanSentinel", dependencies: ["PelicanCore"]), .testTarget(name: "PelicanCoreTests", dependencies: ["PelicanCore"]), .testTarget(name: "PelicanAppTests", dependencies: ["PelicanSentinel", "PelicanCore"])])
