// StepImportProbeTests — a DIAGNOSTIC probe for "the file loads, the stage draws a
// shadow, and nothing is drawn" (task 2026-08-21, his `M2 verticalStand THICK`).
//
// Points the real importer at a STEP path handed in through the environment and
// prints every count the viewer depends on. `TOPOPT_STEP_PROBE=/path/to/file.step`.
// Skips when unset, so it costs a normal suite run nothing.
//
// ★ THE HYPOTHESIS IT WAS BUILT TO KILL OR CONFIRM: a shadow with no body means the
// stage HAS bounds — so a mesh arrived — but nothing rasterised. `vertexCount > 0`
// with `indices.count == 0` is exactly that shape: tessellation produced points and
// no faces.
//
// ★★ REFUTED, ON macOS, 2026-08-21. His file imports CLEAN, and by every measure this
// probe can take it is healthier than the fixture that renders correctly:
//
//                              M2_verticalStand_THICK    M2_verticalStand (works)
//     triangleCount ........              3,324                     3,106
//     vertexCount ..........              1,664                     1,555
//     indices.count ........              9,972  (= 3×tri)          9,318  (= 3×tri)
//     faceCount ............                 77                        78
//     watertight ...........               true                      true
//     degenerate triangles .                  0                         0
//     out-of-range indices .                  0                         0
//     non-finite vertices ..                  0                         0
//     signed volume ........        978,348.8 mm³             543,268.7 mm³
//                                    (OUTWARD)                  (OUTWARD)
//
// So it is NOT tessellation (indices are exactly 3× the triangles) and NOT winding
// (positive signed volume — the second hypothesis, tested because an inverted mesh is
// culled by the rasteriser while a contact shadow, which does not cull, survives:
// precisely "a shadow and no body"). The 1.8x volume matches "20 mm walls".
//
// Both hypotheses are recorded here as REFUTED rather than dropped, because the next
// person to look will otherwise test them again. Whatever empties that viewport is
// downstream of the import, and the macOS import is not where it lives.

import XCTest
import simd
import TopOptKit

final class StepImportProbeTests: XCTestCase {

    func testProbeAStepFileNamedByTheEnvironment() throws {
        guard let path = ProcessInfo.processInfo.environment["TOPOPT_STEP_PROBE"],
              !path.isEmpty else {
            throw XCTSkip("set TOPOPT_STEP_PROBE to a .step path to run this probe")
        }
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path),
                          "TOPOPT_STEP_PROBE points at nothing: \(path)")

        let mesh = try TopOptKit.importMesh(path: path)
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var nonFinite = 0
        let vn = mesh.vertices.count / 3
        for v in 0..<vn {
            let p = SIMD3<Float>(mesh.vertices[v * 3], mesh.vertices[v * 3 + 1],
                                 mesh.vertices[v * 3 + 2])
            if !p.x.isFinite || !p.y.isFinite || !p.z.isFinite { nonFinite += 1; continue }
            lo = simd_min(lo, p); hi = simd_max(hi, p)
        }
        let degenerate = (mesh.indices.count >= 3)
            ? stride(from: 0, to: mesh.indices.count - 2, by: 3).filter { t in
                let a = mesh.indices[t], b = mesh.indices[t + 1], c = mesh.indices[t + 2]
                return a == b || b == c || a == c
            }.count
            : 0
        let outOfRange = mesh.indices.filter { Int($0) >= vn }.count

        // ★ WINDING, BY SIGNED VOLUME. A closed mesh wound outward has POSITIVE
        // divergence-theorem volume; wound inward it is the same magnitude, negated.
        // Inverted winding is invisible in every count above and is culled by the
        // rasteriser — a body that vanishes while its shadow (which does not cull)
        // stays is exactly that shape.
        func vtx(_ k: Int) -> SIMD3<Float> {
            let i = Int(mesh.indices[k]) * 3
            return SIMD3<Float>(mesh.vertices[i], mesh.vertices[i + 1], mesh.vertices[i + 2])
        }
        var vol = 0.0
        for t in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
            let a = vtx(t), b = vtx(t + 1), c = vtx(t + 2)
            vol += Double(simd_dot(a, simd_cross(b, c))) / 6.0
        }

        print("""

        ================================================================================
        STEP IMPORT PROBE — \((path as NSString).lastPathComponent)
        --------------------------------------------------------------------------------
        triangleCount ............ \(mesh.triangleCount)
        vertexCount .............. \(mesh.vertexCount)   (vertices array / 3 = \(vn))
        indices.count ............ \(mesh.indices.count)   (expected \(mesh.triangleCount * 3))
        faceCount ................ \(mesh.faceCount)
        faceIDs.count ............ \(mesh.faceIDs.count)
        watertight ............... \(mesh.watertight)
        bounds min ............... \(lo)
        bounds max ............... \(hi)
        extent ................... \(hi - lo)
        non-finite vertices ...... \(nonFinite)
        degenerate triangles ..... \(degenerate)
        out-of-range indices ..... \(outOfRange)
        signed volume ............ \(String(format: "%.1f", vol)) mm³ \
        (\(vol >= 0 ? "OUTWARD" : "★ INVERTED — every face is backfacing"))
        ================================================================================
        """)

        // Reported, not asserted — this is a probe. The one bar it does hold is that
        // the arrays AGREE with each other, because a mesh whose counts disagree is a
        // mesh no renderer can draw and that is worth failing on wherever it appears.
        XCTAssertEqual(mesh.indices.count, mesh.triangleCount * 3,
                       "indices must match the stated triangle count")
        XCTAssertEqual(mesh.vertices.count, mesh.vertexCount * 3,
                       "vertices must match the stated vertex count")
        XCTAssertEqual(outOfRange, 0, "every index must address a real vertex")
    }
}
