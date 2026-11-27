// FlexibleManualT2Tests — round 7 · T2: THE TWO DRAWING LEFTOVERS of the Manual P2 checks (2026-10-23).
//   (a) honeycomb walls cut where the lattice ends hung there as SLIVERS (his pad's lower right): the region's and the part's
//       clips cut each wall at the point, so a wall crossing a clip obliquely ended in a knife-edge wedge and a wall running beside
//       it was shaved thin. Fix (FlexibleLatticeField.squareClip, MSL flx_square_clip): a wall's cross-section is kept only where
//       BOTH its faces are inside — every cut wall ends square and whole, never past the old clip; per wall family through the
//       point (at a junction a whole wall keeps the junction). A uniform honeycomb only: a gyroid is cut as before. Auto showed
//       the same slivers (his pad's Auto honeycomb, measured here), and the fix is drawing only, so it holds in both modes.
//   (b) Stepped grade BAND SEAMS used the gyroid sheet blend (two cells 3 × apart blended → 5.5 × the fragments of the lattice
//       away): an edge with a Stepped band on either side now gets the SEAM WALL the type seams use, and a piece of one density
//       reads that density where a corner carries a THIRD piece's ρ (FlexibleLatticeField.manualPieceWall's `side`) — the leak
//       that shredded the voxels where a band edge meets the group's own edge.
// On HIS live pad of 2026-10-21 (restored the app's way, lattice built through the page). Each RED control is asserted red inside
// its test:
//   testTheClipEndsEveryHoneycombWallSquare      sliver share at the clip ≤ 1.5 × the lattice away, Manual AND Auto honeycomb;
//                                                RED: the clip at the point (today's) shreds both
//   testAStepBandEdgeIsACleanLine                band|band fragments ≤ 1.5 × the lattice away on the same lines; RED: the sheet blend
//   testTheGPUSquaresTheClipAndTheBandWallAsSwift parity ≤ 5e-3 mm at 300 clip points + 300 band-seam points, Manual and Auto;
//                                                RED: the old clip / blend misses
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleManualT2Tests: XCTestCase {
    typealias P2 = FlexibleManualP2Tests
    typealias F = FlexibleLatticeField
    typealias Fx = FlexibleLatticeFixtures

    override func tearDown() {
        F.controlClipAtThePoint = false
        F.controlBandSheetBlend = false
        super.tearDown()
    }

    func opened(_ what: String) async throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore(FlexibleU21DeleteUndoTests.padDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let m = try await FlexibleHisProject.openedModel(r.project, test: self)
        try await FlexibleSquishFixture.settle(m, what)
        m.keepCombinedField = true
        m.setManual(true)
        m.setManualType("gyroid", group: nil)
        m.setManualBeads(1, group: nil)
        m.setManualDensity(0.20, group: nil)
        return (r, m)
    }
    func rebuild(_ m: FlexibleStageModel, _ what: String) async throws -> FlexibleLatticeInputs {
        m.discardLattice()
        return try await FlexibleSquishFixture.build(m, what).inputs
    }

    // MARK: the sliver tally at the clip

    /// Is the region's edge (mask < ½) within `radius` mm of p? (26 directions, ¼ mm steps: dRegion itself saturates at one
    /// mask voxel, so it is no distance.)
    static func regionWithin(_ p: SIMD3<Float>, _ f: FlexibleLatticeInputs, _ radius: Float) -> Bool {
        if f.mask.sample(p) < 0.5 { return true }
        var r: Float = 0.25
        while r <= radius + 1e-4 {
            for dz in -1...1 { for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 || dz != 0 {
                let d = simd_normalize(SIMD3<Float>(Float(dx), Float(dy), Float(dz)))
                if f.mask.sample(p + d * r) < 0.5 { return true }
            } } }
            r += 0.25
        }
        return false
    }
    /// Where p sits against the clips: near (the part's surface or the region's edge within 1.5 mm — which: 0 region, 1 part,
    /// 2 skin), away (both 3 mm off and outside the skin), or neither (nil).
    static func clip(_ p: SIMD3<Float>, _ f: FlexibleLatticeInputs) -> (near: Bool, which: Int)? {
        let pa = F.dPart(p, f), sk = F.dSkin(p, f)
        if sk >= -1.5 { return (true, 2) }
        if pa >= -1.5 { return (true, 1) }
        if regionWithin(p, f, 1.5) { return (true, 0) }
        if pa < -3, sk < -3, !regionWithin(p, f, 3) { return (false, -1) }
        return nil
    }
    /// The wall's local THICKNESS at a drawn solid point p: the chord of the drawn solid along the wall's own normal (∇wall)
    /// through p. A whole wall reads t wherever it is cut square; a knife-edge wedge or a shaved wall reads less. (A chord along
    /// a fixed line would also count every square corner a line grazes — a fragment that is no sliver.)
    static func thickness(_ p: SIMD3<Float>, _ f: FlexibleLatticeInputs) -> Float? {
        let h: Float = 0.02
        let g = SIMD3<Float>(F.wall(p + SIMD3(h, 0, 0), f) - F.wall(p - SIMD3(h, 0, 0), f),
                             F.wall(p + SIMD3(0, h, 0), f) - F.wall(p - SIMD3(0, h, 0), f),
                             F.wall(p + SIMD3(0, 0, h), f) - F.wall(p - SIMD3(0, 0, h), f)) / (2 * h)
        guard simd_length(g) > 0.3 else { return nil }   // a junction's kink: no one normal
        let n = simd_normalize(g)
        func solid(_ q: SIMD3<Float>) -> Bool { F.lattice(at: q, f) < 0 }
        guard solid(p) else { return nil }
        let st: Float = 0.01
        var a: Float = 0, b: Float = 0
        while a < 3 && solid(p + n * (a + st)) { a += st }
        while b < 3 && solid(p - n * (b + st)) { b += st }
        return a + b
    }
    struct Slivers {
        var band = 0, bandThin = 0, ctl = 0, ctlThin = 0
        var thinBy = [0, 0, 0], bandBy = [0, 0, 0]
        var `where`: [String] = []
        var bandShare: Float { Float(bandThin) / Float(Swift.max(band, 1)) }
        /// The lattice away from the clip; never under one sample's worth (a share of 0 out of N is "under 1 in N").
        var ctlShare: Float { Swift.max(Float(ctlThin), 1) / Float(Swift.max(ctl, 1)) }
        var line: String {
            String(format: "clip band %d thin of %d solid samples = %.4f; away %d of %d = %.4f (floor 1/N %.4f); thin by term region/part/skin %d/%d/%d of %d/%d/%d",
                   bandThin, band, bandShare, ctlThin, ctl, Float(ctlThin) / Float(Swift.max(ctl, 1)), ctlShare,
                   thinBy[0], thinBy[1], thinBy[2], bandBy[0], bandBy[1], bandBy[2])
        }
    }
    /// Drawn solid points near the clip (within 1.5 mm) and away from it (3 mm off), among `pts` whose wall `t` is known:
    /// thin = a local thickness under ½ t.
    static func slivers(_ f: FlexibleLatticeInputs, _ pts: [SIMD3<Float>], t: (SIMD3<Float>) -> Float?, cap: Int = 1500) -> Slivers {
        var s = Slivers()
        for p in pts {
            if s.band >= cap && s.ctl >= cap { break }
            guard F.lattice(at: p, f) < 0, let tw = t(p) else { continue }
            guard let c = clip(p, f) else { continue }
            let near = c.near
            if near ? s.band >= cap : s.ctl >= cap { continue }
            guard let th = thickness(p, f) else { continue }
            let thin = th < 0.5 * tw
            if near && thin && s.where.count < 12 {
                s.where.append(String(format: "(%.2f, %.2f, %.2f) term %d wall %.3f thick %.3f dPart %.3f dRegion %.3f", p.x, p.y, p.z, c.which,
                                      F.wall(p, f), th, F.dPart(p, f), F.dRegion(p, f)))
            }
            if near { s.band += 1; s.bandBy[c.which] += 1; if thin { s.bandThin += 1; s.thinBy[c.which] += 1 } }
            else { s.ctl += 1; if thin { s.ctlThin += 1 } }
        }
        return s
    }
    /// Jittered points through the voxels (deterministic): `per` per voxel.
    static func jittered(_ f: FlexibleLatticeInputs, _ vox: [Int], per: Int, seed: UInt64 = 0x7A2C11D3) -> [SIMD3<Float>] {
        var s = seed
        func next() -> Float { s = s &* 6364136223846793005 &+ 1442695040888963407; return Float(s >> 40) / Float(1 << 24) }
        var out: [SIMD3<Float>] = []
        for v in vox { for _ in 0..<per { out.append(P2.centre(f, v) + (SIMD3(next(), next(), next()) - 0.5) * f.rho.spacing) } }
        // spread, not voxel by voxel
        var g = seed ^ 0x55
        for i in stride(from: out.count - 1, to: 0, by: -1) {
            g = g &* 6364136223846793005 &+ 1442695040888963407
            out.swapAt(i, Int(g >> 33) % (i + 1))
        }
        return out
    }

    // MARK: (a) — the clip ends every honeycomb wall square, Manual and Auto

    func testTheClipEndsEveryHoneycombWallSquare() async throws {
        let (r, m) = try await opened("his pad · T2 clip")
        let bw = Float(r.project.printParams.strutLineWidthMM)
        let g = try XCTUnwrap(m.squeezeGroups.first { $0.kind == .faces })
        m.setGroupOwnLattice(g.id, own: true)
        m.setManualType("honeycomb", group: g.id)
        m.setManualBeads(2, group: g.id)
        m.setManualDensity(0.25, group: g.id)
        let f = try await rebuild(m, "his pad · T2 clip · Manual honeycomb")
        // the group's voxels to the part's surface (the clip included), the points inside its honeycomb (no seam cell)
        let field = try XCTUnwrap(m.lastCombinedField)
        let mine = Set(m.manualOwnerGroups().filter { $0.value == g.id }.map(\.key))
        let vox = field.density.indices.filter {
            field.density[$0] >= 0 && $0 < field.owner.count && mine.contains(field.owner[$0])
        }
        XCTAssertGreaterThan(vox.count, 50)
        let pts = Self.jittered(f, vox, per: 24)
        let honey: (SIMD3<Float>) -> Float? = { p in
            guard let mp = F.manualPoint(p, f), !mp.seam, mp.type == 1 else { return nil }
            return mp.t
        }
        let fixed = Self.slivers(f, pts, t: honey)
        F.controlClipAtThePoint = true
        let old = Self.slivers(f, pts, t: honey)
        F.controlClipAtThePoint = false
        print("FLEX-T2 MANUAL honeycomb 2 beads (\(2 * bw) mm), \(vox.count) group voxels, grid \(f.rho.spacing) mm: T2 \(fixed.line) · RED CONTROL (clip at the point) \(old.line)")
        print("FLEX-T2 MANUAL thin at the clip: " + fixed.where.joined(separator: " | "))
        XCTAssertGreaterThan(fixed.band, 300, "solid samples at the clip"); XCTAssertGreaterThan(fixed.ctl, 300, "solid samples away")
        XCTAssertLessThanOrEqual(fixed.bandShare, 1.5 * fixed.ctlShare, "★ Manual: slivers hang at the clip: \(fixed.line)")
        XCTAssertGreaterThan(old.bandShare, 3 * old.ctlShare, "★ RED CONTROL: the clip at the point must leave slivers (today's)")

        // ★ AUTO honeycomb on the same pad (his Auto, the type set): the same clip, the same slivers — and the same fix
        m.setManual(false)
        m.edit { $0.topology = "honeycomb" }
        await m.waitForIdle()
        let a = try await rebuild(m, "his pad · T2 clip · Auto honeycomb")
        XCTAssertEqual(a.topology, .honeycomb, "Auto drew honeycomb")
        XCTAssertNil(a.manualWall, "Auto's field (no manual grids)")
        let aPts = pts.filter { a.mask.sample($0) > 0.01 }
        let autoT: (SIMD3<Float>) -> Float? = { _ in a.wallMM }
        let aFixed = Self.slivers(a, aPts, t: autoT)
        F.controlClipAtThePoint = true
        let aOld = Self.slivers(a, aPts, t: autoT)
        F.controlClipAtThePoint = false
        print("FLEX-T2 AUTO honeycomb (wall \(a.wallMM) mm, cell \(a.honeycombCellMM) mm): T2 \(aFixed.line) · RED CONTROL (clip at the point) \(aOld.line)")
        XCTAssertGreaterThan(aFixed.band, 300); XCTAssertGreaterThan(aFixed.ctl, 300)
        XCTAssertLessThanOrEqual(aFixed.bandShare, 1.5 * aFixed.ctlShare, "★ Auto: slivers hang at the clip: \(aFixed.line)")
        XCTAssertGreaterThan(aOld.bandShare, 3 * aOld.ctlShare, "★ RED CONTROL (Auto): the clip at the point leaves the same slivers")
    }

    // MARK: (b) — a Stepped band edge is a clean line

    func testAStepBandEdgeIsACleanLine() async throws {
        let (_, m) = try await opened("his pad · T2 stepped")
        let g = try XCTUnwrap(m.squeezeGroups.first { $0.kind == .faces })
        m.setGroupOwnLattice(g.id, own: true)
        m.setManualType("gyroid", group: g.id)
        m.setManualBeads(1, group: g.id)
        m.setManualDensity(0.10, group: g.id)
        m.setManualGrade(on: true, group: g.id)
        m.setManualGradeBy("density", group: g.id)
        m.setManualGradeValue(end: true, 0.30, group: g.id)
        m.setManualGradeAlong("depth", group: g.id)
        m.setManualStepped(true, group: g.id)
        let st = try await rebuild(m, "his pad · T2 stepped")
        let pc = try XCTUnwrap(st.manualPiece)
        // the group's pieces (its bands): the codes on its voxels
        let field = try XCTUnwrap(m.lastCombinedField)
        let mine = Set(m.manualOwnerGroups().filter { $0.value == g.id }.map(\.key))
        var bandCodes = Set<Float>()
        for v in field.density.indices where field.density[v] >= 0 && v < field.owner.count && mine.contains(field.owner[v]) && st.mask.values[v] >= 0.5 {
            bandCodes.insert(pc.values[v])
        }
        XCTAssertGreaterThanOrEqual(bandCodes.count, 2, "two bands or more: \(bandCodes.sorted())")
        XCTAssertTrue(bandCodes.allSatisfy { F.pieceBits($0).stepped }, "★ every band carries the Stepped bit: \(bandCodes.sorted())")
        let bands = P2.seamLines(st) { a, c in bandCodes.contains(a) && bandCodes.contains(c) }
        let edges = P2.seamLines(st) { a, c in bandCodes.contains(a) != bandCodes.contains(c) }
        XCTAssertGreaterThan(bands.count, 100, "lines across the band edges")
        let fixed = P2.tally(st, bands)
        F.controlBandSheetBlend = true
        let old = P2.tally(st, bands)
        F.controlBandSheetBlend = false
        let edge = P2.tally(st, edges)
        print("FLEX-T2 STEPPED BAND EDGES (\(bandCodes.count) bands) over \(bands.count) lines: T2 \(fixed.line) · RED CONTROL (sheet blend) \(old.line) · the Stepped group's own edge (\(edges.count) lines, a seam wall too) \(edge.line)")
        XCTAssertLessThanOrEqual(fixed.band, 1.5 * fixed.control, "★ a band edge shreds: \(fixed.line)")
        XCTAssertGreaterThan(old.band, 1.5 * old.control, "★ RED CONTROL: the sheet blend across a band edge shreds (today's)")
        // the bands still draw their own cells and step hard (P2's test pins the counts; here: one band's cell off the seams)
        let samples = P2.jitterless(st, field.density.indices.filter { st.mask.values[$0] >= 0.5 && bandCodes.contains(pc.values[$0]) })
        let cells = Set(samples.compactMap { F.manualPoint($0, st) }.filter { !$0.seam }.map { ($0.cell * 100).rounded() })
        XCTAssertEqual(cells.count, bandCodes.count, "★ off the seams each band draws its one cell: \(cells.sorted())")
    }

    // MARK: the GPU draws the square clip and the band wall exactly as the Swift field

    func testTheGPUSquaresTheClipAndTheBandWallAsSwift() throws {
        // a box whose lattice region is cut OBLIQUELY (x + ½y < 34, voxel by voxel as core's mask is), Manual: a honeycomb 2-bead
        // piece beside two Stepped gyroid bands; then Auto honeycomb on the same cut
        var f = Fx.boxInputs(.honeycomb)
        let g = f.rho
        var mask = g.values, w = g.values, t = g.values, rho = g.values, code = g.values
        for k in 0..<g.nz { for j in 0..<g.ny { for i in 0..<g.nx {
            let v = (k * g.ny + j) * g.nx + i
            let p = g.c0 + SIMD3<Float>(Float(i), Float(j), Float(k)) * g.spacing
            mask[v] = p.x + 0.5 * p.y < 34 ? 1 : 0
            if p.y >= 20 { w[v] = 0.9; t[v] = 1; rho[v] = 0.25; code[v] = 1 }                                   // honeycomb 2 beads
            else { w[v] = 0.45; t[v] = 0; rho[v] = p.z < 10 ? 0.15 : 0.3; code[v] = p.z < 10 ? 4 + 8 : 4 + 16 }  // two Stepped bands
        } } }
        func grid(_ a: [Float]) -> FlexGrid { FlexGrid(nx: g.nx, ny: g.ny, nz: g.nz, c0: g.c0, spacing: g.spacing, values: a) }
        f.mask = grid(mask)
        var auto = f
        auto.wallMM = 0.9; auto.honeycombCellMM = 7.2
        let x = FlexibleLatticeBuilder.manualAcross(rho: rho, code: code, nx: g.nx, ny: g.ny, nz: g.nz)
        f.rho = grid(rho)
        f.wallMM = 0.45; f.lMinMM = 3.0915 * 0.45 / 0.9; f.lMaxMM = 3.0915 * 0.9 / 0.05
        f.manualWall = grid(w); f.manualType = grid(t); f.manualPiece = grid(code)
        f.manualAcross = grid(x.across); f.manualOther = grid(x.other)
        XCTAssertTrue(F.pieceBits(12).stepped && F.pieceBits(20).stepped && !F.pieceBits(1).stepped)

        var seed: UInt64 = 0x7E2C0FF1
        func next() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(seed >> 40) / Float(1 << 24) }
        func check(_ inputs: FlexibleLatticeInputs, _ name: String, token: Int, bandPoints: Bool) throws {
            let pass = try FlexibleLatticePass(device: try Fx.device())
            pass.upload(Fx.layer(inputs, token: token))
            let ref = try XCTUnwrap(pass.referenceInputs)
            // 300 points at the clips (the region's cut, the box's sides) on or near a wall, + 300 in band-seam cells
            var clipPts: [SIMD3<Float>] = [], seamPts: [SIMD3<Float>] = []
            var tries = 0
            while clipPts.count < 300 && tries < 400_000 {
                tries += 1
                let p = SIMD3<Float>(next() * 41 - 0.5, next() * 41 - 0.5, 2 + next() * 16)
                let r = F.dRegion(p, ref), pa = F.dPart(p, ref)
                guard (r > -2.5 && r < 0.5 && pa < -0.5) || (pa > -1.5 && pa < 0.3), F.wall(p, ref) < 0.3 else { continue }
                clipPts.append(p)
            }
            tries = 0
            while bandPoints && seamPts.count < 300 && tries < 400_000 {
                tries += 1
                let p = SIMD3<Float>(next() * 30, next() * 20, next() * 20)
                if let mp = F.manualPoint(p, ref), mp.seam, F.dRegion(p, ref) < -1 { seamPts.append(p) }
            }
            let pts = clipPts + seamPts
            let gpu = try XCTUnwrap(pass.probe(pts))
            var worst: Float = 0, worstSeam: Float = 0
            for (i, p) in pts.enumerated() {
                let d = abs(gpu[i] - F.lattice(at: p, ref))
                if i < clipPts.count { worst = max(worst, d) } else { worstSeam = max(worstSeam, d) }
            }
            // RED: the old clip and blend on the Swift side
            F.controlClipAtThePoint = true; F.controlBandSheetBlend = true
            let miss = pts.indices.map { abs(gpu[$0] - F.lattice(at: pts[$0], ref)) }.max() ?? 0
            F.controlClipAtThePoint = false; F.controlBandSheetBlend = false
            print("FLEX-T2 GPU \(name): max |gpu − swift| at the clip \(worst) mm over \(clipPts.count) points; band seams \(worstSeam) mm over \(seamPts.count); RED CONTROL (old clip/blend vs the GPU) \(miss) mm")
            XCTAssertEqual(clipPts.count, 300, name)
            if bandPoints { XCTAssertEqual(seamPts.count, 300, name) }
            XCTAssertLessThanOrEqual(worst, 5e-3, "★ \(name): the GPU's square clip is the Swift field's")
            XCTAssertLessThanOrEqual(worstSeam, 5e-3, "★ \(name): the GPU's band wall is the Swift field's")
            XCTAssertGreaterThan(miss, 0.05, "RED CONTROL (\(name)): the old clip / blend must miss")
        }
        try check(f, "Manual", token: 61, bandPoints: true)
        try check(auto, "Auto honeycomb", token: 62, bandPoints: false)
    }
}

extension FlexibleManualP2Tests {
    /// The voxels' centres nudged off the grid nodes (P2's jitter), one point each.
    static func jitterless(_ f: FlexibleLatticeInputs, _ vox: [Int]) -> [SIMD3<Float>] {
        vox.map { centre(f, $0) + SIMD3<Float>(0.31, 0.17, 0.23) * f.rho.spacing }
    }
}
#endif
