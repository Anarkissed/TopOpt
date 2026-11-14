import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★★ THE BRIDGE'S PAYLOAD REACHES THE SCENE INTACT (2026-09-07).
///
/// `organic_preview_field` returns ONE flat array: a header, then the synthetic rows,
/// the centreline field, the relative density, the SURFACE field, the synthesised von
/// Mises, and the spans. Every block is found by adding up the lengths of the ones
/// before it, so DROPPING one silently reads every later block from the wrong place.
/// Adding the synthesised field did exactly that — the edit deleted the surface
/// field's append — and the spans then parsed as empty. No capsules, so the renderer
/// fell back to the distance field; no field either, so the part fell back to the
/// doubled ladder. Every test passed: they check the header and the field's length,
/// and both were fine.
///
/// This is the guard that would have caught it: trace a real block and require that
/// geometry comes out the other end.
final class OrganicCandidateSetProbe: XCTestCase {

    private func wall(depth: Double, halfMM: Double, faceID: Int) -> LatticeRegionSpec {
        var s = LatticeRegionSpec(role: .include, kind: .face)
        s.origin = SIMD3<Double>(10, 0, 10)
        s.normal = SIMD3<Double>(0, 1, 0)
        s.halfUMM = halfMM; s.halfWMM = halfMM; s.depthMM = depth
        s.outlineLoops = [[SIMD2(-halfMM, -halfMM), SIMD2(halfMM, -halfMM),
                           SIMD2(halfMM, halfMM), SIMD2(-halfMM, halfMM)]]
        s.faceID = faceID
        s.selectableKey = "f:x:\(faceID)"
        return s
    }

    func testWhatReachesTheTracerWithAndWithoutTheRegionIDs() throws {
        guard TopOptKit.latticeAlgorithmIsKnown("organic") else { throw XCTSkip("no organic on this core") }
        let mesh = LatticeWizardSample.cube(edgeMM: 20, at: .zero)
        let n = 16
        let spacing = 20.0 / Double(n)
        var tensor = [Double](repeating: 0, count: 6 * n * n * n)
        for i in 0..<(n * n * n) {
            tensor[6 * i] = 10; tensor[6 * i + 1] = 3; tensor[6 * i + 2] = 1
        }
        let w = wall(depth: 8, halfMM: 9, faceID: 2)
        var input = LatticeOrganicInput(
            tensor: tensor, dims: (n, n, n), originMM: .zero, spacingMM: spacing,
            minExtrudableWidthMM: 0.45, buildDirection: SIMD3(0, 0, 1),
            separationMinMM: 2.9, separationMaxMM: 2.9, rhoMin: 0.05, rhoMax: 0.9,
            shapeFit: true)

        func spans(withIDs: Bool) -> Int {
            var o = input
            if withIDs {
                let plan = OrganicSyntheticStress.plan(
                    regions: [w], dims: o.dims, originMM: o.originMM, spacingMM: o.spacingMM,
                    defaultFoci: 4, statedFoci: [:])
                o.regionIDs = plan.regionIDs
            }
            let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                        stageMode: .aesthetic, algorithm: "organic",
                                        organic: o, regions: [w], whenEmpty: .latticeNothing)
            print("  ids=\(withIDs) → \(scene.organicCapsules.count) capsules · why: \(scene.organicNotDrawnReason ?? "drawn") · \(scene.organicSummary)")
            return scene.organicCapsules.count
        }
        // ★ and the SEPARATION is the other variable: 3.96–5.50 traced 23,702 spans on
        // his part; 2.91 traced none.
        for sep in [2.9, 3.96, 5.5] {
            input.separationMinMM = sep; input.separationMaxMM = sep
            print("  separation \(sep) mm:")
            _ = spans(withIDs: false)
        }
        input.separationMinMM = 2.9; input.separationMaxMM = 2.9
        let old = spans(withIDs: false)
        let new = spans(withIDs: true)
        print("""

        ── what reaches the tracer ──────────────────────────────────────────
        occupancy resample (the old path) .... \(old) capsules
        exact region ids (the new path) ...... \(new) capsules
        """)
        XCTAssertGreaterThan(old, 0, "positive control: the old path traced something")
        XCTAssertGreaterThan(new, 0, "★ the exact-id path must not starve the tracer")
        XCTAssertEqual(old, new,
                       "★ the two ways of asking which voxels are in the region must "
                       + "agree — they sampled points half a voxel apart")

        // ★ AND THE PAYLOAD ITSELF, BLOCK BY BLOCK. Every later block is found by
        // adding the lengths of the earlier ones, so a dropped append is invisible
        // until something at the END comes back empty.
        let f = 24
        let t = try XCTUnwrap(TopOptKit.organicTrace(
            nx: n, ny: n, nz: n, spacingMM: spacing, origin: .zero,
            candidate: [Bool](repeating: true, count: n * n * n),
            stressTensor: tensor,
            separationMM: [Double](repeating: 3.0, count: n * n * n),
            minExtrudableWidthMM: 0.45, buildDirection: SIMD3(0, 0, 1),
            fieldDims: (f, f, f), fieldOrigin: .zero, fieldSpacingMM: 20.0 / Double(f),
            bandMM: 1.0))
        XCTAssertEqual(t.field.count, f * f * f, "the centreline field")
        XCTAssertEqual(t.surfaceField.count, t.field.count, "★ the SURFACE field — the block that went missing")
        XCTAssertEqual(t.relativeDensity.count, n * n * n, "the relative density")
        XCTAssertGreaterThan(t.spans.count, 0, "★ and the spans, which are LAST and so fail first")
        XCTAssertTrue(t.field.allSatisfy { $0 >= 0 && $0.isFinite })
        XCTAssertTrue(t.surfaceField.allSatisfy { $0.isFinite },
                      "★ a surface field read out of the spans' bytes is not finite")
        for s in t.spans {
            XCTAssertGreaterThan(s.r, 0, "★ a radius parsed at the wrong offset is not a radius")
            XCTAssertLessThan(s.r, 20, "★ …nor is a coordinate")
        }
    }
}
