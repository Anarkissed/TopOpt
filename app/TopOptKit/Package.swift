// swift-tools-version:5.9
// TopOptKit — the Swift/C++ bridge over the topopt core library (ROADMAP M7.1).
//
// Layout: `TopOptBridge` is the C++ facade target (interop-clean header +
// bridge.cpp over the core). `TopOptKit` is the Swift wrapper the app and tests
// use. `TopOptKitTests` exercises the wrapper headlessly on macOS — the M7
// verification standard is `xcodebuild test` on this package (raw output in the
// handoff), since /app/ is not covered by Linux CI (ROADMAP M7 rules).
//
// The core is built into this package by CMake as a multi-platform static-library
// xcframework (`vendor/TopOptCore.xcframework`: macOS-arm64 with OpenCASCADE, plus
// OCCT-free iOS simulator + device slices) by `../scripts/build_core.sh` — run it
// before building. The xcframework lets Xcode pick the right slice per platform,
// which a single `-L` static lib cannot (iOS device and simulator are distinct
// platforms). STEP import needs OpenCASCADE and so is macOS-only: the bridge
// compiles it only where TOPOPT_BRIDGE_HAS_OCCT is defined (below), and the OCCT
// libraries are linked only on macOS. OCCT is dynamically linked (LGPL 2.1,
// ARCHITECTURE §4/§10). The manifest carries no machine-specific absolute paths:
// the only absolute path (the OCCT lib dir, macOS-only) is derived from this
// manifest's own location via #filePath and the package-relative vendor tree.
import Foundation
import PackageDescription

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "TopOptKit",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "TopOptKit", targets: ["TopOptKit"]),
        // The M7.2 SwiftUI design system (tokens + reusable glass views). Pure
        // SwiftUI, no C++ interop / core dependency, so it builds on every slice
        // and its tokens are unit-testable headlessly (TopOptDesignTests).
        .library(name: "TopOptDesign", targets: ["TopOptDesign"]),
    ],
    targets: [
        // The CMake-built core, per-platform, selected automatically by Xcode.
        .binaryTarget(name: "TopOptCore", path: "vendor/TopOptCore.xcframework"),
        .target(
            name: "TopOptBridge",
            dependencies: ["TopOptCore"],
            cxxSettings: [
                .headerSearchPath("../../vendor/include"),
                // STEP import/tagging is compiled only where OpenCASCADE is
                // linked (the macOS core slice); elsewhere the bridge returns a
                // clear "not available on this platform" error.
                .define("TOPOPT_BRIDGE_HAS_OCCT", .when(platforms: [.macOS])),
                // -stdlib=libc++ so the C++ standard-library include path reaches
                // the module build under Xcode's explicit-modules scanner, where
                // the module is compiled as C++ (requires cplusplus) but the
                // libc++ search path can otherwise be absent -> "'cstdint' file
                // not found".
                .unsafeFlags(["-std=c++17", "-stdlib=libc++"]),
            ]
        ),
        .target(
            name: "TopOptKit",
            dependencies: ["TopOptBridge"],
            swiftSettings: [.interoperabilityMode(.Cxx)],
            linkerSettings: [
                // OpenCASCADE is linked only on macOS (the only slice that
                // contains the STEP importer). Absolute -L path derived from the
                // manifest location so it resolves when an app links TopOptKit.
                .unsafeFlags([
                    "-L\(packageDir)/vendor/occt-lib",
                    "-lTKDESTEP", "-lTKXSBase", "-lTKDE", "-lTKMesh",
                    "-lTKTopAlgo", "-lTKGeomAlgo", "-lTKPrim", "-lTKBRep",
                    "-lTKGeomBase", "-lTKG3d", "-lTKG2d", "-lTKMath", "-lTKernel",
                ], .when(platforms: [.macOS])),
            ]
        ),
        .testTarget(
            name: "TopOptKitTests",
            dependencies: ["TopOptKit"],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        // M7.2 design system: SwiftUI-only, no C++ interop (so it needs none of
        // the bridge's Cxx build settings and stays cross-platform).
        .target(
            name: "TopOptDesign"
        ),
        .testTarget(
            name: "TopOptDesignTests",
            dependencies: ["TopOptDesign"]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
