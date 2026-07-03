// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PracticePad",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PracticePad", targets: ["PracticePad"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "PracticePad",
            path: "Sources/PracticePad"
        )
    ]
)
