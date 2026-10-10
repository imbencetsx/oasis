// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Oasis",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Oasis", targets: ["Oasis"])],
    targets: [
        .executableTarget(name: "Oasis"),
        .testTarget(name: "OasisTests", dependencies: ["Oasis"])
    ],
    swiftLanguageModes: [.v6]
)
