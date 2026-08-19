// LatticeStressOverlayTests — ★ C2: THE OVERLAY HAS SOMETHING TO PAINT WITH.
//
// ★ WHY THIS EXISTS. `LatticeSDFScene.demand` is a `var` with an implicit nil, so
// the first cut of the stress bake — written ABOVE the line that assigns it —
// read nil every time. `stressRGB` was always nil, the texture was never built,
// and the flag that gates the overlay (`stressTex != nil`) was never set. The
// setting would have travelled the whole way and drawn nothing: the same defect
// this branch has already hit with `boundary`, with the rebake key, and with the
// uniform layout. A test that asserts the VOLUME EXISTS is what closes it.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

final class LatticeStressOverlayTests: XCTestCase {

    /// A field with real spatial variation, so the colours cannot all be one value.
    ///
    /// ★ IT VARIES ALONG THE PART'S LONGEST AXIS, and the spacing is taken from
    /// that axis rather than from the bbox diagonal. A first cut used
    /// `length(ext)/24` — 12.5 mm — and graded along Y, which spans only 52 mm on
    /// his part: about four field cells, so the volume genuinely held ~5 distinct
    /// colours and the test failed on its own fixture, not on the code. The
    /// fixture is the thing that was wrong.
    private func gradedField(_ b: MeshBounds) -> StressField {
        let ext = b.max - b.min
        let n = 48
        let sp = Swift.max(ext.x, Swift.max(ext.y, ext.z)) / Float(n)
        var vals = [Float](repeating: 0, count: n * n * n)
        for k in 0..<n { for j in 0..<n { for i in 0..<n {
            vals[(k * n + j) * n + i] = Float(i) / Float(n - 1)   // along X, the long axis
        } } }
        return StressField(nx: n, ny: n, nz: n, origin: b.min, spacing: sp, values: vals)
    }

    func testAFieldProducesAStressVolume() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let withField = LatticeSDFScene(mesh: mesh, field: gradedField(mesh.bounds),
                                        latticeID: "octet")
        let rgb = try XCTUnwrap(withField.stressRGB,
                                "★ a scene WITH a stress field must bake the overlay "
                                + "volume — nil here means the overlay paints nothing "
                                + "and the setting is decorative")
        XCTAssertEqual(rgb.count, withField.occupancy.values.count * 4,
                       "one RGBA per voxel of the occupancy grid")

        // ★ AND IT MUST VARY. An all-one-colour volume would satisfy the count and
        // still be useless — that is what a nil demand would have produced had it
        // been defaulted rather than absent.
        var seen = Set<Int>()
        for i in stride(from: 0, to: rgb.count, by: 4) {
            seen.insert(Int(rgb[i]) << 16 | Int(rgb[i + 1]) << 8 | Int(rgb[i + 2]))
        }
        XCTAssertGreaterThan(seen.count, 8,
                             "★ the overlay must span the ramp, not paint one colour")
    }

    /// No field ⇒ no volume, and the preview keeps the density ramp.
    func testNoFieldMeansNoOverlay() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let bare = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet")
        XCTAssertNil(bare.stressRGB,
                     "★ without a field there is nothing to paint, and the flag that "
                     + "gates the overlay must stay off")
    }
}
