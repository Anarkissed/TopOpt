// Headless tests for the M7.viz.4 load-path visualization's pure-data derivation:
// the symmetric eigen-solver, the strain gradient from the nodal displacement
// field, the principal-direction glyph builder, and the ResultsModel wiring
// (toggle, mutual exclusivity with flex, the render buffer). The Metal line draw
// is device QA (the M7 /app/ standard); a GPU smoke test here only confirms the
// overlay changes the rasterization, mirroring the flex GPU smoke.

import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit
import TopOptDesign
#if canImport(MetalKit)
import Metal
#endif

final class LoadPathTests: XCTestCase {

    // MARK: helpers

    /// A DisplacementField over an nx×ny×nz voxel grid whose node displacements are
    /// `f(worldPosition)` — an analytic field so the derived strain is known exactly.
    private func field(nx: Int, ny: Int, nz: Int, spacing: Float,
                       origin: SIMD3<Float> = .zero,
                       _ f: (SIMD3<Float>) -> SIMD3<Float>) -> DisplacementField {
        let na = nx + 1, nb = ny + 1, nc = nz + 1
        var vals = [Float](repeating: 0, count: 3 * na * nb * nc)
        for c in 0..<nc {
            for b in 0..<nb {
                for a in 0..<na {
                    let n = (c * nb + b) * na + a
                    let p = origin + SIMD3<Float>(Float(a), Float(b), Float(c)) * spacing
                    let d = f(p)
                    vals[3 * n] = d.x; vals[3 * n + 1] = d.y; vals[3 * n + 2] = d.z
                }
            }
        }
        return DisplacementField(nx: nx, ny: ny, nz: nz, origin: origin, spacing: spacing, values: vals)
    }

