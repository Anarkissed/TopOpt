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
// iOS simulator + device slices) by `../scripts/build_core.sh` — run it before
// building.
//
// OpenCASCADE on iOS (M7.1b): the STEP importer needs OCCT. On macOS it is the
// Homebrew dylibs, linked via the -L flags below. On iOS it is delivered as
// cross-built dynamic-framework xcframeworks under `vendor/occt-ios/` (produced
// by `../scripts/build_occt_ios.sh`; LGPL 2.1 dynamic linking, ARCHITECTURE
// §4/§10). This manifest DETECTS those xcframeworks on disk: when present it
// declares a binaryTarget per toolkit, links+embeds them on iOS, and defines
// TOPOPT_BRIDGE_HAS_OCCT on iOS too; when absent (before build_occt_ios.sh has
// run) it is byte-for-byte the pre-M7.1b macOS-only behavior, so the macOS test
// path never regresses. lib3mf (3MF export, M7.9) under `vendor/lib3mf-ios/` is
// wired the same, opt-in way.
//
// The manifest carries no machine-specific absolute paths: the only absolute
// path (the macOS OCCT lib dir) is derived from this manifest's own location via
// #filePath and the package-relative vendor tree.
import Foundation
import PackageDescription

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

// --- iOS binary-dependency detection (opt-in; empty until build_occt_ios.sh) --
// Glob a vendor subdir for *.xcframework and turn each into a binaryTarget named
// after the framework (e.g. vendor/occt-ios/TKernel.xcframework -> "TKernel").
// A binaryTarget is only *linked* where a target depends on it (we condition
// those dependencies on iOS), so declaring these is inert on macOS.
func iosXCFrameworkTargets(_ subdir: String) -> [Target] {
    let dir = "\(packageDir)/vendor/\(subdir)"
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
    return entries
        .filter { $0.hasSuffix(".xcframework") }
        .sorted()
        .map { name in
            .binaryTarget(name: String(name.dropLast(".xcframework".count)),
                          path: "vendor/\(subdir)/\(name)")
        }
}

let iosOCCTTargets = iosXCFrameworkTargets("occt-ios")
let iosLib3mfTargets = iosXCFrameworkTargets("lib3mf-ios")
let hasIOSOCCT = !iosOCCTTargets.isEmpty

// iOS-only dependencies on the detected OCCT/lib3mf frameworks (link + embed).
let iosBinaryDeps: [Target.Dependency] =
    (iosOCCTTargets + iosLib3mfTargets).map {
        .target(name: $0.name, condition: .when(platforms: [.iOS]))
    }

// STEP import/tagging is compiled where OpenCASCADE is linked: always macOS, and
// iOS too once the iOS OCCT frameworks are present. Elsewhere the bridge returns
// a clear "not available on this platform" error.
let occtPlatforms: [Platform] = hasIOSOCCT ? [.macOS, .iOS] : [.macOS]

var packageTargets: [Target] = [
    // The CMake-built core, per-platform, selected automatically by Xcode.
    .binaryTarget(name: "TopOptCore", path: "vendor/TopOptCore.xcframework"),
    .target(
        name: "TopOptBridge",
        dependencies: ["TopOptCore"] + iosBinaryDeps,
        cxxSettings: [
            .headerSearchPath("../../vendor/include"),
            .define("TOPOPT_BRIDGE_HAS_OCCT", .when(platforms: occtPlatforms)),
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
            // OpenCASCADE on macOS is the Homebrew dylibs (the macOS core slice
            // is the one that contains the STEP importer there). Absolute -L path
            // derived from the manifest location so it resolves when an app links
            // TopOptKit. On iOS, OCCT comes from the embedded xcframeworks above
            // (iosBinaryDeps), so no -L flags are needed there.
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
    // M7.3 flow: depends on TopOptKit, so it must also enable C++ interop
    // (a Swift module built with Cxx interop forces its consumers to enable it).
    .target(
        name: "TopOptFlows",
        dependencies: ["TopOptKit", "TopOptDesign"],
        swiftSettings: [.interoperabilityMode(.Cxx)]
    ),
    .testTarget(
        name: "TopOptFlowsTests",
        dependencies: ["TopOptFlows"],
        swiftSettings: [.interoperabilityMode(.Cxx)]
    ),
]
// The detected iOS OCCT/lib3mf binary targets (empty until build_occt_ios.sh).
packageTargets += iosOCCTTargets + iosLib3mfTargets

let package = Package(
    name: "TopOptKit",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "TopOptKit", targets: ["TopOptKit"]),
        // The M7.2 SwiftUI design system (tokens + reusable glass views). Pure
        // SwiftUI, no C++ interop / core dependency, so it builds on every slice
        // and its tokens are unit-testable headlessly (TopOptDesignTests).
        .library(name: "TopOptDesign", targets: ["TopOptDesign"]),
        // The M7.3 home + import flow (AppModel + Home/Import/Workspace screens).
        // Composes TopOptKit (bridge) + TopOptDesign; its flow logic is unit-
        // testable headlessly (TopOptFlowsTests).
        .library(name: "TopOptFlows", targets: ["TopOptFlows"]),
    ],
    targets: packageTargets,
    cxxLanguageStandard: .cxx17
)
