import XCTest
import simd
@testable import TopOptFlows
import TopOptKit

/// ★ PROBE (his 2026-09-18 report): under ORGANIC the wall's far face stays as a grey wall
/// behind the struts and the FLOOR opens — the opposite of octet. This replicates
/// `shell_is_latticed` (decl mode) over every triangle of his part, for the octet scene
/// and for the same scene with organic's rim erosion, and prints the open fraction per
/// face direction. Measurement, not a pin.
final class LatticeShellSeeThroughProbe: XCTestCase {
    private func regions(_ mesh: ViewerMesh) -> [LatticeRegionSpec] {
        var out: [LatticeRegionSpec] = []
        for (face, depth) in [(15, 12.0), (2, 13.0)] {
            if let plane = LatticeRegionEmission.planeFor(face: FaceID(face), in: mesh),
               let spec = LatticeRegionEmission.spec(for: plane, role: .include, depthMM: depth, faceID: face) {
                out.append(spec)
            }
        }
        return out
    }

    /// The shader's rule, verbatim: face decls (inward normals), 30° agreement, one voxel
    /// in along ±inward, region ≤ 0 ⇒ open. The eye test is skipped (both sides counted).
    private func open(_ p: SIMD3<Float>, _ sn: SIMD3<Float>, decls: [SIMD3<Float>],
                      r: LatticeVoxelGrid, voxel: Float) -> Bool {
        let gate = Float(cos(30.0 * Double.pi / 180))
        for inward in decls {
            var capSign: Float = 0
            if simd_dot(sn, -inward) >= gate { capSign = 1 }
            else if simd_dot(sn, inward) >= gate { capSign = -1 }
            else { continue }
            let q = p + inward * (voxel * capSign)
            let g = (q - r.origin) / r.spacing
            if g.x < -0.5 || g.y < -0.5 || g.z < -0.5 || g.x > Float(r.nx) - 0.5 || g.y > Float(r.ny) - 0.5 || g.z > Float(r.nz) - 0.5 { continue }
            let a = min(max(Int(g.x.rounded()), 0), r.nx - 1), b = min(max(Int(g.y.rounded()), 0), r.ny - 1), c = min(max(Int(g.z.rounded()), 0), r.nz - 1)
            if r.values[(c * r.ny + b) * r.nx + a] <= 0 { return true }
        }
        return false
    }

    private func census(_ scene: LatticeSDFScene, mesh: ViewerMesh, label: String) throws -> [String: Double] {
        let r = try XCTUnwrap(scene.regionSDF, "\(label): no region field")
        let voxel = max(r.spacing.x, max(r.spacing.y, r.spacing.z))
        let decls = scene.regions.filter { $0.role == .include && $0.kind == .face }
            .map { SIMD3<Float>(LatticeRegionMask.unit($0.normal)) }
        var openArea: [String: Double] = [:], area: [String: Double] = [:]
        let P = mesh.positions, I = mesh.indices
        var t = 0
        while t + 2 < I.count {
            let i0 = Int(I[t]), i1 = Int(I[t + 1]), i2 = Int(I[t + 2]); t += 3
            let a = SIMD3<Float>(P[3*i0], P[3*i0+1], P[3*i0+2]), b = SIMD3<Float>(P[3*i1], P[3*i1+1], P[3*i1+2]), c = SIMD3<Float>(P[3*i2], P[3*i2+1], P[3*i2+2])
            let n = simd_cross(b - a, c - a); let A = Double(simd_length(n)) * 0.5
            guard A > 1e-9 else { continue }
            let sn = simd_normalize(n)
            let ax = abs(sn.x) >= abs(sn.y) && abs(sn.x) >= abs(sn.z) ? "x" : (abs(sn.y) >= abs(sn.z) ? "y" : "z")
            let key = (sn[ax == "x" ? 0 : ax == "y" ? 1 : 2] >= 0 ? "+" : "-") + ax
            area[key, default: 0] += A
            if open((a + b + c) / 3, sn, decls: decls, r: r, voxel: voxel) { openArea[key, default: 0] += A }
        }
        var out: [String: Double] = [:]
        for (k, v) in area { out[k] = (openArea[k] ?? 0) / v }
        print("SHELL \(label): decl normals \(decls.map { "(\($0.x),\($0.y),\($0.z))" }) · open fraction by face direction: "
              + out.keys.sorted().map { String(format: "%@ %.0f%%", $0, 100 * out[$0]!) }.joined(separator: "  "))
        return out
    }

