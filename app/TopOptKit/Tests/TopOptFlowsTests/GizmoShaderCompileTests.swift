// GizmoShaderCompileTests.swift — proves the recoloured liquid-glass gizmo shader still
// compiles as valid MSL (design-overhaul 109).
//
// The gizmo renders by compiling `GizmoRenderer.shaderSource(.standard)` at runtime with
// `device.makeLibrary(source:)`. A malformed shader does NOT crash — the renderer's `init?`
// just returns nil and the widget falls back to `Color.clear` (an invisible gizmo). The
// blue-frost recolour only touched colour literals, but a stray typo there would be silent, so
// this compiles the exact source the app ships and fails loudly if it is broken.
//
// GPU-gated: skips when no Metal device is available (headless CI), so it never turns a
// no-GPU environment red.

#if canImport(Metal)
import XCTest
import Metal
@testable import TopOptFlows

final class GizmoShaderCompileTests: XCTestCase {

    func testGizmoShaderSourceCompiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device (headless) — shader compile is device QA here")
        }
        let source = GizmoRenderer.shaderSource(.standard)
        // Must compile, and expose both entry points the pipeline binds.
        let library = try device.makeLibrary(source: source, options: nil)
        XCTAssertNotNil(library.makeFunction(name: "gizmo_vertex"), "vertex entry point missing")
        XCTAssertNotNil(library.makeFunction(name: "gizmo_fragment"), "fragment entry point missing")
    }
}
#endif
