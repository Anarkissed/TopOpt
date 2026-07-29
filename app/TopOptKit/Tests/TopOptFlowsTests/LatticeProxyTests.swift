// Headless tests for the lattice viewer proxy (handoff 2026-07-28-lattice-viewer-
// proxy). Everything here is pure value-type math — no GPU, no core, no worker — the
// /app/ verification standard. It pins:
//   • FAITHFULNESS — the on-device lattice family reproduces the worker's committed
//     per-cell strut counts and canonical lengths (→ the K in ρ ≈ K·(r/L)²);
//   • GRADING — demand→density→colour is monotonic and inverts to the legend;
//   • V4 (works with NO real mesh / NO field) — uniform fallback paints one honest
//     colour; the whole proxy needs only the part surface + local params;
//   • V3 (updates on a local param change, no worker) — tints are a pure function of
//     the params, so a change re-shades with the SAME field object;
//   • V1 (cost) — proxy vs real triangles / GPU bytes at 8/6/4 mm cells.

import XCTest
import simd
import TopOptDesign
@testable import TopOptFlows

@MainActor
final class LatticeProxyTests: XCTestCase {

    // MARK: faithfulness to the worker's committed lattice family

    /// Canonical struts per cell match reference_region.csv struts/cell.
    func testCanonicalStrutCountsMatchWorker() {
        let expected: [String: Int] = ["sc": 3, "bcc": 8, "bccz": 9, "fcc": 12,
                                       "fccz": 13, "diamond": 16, "octet": 24]
        for (id, n) in expected {
            XCTAssertEqual(LatticeType.named(id).struts.count, n, "\(id) canonical strut count")
        }
    }

    /// Total canonical strut length per cell matches density.txt to 4 digits — this
    /// is what fixes each K, so the grading radius map is the worker's.
    func testCanonicalStrutLengthMatchesDensityTxt() {
        // multiples of L from density.txt (canonical strut length / cell ÷ L)
        let expected: [String: Double] = [
            "sc": 3.0, "bcc": 6.9282, "bccz": 7.9282, "fcc": 8.4853,
            "fccz": 9.4853, "diamond": 6.9282, "octet": 16.9706,
        ]
        for (id, mult) in expected {
            let lat = LatticeType.named(id)
            let got = lat.canonicalStrutLengthMM(cellMM: 8) / 8
            XCTAssertEqual(got, mult, accuracy: 1e-3, "\(id) canonical length multiple")
        }
    }

    /// The density↔radius map is the exact inverse pair, at the reference point
    /// density.txt uses (r/L = 0.1): octet ρ = 0.48, sc ρ = 0.08485.
    func testDensityRadiusMapIsWorkerLaw() {
        let octet = LatticeType.octet
        let r = octet.strutRadiusMM(relativeDensity: 0.48, cellMM: 8)
        XCTAssertEqual(r / 8, 0.1, accuracy: 1e-6)                       // r/L = 0.1
        XCTAssertEqual(octet.relativeDensity(strutRadiusMM: r, cellMM: 8), 0.48, accuracy: 1e-9)
        XCTAssertEqual(LatticeType.sc.relativeDensity(strutRadiusMM: 0.8, cellMM: 8), 0.08485, accuracy: 1e-4)
    }

    // MARK: grading — monotone, invertible, distinct colour

    func testRelativeDensityGradingEndpointsAndMonotone() {
        let p = LatticeProxyParams(minRelativeDensity: 0.1, maxRelativeDensity: 0.6)
        XCTAssertEqual(LatticeDensityProxy.relativeDensity(demandFraction: 0, params: p), 0.1, accuracy: 1e-9)
        XCTAssertEqual(LatticeDensityProxy.relativeDensity(demandFraction: 1, params: p), 0.6, accuracy: 1e-9)
        var last = -1.0
        for i in 0...10 {
            let rho = LatticeDensityProxy.relativeDensity(demandFraction: Double(i) / 10, params: p)
            XCTAssertGreaterThan(rho, last); last = rho
        }
    }

    func testLegendFractionInvertsGrading() {
        let p = LatticeProxyParams(minRelativeDensity: 0.1, maxRelativeDensity: 0.6)
        for d in stride(from: 0.0, through: 1.0, by: 0.2) {
            let rho = LatticeDensityProxy.relativeDensity(demandFraction: d, params: p)
            // linear gamma → legend fraction returns the demand fraction
            XCTAssertEqual(LatticeDensityProxy.legendFraction(relativeDensity: rho, params: p), d, accuracy: 1e-9)
        }
    }