    func testWhichFacesTheShellOpensUnderOctetAndUnderOrganic() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let regs = regions(mesh)
        try XCTSkipIf(regs.isEmpty, "no declarable faces")
        let octet = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet", regions: regs, whenEmpty: .latticeNothing)
        let a = try census(octet, mesh: mesh, label: "octet")
        var o = LatticeOrganicInput(tensor: [], dims: (0, 0, 0), originMM: .zero, spacingMM: 1,
                                    minExtrudableWidthMM: 0.45, buildDirection: SIMD3(0, 0, 1),
                                    separationMinMM: 3.47, separationMaxMM: 5.2, rhoMin: 0.073, rhoMax: 0.9)
        o.solidRimMM = 1.71
        let organic = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet", algorithm: "organic",
                                      organic: o, regions: regs, whenEmpty: .latticeNothing)
        let b = try census(organic, mesh: mesh, label: "organic(rim 1.71)")
        for k in Set(a.keys).union(b.keys).sorted() {
            print(String(format: "SHELL   %@: octet %.0f%% → organic %.0f%%", k, 100 * (a[k] ?? 0), 100 * (b[k] ?? 0)))
        }
    }
}

extension LatticeShellSeeThroughProbe {
    /// The REAL renderer: the shell clip's mode/decls as the mesh view builds them, and
    /// an offscreen render with the body VISIBLE, octet vs organic, same camera.
    func testTheRealRendererShellClipUnderOctetAndOrganic() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no GPU") }
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let regs = regions(mesh)
        try XCTSkipIf(regs.isEmpty, "no declarable faces")
        let n = 56
        let e = mesh.bounds.max - mesh.bounds.min
        let sp = Double(max(e.x, max(e.y, e.z))) / Double(n)
        var tensor = [Double](repeating: 0, count: 6 * n * n * n)
        for i in 0..<(n * n * n) { tensor[6 * i] = 10; tensor[6 * i + 1] = 3; tensor[6 * i + 2] = 1 }
        var input = LatticeOrganicInput(tensor: tensor, dims: (n, n, n), originMM: SIMD3<Double>(mesh.bounds.min),
                                        spacingMM: sp, minExtrudableWidthMM: 0.45, buildDirection: SIMD3(0, 0, 1),
                                        separationMinMM: 3.47, separationMaxMM: 5.2, rhoMin: 0.073, rhoMax: 0.9)
        input.solidRimMM = 1.71
        for (label, algo, org) in [("octet", "", nil), ("organic", "organic", input)] as [(String, String, LatticeOrganicInput?)] {
            let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet", stageMode: .aesthetic,
                                        algorithm: algo, organic: org, maxDim: 64, regions: regs, whenEmpty: .latticeNothing)
            guard let r = MeshRenderer(device: device, sampleCount: 4) else { throw XCTSkip("MeshRenderer") }
            r.setMesh(mesh)
            r.camera.setOrientation(azimuth: 0.7, elevation: 0.5)
            r.setLatticeScene(scene, token: 1)
            r.latticeParams = LatticeProxyParams(latticeID: "octet", cellMM: 11, minRelativeDensity: 0.073, maxRelativeDensity: 0.9)
            r.latticeSteppedCellMM = []
            try XCTSkipUnless(r.latticePipelinesDidBuild, "pipelines")
            print("SHELL-REAL \(label): capsulePipelineBuilt \(r.organicCapsulePipelineDidBuild) initError \(MeshRenderer.lastInitError ?? "nil")")
            let sc = r.shellClipForTests
            let mode = sc.grid.w < 0.5 ? "OFF" : (sc.gate.y > 1.5 ? "CELL-ACTIVATION" : "DECL(\(sc.declCount))")
            print("SHELL-REAL \(label): mode \(mode) grid.w \(sc.grid.w) dims \(sc.dims) neutralTex \(r.shellClipTextureIsNeutralForTests) "
                  + "capsules \(scene.organicCapsules.count) regionSDF \(scene.regionSDF != nil) activeCells \(r.activeCellsForTests)")
            let size = 320
            r.setBodyAlpha(1)
            let body = try XCTUnwrap(r.renderOffscreen(size: size, stage: false))
            r.setBodyAlpha(0)
            let bare = try XCTUnwrap(r.renderOffscreen(size: size, stage: false))
            var lit1 = 0, lit0 = 0, grey1 = 0, grey0 = 0
            func isGrey(_ px: [UInt8], _ i: Int) -> Bool {
                let b = Int(px[i]), g = Int(px[i+1]), r = Int(px[i+2])
                return r + g + b > 90 && abs(r - g) < 14 && abs(g - b) < 14
            }
            for i in stride(from: 0, to: size * size * 4, by: 4) {
                if Int(body[i]) + Int(body[i+1]) + Int(body[i+2]) > 24 { lit1 += 1 }
                if Int(bare[i]) + Int(bare[i+1]) + Int(bare[i+2]) > 24 { lit0 += 1 }
                if isGrey(body, i) { grey1 += 1 }
                if isGrey(bare, i) { grey0 += 1 }
            }
            print("SHELL-REAL \(label): lit with body \(lit1) · without \(lit0) · GREY(body) with body \(grey1) · without \(grey0)")
            r.latticeHidden = true
            r.setBodyAlpha(1)
            let only = try XCTUnwrap(r.renderOffscreen(size: size, stage: false))
            var greyOnly = 0
            for i in stride(from: 0, to: size * size * 4, by: 4) where isGrey(only, i) { greyOnly += 1 }
            print("SHELL-REAL \(label): GREY body-only (lattice hidden) \(greyOnly)")
            r.latticeHidden = false
        }
    }
}

