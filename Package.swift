// swift-tools-version:5.9
import PackageDescription
import Foundation

// Rubber Band is provided as a system library (install with:
// `brew install rubberband`). Homebrew lives at /opt/homebrew on Apple Silicon
// and /usr/local on Intel; pick whichever exists so the include/link flags
// point at the right place.
let brewPrefix: String = {
    for candidate in ["/opt/homebrew", "/usr/local"] {
        if FileManager.default.fileExists(atPath: candidate + "/include/rubberband/rubberband-c.h") {
            return candidate
        }
    }
    return "/opt/homebrew"
}()

let package = Package(
    name: "PracticePad",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PracticePad", targets: ["PracticePad"])
    ],
    dependencies: [],
    targets: [
        // Carries only the module map / umbrella header for Rubber Band's C API.
        .target(
            name: "CRubberBand",
            cSettings: [
                .unsafeFlags(["-I\(brewPrefix)/include"])
            ]
        ),
        .executableTarget(
            name: "PracticePad",
            dependencies: ["CRubberBand"],
            path: "Sources/PracticePad",
            cSettings: [
                .unsafeFlags(["-I\(brewPrefix)/include"])
            ],
            swiftSettings: [
                .unsafeFlags(["-I\(brewPrefix)/include"])
            ],
            linkerSettings: [
                .unsafeFlags(["-L\(brewPrefix)/lib"])
            ]
        )
    ]
)