    /// The density ramp is NOT the stress ramp (so a preview is never read as stress)
    /// and is monotone in luminance.
    func testDensityColourDistinctFromStressAndMonotoneLuma() {
        let dense = LatticeDensityProxy.densityColor(fraction: 1)
        let sparse = LatticeDensityProxy.densityColor(fraction: 0)
        let stressHigh = ResultsModel.stressColor(fraction: 1)     // red
        // dense end is indigo, not the stress red
        XCTAssertLessThan(dense.r, 0.3)
        XCTAssertGreaterThan(stressHigh.r, 0.9)
        func luma(_ c: RGBA) -> Double { 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }
        XCTAssertGreaterThan(luma(sparse), luma(dense))            // sparse pale, dense deep
        var last = 2.0
        for i in 0...10 {
            let l = luma(LatticeDensityProxy.densityColor(fraction: Double(i) / 10))
            XCTAssertLessThanOrEqual(l, last + 1e-9); last = l
        }
    }

    // MARK: V4 — works with NO real mesh and NO field (uniform fallback)

    func testUniformFallbackWhenNoField() {
        let mesh = Self.box(nx: 2)
        let p = LatticeProxyParams(uniformRelativeDensity: 0.25)
        let tints = LatticeDensityProxy.tints(for: mesh, demand: nil, params: p)
        XCTAssertEqual(tints.count, mesh.flat.vertexCount)
        // every vertex the same colour (a uniform, ungraded preview)
        XCTAssertTrue(tints.allSatisfy { simd_length($0 - tints[0]) < 1e-6 })
        // and it is the colour of ρ = 0.25 on the ramp
        let want = LatticeDensityProxy.densityColor(
            fraction: LatticeDensityProxy.legendFraction(relativeDensity: 0.25, params: p))
        XCTAssertEqual(Double(tints[0].x), want.r, accuracy: 1e-6)
    }

    func testEmptyOrZeroFieldFallsBackToUniform() {
        let mesh = Self.box(nx: 2)
        let empty = StressField(nx: 0, ny: 0, nz: 0, origin: .zero, spacing: 0, values: [])
        let t1 = LatticeDensityProxy.tints(for: mesh, demand: empty, params: LatticeProxyParams())
        XCTAssertTrue(t1.allSatisfy { simd_length($0 - t1[0]) < 1e-6 })
    }

    // MARK: graded shading — denser where demand is higher