/// ★ THE ORGANIC BAND GRADE (2026-09-18): with a band, the spacing near the outline
/// is graded toward the floor and the scene says how many voxels it touched.
final class OrganicShapeBandTests: XCTestCase {
    func testTheBandGradesSpacingTowardTheFloorNearTheOutline() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let regs = [(15, 12.0), (2, 11.0)].compactMap { f, d in
            LatticeRegionEmission.planeFor(face: FaceID(f), in: mesh).flatMap {
                LatticeRegionEmission.spec(for: $0, role: .include, depthMM: d, faceID: f) }
        }
        try XCTSkipIf(regs.isEmpty)
        let n = 40
        let e = mesh.bounds.max - mesh.bounds.min
        let sp = Double(max(e.x, max(e.y, e.z))) / Double(n)
        var tensor = [Double](repeating: 0, count: 6 * n * n * n)
        for i in 0..<(n * n * n) { tensor[6 * i] = 10; tensor[6 * i + 1] = 3; tensor[6 * i + 2] = 1 }
        func scene(band: Double) -> LatticeSDFScene {
            var input = LatticeOrganicInput(tensor: tensor, dims: (n, n, n), originMM: SIMD3<Double>(mesh.bounds.min),
                                            spacingMM: sp, minExtrudableWidthMM: 0.45, buildDirection: SIMD3(0, 0, 1),
                                            separationMinMM: 4, separationMaxMM: 6, rhoMin: 0.073, rhoMax: 0.9)
            input.shapeBandMM = band
            return LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet", stageMode: .aesthetic,
                                   algorithm: "organic", organic: input, maxDim: 64, regions: regs, whenEmpty: .latticeNothing)
        }
        let off = scene(band: 0), on = scene(band: 8)
        print("BAND off: \(off.organicSummary)")
        print("BAND on:  \(on.organicSummary)")
        XCTAssertFalse(off.organicSummary.contains("shape band"), "no band ⇒ no grade")
        XCTAssertTrue(on.organicSummary.contains("shape band 8.0 mm"), "the band is reported")
        let graded = on.organicSummary.split(separator: " ").enumerated().first { $0.element == "voxels" && $0.offset > 0 }
            .flatMap { Int(on.organicSummary.split(separator: " ")[$0.offset - 1]) } ?? 0
        XCTAssertGreaterThan(graded, 100, "★ the band graded nothing: \(on.organicSummary)")
    }
}
