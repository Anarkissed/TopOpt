import XCTest
import simd
@testable import TopOptFlows

/// ★★★ THE STRESS OVERLAY PAINTS THE **MEASUREMENT**, NOT THE GRADING DEMAND
/// (maintainer, 2026-08-24 evening: "The lattice view doesn't have the actual
/// stress values *overlayed*... The lattice is blue but does not compare to the
/// look when the lattice is off").
///
/// The strut colours were baked from `demand` — the density input, which minimize
/// plastic caps by utilisation, ~0 on his part — so every strut took the ramp's
/// bottom colour while the solid view showed the load paths. The bake now reads
/// `stressDemand`, the measured field percentile-normalised on the same grid.
final class LatticeStressOverlayTests: XCTestCase {

    func testTheOverlayVariesWithTheMeasuredField() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        guard let r = LatticeRegionEmission.planeFor(face: FaceID(2), in: mesh),
              let spec = LatticeRegionEmission.spec(for: r, role: .include,
                                                    depthMM: 13.0, faceID: 2)
        else { throw XCTSkip("no plane") }
        // A measured field with real structure: stress rises linearly along X.
        let b = mesh.bounds
        let n = 16
        var vm = [Float](repeating: 0, count: n * n * n)
        for k in 0..<n { for j in 0..<n { for i in 0..<n {
            vm[(k * n + j) * n + i] = Float(i) / Float(n - 1) * 10.0
        } } }
        let span = max(b.max.x - b.min.x, max(b.max.y - b.min.y, b.max.z - b.min.z))
        let field = StressField(nx: n, ny: n, nz: n,
                                origin: b.min,
                                spacing: span / Float(n - 1),
                                values: vm)
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    stressField: field,
                                    regions: [spec], whenEmpty: .latticeNothing)
        guard let rgb = scene.stressRGB else {
            return XCTFail("a scene with a measured field must bake overlay colours — "
                + "before this fix, a withheld grading field also silenced the overlay")
        }
        // The colours must VARY: distinct colour triples across the volume. A
        // demand-painted bake on an unloaded part collapses to one colour.
        var distinct = Set<[UInt8]>()
        for i in stride(from: 0, to: rgb.count, by: 4) {
            distinct.insert([rgb[i], rgb[i + 1], rgb[i + 2]])
            if distinct.count > 8 { break }
        }
        XCTAssertGreaterThan(distinct.count, 8,
            "a linear measured field must paint a ramp, not one colour")
        // And they are the TINT of the measured stressDemand — the same ramp the
        // legend and the solid plot use — not of the grading demand.
        guard let sd = scene.stressDemand else { return XCTFail("no stressDemand") }
        for probe in [0, sd.values.count / 2, sd.values.count - 1] {
            let c = LatticeStressTint.colour(fraction: Double(sd.values[probe]))
            XCTAssertEqual(Double(rgb[probe * 4]), Double(c.x * 255), accuracy: 1.5)
            XCTAssertEqual(Double(rgb[probe * 4 + 1]), Double(c.y * 255), accuracy: 1.5)
            XCTAssertEqual(Double(rgb[probe * 4 + 2]), Double(c.z * 255), accuracy: 1.5)
        }
    }
}
