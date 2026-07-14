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
// xcframework (`vendor/TopOptCore.xcframework`) by `../scripts/build_core.sh`.
//
// OpenCASCADE on iOS (M7.1b): STEP import needs OCCT. On macOS it is the Homebrew
// dylibs, linked via the -L flags below. On iOS it is delivered as cross-built
// dynamic-framework xcframeworks under `vendor/occt-ios/` (from
// `../scripts/build_occt_ios.sh`; LGPL 2.1 dynamic linking, ARCHITECTURE §4/§10),
// which the app links + embeds through the `TopOptOCCT` product.
//
// WHERE the iOS OCCT/lib3mf framework list comes from (M7.1c hardening):
// It is read at manifest-evaluation time from a SEPARATE, GIT-IGNORED file,
// `occt-frameworks.generated.json`, written by build_occt_ios.sh from what it
// actually produced under vendor/occt-ios/. The list is deliberately NOT stored
// in THIS committed file, so a stray `git add -A` cannot re-commit a populated
// list and break the macOS/CI build (run 039). When the JSON is absent (fresh
// checkout, CI, OCCT-free machine) the lists resolve to EMPTY: macOS build/tests
// stay green and no iOS binaryTargets are declared. That is the committed default.
//
// DISK-GATED (M7.1c hardening follow-up): even when the JSON IS present, a
// framework is declared only if its vendor/occt-ios/<name>.xcframework exists on
// disk (see loadGeneratedFrameworks). So a committed or stale JSON is harmless —
// on a fresh checkout the git-ignored vendor/ tree is absent, so the list gates
// to empty and the build stays OCCT-free/green regardless of what the JSON says.
//
// CACHE NOTE: SwiftPM caches the *compiled manifest* keyed on THIS FILE's
// contents, NOT on files the manifest reads. Because the list now lives outside
// this file, changing the JSON does NOT change that cache key — so
// build_occt_ios.sh explicitly invalidates the SwiftPM manifest cache (and bumps
// this file's mtime, which leaves `git status` clean) after writing the JSON, to
// force re-evaluation. See that script's write_manifest_list / cache-bust step.
import Foundation
import PackageDescription

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

// Read the git-ignored generated list. Absent/malformed -> empty (OCCT-free).
struct GeneratedFrameworks: Decodable {
    let occt: [String]?
    let lib3mf: [String]?
}
func loadGeneratedFrameworks() -> (occt: [String], lib3mf: [String]) {
    let path = packageDir + "/occt-frameworks.generated.json"
    guard let data = FileManager.default.contents(atPath: path),
          let g = try? JSONDecoder().decode(GeneratedFrameworks.self, from: data)
    else { return ([], []) }
    // DISK PRESENCE IS THE REAL GATE. Only declare a framework whose .xcframework
    // actually exists under vendor/. The JSON is a per-machine hint; gating on the
    // file on disk means a committed or stale JSON is HARMLESS — on a fresh
    // checkout / CI the git-ignored vendor/ tree is absent, so the list filters to
    // empty -> OCCT-free -> macOS/CI build stays green. Without this, a committed
    // list points binaryTargets at absent artifacts and `swift build` fails with
    // "local binary target 'TKBO' … does not contain a binary artifact" (the
    // post-M7.1c breakage a maintainer hit by force-committing the JSON).
    let fm = FileManager.default
    func onDisk(_ names: [String]?, _ subdir: String) -> [String] {
        (names ?? []).filter {
            fm.fileExists(atPath: packageDir + "/vendor/\(subdir)/\($0).xcframework")
        }
    }
    return (onDisk(g.occt, "occt-ios"), onDisk(g.lib3mf, "lib3mf-ios"))
}
let (iosOCCTFrameworks, iosLib3mfFrameworks) = loadGeneratedFrameworks()

let iosBinaryNames = iosOCCTFrameworks + iosLib3mfFrameworks
let hasIOSOCCT = !iosOCCTFrameworks.isEmpty

