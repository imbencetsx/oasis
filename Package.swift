// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Oasis",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Oasis", targets: ["Oasis"])],
    dependencies: [.package(path: "Vendor/CefSwift")],
    targets: [
        .executableTarget(name: "Oasis", dependencies: [.product(name: "CefSwiftUI", package: "CefSwift")]),
        .testTarget(name: "OasisTests", dependencies: ["Oasis"])
    ],
    swiftLanguageModes: [.v6]
)
