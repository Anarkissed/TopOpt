// LatticeSectorRenderTests — ★ BATCH E: a split piece's lattice is DRAWN on its own side of the cut,
// by the #354 preview (octet "doubled", stepped and organic), from the SAME emission the run gets.
//
// Measured where the preview measures: the scene's region field (`regionSDF`, which both the march
// and the shell's hole sample) per voxel, and the organic trace's capsules; then real frames from the
// shipping renderer, with the sibling as the flip control (top B latticed must light the OTHER side).
// FLEX_E_EVIDENCE_DIR writes the frames.

import XCTest
import Metal
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class LatticeSectorRenderTests: XCTestCase {

    /// The split pad with ONE piece latticed (`a` ⇒ top A, x ≥ 50; else top B, x < 50).
    private func padRegions(topA: Bool) -> (ProjectModel, [LatticeRegionSpec]) {
        let pad = LatticeSectorOutlineTests.splitPad()
        if !topA {
            pad.p.selection.removeRegions([pad.a])
            pad.p.selection.addRegions([pad.b], to: pad.gid)
            pad.p.force.sync(groups: pad.p.selection.groups)
            pad.p.writeLatticeDepthMM(.region(group: pad.gid, region: pad.b), mm: 25)
        }
        return (pad.p, pad.p.latticeJobRegions().regions)
    }

    private func scene(_ mesh: ViewerMesh, _ regions: [LatticeRegionSpec], algorithm: String,
                       organic: LatticeOrganicInput? = nil) -> LatticeSDFScene {
        LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet", stageMode: .aesthetic, algorithm: algorithm,
                        boundaryFinishWritten: true, organic: organic, maxDim: 64, regions: regions,
                        whenEmpty: .latticeNothing)
    }

    /// Voxels inside the part AND inside the declared region, split by world x at the cut.
    private func latticedVoxels(_ s: LatticeSDFScene) throws -> (left: Int, right: Int) {
        let g = try XCTUnwrap(s.regionSDF, "an include region bakes a region field")
        let occ = s.occupancy
        XCTAssertEqual(g.count, occ.count, "the region field is on the occupancy's own grid")
        var left = 0, right = 0
        for k in 0..<g.nz { for j in 0..<g.ny { for i in 0..<g.nx {
            let n = (k * g.ny + j) * g.nx + i
            guard g.values[n] < 0, occ.values[n] > 0.5 else { continue }
            let x = Double(g.origin.x) + Double(i) * Double(g.spacing.x)
            // one voxel of slack at the cut, where a distance field interpolates
            if x < 50 - Double(g.spacing.x) { left += 1 } else if x > 50 + Double(g.spacing.x) { right += 1 }
        } } }
        return (left, right)
    }

    /// ★ The preview's region field holds top A's side only — and top B's only when B is the one
    /// latticed (the flip control). Octet ("doubled") and stepped bake the same field.
    func testThePreviewsRegionFieldIsOnThePiecesOwnSide() throws {
        let mesh = LatticeSectorOutlineTests.pad()
        for algo in ["doubled", "stepped"] {
            let (_, ra) = padRegions(topA: true)
            let a = try latticedVoxels(scene(mesh, ra, algorithm: algo))
            let (_, rb) = padRegions(topA: false)
            let b = try latticedVoxels(scene(mesh, rb, algorithm: algo))
            print("E-RENDER field \(algo): topA left \(a.left) right \(a.right) · topB left \(b.left) right \(b.right)")
            XCTAssertGreaterThan(a.right, 1000, "\(algo): top A's lattice is baked")
            XCTAssertEqual(a.left, 0, "★ \(algo): nothing past the cut under top B")
            XCTAssertGreaterThan(b.left, 1000, "control (\(algo)): top B latticed fills the OTHER side")
            XCTAssertEqual(b.right, 0, "control (\(algo))")
        }
    }

    /// ★ ORGANIC: the trace stays inside top A's prism (every capsule end at x ≥ 50, less a strut).
    func testTheOrganicTraceStaysOnThePiecesOwnSide() throws {
        let mesh = LatticeSectorOutlineTests.pad()
        let (_, ra) = padRegions(topA: true)
        let n = 48
        let e = mesh.bounds.max - mesh.bounds.min
        let sp = Double(max(e.x, max(e.y, e.z))) / Double(n)
        let dims = (n, Int((Double(e.y) / sp).rounded(.up)) + 1, Int((Double(e.z) / sp).rounded(.up)) + 1)
        var tensor = [Double](repeating: 0, count: 6 * dims.0 * dims.1 * dims.2)
        for i in 0..<(dims.0 * dims.1 * dims.2) { tensor[6 * i] = 10; tensor[6 * i + 1] = 3; tensor[6 * i + 2] = 1 }
        let input = LatticeOrganicInput(tensor: tensor, dims: dims, originMM: SIMD3<Double>(mesh.bounds.min), spacingMM: sp,
                                        minExtrudableWidthMM: 0.45, buildDirection: SIMD3(0, 0, 1),
                                        separationMinMM: 4, separationMaxMM: 8, rhoMin: 0.05, rhoMax: 0.9)
        let s = scene(mesh, ra, algorithm: "organic", organic: input)
        let caps = s.organicCapsules
        print("E-RENDER organic: \(caps.count) capsules, x \(caps.map { min($0.a.x, $0.b.x) }.min() ?? -1)…\(caps.map { max($0.a.x, $0.b.x) }.max() ?? -1) · \(s.organicSummary)")
        XCTAssertGreaterThan(caps.count, 0, "the organic trace drew top A")
        for c in caps {
            XCTAssertGreaterThanOrEqual(Double(min(c.a.x, c.b.x)) + Double(c.r), 50 - sp,
                                        "★ an organic strut past the cut at x = \(min(c.a.x, c.b.x))")
        }
        // the control: the whole top latticed reaches x < 50
        let pad = LatticeSectorOutlineTests.splitPad()
        pad.p.selection.addRegions([pad.b], to: pad.gid)
        pad.p.force.sync(groups: pad.p.selection.groups)
        let whole = scene(mesh, pad.p.latticeJobRegions().regions, algorithm: "organic", organic: input)
        XCTAssertLessThan(Double(whole.organicCapsules.map { min($0.a.x, $0.b.x) }.min() ?? 100), 50 - sp,
                          "control: with top B latticed too, the trace crosses the cut")
    }

    /// ★ REAL FRAMES (the shipping renderer, lattice only, from above): top A's picture and top B's
    /// are mirror images about the cut — the lit columns sit on opposite halves of the frame.
    func testTheFramesLightOnlyThePiecesSide() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no GPU") }
        let mesh = LatticeSectorOutlineTests.pad()
        func frame(_ topA: Bool) throws -> (px: [UInt8], size: Int) {
            let (_, regions) = padRegions(topA: topA)
            guard let r = MeshRenderer(device: device, sampleCount: 4) else { throw XCTSkip("renderer") }
            try XCTSkipUnless(r.latticePipelinesDidBuild)
            r.setMesh(mesh)
            r.showGround = false
            r.camera.frame(mesh.bounds)
            r.camera.setOrientation(azimuth: 0, elevation: 1.45)
            r.setLatticeScene(scene(mesh, regions, algorithm: "doubled"), token: 1)
            r.latticeParams = LatticeProxyParams(latticeID: "octet", cellMM: 8, minRelativeDensity: 0.1, maxRelativeDensity: 0.5)
            r.setBodyAlpha(0)
            let size = 320
            return (try XCTUnwrap(r.renderOffscreen(size: size, stage: false)), size)
        }
        func columns(_ f: (px: [UInt8], size: Int)) -> (lo: Int, hi: Int, centroid: Double) {
            var lo = 0, hi = 0, sx = 0.0, n = 0
            for y in 0..<f.size { for x in 0..<f.size {
                let i = (y * f.size + x) * 4
                guard Int(f.px[i]) + Int(f.px[i + 1]) + Int(f.px[i + 2]) > 24 else { continue }
                if x < f.size / 2 { lo += 1 } else { hi += 1 }
                sx += Double(x); n += 1
            } }
            return (lo, hi, n > 0 ? sx / Double(n) : -1)
        }
        let a = try frame(true), b = try frame(false)
        let ca = columns(a), cb = columns(b)
        print("E-RENDER frames: topA lit lo \(ca.lo) hi \(ca.hi) centroid \(ca.centroid) · topB lit lo \(cb.lo) hi \(cb.hi) centroid \(cb.centroid)")
        if let dir = ProcessInfo.processInfo.environment["FLEX_E_EVIDENCE_DIR"] {
            LatticeQuiltFrameProbe.writePNG(a.px, size: a.size, to: dir + "/E_split_topA_lattice_from_above.png")
            LatticeQuiltFrameProbe.writePNG(b.px, size: b.size, to: dir + "/E_split_topB_lattice_from_above.png")
        }
        XCTAssertGreaterThan(ca.lo + ca.hi, 500, "control: top A's lattice draws")
        XCTAssertGreaterThan(cb.lo + cb.hi, 500, "control: top B's lattice draws")
        // ★ each lights ONE half of the frame (the cut runs through the middle), and they are opposite
        let aRight = ca.hi > ca.lo
        XCTAssertNotEqual(aRight, cb.hi > cb.lo, "★ top A and top B light opposite halves")
        XCTAssertLessThan(Double(min(ca.lo, ca.hi)), 0.05 * Double(ca.lo + ca.hi), "★ top A: nothing on top B's half")
        XCTAssertLessThan(Double(min(cb.lo, cb.hi)), 0.05 * Double(cb.lo + cb.hi), "★ top B: nothing on top A's half")
    }

    /// EVIDENCE ONLY (FLEX_E_EVIDENCE_DIR): his split pad, the #354 octet preview from an oblique
    /// view, the part ghosted — top A alone (his img 4 state, after) and both halves (the seam).
    func testEvidenceFrames() throws {
        guard let dir = ProcessInfo.processInfo.environment["FLEX_E_EVIDENCE_DIR"] else { throw XCTSkip("FLEX_E_EVIDENCE_DIR") }
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no GPU") }
        let mesh = LatticeSectorOutlineTests.pad()
        let whole: [LatticeRegionSpec] = {
            let pad = LatticeSectorOutlineTests.splitPad()
            pad.p.selection.addRegions([pad.b], to: pad.gid)
            pad.p.force.sync(groups: pad.p.selection.groups)
            pad.p.writeLatticeDepthMM(.region(group: pad.gid, region: pad.b), mm: 25)
            return pad.p.latticeJobRegions().regions
        }()
        for (name, regions) in [("topA", padRegions(topA: true).1), ("topA_and_topB", whole)] {
            for (view, az, el) in [("iso", Float(0.7), Float(0.55)), ("above", Float(0), Float(1.45))] {
                guard let r = MeshRenderer(device: device, sampleCount: 4) else { throw XCTSkip("renderer") }
                try XCTSkipUnless(r.latticePipelinesDidBuild)
                r.setMesh(mesh)
                r.showGround = false
                r.camera.frame(mesh.bounds)
                r.camera.setOrientation(azimuth: az, elevation: el)
                r.setLatticeScene(scene(mesh, regions, algorithm: "doubled"), token: 1)
                r.latticeParams = LatticeProxyParams(latticeID: "octet", cellMM: 8, minRelativeDensity: 0.1, maxRelativeDensity: 0.5)
                r.setBodyAlpha(0.25)
                let px = try XCTUnwrap(r.renderOffscreen(size: 640, stage: false))
                LatticeQuiltFrameProbe.writePNG(px, size: 640, to: dir + "/E_split_pad_\(name)_\(view).png")
            }
        }
    }
}