    func testGradedShadingFollowsDemandField() {
        let mesh = Self.box(nx: 4)                       // spans 0…4 in x
        // von Mises rising with x: sparse at x=0, peak at x=max.
        let n = 5
        var vals = [Float](repeating: 0, count: n * n * n)
        for k in 0..<n { for j in 0..<n { for i in 0..<n { vals[(k * n + j) * n + i] = Float(i) } } }
        let field = StressField(nx: n, ny: n, nz: n, origin: .zero, spacing: 1, values: vals)
        let p = LatticeProxyParams(minRelativeDensity: 0.1, maxRelativeDensity: 0.6)
        let tints = LatticeDensityProxy.tints(for: mesh, demand: field, params: p)
        // the low-x vertices should be paler (lower luma index) than high-x ones:
        // sample the darkest tint sits near max x, palest near min x.
        let positions = mesh.flat.positions
        func luma(_ c: SIMD4<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
        var loX: (x: Float, luma: Float) = (.greatestFiniteMagnitude, 0)
        var hiX: (x: Float, luma: Float) = (-.greatestFiniteMagnitude, 0)
        for v in 0..<mesh.flat.vertexCount {
            let x = positions[v * 3]; let l = luma(tints[v])
            if x < loX.x { loX = (x, l) }
            if x > hiX.x { hiX = (x, l) }
        }
        XCTAssertGreaterThan(loX.luma, hiX.luma, "sparse (pale) at low demand, dense (deep) at high demand")
    }

    // MARK: V3 — a local param change re-shades with the SAME field, no worker

    func testParamChangeReshadesLocally() {
        // A triangle whose three corners sample demand fractions 0, 0.5, 1 — so a
        // grading-curve change moves the MID corner (the extremes stay pinned).
        let verts: [Float] = [0, 0, 0,  3, 0, 0,  6, 0, 0]
        let mesh = ViewerMesh(vertices: verts, indices: [0, 1, 2], faceIDs: [])
        // von Mises rising linearly with x over x = 0…6 (peak 6 at x = 6).
        let field = StressField(nx: 7, ny: 1, nz: 1, origin: .zero, spacing: 1,
                                values: [0, 1, 2, 3, 4, 5, 6])
        // Changing the grading curve (gamma) re-shades the surface — purely a function
        // of params, same field object, no worker round trip.
        let a = LatticeDensityProxy.tints(for: mesh, demand: field,
                    params: LatticeProxyParams(gamma: 1))
        let b = LatticeDensityProxy.tints(for: mesh, demand: field,
                    params: LatticeProxyParams(gamma: 3))
        XCTAssertNotEqual(a, b, "a gamma change must re-shade with the same field")

        // And the density-range labels track ρmin/ρmax instantly (the legend side of
        // the update): the same demand fraction reads a different absolute density.
        let narrow = LatticeProxyParams(minRelativeDensity: 0.1, maxRelativeDensity: 0.3)
        let wide = LatticeProxyParams(minRelativeDensity: 0.1, maxRelativeDensity: 0.9)
        XCTAssertNotEqual(LatticeDensityProxy.relativeDensity(demandFraction: 1, params: narrow),
                          LatticeDensityProxy.relativeDensity(demandFraction: 1, params: wide))
    }

    // MARK: V1 — cost of the proxy vs the real lattice at 8 / 6 / 4 mm

    func testRealTrianglesReproduceCommittedReferenceAt8mm() {
        // At the reference cell + volume, the projection returns the committed count.
        let ref = LatticeDensityProxy.realReferences["octet"]!
        let t = LatticeDensityProxy.realTriangles(latticeID: "octet", cellMM: 8,
                                                  volumeMM3: ref.referenceVolumeMM3)
        XCTAssertEqual(t, 316000)
    }

    func testRealTrianglesScaleAsInverseCellCubed() {
        let ref = LatticeDensityProxy.realReferences["octet"]!
        let v = ref.referenceVolumeMM3
        let t8 = LatticeDensityProxy.realTriangles(latticeID: "octet", cellMM: 8, volumeMM3: v)
        let t4 = LatticeDensityProxy.realTriangles(latticeID: "octet", cellMM: 4, volumeMM3: v)
        XCTAssertEqual(Double(t4) / Double(t8), 8, accuracy: 0.001)   // halve cell → 8×
    }

    func testProxyIsOrdersCheaperThanRealAtEveryCell() {
        let ref = LatticeDensityProxy.realReferences["octet"]!
        let patchTris = LatticeSamplePatch.triangleCount(lattice: .octet, cells: 2)
        for cell in [8.0, 6.0, 4.0] {
            let c = LatticeDensityProxy.cost(latticeID: "octet", cellMM: cell,
                        volumeMM3: ref.referenceVolumeMM3, proxyPatchTriangles: patchTris)
            XCTAssertEqual(c.proxyTriangles, patchTris)              // proxy fixed in cell size
            XCTAssertGreaterThan(c.triangleRatio, 20)                // ≥ 20× fewer tris
            XCTAssertEqual(c.proxyGPUBytes, patchTris * 156)
        }
        // proxy triangle cost does NOT grow with a finer cell; real does.
        let coarse = LatticeDensityProxy.cost(latticeID: "octet", cellMM: 8,
                        volumeMM3: ref.referenceVolumeMM3, proxyPatchTriangles: patchTris)
        let fine = LatticeDensityProxy.cost(latticeID: "octet", cellMM: 4,
                        volumeMM3: ref.referenceVolumeMM3, proxyPatchTriangles: patchTris)
        XCTAssertEqual(coarse.proxyTriangles, fine.proxyTriangles)
        XCTAssertGreaterThan(fine.realTriangles, coarse.realTriangles)
    }

    // MARK: helpers

    /// A tiny axis-aligned cube mesh spanning 0…`nx` in every axis, as a viewer mesh
    /// (positions/indices only). Enough for the tint pipeline to iterate flat verts.
    static func box(nx: Int) -> ViewerMesh {
        let s = Float(nx)
        let c: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(s, 0, 0), SIMD3(s, s, 0), SIMD3(0, s, 0),
            SIMD3(0, 0, s), SIMD3(s, 0, s), SIMD3(s, s, s), SIMD3(0, s, s),
        ]
        var verts: [Float] = []
        for p in c { verts += [p.x, p.y, p.z] }
        let quads = [[0, 1, 2, 3], [4, 5, 6, 7], [0, 1, 5, 4],
                     [2, 3, 7, 6], [1, 2, 6, 5], [0, 3, 7, 4]]
        var idx: [Int32] = []
        for q in quads { idx += [Int32(q[0]), Int32(q[1]), Int32(q[2]),
                                 Int32(q[0]), Int32(q[2]), Int32(q[3])] }
        return ViewerMesh(vertices: verts, indices: idx, faceIDs: [])
    }
}
