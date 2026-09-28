import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★★ "THE SAMPLE CUBE WHEN THE PRINT REPAIRS ARE ON LOOKS AWFUL … how did it go from
/// a cube which had grade to shape to whatever this is?" (his walk, 2026-09-09).
///
/// The same cube the wizard bakes, through the wizard's own path, with the repairs off
/// and on. Measures where the geometry actually IS: its bounding box against the 20 mm
/// block, how much length sits outside the block, and how far the worst offender
/// reaches. A picture cannot be argued with, but neither can a millimetre.
final class OrganicRepairedCubeProbe: XCTestCase {

    /// His saved picks (project.json, M2 verticalStand, 2026-09-09): organic, GROWN,
    /// ties on, shape fit on, boundary none (bare), auto cell.
    private func hisSettings() -> LatticeSettings {
        var s = LatticeSettings()
        s.enabled = true
        s.algorithm = "organic"
        s.organicGrowth = true
        s.organicTransferTies = true
        s.organicTieSwirl = 1
        s.organicShapeFit = true
        s.organicShapeFitOnly = false
        s.organicOverhangFillet = false
        s.organicSolidRimMM = -1
        s.organicStrutWidthMM = 0.9
        s.organicLookPercent = 54
        s.boundary = .none
        s.cellSizeMode = .auto
        s.stageMode = .aesthetic
        s.simulateStresses = true
        return s
    }

    private func measure(_ tag: String, _ b: OrganicSampleCube.Baked, edge: Double) {
        let caps = b.scene.organicCapsules
        guard !caps.isEmpty else { print("── \(tag): NO CAPSULES"); return }
        var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
        var total = 0.0, outside = 0.0, worst = 0.0, outCount = 0
        for c in caps {
            let a = SIMD3<Double>(c.a), bb = SIMD3<Double>(c.b), r = Double(c.r)
            lo = simd_min(lo, simd_min(a, bb) - SIMD3(repeating: r))
            hi = simd_max(hi, simd_max(a, bb) + SIMD3(repeating: r))
            let len = simd_length(bb - a)
            total += len
            // how far outside the block does each end sit?
            func out(_ p: SIMD3<Double>) -> Double {
                let d = simd_max(SIMD3<Double>(repeating: 0) - p, p - SIMD3<Double>(repeating: edge))
                return simd_reduce_max(simd_max(d, SIMD3<Double>(repeating: 0)))
            }
            let oa = out(a), ob = out(bb)
            if Swift.max(oa, ob) > 0.05 { outCount += 1; outside += len; worst = Swift.max(worst, Swift.max(oa, ob)) }
        }
        print("── \(tag): \(caps.count) capsules · \(String(format: "%.0f", total)) mm")
        print(String(format: "   bounds x %.2f…%.2f  y %.2f…%.2f  z %.2f…%.2f   (the block is 0…%.0f on every axis)",
                     lo.x, hi.x, lo.y, hi.y, lo.z, hi.z, edge))
        print(String(format: "   spans reaching outside the block: %d (%.1f %%), %.0f mm of length, worst end %.2f mm out",
                     outCount, 100 * Double(outCount) / Double(caps.count), outside, worst))
        let rad = caps.map { Double($0.r) }.sorted()
        let len = caps.map { simd_length(SIMD3<Double>($0.b) - SIMD3<Double>($0.a)) }.sorted()
        func p(_ v: [Double], _ q: Double) -> Double { v[Swift.min(v.count - 1, Swift.max(0, Int((q * Double(v.count - 1)).rounded())))] }
        print(String(format: "   radius mm  p05 %.3f  p50 %.3f  p95 %.3f  max %.3f", p(rad, 0.05), p(rad, 0.5), p(rad, 0.95), rad.last ?? 0))
        print(String(format: "   span length mm  p05 %.2f  p50 %.2f  p95 %.2f  max %.2f  · mean %.2f",
                     p(len, 0.05), p(len, 0.5), p(len, 0.95), len.last ?? 0, total / Double(caps.count)))
        print("   census: \(b.measurement)")
    }

    func testTheCubeWithAndWithoutTheRepairs() async throws {
        guard TopOptKit.latticeAlgorithmIsKnown("organic") else { throw XCTSkip("no organic on this core") }
        let s = hisSettings()
        let edge = OrganicSampleCube.edgeMM
        for (grown, repairs) in [(true, false), (true, true), (false, false), (false, true)] {
            var ss = s; ss.organicGrowth = grown
            let picks = OrganicSampleCube.Picks(settings: ss, layerHeightMM: 0.2, showRepairs: repairs)
            guard let b = await OrganicSampleCube.baked(picks: picks, latticeID: "octet") else {
                XCTFail("no cube (grown \(grown), repairs \(repairs))"); return
            }
            measure("\(grown ? "GROWN" : "TRACED") · \(repairs ? "REPAIRS ON" : "repairs off")", b, edge: edge)
        }
    }
}
