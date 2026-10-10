import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★ P4 — ONE OUTLINE AS SIMPLE LOOPS (the reviewer, 2026-10-10 21:27, approved by the maintainer: "union
/// to simple loops; collapsed holes dropped; the grown holes and the unshrunk total-shrink fixed … Land it
/// FIRST, as its own commit. It is a defect in jobs today (63 of 110 multi-loop regions on 102117B9). Red
/// first: a job with two overlapping loops where core's region_contains reads the overlap as outside.
/// 68BF7B74 face 2's zero-length edges go in the same test set.")
///
/// Core reads `outline_uv` EVEN-ODD over every loop (clearance.cpp:147-158). Today's wire offsets each loop
/// on its own (`offsetRing`, mitred), so two fragments grown by the expand overlap and core reads the
/// overlap as a hole; an expand grows a HOLE instead of shrinking it; and a shrink that eats a loop hands
/// back the loop unshrunk. The preview's own set (the bake's dOut) is the raw outline grown by the expand —
/// the reference every case below is checked against, through core's own containment (the bridge's
/// `stepped_region_owners` → `region_contains`).
final class LatticeOutlineUnionTests: XCTestCase {

    private func face(_ loops: [[SIMD2<Double>]], expand: Double = 0) -> LatticeRegionSpec {
        var r = LatticeRegionSpec(role: .include, kind: .face)
        r.origin = .zero; r.normal = SIMD3(0, 0, 1); r.depthMM = 4
        var hu = 0.0, hw = 0.0
        for l in loops { for q in l { hu = Swift.max(hu, abs(q.x)); hw = Swift.max(hw, abs(q.y)) } }
        r.halfUMM = hu; r.halfWMM = hw
        r.outlineLoops = loops
        r.inPlaneOffsetMM = expand
        return r
    }

    private func square(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> [SIMD2<Double>] {
        [SIMD2(x0, y0), SIMD2(x1, y0), SIMD2(x1, y1), SIMD2(x0, y1)]
    }

    /// Core's verdict: is the point at in-plane (u, w), 1 mm into the slab, inside the region as the job sends it?
    private func coreInside(_ r: LatticeRegionSpec, _ uv: SIMD2<Double>) throws -> Bool {
        let n = LatticeRegionMask.unit(r.normal)
        let (bu, bv) = LatticeRegionMask.basis(n)
        let p = r.origin + bu * uv.x + bv * uv.y + n * 1.0
        let owners = try XCTUnwrap(TopOptKit.steppedRegionOwners(regions: [r.wireDictionary], points: [p]),
                                   "core answers: \(TopOptKit.lastCoreRefusal ?? "")")
        return owners.owners.first == 1
    }

    /// The preview's verdict: the bake's own outline distance, positive inside.
    private func previewInside(_ r: LatticeRegionSpec, _ uv: SIMD2<Double>) -> Bool {
        -(LatticeFaceOutline.signedDistanceAcrossSeams(uv, loops: r.outlineLoops, seams: r.outlineSeams,
                                                       tilts: r.outlineSeamTilt, caps: r.outlineSeamDepthMM)
          - r.inPlaneOffsetMM) > 0
    }

    /// ★ RED on today's wire: two fragments of one region sharing an edge, grown 1 mm. Each grown ring
    /// covers the 2 mm band around the shared edge, so core's even-odd reads that band as a HOLE where the
    /// preview draws solid.
    func testTwoOverlappingRingsAreOneRegionInCore() throws {
        let r = face([square(0, 0, 10, 10), square(10, 0, 20, 10)], expand: 1)
        for uv in [SIMD2(10.5, 5.0), SIMD2(9.5, 5.0), SIMD2(10.0, 10.5)] {
            XCTAssertTrue(previewInside(r, uv), "the preview draws \(uv) solid")
            XCTAssertTrue(try coreInside(r, uv), "★ core reads \(uv) inside, as the preview does")
        }
        // controls: well inside, and outside the grown outline
        XCTAssertTrue(try coreInside(r, SIMD2(5, 5)))
        XCTAssertFalse(try coreInside(r, SIMD2(21.5, 5)))
        XCTAssertFalse(previewInside(r, SIMD2(21.5, 5)))
    }

    /// ★ RED on today's wire: an expand SHRINKS a hole. A 20 mm square with an 8–12 mm hole, grown 1 mm:
    /// the hole is 9–11 in the preview; today's wire grew it to 7–13.
    func testAnExpandShrinksAHole() throws {
        let r = face([square(0, 0, 20, 20), square(8, 8, 12, 12)], expand: 1)
        XCTAssertTrue(previewInside(r, SIMD2(7.5, 10)))
        XCTAssertTrue(try coreInside(r, SIMD2(7.5, 10)), "★ 0.5 mm into the old hole edge is solid")
        XCTAssertTrue(try coreInside(r, SIMD2(8.5, 10)), "★ and so is 0.5 mm inside the raw hole")
        XCTAssertFalse(previewInside(r, SIMD2(10, 10)), "control: the hole's middle stays open in the preview")
        XCTAssertFalse(try coreInside(r, SIMD2(10, 10)), "control: and in core")
    }

    /// ★ RED on today's wire: a shrink that eats the whole outline leaves NOTHING — never the unshrunk outline.
    func testATotalShrinkLeavesNoOutline() {
        let r = face([square(0, 0, 4, 4)], expand: -3)
        XCTAssertFalse(previewInside(r, SIMD2(2, 2)), "the preview draws nothing")
        XCTAssertTrue(r.wireOutlineLoops.isEmpty, "★ no outline is left: \(r.wireOutlineLoops)")
        // a partial shrink still sends the shrunk outline
        let partial = face([square(0, 0, 10, 10)], expand: -1)
        XCTAssertFalse(partial.wireOutlineLoops.isEmpty)
    }

    /// ★ RED on today's wire (68BF7B74 face 2's eight zero-length edges): a notch narrower than twice the
    /// expand closes, and `offsetRing` collapsed its vertices onto one point. The sent loops are simple: no
    /// zero-length edge, no two loops overlapping.
    func testAClosingNotchLeavesNoZeroLengthEdge() throws {
        let notch: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(20, 0), SIMD2(20, 10), SIMD2(10.5, 10), SIMD2(10.5, 7),
                                      SIMD2(9.5, 7), SIMD2(9.5, 10), SIMD2(0, 10)]
        let r = face([notch], expand: 1)
        let loops = r.wireOutlineLoops
        XCTAssertFalse(loops.isEmpty)
        var shortest = Double.greatestFiniteMagnitude
        for l in loops { for i in l.indices { shortest = Swift.min(shortest, simd_length(l[(i + 1) % l.count] - l[i])) } }
        XCTAssertGreaterThan(shortest, 1e-6, "★ no zero-length edge on the wire")
        XCTAssertTrue(try coreInside(r, SIMD2(10, 9)), "the closed notch is solid, as the preview draws it")
        XCTAssertTrue(previewInside(r, SIMD2(10, 9)))
    }

    /// CONTROL: a region with nothing to offset goes on the wire byte-identical — the five projects with no
    /// expand and no diverging seam do not move.
    func testNothingToOffsetIsByteIdentical() {
        let loops = [square(0, 0, 10, 10), square(20, 0, 30, 10)]
        XCTAssertEqual(face(loops).wireOutlineLoops, loops)
    }

    /// The emission drops a region whose outline shrank away, by name, rather than sending core an empty
    /// outline_uv (which core reads as the region's whole bounding box).
    func testTheEmissionDropsAShrunkAwayRegion() {
        var gone = face([square(0, 0, 4, 4)], expand: -3); gone.selectableKey = "f:G:7"
        let kept = face([square(0, 0, 10, 10)], expand: -1)
        var regions = [gone, kept]
        let dropped = LatticeRegionEmission.dropShrunkAway(&regions)
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions.first?.inPlaneOffsetMM, -1)
        XCTAssertEqual(dropped, ["f:G:7"])
    }
}