// One binaryTarget per produced xcframework (paths exist because the generating
// script produced them; empty list -> none declared -> no missing-path errors).
let iosBinaryTargets: [Target] =
    iosOCCTFrameworks.map { .binaryTarget(name: $0, path: "vendor/occt-ios/\($0).xcframework") } +
    iosLib3mfFrameworks.map { .binaryTarget(name: $0, path: "vendor/lib3mf-ios/\($0).xcframework") }

// STEP import/tagging is compiled where OpenCASCADE is linked: always macOS, and
// iOS too once the iOS OCCT frameworks are present. Elsewhere the bridge returns
// a clear "not available on this platform" error.
let occtPlatforms: [Platform] = hasIOSOCCT ? [.macOS, .iOS] : [.macOS]

var packageTargets: [Target] = [
    // The CMake-built core, per-platform, selected automatically by Xcode.
    .binaryTarget(name: "TopOptCore", path: "vendor/TopOptCore.xcframework"),
    .target(
        name: "TopOptBridge",
        // The OCCT frameworks are linked into the app through the TopOptOCCT
        // product (below); the bridge itself references OCCT only through the
        // core, so it needs no binary dependency — just the compile define.
        dependencies: ["TopOptCore"],
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
            // contains the STEP importer there). Absolute -L path derived from the
            // manifest location so it resolves when an app links TopOptKit. On iOS,
            // OCCT comes from the embedded xcframeworks via the TopOptOCCT product.
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
        // On macOS the core slice links OCCT via TopOptKit's Homebrew -L/-l flags.
        // On iOS the OCCT symbols the core slice pulls in (STEP import) are only
        // satisfied by the cross-built OCCT frameworks, which the *app* gets via
        // the TopOptOCCT product. A package unit-test bundle does not link that
        // product, so to exercise STEP import on an iphonesimulator destination
        // the test bundle must itself link + embed the iOS OCCT frameworks.
        // iOS-gated and empty on macOS / OCCT-free checkouts (iosBinaryNames == [])
        // so macOS build/tests and CI are unaffected.
        dependencies: ["TopOptKit"]
            + iosBinaryNames.map { .target(name: $0, condition: .when(platforms: [.iOS])) },
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
        // Transitively links the core (TopOptFlows -> TopOptKit -> TopOptCore),
        // so on iOS it must link + embed the OCCT frameworks too (see the note on
        // TopOptKitTests). iOS-gated; empty on macOS / OCCT-free checkouts.
        dependencies: ["TopOptFlows"]
            + iosBinaryNames.map { .target(name: $0, condition: .when(platforms: [.iOS])) },
        swiftSettings: [.interoperabilityMode(.Cxx)]
    ),
    // Carrier for the iOS OCCT/lib3mf frameworks. The app's xcodeproj links the
    // `TopOptOCCT` product; the shim keeps that product valid on an OCCT-free
    // checkout, and the binary xcframeworks (when present) are listed in the
    // product so Xcode links + embeds them into the app. See TopOptOCCTShim.swift.
    .target(name: "TopOptOCCTShim"),
]
// The detected iOS OCCT/lib3mf binary targets (empty until build_occt_ios.sh).
packageTargets += iosBinaryTargets

let package = Package(
    name: "TopOptKit",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "TopOptKit", targets: ["TopOptKit"]),
        // The M7.2 SwiftUI design system (tokens + reusable glass views).
        .library(name: "TopOptDesign", targets: ["TopOptDesign"]),
        // The M7.3 home + import flow (AppModel + Home/Import/Workspace screens).
        .library(name: "TopOptFlows", targets: ["TopOptFlows"]),
        // The iOS OCCT/lib3mf frameworks, vended to the app. Listing the binary
        // targets directly in the product is the SwiftPM binary-distribution
        // pattern that makes Xcode link + embed them into an app that depends on
        // the product. Always includes the shim so the product exists OCCT-free.
        .library(name: "TopOptOCCT", targets: ["TopOptOCCTShim"] + iosBinaryNames),
    ],
    targets: packageTargets,
    cxxLanguageStandard: .cxx17
)