    private func assertClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, accuracy: Float = 1e-4,
                             _ msg: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, msg, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, msg, file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: accuracy, msg, file: file, line: line)
    }

    // MARK: symmetric eigen-solver

    func testEigenOfDiagonalIsSortedDiagonal() {
        let pairs = SymmetricEigen.decompose([[3, 0, 0], [0, 7, 0], [0, 0, 1]])
        XCTAssertEqual(pairs.map { $0.value }, [7, 3, 1])   // descending
        // Eigenvectors are the axes (up to sign).
        XCTAssertEqual(abs(pairs[0].vector.y), 1, accuracy: 1e-9)   // λ=7 → Y
        XCTAssertEqual(abs(pairs[1].vector.x), 1, accuracy: 1e-9)   // λ=3 → X
        XCTAssertEqual(abs(pairs[2].vector.z), 1, accuracy: 1e-9)   // λ=1 → Z
    }

    func testEigenReconstructsAndIsOrthonormal() {
        // A dense symmetric matrix; check A·v = λ·v and mutual orthonormality.
        let m: [[Double]] = [[2, -1, 0], [-1, 2, -1], [0, -1, 2]]
        let pairs = SymmetricEigen.decompose(m)
        for (value, vec) in pairs {
            let av = SIMD3<Double>(
                m[0][0] * vec.x + m[0][1] * vec.y + m[0][2] * vec.z,
                m[1][0] * vec.x + m[1][1] * vec.y + m[1][2] * vec.z,
                m[2][0] * vec.x + m[2][1] * vec.y + m[2][2] * vec.z)
            let lv = value * vec
            XCTAssertEqual(simd_length(av - lv), 0, accuracy: 1e-9, "A·v ≠ λ·v")
            XCTAssertEqual(simd_length(vec), 1, accuracy: 1e-9, "eigenvector not unit")
        }
        // Pairwise orthogonal.
        XCTAssertEqual(simd_dot(pairs[0].vector, pairs[1].vector), 0, accuracy: 1e-9)
        XCTAssertEqual(simd_dot(pairs[0].vector, pairs[2].vector), 0, accuracy: 1e-9)
        XCTAssertEqual(simd_dot(pairs[1].vector, pairs[2].vector), 0, accuracy: 1e-9)
        // Known eigenvalues of this matrix: 2, 2±√2.
        XCTAssertEqual(pairs[0].value, 2 + 2.0.squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(pairs[1].value, 2, accuracy: 1e-9)
        XCTAssertEqual(pairs[2].value, 2 - 2.0.squareRoot(), accuracy: 1e-9)
    }

    // MARK: strain tensor from the displacement gradient

    func testStrainUniaxialStretch() {
        // u = (s·x, 0, 0) → ∂ux/∂x = s, ε = diag(s, 0, 0).
        let s: Float = 0.01
        let d = field(nx: 1, ny: 1, nz: 1, spacing: 2) { p in SIMD3<Float>(s * p.x, 0, 0) }
        let eps = LoadPathField.strainTensor(displacement: d, i: 0, j: 0, k: 0, spacing: 2)
        XCTAssertEqual(eps[0][0], Double(s), accuracy: 1e-6)
        for r in 0..<3 { for c in 0..<3 where !(r == 0 && c == 0) {
            XCTAssertEqual(eps[r][c], 0, accuracy: 1e-6, "off-axis strain \(r),\(c)")
        }}
    }

    func testStrainSimpleShearIsSymmetric() {
        // u = (s·y, 0, 0) → ∂ux/∂y = s, ε_xy = ε_yx = s/2, everything else 0.
        let s: Float = 0.02
        let d = field(nx: 1, ny: 1, nz: 1, spacing: 1) { p in SIMD3<Float>(s * p.y, 0, 0) }
        let eps = LoadPathField.strainTensor(displacement: d, i: 0, j: 0, k: 0, spacing: 1)
        XCTAssertEqual(eps[0][1], Double(s) / 2, accuracy: 1e-6)
        XCTAssertEqual(eps[1][0], Double(s) / 2, accuracy: 1e-6)   // symmetric
        XCTAssertEqual(eps[0][0], 0, accuracy: 1e-6)
        XCTAssertEqual(eps[1][1], 0, accuracy: 1e-6)
    }

    // MARK: glyph direction

    func testGlyphDominantDirectionIsStretchAxis() {
        // Uniaxial stretch → dominant principal axis is X, tensile.
        let s: Float = 0.01
        let d = field(nx: 1, ny: 1, nz: 1, spacing: 1) { p in SIMD3<Float>(s * p.x, 0, 0) }
        let g = try! XCTUnwrap(LoadPathField.glyph(displacement: d, i: 0, j: 0, k: 0,
                                                   center: SIMD3(0.5, 0.5, 0.5), spacing: 1, stressMPa: 5))
        XCTAssertEqual(abs(g.direction.x), 1, accuracy: 1e-4)   // along X (sign arbitrary)
        XCTAssertEqual(simd_length(g.direction), 1, accuracy: 1e-5)
        XCTAssertGreaterThan(g.principalStrain, 0)              // tension
        XCTAssertTrue(g.isTensile)
        XCTAssertEqual(g.stressMPa, 5)
    }

    func testGlyphShearDirectionIs45Degrees() {
        // Simple shear → principal axes at 45° in the XY plane.
        let s: Float = 0.02
        let d = field(nx: 1, ny: 1, nz: 1, spacing: 1) { p in SIMD3<Float>(s * p.y, 0, 0) }
        let g = try! XCTUnwrap(LoadPathField.glyph(displacement: d, i: 0, j: 0, k: 0,
                                                   center: .zero, spacing: 1, stressMPa: 1))
        // Dominant direction lies in XY at |x| == |y|, no Z component.
        XCTAssertEqual(g.direction.z, 0, accuracy: 1e-4)
        XCTAssertEqual(abs(g.direction.x), abs(g.direction.y), accuracy: 1e-3)
        XCTAssertEqual(abs(simd_dot(g.direction, normalize(SIMD3<Float>(1, 1, 0)))), 1, accuracy: 1e-3)
    }

    func testGlyphNilOnUndeformedVoxel() {
        // Zero displacement everywhere → no strain → no meaningful direction.
        let d = field(nx: 1, ny: 1, nz: 1, spacing: 1) { _ in .zero }
        XCTAssertNil(LoadPathField.glyph(displacement: d, i: 0, j: 0, k: 0,
                                         center: .zero, spacing: 1, stressMPa: 0))
    }

    // MARK: field builder

    func testBuildEmptyOnEmptyField() {
        let empty = DisplacementField(nx: 0, ny: 0, nz: 0, origin: .zero, spacing: 0, values: [])
        XCTAssertTrue(LoadPathField.build(displacement: empty, stress: nil).isEmpty)
    }

    func testBuildProducesAlignedGlyphsOverPrintedVoxels() {
        // Uniaxial stretch on a 3×3×3 grid, uniform stress → a glyph per voxel, all
        // pointing along X, coloured by the stress value.
        let s: Float = 0.01
        let d = field(nx: 3, ny: 3, nz: 3, spacing: 1) { p in SIMD3<Float>(s * p.x, 0, 0) }
        let stress = StressField(nx: 3, ny: 3, nz: 3, origin: .zero, spacing: 1,
                                 values: [Float](repeating: 12, count: 27))
        let path = LoadPathField.build(displacement: d, stress: stress)
        XCTAssertEqual(path.count, 27)                      // stride 1 at this size
        XCTAssertGreaterThan(path.segmentLength, 0)
        for g in path.glyphs {
            XCTAssertEqual(abs(g.direction.x), 1, accuracy: 1e-3)
            XCTAssertEqual(g.stressMPa, 12)
        }
    }

    func testBuildSkipsVoidVoxelsViaStressGate() {
        // Deformation everywhere, but stress only in voxel (0,0,0) → one glyph.
        let s: Float = 0.01
        let d = field(nx: 2, ny: 2, nz: 2, spacing: 1) { p in SIMD3<Float>(s * p.x, 0, 0) }
        var sv = [Float](repeating: 0, count: 8)
        sv[0] = 9                                            // only voxel (0,0,0) printed
        let stress = StressField(nx: 2, ny: 2, nz: 2, origin: .zero, spacing: 1, values: sv)
        let path = LoadPathField.build(displacement: d, stress: stress)
        XCTAssertEqual(path.count, 1)
        XCTAssertEqual(path.glyphs[0].stressMPa, 9)
    }

    func testBuildRespectsGlyphBudget() {
        // A grid with far more voxels than the budget subsamples via the stride.
        let s: Float = 0.01
        let d = field(nx: 20, ny: 20, nz: 20, spacing: 1) { p in SIMD3<Float>(s * p.x, 0, 0) }
        let path = LoadPathField.build(displacement: d, stress: nil, maxGlyphs: 64)
        XCTAssertGreaterThan(path.count, 0)
        XCTAssertLessThanOrEqual(path.count, 64)            // stays under budget
    }

    // MARK: honesty copy

    func testLoadPathCopyIsHonestEstimate() {
        XCTAssertTrue(LoadPathCopy.what.lowercased().contains("principal-stress"))
        XCTAssertTrue(LoadPathCopy.what.lowercased().contains("anchors"))
        // States it is an estimate from the deflection field, not a solved tensor.
        XCTAssertTrue(LoadPathCopy.how.lowercased().contains("estimated"))
        XCTAssertTrue(LoadPathCopy.how.lowercased().contains("deflection"))
    }

    // MARK: ResultsModel wiring

    /// A results model over a 3×3×3 uniaxial-stretch variant so the load path is
    /// non-trivial (a glyph per printed voxel, all along X).
    @MainActor private func loadPathModel() -> ResultsModel {
        let s: Float = 0.01
        let disp = field(nx: 3, ny: 3, nz: 3, spacing: 1) { p in SIMD3<Float>(s * p.x, 0, 0) }
        let stress = [Float](repeating: 10, count: 27)
        let v = OptimizeVariant(
            requestedVolumeFraction: 0.5, achievedVolumeFraction: 0.5, massGrams: 10,
            supportVolumeVoxels: 0, meshTriangleCount: 1, worstCaseMargin: 2, accepted: true,
            v3Passes: true, orientation: SIMD3(0, 0, 1), maxStressMPa: 10,
            meshVertices: [0, 0, 0, 1, 0, 0, 1, 1, 1], meshIndices: [0, 1, 2],
            vonMisesField: stress, displacementField: Array(disp.values))
        let out = OptimizeOutcome(variants: [v], stoppedOnMargin: false, cancelled: false,
                                  acceptedCount: 1, voxelVolumeMM3: 1,
                                  gridNx: 3, gridNy: 3, gridNz: 3, gridOrigin: .zero, spacing: 1)
        return ResultsModel(projectName: "P", outcome: out, materialName: "PLA", yieldStrengthMPa: 55)
    }

    @MainActor func testHasLoadPathReflectsDisplacementField() {
        XCTAssertTrue(loadPathModel().hasLoadPath)
        // No displacement field → no load path (same requirement as flex).
        let m = ResultsModel(projectName: "P", outcome: OptimizeOutcome(
            variants: [OptimizeVariant(requestedVolumeFraction: 0.5, achievedVolumeFraction: 0.5,
                massGrams: 1, supportVolumeVoxels: 0, meshTriangleCount: 1, worstCaseMargin: 2,
                accepted: true, v3Passes: true, maxStressMPa: 1)],
            stoppedOnMargin: false, cancelled: false, acceptedCount: 1, voxelVolumeMM3: 1))
        XCTAssertFalse(m.hasLoadPath)
    }

    @MainActor func testSelectedLoadPathIsDerivedAndCached() {
        let m = loadPathModel()
        let path = try! XCTUnwrap(m.selectedLoadPath)
        XCTAssertFalse(path.isEmpty)
        for g in path.glyphs { XCTAssertEqual(abs(g.direction.x), 1, accuracy: 1e-3) }
        // Cached: identical glyph count + segment on re-query for the same selection.
        XCTAssertEqual(m.selectedLoadPath?.count, path.count)
    }

    @MainActor func testLoadPathSegmentsBufferLayoutAndColor() {
        let m = loadPathModel()
        let path = try! XCTUnwrap(m.selectedLoadPath)
        let verts = m.loadPathSegments(for: path)
        // Two vertices per glyph, stride-7 (pos xyz + rgba).
        XCTAssertEqual(verts.count, path.count * 2 * 7)
        // Every vertex is opaque and its endpoints straddle the glyph centre along
        // the direction (segment midpoint == the voxel centre).
        for (gi, g) in path.glyphs.enumerated() {
            let base = gi * 14
            let p0 = SIMD3<Float>(verts[base], verts[base + 1], verts[base + 2])
            let p1 = SIMD3<Float>(verts[base + 7], verts[base + 8], verts[base + 9])
            assertClose((p0 + p1) * 0.5, g.position, accuracy: 1e-3)
            XCTAssertEqual(verts[base + 6], 1)              // alpha
            XCTAssertEqual(verts[base + 13], 1)
            // Stress 10 on a scale keyed to yield 55 → a below-yield colour (not red).
            let r = verts[base + 3]
            XCTAssertLessThan(r, 1)
        }
    }

    @MainActor func testToggleLoadPathAndMutualExclusionWithFlex() {
        let m = loadPathModel()
        XCTAssertFalse(m.loadPathOn)
        m.toggleFlex()                                       // flex on
        XCTAssertTrue(m.flexOn)
        m.toggleLoadPath()                                   // load path on → flex off
        XCTAssertTrue(m.loadPathOn)
        XCTAssertFalse(m.flexOn)
        m.toggleFlex()                                       // flex on → load path off
        XCTAssertTrue(m.flexOn)
        XCTAssertFalse(m.loadPathOn)
    }

    // MARK: GPU smoke (device QA covers legibility; this only proves it draws)

    #if canImport(MetalKit)
    func testRendererDrawsLoadPathLines() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device on this host")
        }
        guard let renderer = MeshRenderer(device: device) else {
            XCTFail("MeshRenderer init failed: \(MeshRenderer.lastInitError ?? "unknown")")
            return
        }
        // A unit cube so there is something on-stage; then overlay bright load-path
        // lines and confirm the rasterization changes, and clearing restores it.
        let corners: [Float] = [0,0,0, 1,0,0, 1,1,0, 0,1,0, 0,0,1, 1,0,1, 1,1,1, 0,1,1]
        let tris: [Int32] = [1,2,6, 1,6,5, 0,4,7, 0,7,3, 3,7,6, 3,6,2,
                             0,1,5, 0,5,4, 4,5,6, 4,6,7, 0,3,2, 0,2,1]
        renderer.setMesh(ViewerMesh(vertices: corners, indices: tris, faceIDs: []))
        let baseline = renderer.renderOffscreen(size: 96)
        XCTAssertNotNil(baseline)

        // A magenta segment across the cube (pos xyz + rgba, two vertices).
        let seg: [Float] = [-1, 0.5, 0.5, 1, 0, 1, 1,
                             2, 0.5, 0.5, 1, 0, 1, 1]
        renderer.setLoadPath(seg)
        XCTAssertNotEqual(renderer.renderOffscreen(size: 96), baseline, "load-path lines did not draw")

        renderer.clearLoadPath()
        XCTAssertEqual(renderer.renderOffscreen(size: 96), baseline, "clearing did not restore the frame")
    }
    #endif
}
