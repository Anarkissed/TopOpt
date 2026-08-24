import XCTest
import simd
@testable import TopOptFlows

/// ★★★ DOES THE TILING PHASE SURVIVE THE `.a` CHANNEL?
///
/// The promise I made when the quilt came back: read the phase back off the cell
/// texture's alpha the same way the albedo was read, and compare it to what the bake
/// wrote. If they disagree that is the bug; if they agree the phase is right and the
/// quilt is something else.
///
/// ★ IT PUSHES THE VALUE THROUGH THE **REAL** PACKER (`float32to16`, the one
/// `makeCellTexture` calls) and decodes it with the shader's own arithmetic, copied
/// verbatim from `UnifiedShading.swift`:
///
///     float packed = max(0.0, cs.a);
///     int   paxis  = int(floor(packed + 1e-4));
///     float pfrac  = packed - float(paxis);
///
/// Re-implementing either half would make this a probe that agrees with itself.
final class LatticePhaseChannelReadbackProbe: XCTestCase {

    /// Widen a half back to Float exactly as the GPU does when it samples rgba16Float.
    private func half2float(_ h: UInt16) -> Float {
        let sign = UInt32(h & 0x8000) << 16
        let exp = Int((h >> 10) & 0x1f)
        let mant = UInt32(h & 0x03ff)
        if exp == 0 {
            if mant == 0 { return Float(bitPattern: sign) }
            // subnormal half -> normal float
            var e = -1, m = mant
            repeat { m <<= 1; e += 1 } while (m & 0x0400) == 0
            m &= 0x03ff
            let fe = UInt32(127 - 15 - e)
            return Float(bitPattern: sign | (fe << 23) | (m << 13))
        }
        if exp == 0x1f {
            return Float(bitPattern: sign | 0x7f800000 | (mant << 13))
        }
        let fe = UInt32(exp - 15 + 127)
        return Float(bitPattern: sign | (fe << 23) | (mant << 13))
    }

    /// The shader's decode, verbatim.
    private func decode(_ packed: Float) -> (axis: Int, frac: Float) {
        let p = max(0.0, packed)
        let a = Int((p + 1e-4).rounded(.down))
        return (a, p - Float(a))
    }

    /// The round trip, over every axis and a dense sweep of fractions.
    func testPhaseRoundTripThroughTheAlphaChannel() {
        var worstFrac: Float = 0
        var worstAt = ""
        var axisFlips: [String] = []

        for axis in 0...2 {
            var f: Float = 0
            while f < 1.0 {
                // What the bake writes (LatticeSDFMetal.faceTilingPhase).
                var frac = f
                if frac > 0.999 || frac < 0.001 { frac = 0 }
                let written = Float(axis) + frac

                // What the texture actually stores, and what the shader reads back.
                let got = decode(half2float(float32to16(written)))

                if got.axis != axis {
                    axisFlips.append(String(format: "axis %d frac %.4f -> axis %d",
                                            axis, frac, got.axis))
                }
                let err = abs(got.frac - frac)
                if err > worstFrac { worstFrac = err; worstAt = String(
                    format: "axis %d frac %.4f -> %.4f (err %.5f)",
                    axis, frac, got.frac, err) }
                f += 0.0005
            }
        }

        print("PHASE READBACK — worst fraction error \(worstFrac)  at \(worstAt)")
        print("PHASE READBACK — axis flips: \(axisFlips.count)")
        for s in axisFlips.prefix(10) { print("   \(s)") }

        // ★ THE AXIS MUST NEVER MOVE. A flip does not blur the tiling, it shifts the
        // whole region's grid onto a DIFFERENT AXIS — every cap plane in that region
        // lands mid-cell, which is the quilt.
        XCTAssertTrue(axisFlips.isEmpty,
                      "the packed phase changed axis in the .a channel: \(axisFlips.prefix(5))")

        // ★ AND THE FRACTION HAS TO BE GOOD ENOUGH TO PUT A CAP PLANE ON A CELL EDGE.
        // The fraction is measured in CELLS, so an error of e shifts the cap plane by
        // e·cell. At 2.2 mm cells, 0.01 is 22 microns — invisible. 0.1 would be a fifth
        // of a strut pitch and would read as a seam.
        XCTAssertLessThan(worstFrac, 0.01,
                          "the tiling phase is too coarse in half precision: \(worstAt)")
    }

    /// The same trip, but through the real `LatticeCellField` -> packer path a bake uses,
    /// so the array plumbing (`steppedPhase.count == values.count`) is exercised too and
    /// not just the scalar conversion.
    func testPhaseSurvivesTheFieldToTexturePacking() {
        let n = 8
        let grid = LatticeVoxelGrid(nx: n, ny: 1, nz: 1,
                                    origin: .zero,
                                    spacing: SIMD3<Float>(repeating: 1),
                                    values: [Float](repeating: 1, count: n))
        // One representative phase per axis plus the boundary cases the bake clamps.
        let phases: [Float] = [0, 0.25, 0.5, 0.75,
                               1.0, 1.5,
                               2.0, 2.75]
        let field = LatticeCellField(field: grid,
                                     level: [Float](repeating: 0, count: n),
                                     steppedCellMM: [Float](repeating: 2.2, count: n),
                                     steppedPhase: phases,
                                     baseCellMM: 2.2, maxLevel: 0, fromCorePlan: true)

        for i in 0..<n {
            let written = field.steppedPhase[i]
            let got = decode(half2float(float32to16(written)))
            let wantAxis = Int(Foundation.floor(written))
            let wantFrac = written - Float(wantAxis)
            XCTAssertEqual(got.axis, wantAxis, "axis moved for phase \(written)")
            XCTAssertEqual(got.frac, wantFrac, accuracy: 0.01,
                           "fraction drifted for phase \(written)")
        }
    }
}
