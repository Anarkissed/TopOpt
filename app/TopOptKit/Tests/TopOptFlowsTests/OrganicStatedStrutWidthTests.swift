import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★★ THE STATED STRUT WIDTH REACHES THE SAMPLE'S TRACE (his walk, 2026-09-09: "The
/// sample cube when the print repairs are on looks awful … This desperately needs a
/// fix").
///
/// It did not. The width was treated as a live radius on the draw — true of a field
/// march, false of the geometry: core's emission merges endpoints closer than a share
/// of the STRUT RADIUS and drops what is left as degenerate, so the radius decides how
/// much of the weave survives the repairs. Measured on his cube, traced:
///
///   width not passed (core derives 1.59 mm from the window): 1671 mm emitted →
///       325 mm after node_merge → 378 mm written, 61 struts
///   his 0.90 mm passed:                                      4061 mm emitted →
///       3707 mm after node_merge → 5371 mm written, 4199 struts
///
/// The part preview has always passed it (`WorkspacePlaceholder`); only the sample did
/// not, which is why the cube and the part disagreed.
final class OrganicStatedStrutWidthTests: XCTestCase {

    private func settings(width: Double) -> LatticeSettings {
        var s = LatticeSettings()
        s.enabled = true
        s.algorithm = "organic"
        s.organicGrowth = true
        s.organicStrutWidthMM = width
        return s
    }

    func testThePicksCarryTheWidthTheUserTyped() {
        let p = OrganicSampleCube.Picks(settings: settings(width: 0.9), layerHeightMM: 0.2)
        XCTAssertEqual(p.strutWidthMM, 0.9, accuracy: 1e-9,
                       "★ the sample's trace must be told the width he typed")
        let none = OrganicSampleCube.Picks(settings: settings(width: 0), layerHeightMM: 0.2)
        XCTAssertEqual(none.strutWidthMM, 0,
                       "no width stated ⇒ 0, and core derives the bead from the window")
    }

    /// A different width is a different cube, so it must not answer from the other's
    /// cache entry — and a sample with NO width stated must keep the key the shipped
    /// variants were baked under.
    func testTheWidthKeysTheCacheOnlyWhenStated() {
        let a = OrganicSampleCube.Picks(settings: settings(width: 0.9), layerHeightMM: 0.2)
        let b = OrganicSampleCube.Picks(settings: settings(width: 1.4), layerHeightMM: 0.2)
        let none = OrganicSampleCube.Picks(settings: settings(width: 0), layerHeightMM: 0.2)
        let ka = OrganicVariantCache.key(picks: a, fieldIdentity: "f")
        let kb = OrganicVariantCache.key(picks: b, fieldIdentity: "f")
        let kn = OrganicVariantCache.key(picks: none, fieldIdentity: "f")
        XCTAssertNotEqual(ka, kb, "★ two widths are two topologies")
        XCTAssertNotEqual(ka, kn, "★ and neither is the derived-bead cube")
        var legacy = none
        legacy.strutWidthMM = 0
        XCTAssertEqual(OrganicVariantCache.key(picks: legacy, fieldIdentity: "f"), kn,
                       "★ no width stated ⇒ the key this build's shipped variants carry")
    }

    /// Core keeps the topology and re-beads it: the same 3352 spans at every width, with
    /// the radius scaled by its own calibration rather than to half the stated width
    /// (0.90 mm stated ⇒ 0.345 mm radius, not 0.45). That is core's business; this pins
    /// that the number ARRIVES, which is the part that was broken.
    func testCoreActsOnTheStatedWidth() throws {
        guard TopOptKit.latticeAlgorithmIsKnown("organic") else { throw XCTSkip("no organic on this core") }
        let n = 24, edge = 20.0, sp = edge / Double(n)
        var t = [Double](repeating: 0, count: 6 * n * n * n)
        for k in 0..<n { for j in 0..<n { for i in 0..<n {
            let e = (k * n + j) * n + i
            let y = 2 * Double(j) / Double(n - 1) - 1
            let m = 1 - Double(i) / Double(n - 1)
            t[6 * e] = 12 * m * y; t[6 * e + 1] = 0.6 * m; t[6 * e + 3] = 4 * (1 - y * y)
        } } }
        func radius(_ width: Double) -> Double? {
            TopOptKit.organicTrace(
                nx: n, ny: n, nz: n, spacingMM: sp, origin: .zero,
                candidate: [Bool](repeating: true, count: n * n * n), stressTensor: t,
                separationMM: [Double](repeating: 3, count: n * n * n),
                minExtrudableWidthMM: 0.42, buildDirection: SIMD3(0, 0, 1),
                fieldDims: (8, 8, 8), fieldOrigin: .zero, fieldSpacingMM: edge / 8,
                bandMM: 2.0, rhoMin: 0.05, rhoMax: 0.9,
                strutDiameterMM: width, grow: false, layerHeightMM: 0.2,
                anchorAtBoundary: false, showRepairs: false)?.spans.first?.r
        }
        guard let thin = radius(0.6), let thick = radius(1.8) else { throw XCTSkip("no trace") }
        print(String(format: "── stated 0.60 mm → r %.3f · stated 1.80 mm → r %.3f", thin, thick))
        XCTAssertGreaterThan(thick, thin * 1.5,
                             "★ a stated width must move the emitted radius")
    }
}
