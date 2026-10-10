import XCTest
import simd
@testable import TopOptFlows

/// ★★★ DOES THE CELL'S ORIGIN SURVIVE THE `.a` CHANNEL?
///
/// The promise made when the quilt came back: read the phase back off the cell
/// texture's alpha the way the shader does and compare it to what the bake wrote. If
/// they disagree that is the bug; if they agree the phase is right and the quilt is
/// something else.
///
/// ★ SINCE 2026-09-17 (Stepped's any-step packing) the channel is a 32-bit float
/// carrying the cell's origin on ALL THREE axes — three 7-bit fractions of the cell
/// plus the face axis, packed by `LatticeSDFRenderer.packCellOrigin` and unpacked by
/// `lsdf_cell_frame_at`, verbatim:
///
///     int   packed = int(max(0.0, cs.a) + 0.5);
///     int   paxis  = packed & 3;
///     int   pq     = packed >> 2;
///     float3 phase = float3(pq & 127, (pq >> 7) & 127, (pq >> 14) & 127) * (m / 128.0);
///
/// This pushes values through the REAL packer and decodes them with that arithmetic
/// copied here. Re-implementing either half would make a probe that agrees with itself.
final class LatticePhaseChannelReadbackProbe: XCTestCase {

    /// The shader's decode, verbatim (in texel units; `m` = cell size / pitch).
    private func decode(_ packed: Float, m: Float) -> (axis: Int, phase: SIMD3<Float>) {
        let p = Int(max(0.0, packed) + 0.5)
        let axis = p & 3
        let q = p >> 2
        let phase = SIMD3<Float>(Float(q & 127), Float((q >> 7) & 127), Float((q >> 14) & 127)) * (m / 128)
        return (axis, phase)
    }

    /// A float32 `a` channel holds the packed integer EXACTLY — every value the packer
    /// can produce is below 2^24.
    func testThePackedIntegerIsExactInAFloat() {
        let top = Float(3 + 4 * (127 + 128 * (127 + 128 * 127)))
        XCTAssertLessThan(top, Float(1 << 24))
        XCTAssertEqual(top, Float(Int(top)), "the largest packed value is not an exact float")
    }

    /// The old scalar phase (one fraction along the face axis) through the new packer:
    /// the axis never moves, the fraction comes back within 1/256 of a cell.
    func testTheFaceAxisPhaseRoundTripsThroughTheAlphaChannel() {
        var worst: Float = 0
        var worstAt = ""
        var axisFlips: [String] = []
        let sMM: Float = 2.2, pitch: Float = 1.1
        let m = sMM / pitch
        for axis in 0...2 {
            var f: Float = 0
            while f < 1.0 {
                var frac = f
                if frac > 0.999 || frac < 0.001 { frac = 0 }
                let written = Float(axis) + frac
                let packed = LatticeSDFRenderer.packCellOrigin(sizeMM: sMM, pitchMM: pitch, phase: written, origin: nil)
                let got = decode(packed, m: m)
                if got.axis != axis {
                    axisFlips.append(String(format: "axis %d frac %.4f -> axis %d", axis, frac, got.axis))
                }
                // the phase is in texel units: frac·m along the axis, 0 elsewhere
                for ax in 0..<3 {
                    let want: Float = ax == axis ? frac * m : 0
                    // modulo the cell: a phase of 0.9985 cells and one of 0 are the
                    // same tiling to within 0.0015 cells, and the packer wraps it so
                    let raw = abs(got.phase[ax] - want) / m
                    let err = min(raw, abs(1 - raw))
                    if err > worst { worst = err; worstAt = String(format: "axis %d frac %.4f -> %.4f (err %.5f cells)", axis, frac, got.phase[ax] / m, err) }
                }
                f += 0.0005
            }
        }
        print("PHASE READBACK — worst error \(worst) cells at \(worstAt); axis flips \(axisFlips.count)")
        XCTAssertTrue(axisFlips.isEmpty, "the packed phase changed axis: \(axisFlips.prefix(5))")
        // 1/128 of a cell, rounded: within 1/256 — 47 microns of a 12 mm cell, 12 of a
        // 3 mm one. 0.1 would be a fifth of a strut pitch and would read as a seam.
        XCTAssertLessThan(worst, 1.0 / 256 + 1e-4, "the origin is too coarse in the channel: \(worstAt)")
    }

    /// A full three-axis origin, the Stepped case — a 9 mm cell three texels in on
    /// two axes and half a texel down on the third — through the field's own arrays
    /// and the packer, back within 1/256 of a cell per axis.
    func testAThreeAxisOriginSurvivesTheFieldToTexturePacking() {
        let n = 6
        let pitch: Float = 3
        let grid = LatticeVoxelGrid(nx: n, ny: 1, nz: 1, origin: .zero,
                                    spacing: SIMD3<Float>(repeating: pitch),
                                    values: [Float](repeating: 1, count: n))
        let sizes: [Float] = [9, 9, 8, 4, 3, 12]
        let origins: [SIMD3<Float>] = [SIMD3(1, 0, 0.5), SIMD3(0, 1, 2.9), SIMD3(1.3333, 0, 0),
                                       SIMD3(0.3333, 0.6667, 1), SIMD3(0, 0, 0), SIMD3(3.5, 0, 0)]
        let phases: [Float] = [1, 1.5, 2, 0.25, 1, 1]
        var field = LatticeCellField(field: grid, level: [Float](repeating: 0, count: n),
                                     steppedCellMM: sizes, steppedPhase: phases,
                                     baseCellMM: Double(pitch), maxLevel: 0, fromCorePlan: false)
        field.steppedOrigin = origins
        for i in 0..<n {
            let m = sizes[i] / pitch
            let packed = LatticeSDFRenderer.packCellOrigin(sizeMM: sizes[i], pitchMM: pitch,
                                                           phase: phases[i], origin: field.steppedOrigin[i])
            let got = decode(packed, m: m)
            XCTAssertEqual(got.axis, Int(phases[i].rounded(.down)), "axis moved at \(i)")
            for ax in 0..<3 {
                XCTAssertEqual(got.phase[ax], origins[i][ax], accuracy: m / 256 + 1e-4,
                               "origin drifted at cell \(i) axis \(ax): wrote \(origins[i][ax]) read \(got.phase[ax])")
            }
        }
    }
}
