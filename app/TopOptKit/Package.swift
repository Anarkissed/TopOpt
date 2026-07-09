// swift-tools-version:5.9
// TopOptKit — the Swift/C++ bridge over the topopt core library (ROADMAP M7.1).
//
// Layout: `TopOptBridge` is the C++ facade target (interop-clean header +
// bridge.cpp over the core). `TopOptKit` is the Swift wrapper the app and tests
// use. `TopOptKitTests` exercises the wrapper headlessly on macOS — the M7
// verification standard is `xcodebuild test` on this package (raw output in the
// handoff), since /app/ is not covered by Linux CI (ROADMAP M7 rules).
//
// The core is built into this package via CMake as a static library and vendored
// under `vendor/` by `../scripts/build_core.sh` (run it before building):
//   vendor/include      -> ../../core/include        (core public headers)
//   vendor/occt-include  -> $(brew --prefix opencascade)/include/opencascade
//   vendor/lib/libtopopt.a  (CMake output, copied)
//   vendor/occt-lib      -> $(brew --prefix opencascade)/lib
//
// Link-search paths must be ABSOLUTE: a linker `-L` unsafeFlag is resolved
// against the linker's working directory, which is the package root only when
// building the package directly (`xcodebuild test` here) — NOT when an app
// target links TopOptKit as a dependency, where a relative `-Lvendor/lib` yields
// `ld: library 'topopt' not found`. We derive the absolute package directory
// from this manifest's own path (`#filePath`), so the flags stay machine-
// independent (no hard-coded user/Homebrew paths; ARCHITECTURE §4/§10 OCCT is
// dynamically linked).
import Foundation
import PackageDescription

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "TopOptKit",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "TopOptKit", targets: ["TopOptKit"]),
    ],
    targets: [
        .target(
            name: "TopOptBridge",
            cxxSettings: [
                .headerSearchPath("../../vendor/include"),
                .headerSearchPath("../../vendor/occt-include"),
                // -stdlib=libc++ so the C++ standard-library include path
                // (<sdk>/usr/include/c++/v1) reaches the module build even under
                // Xcode's explicit-modules dependency scanner, where the module
                // is compiled as C++ (requires cplusplus) but the libc++ search
                // path can otherwise be absent -> "'cstdint' file not found".
                .unsafeFlags(["-std=c++17", "-stdlib=libc++"]),
            ]
        ),
        .target(
            name: "TopOptKit",
            dependencies: ["TopOptBridge"],
            swiftSettings: [.interoperabilityMode(.Cxx)],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(packageDir)/vendor/lib", "-ltopopt",
                    "-L\(packageDir)/vendor/occt-lib",
                    "-lTKDESTEP", "-lTKXSBase", "-lTKDE", "-lTKMesh",
                    "-lTKTopAlgo", "-lTKGeomAlgo", "-lTKPrim", "-lTKBRep",
                    "-lTKGeomBase", "-lTKG3d", "-lTKG2d", "-lTKMath", "-lTKernel",
                ]),
            ]
        ),
        .testTarget(
            name: "TopOptKitTests",
            dependencies: ["TopOptKit"],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
