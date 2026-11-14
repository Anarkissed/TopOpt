// FlexibleR7U21EdgeLookTests — round 7 · U21 batch H, EDGE-LOOK (his notes of 2026-10-21, Img3 = 13.png: "Edges/corners
// don't look great"). On HIS live pad of 2026-10-21 (round7/batch_u21/his_live_1021_pad: Group 2 = Edge 12 + Edge 9, flat
// prisms 9.5 and 8.0 mm), restored the app's way, lattice built.
// What was wrong: each press's column is cut at its flat prism's plane by VOXEL CENTRE, so ρ jumps from the press's design
// (up to 0.32) to the face lattice's 0.14 across one 1.04 mm voxel, and the gyroid ladder ran through up to 4.66 rungs inside
// it — a shredded 1–1.5 mm band along the plane (the probe: 0.215 fragments/mm against 0.005 away from it).
// The fix (FlexibleGroupField.pressSeam + FlexibleLatticeField.seamSheet, MSL twin flx_wall_seam): each side keeps its own
// gyroid from its own same-side interpolation, and the two meet at the plane's true position (sub-voxel), with the whole
// gradient. Each RED control is asserted red inside its test:
//   testThePressCliffDrawsNoFragments      band fragment rate ≤ 1.5 × the control's; RED (the ladder across the cliff) ≥ 5 ×
//   testTheJunctionKeepsTheGradientBounded |∇G|/k p99 in the band ≤ 2.5; RED max ≥ 10
//   testSmoothDensityIsUntouched           every point in a cell with no seam (incl. the cliffs away from the presses)
//                                          bit-identical; ρ and the mask unchanged; RED (a 40-voxel band) differs
//   testEvidenceRenders                    (not a gate) front-left-close s 0 / s 0.5, only with EDGE_LOOK_DIR set
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleR7U21EdgeLookTests: XCTestCase {
    static var padDir: URL {
        FlexibleHisProject.repoRoot.appendingPathComponent(
            "docs/handoffs/evidence/2026-09-29-flexible-screens/round7/batch_u21/his_live_1021_pad", isDirectory: true)
    }

    struct Built {
        let inputs: FlexibleLatticeInputs
        let field: FlexDensityField
        let cuts: [(String, FlexibleFlatPrism.Cut)]
        let pressCuts: [Int: FlexibleFlatPrism.Cut]
        let lines: [(SIMD3<Float>, SIMD3<Float>)]
    }
    static var built: Built?

    override func tearDown() {
        FlexibleLatticeField.controlLadderAcrossCliffs = false
        FlexibleGroupField.controlSeamBandVoxels = nil
        FlexibleBackend.sendsPresses = true
        super.tearDown()
    }

    /// His pad restored as saved, its lattice built through the page (once per run).
    func pad() async throws -> Built {
        if let b = Self.built { return b }
        FlexibleBackend.sendsPresses = true
        let r = try FlexibleHisProject.restore(Self.padDir, asSaved: true)
        defer { r.cleanup() }
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        m.keepCombinedField = true
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his pad of 10-21")
        let strips = m.presses.filter { $0.strip != nil }
        try await FlexibleHisProject.waitFor(300, "core's verdict on his presses") {
            strips.allSatisfy { m.pressSupport[$0.id].map { $0.inJob || $0.reason != .designing } ?? false }
        }
        s.didExitSettings()
        s.apply(r.project, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(400, "the lattice") { m.lattice != nil && !m.latticeBuilding && !m.latticeIsStale }
        let f = try XCTUnwrap(m.lattice?.inputs)
        let field = try XCTUnwrap(m.lastCombinedField)
        await m.waitForIdle()
        let cuts: [(String, FlexibleFlatPrism.Cut)] = strips.compactMap { p in FlexibleFlatPrism.cut(of: p).map { (p.strip?.label ?? "?", $0) } }
        var pressCuts: [Int: FlexibleFlatPrism.Cut] = [:]
        for p in strips {
            guard let c = FlexibleFlatPrism.cut(of: p) else { continue }
            if let k = m.pressRegistrations[p.id]?.key { pressCuts[k] = c }
            if let first = p.regions.first { pressCuts[first] = c }
        }
        XCTAssertEqual(cuts.count, 2, "his Group 2: Edge 12 and Edge 9")
        // the lines along each cut's arrow through its plane (the probe's): every third mask voxel within 0.6 voxel of a
        // plane, 2 mm inside the part, at most ~600
        let g = f.rho, mk = f.mask, h = g.spacing
        var lines: [(SIMD3<Float>, SIMD3<Float>)] = []
        var n = 0
        for k in 0..<g.nz { for j in 0..<g.ny { for i in 0..<g.nx where mk.at(i, j, k) >= 0.5 {
            let p = g.c0 + SIMD3<Float>(Float(i), Float(j), Float(k)) * h
            for (_, c) in cuts where abs(c.height(SIMD3<Double>(p)) - c.depthMM) < 0.6 * Double(h) {
                n += 1
                guard n % 3 == 0, FlexibleLatticeField.dPart(p, f) < -2 else { continue }
                lines.append((SIMD3<Float>(c.onPlane(SIMD3<Double>(p))), SIMD3<Float>(simd_normalize(c.direction))))
            }
        } } }
        if lines.count > 600 { let st = lines.count / 600 + 1; lines = stride(from: 0, to: lines.count, by: st).map { lines[$0] } }
        let b = Built(inputs: f, field: field, cuts: cuts, pressCuts: pressCuts, lines: lines)
        Self.built = b
        return b
    }

    struct Tally { var bandThin = 0, bandRuns = 0, ctlThin = 0, ctlRuns = 0; var bandMM: Float = 0, ctlMM: Float = 0
        var band: Float { Float(bandThin) / Swift.max(bandMM, 1e-3) }
        var control: Float { Float(ctlThin) / Swift.max(ctlMM, 1e-3) }
        var line: String { String(format: "band %d of %d runs over %.1f mm = %.4f /mm; control %d of %d over %.1f mm = %.4f /mm",
                                  bandThin, bandRuns, bandMM, band, ctlThin, ctlRuns, ctlMM, control) }
    }
    /// Solid runs of the walls along each line (tau −3…3 mm, 5 µm steps): a run thinner than t/2 that ends inside the part
    /// is a FRAGMENT. Band = |tau| ≤ 1.5 mm (the plane), control = the rest.
    static func tally(_ f: FlexibleLatticeInputs, _ lines: [(SIMD3<Float>, SIMD3<Float>)]) -> Tally {
        var t = Tally()
        let step: Float = 0.005
        for (o, d) in lines {
            var start: Float? = nil
            var tau: Float = -3
            while tau <= 3 {
                let p = o + d * tau
                let ok = FlexibleLatticeField.dPart(p, f) < -0.5 && f.mask.sample(p) > 0.9
                if ok { if abs(tau) <= 1.5 { t.bandMM += step } else { t.ctlMM += step } }
                let solid = ok && FlexibleLatticeField.wall(p, f) < 0
                if solid { if start == nil { start = tau } } else if let s0 = start {
                    let thin = ok && (tau - s0) < 0.5 * f.wallMM
                    if abs(0.5 * (tau + s0)) <= 1.5 { t.bandRuns += 1; if thin { t.bandThin += 1 } } else { t.ctlRuns += 1; if thin { t.ctlThin += 1 } }
                    start = nil
                }
                tau += step
            }
        }
        return t
    }

    func testThePressCliffDrawsNoFragments() async throws {
        let b = try await pad()
        XCTAssertNotNil(b.inputs.rhoAcross, "the presses' seams reach the lattice inputs")
        XCTAssertNotNil(b.inputs.pressSide)
        XCTAssertGreaterThan(b.lines.count, 100)
        let fixed = Self.tally(b.inputs, b.lines)
        FlexibleLatticeField.controlLadderAcrossCliffs = true
        let old = Self.tally(b.inputs, b.lines)
        FlexibleLatticeField.controlLadderAcrossCliffs = false
        print("EDGE-LOOK fragments over \(b.lines.count) lines: SEAM \(fixed.line) · RED CONTROL (the ladder across the cliff) \(old.line)")
        XCTAssertLessThanOrEqual(fixed.band, 1.5 * Swift.max(fixed.control, old.control),
                                 "the band along the plane shreds: \(fixed.line)")
        XCTAssertGreaterThanOrEqual(old.band, 5 * old.control, "★ RED CONTROL: today's ladder across the cliff must shred the band")
    }

    static func gradients(_ f: FlexibleLatticeInputs, _ lines: [(SIMD3<Float>, SIMD3<Float>)]) -> (band: [Float], control: [Float]) {
        var gb: [Float] = [], gc: [Float] = []
        for (o, d) in lines {
            var tau: Float = -3
            while tau <= 3 {
                let p = o + d * tau
                if FlexibleLatticeField.dPart(p, f) < -0.5, f.mask.sample(p) > 0.9 {
                    let s = FlexibleLatticeField.sheet(p, f)
                    let v = simd_length(s.grad) / Swift.max(s.k, 1e-6)
                    if abs(tau) <= 1.5 { gb.append(v) } else { gc.append(v) }
                }
                tau += 0.05
            }
        }
        return (gb, gc)
    }
    static func pct(_ a: [Float], _ q: Double) -> Float {
        guard !a.isEmpty else { return -1 }
        let s = a.sorted(); return s[Swift.min(s.count - 1, Int(Double(s.count - 1) * q))]
    }

    func testTheJunctionKeepsTheGradientBounded() async throws {
        let b = try await pad()
        XCTAssertNotNil(b.inputs.rhoAcross)
        let fixed = Self.gradients(b.inputs, b.lines)
        FlexibleLatticeField.controlLadderAcrossCliffs = true
        let old = Self.gradients(b.inputs, b.lines)
        FlexibleLatticeField.controlLadderAcrossCliffs = false
        print(String(format: "EDGE-LOOK |grad G|/k: SEAM band p50 %.3f p99 %.3f max %.3f, control p99 %.3f · RED CONTROL band p99 %.3f max %.3f, control p99 %.3f",
                     Self.pct(fixed.band, 0.5), Self.pct(fixed.band, 0.99), fixed.band.max() ?? -1, Self.pct(fixed.control, 0.99),
                     Self.pct(old.band, 0.99), old.band.max() ?? -1, Self.pct(old.control, 0.99)))
        XCTAssertGreaterThan(fixed.band.count, 1000)
        XCTAssertLessThanOrEqual(Self.pct(fixed.band, 0.99), 2.5, "the junction's gradient")
        XCTAssertGreaterThanOrEqual(old.band.max() ?? 0, 10, "★ RED CONTROL: the ladder across the cliff")
    }

    /// Whether the cell holding p has a seam corner.
    static func seamCell(_ f: FlexibleLatticeInputs, _ p: SIMD3<Float>) -> Bool {
        guard let ac = f.rhoAcross else { return false }
        let g = f.rho, u = (p - g.c0) / g.spacing
        let i0 = Swift.min(Swift.max(Int(Swift.max(u.x, 0)), 0), g.nx - 2), j0 = Swift.min(Swift.max(Int(Swift.max(u.y, 0)), 0), g.ny - 2)
        let k0 = Swift.min(Swift.max(Int(Swift.max(u.z, 0)), 0), g.nz - 2)
        for dk in 0...1 { for dj in 0...1 { for di in 0...1 where ac.at(i0 + di, j0 + dj, k0 + dk) != g.at(i0 + di, j0 + dj, k0 + dk) { return true } } }
        return false
    }

    func testSmoothDensityIsUntouched() async throws {
        let b = try await pad()
        let f = b.inputs
        XCTAssertNotNil(f.rhoAcross)
        var plain = f
        plain.rhoAcross = nil; plain.pressSide = nil
        // ρ (the colours) is never changed by the seam: the builder's filled ρ, as before
        XCTAssertNil(FlexibleGroupField.pressSeam(rho: f.rho.values, owner: b.field.owner, nx: f.rho.nx, ny: f.rho.ny, nz: f.rho.nz,
                                                  origin: b.field.origin, spacing: b.field.spacing, cuts: [:]), "no presses, no seam")
        // 2,000 random points in mask cells with no seam corner, and the cliffs (> 1 rung) away from the presses
        var seed: UInt64 = 0x2545F4914F6CDD1D
        func next() -> Float { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return Float(seed % 1_000_000) / 1_000_000 }
        let lo = f.rho.c0, hi = f.rho.c0 + SIMD3<Float>(Float(f.rho.nx - 1), Float(f.rho.ny - 1), Float(f.rho.nz - 1)) * f.rho.spacing
        var pts: [SIMD3<Float>] = []
        var tries = 0
        while pts.count < 2000 && tries < 200_000 {
            tries += 1
            let p = lo + SIMD3<Float>(next(), next(), next()) * (hi - lo)
            guard f.mask.sample(p) > 0.5, !Self.seamCell(f, p) else { continue }
            pts.append(p)
        }
        var cliffs: [SIMD3<Float>] = []
        let g = f.rho
        for k in 0..<g.nz { for j in 0..<g.ny { for i in 0..<g.nx where f.mask.at(i, j, k) >= 0.5 {
            for (di, dj, dk) in [(1, 0, 0), (0, 1, 0), (0, 0, 1)] {
                let a = i + di, bb = j + dj, c = k + dk
                guard a < g.nx, bb < g.ny, c < g.nz, f.mask.at(a, bb, c) >= 0.5 else { continue }
                let v = g.at(i, j, k), w = g.at(a, bb, c)
                guard v > 0, w > 0, 4 * abs(log2(w / v)) > 1 else { continue }
                let mid = g.c0 + (SIMD3<Float>(Float(i), Float(j), Float(k)) + 0.5 * SIMD3<Float>(Float(di), Float(dj), Float(dk))) * g.spacing
                if !Self.seamCell(f, mid) { cliffs.append(mid) }
            }
        } } }
        let all = pts + cliffs
        let differ = all.filter { FlexibleLatticeField.wall($0, f).bitPattern != FlexibleLatticeField.wall($0, plain).bitPattern }.count
        // ★ RED CONTROL: a seam band 40 voxels wide reaches these cells and must change them
        FlexibleGroupField.controlSeamBandVoxels = 40
        let wide = try XCTUnwrap(FlexibleGroupField.pressSeam(rho: f.rho.values, owner: b.field.owner, nx: g.nx, ny: g.ny, nz: g.nz,
                                                              origin: b.field.origin, spacing: b.field.spacing, cuts: b.pressCuts))
        FlexibleGroupField.controlSeamBandVoxels = nil
        var w = f
        w.rhoAcross = FlexGrid(nx: g.nx, ny: g.ny, nz: g.nz, c0: g.c0, spacing: g.spacing, values: wide.across)
        w.pressSide = FlexGrid(nx: g.nx, ny: g.ny, nz: g.nz, c0: g.c0, spacing: g.spacing, values: wide.side)
        let differWide = all.filter { FlexibleLatticeField.wall($0, w).bitPattern != FlexibleLatticeField.wall($0, plain).bitPattern }.count
        let seamVoxels = zip(f.rhoAcross!.values, g.values).filter { $0 != $1 }.count
        print("EDGE-LOOK untouched: \(pts.count) random points + \(cliffs.count) cliffs (> 1 rung) away from the presses, \(differ) differ; seam voxels \(seamVoxels); RED CONTROL (40-voxel band) \(differWide) differ")
        XCTAssertEqual(pts.count, 2000)
        XCTAssertEqual(differ, 0, "a cell with no seam must draw exactly as before")
        XCTAssertGreaterThan(differWide, 10, "★ RED CONTROL: a seam spilling past its band must show")
    }

    // MARK: evidence (not a gate)

    func write(_ mr: MeshRenderer, _ url: URL) throws {
        let n = 1400
        let bg = DS.Color.background
        guard var px = mr.renderOffscreen(size: n, clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)) else { XCTFail("renderOffscreen nil"); return }
        for k in stride(from: 0, to: px.count, by: 4) { px.swapAt(k, k + 2); px[k + 3] = 255 }
        let ctx = try XCTUnwrap(CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    /// His pad on the shipping renderer (the page's own layer, Group 2's sim bound, held at s): front-left-close at s 0 and
    /// s 0.5, beside his 13.png. Only with EDGE_LOOK_DIR set.
    func testEvidenceRenders() async throws {
        guard let d = ProcessInfo.processInfo.environment["EDGE_LOOK_DIR"] else { throw XCTSkip("EDGE_LOOK_DIR not set") }
        let dir = URL(fileURLWithPath: d, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FlexibleBackend.sendsPresses = true
        let r = try FlexibleHisProject.restore(Self.padDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his pad of 10-21")
        let strips = m.presses.filter { $0.strip != nil }
        try await FlexibleHisProject.waitFor(300, "core's verdict on his presses") {
            strips.allSatisfy { m.pressSupport[$0.id].map { $0.inJob || $0.reason != .designing } ?? false }
        }
        s.didExitSettings()
        s.apply(r.project, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(400, "the lattice") { m.lattice != nil && !m.latticeBuilding && !m.latticeIsStale }
        let grp = try XCTUnwrap(m.squeezeGroups.first { $0.kind == .edges }, "his edges group")
        let id = FlexibleSim.groupID(grp.number)
        try await FlexibleSquishFixture.solve(m, first: id, "his pad (edges)")
        m.startSquishSims(first: id)
        try await FlexibleHisProject.waitFor(400, "Group 2's sim") { m.squish[id] != nil && m.squish[id] != .pending }
        await m.squishSolver.waitForIdle()
        s.heat = false
        s.refresh()
        try await FlexibleHisProject.waitFor(120, "the page hands Group 2's field") {
            s.layer(r.project, stage: .lattice, pageUp: false)?.fe.contains { $0.simID == id } == true
        }
        let L = try XCTUnwrap(s.layer(r.project, stage: .lattice, pageUp: false))
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let settle = r.project.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let cam = FlexibleRound6Tests.Cam(name: "front-left-close", azimuth: -.pi / 4, elevation: 0.5, zoom: 0.55)
        for sq: Float in [0, 0.5] {
            let mr = try FlexibleRound6EvidenceProbe().renderer(mesh: try XCTUnwrap(s.mesh(r.project, on: .lattice)), tints: s.tints(r.project, on: .lattice, roles: [:], stress: nil), dents: s.dents(r.project, on: .lattice), scale: 0, bodyAlpha: s.bodyAlpha(r.project, on: .lattice) ?? 1, settle: settle, cam: cam, device: device, items: [], layer: L)
            if let fx = mr.flexibleLattice {
                fx.loop = nil
                if let i = fx.feFields.firstIndex(where: { $0.simID == id }) { fx.bindFE(i); if i < fx.feMesh.count { mr.setFlexDisplacements(fx.feMesh[i]) } }
            }
            mr.setFlexScale(sq)
            try write(mr, dir.appendingPathComponent("EDGE_after_front-left-close_s\(Int(sq * 100)).png"))
        }
    }
}
#endif
