// swift-tools-version:5.9
import PackageDescription
import Foundation

// Rubber Band is needed only to *build* (install with: `brew install
// rubberband`). We link its STATIC archive (and libsamplerate's) directly into
// the executable, so the shipped app has no Rubber Band dylib to bundle.
//
// Homebrew lives at /opt/homebrew on Apple Silicon and /usr/local on Intel.
// The "opt/<formula>/lib" paths are stable symlinks maintained by Homebrew.
let brewPrefix: String = {
    for candidate in ["/opt/homebrew", "/usr/local"] {
        if FileManager.default.fileExists(atPath: candidate + "/include/rubberband/rubberband-c.h") {
            return candidate
        }
    }
    return "/opt/homebrew"
}()

let rubberbandLib = "\(brewPrefix)/opt/rubberband/lib/librubberband.a"
let samplerateLib = "\(brewPrefix)/opt/libsamplerate/lib/libsamplerate.a"

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
                // Link the static archives by full path (NOT `-lrubberband`,
                // which would pull in the .dylib). Rubber Band uses Apple's
                // Accelerate framework for FFT/vDSP; libc++ is added by the
                // toolchain automatically since the archives are C++.
                .unsafeFlags([
                    rubberbandLib,
                    samplerateLib,
                    "-framework", "Accelerate",
                    // Rubber Band is C++, so its archive needs the C++ runtime.
                    // Swift links through the C driver, which doesn't add this
                    // automatically; libc++ itself stays dynamic (system lib).
                    "-lc++"
                ])
            ]
        )
    ]
)
