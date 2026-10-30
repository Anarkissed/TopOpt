// FlexibleManualP2Tests — round 7 · MANUAL P2: THE DRAWING MATCHES THE SETTINGS.
//   His notes of 2026-10-23 ~00:00 ("Why is there no grading for density or cell sizes? Why is there no choice between
//   default/stepped grade?") and his decisions ~00:35 (a lattice TYPE per group with "a clean seam where types meet"; walls WHOLE
//   beads; the cell follows the density). P2: what each lattice's card says is what is drawn, per voxel — its type, its walls
//   (beads × the bead width), its cell from the density at those walls, its grade (Default smooth, Stepped hard steps), and a clean
//   seam wherever two pieces meet (FlexibleLatticeField.manualPieceWall, MSL flx_wall_pieces).
// On HIS live pad of 2026-10-21 (restored the app's way, lattice built through the page). Each RED control is asserted red inside
// its test:
//   testAGroupsOwnHoneycombTwoBeadsIsDrawnThere   honeycomb + 0.9 mm walls inside the group, prismatic; RED (the part's type and
//                                                 walls drawn there) and the type seam's fragments vs P1 (RED: P1's field)
//   testTheGradeShrinksTheCellsAndSteppedStepsHard 10 → 30 % through the depth: the cell at the floor well under the face's, more
//                                                 walls crossed per mm there; the sim reads the same per-voxel density; Stepped =
//                                                 exactly `steps` cells, hard; RED (grade off: uniform; Default: many cells)
//   testAWallSeamIsClean                          gyroid 2 beads beside gyroid 1 bead: band fragments ≤ 1.5 × control; RED P1
//   testTheGPUDrawsThePiecesAsTheSwiftField       parity ≤ 5e-3 mm incl. 300 seam points; RED (pieces dropped) misses
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleManualP2Tests: XCTestCase {
    typealias Fx = FlexibleLatticeFixtures
    typealias F = FlexibleLatticeField

    override func tearDown() {
        F.controlP1Manual = false
        FlexibleStageModel.controlOneLatticePerPart = false
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
    static func centre(_ f: FlexibleLatticeInputs, _ v: Int) -> SIMD3<Float> {
        let g = f.rho
        return g.c0 + SIMD3<Float>(Float(v % g.nx), Float((v / g.nx) % g.ny), Float(v / (g.nx * g.ny))) * g.spacing
    }
    /// The voxels core's field gives the group's owners (its faces and presses), inside the part by `inset` mm.
    func groupVoxels(_ m: FlexibleStageModel, _ f: FlexibleLatticeInputs, _ gid: Int, inset: Float = 1) throws -> [Int] {
        let field = try XCTUnwrap(m.lastCombinedField)
        let mine = Set(m.manualOwnerGroups().filter { $0.value == gid }.map(\.key))
        return field.density.indices.filter {
            field.density[$0] >= 0 && $0 < field.owner.count && mine.contains(field.owner[$0]) && f.mask.values[$0] >= 0.5
                && F.dPart(Self.centre(f, $0), f) < -inset
        }
    }
    static func pct(_ a: [Float], _ q: Double) -> Float {
        guard !a.isEmpty else { return -1 }
        let s = a.sorted(); return s[Swift.min(s.count - 1, Int(Double(s.count - 1) * q))]
    }

    // MARK: the fragment tally (FlexibleR7U21EdgeLookTests', over lines through the seams between pieces)

    struct Tally { var bandThin = 0, bandRuns = 0, ctlThin = 0, ctlRuns = 0; var bandMM: Float = 0, ctlMM: Float = 0
        var band: Float { Float(bandThin) / Swift.max(bandMM, 1e-3) }
        var control: Float { Float(ctlThin) / Swift.max(ctlMM, 1e-3) }
        var line: String { String(format: "band %d of %d runs over %.1f mm = %.4f /mm; control %d of %d over %.1f mm = %.4f /mm",
                                  bandThin, bandRuns, bandMM, band, ctlThin, ctlRuns, ctlMM, control) }
    }
    /// Lines across every seam between two pieces (`only`: the pairs to keep): through the face between two lattice voxels of
    /// different pieces, along that axis, 2 mm inside the part; at most ~600.
    static func seamLines(_ f: FlexibleLatticeInputs, only: ((Float, Float) -> Bool)? = nil) -> [(SIMD3<Float>, SIMD3<Float>)] {
        guard let pc = f.manualPiece else { return [] }
        let g = f.rho
        var out: [(SIMD3<Float>, SIMD3<Float>)] = []
        for k in 0..<g.nz { for j in 0..<g.ny { for i in 0..<g.nx {
            let v = (k * g.ny + j) * g.nx + i
            guard f.mask.values[v] >= 0.5 else { continue }
            for (di, dj, dk) in [(1, 0, 0), (0, 1, 0), (0, 0, 1)] {
                let a = i + di, b = j + dj, c = k + dk
                guard a < g.nx, b < g.ny, c < g.nz else { continue }
                let w = (c * g.ny + b) * g.nx + a
                guard f.mask.values[w] >= 0.5, pc.values[w] != pc.values[v] else { continue }
                if let only, !only(pc.values[v], pc.values[w]) { continue }
                let d = SIMD3<Float>(Float(di), Float(dj), Float(dk))
                let p = centre(f, v) + 0.5 * d * g.spacing
                guard F.dPart(p, f) < -2 else { continue }
                out.append((p, d))
            }
        } } }
        if out.count > 600 { let st = out.count / 600 + 1; out = stride(from: 0, to: out.count, by: st).map { out[$0] } }
        return out
    }
    static func tally(_ f: FlexibleLatticeInputs, _ lines: [(SIMD3<Float>, SIMD3<Float>)]) -> Tally {
        var t = Tally()
        let step: Float = 0.005
        for (o, d) in lines {
            var start: Float? = nil
            var tau: Float = -3
            while tau <= 3 {
                let p = o + d * tau
                let ok = F.dPart(p, f) < -0.5 && f.mask.sample(p) > 0.9
                if ok { if abs(tau) <= 1.5 { t.bandMM += step } else { t.ctlMM += step } }
                let solid = ok && F.wall(p, f) < 0
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
    /// The P2 seam against P1's field on the same inputs (the RED control): (fixed, P1).
    func seamTallies(_ f: FlexibleLatticeInputs, _ lines: [(SIMD3<Float>, SIMD3<Float>)]) -> (Tally, Tally) {
        let fixed = Self.tally(f, lines)
        F.controlP1Manual = true
        let old = Self.tally(f, lines)
        F.controlP1Manual = false
        return (fixed, old)
    }

    /// Solid run lengths along `d` through the points (8 mm lines), each run whose middle `keep` accepts.
    static func runs(_ f: FlexibleLatticeInputs, _ pts: [SIMD3<Float>], _ d: SIMD3<Float>, keep: (SIMD3<Float>) -> Bool) -> [Float] {
        var out: [Float] = []
        for o in pts {
            var start: Float? = nil
            var tau: Float = -4
            while tau <= 4 {
                let p = o + d * tau
                let ok = F.dPart(p, f) < -0.5 && f.mask.sample(p) > 0.9
                let solid = ok && F.wall(p, f) < 0
                if solid { if start == nil { start = tau } } else if let s0 = start {
                    if ok, s0 > -4, keep(o + d * (0.5 * (tau + s0))) { out.append(tau - s0) }
                    start = nil
                }
                tau += 0.005
            }
        }
        return out
    }

    // MARK: 1 — a group's own honeycomb, 2 beads, inside the part's gyroid, 1 bead: drawn there, and the type seam clean

    func testAGroupsOwnHoneycombTwoBeadsIsDrawnThere() async throws {
        let (r, m) = try await opened("his pad · P2 honeycomb")
        let bw = Float(r.project.printParams.strutLineWidthMM)
        let g = try XCTUnwrap(m.squeezeGroups.first { $0.kind == .faces })
        m.setGroupOwnLattice(g.id, own: true)
        m.setManualType("honeycomb", group: g.id)
        m.setManualBeads(2, group: g.id)
        m.setManualDensity(0.25, group: g.id)
        let card = Float(try XCTUnwrap(m.manualCellMM(group: g.id)))
        let f = try await rebuild(m, "his pad · P2 honeycomb")
        XCTAssertNotNil(f.manualPiece, "★ the pieces reach the lattice inputs"); XCTAssertNotNil(f.manualAcross)
        let pc = try XCTUnwrap(f.manualPiece)
        let vox = try groupVoxels(m, f, g.id, inset: 2)
        XCTAssertGreaterThan(vox.count, 50, "the group's voxels")
        // the group's interior: every point whose cell holds one piece
        var pts: [SIMD3<Float>] = []
        for (n, v) in vox.enumerated() where n % 3 == 0 {
            let p = Self.centre(f, v) + SIMD3<Float>(0.31, 0.17, 0.23) * f.rho.spacing
            if let mp = F.manualPoint(p, f), !mp.seam { pts.append(p) }
            if pts.count >= 300 { break }
        }
        XCTAssertGreaterThan(pts.count, 40)
        var wrong = 0, prismBad: Float = 0, prismN = 0
        let b = simd_normalize(f.buildDir)
        for p in pts {
            let mp = try XCTUnwrap(F.manualPoint(p, f))
            if mp.type != 1 || abs(mp.t - 2 * bw) > 1e-5 || abs(mp.cell - card) > 1e-3 { wrong += 1 }
            let q = p + b * 0.7
            if let mq = F.manualPoint(q, f), !mq.seam, f.mask.sample(q) > 0.99 {
                prismBad = Swift.max(prismBad, abs(F.wall(p, f) - F.wall(q, f))); prismN += 1
            }
        }
        XCTAssertEqual(wrong, 0, "★ inside the group: honeycomb, walls 2 × \(bw) mm, the card's cell \(card) mm")
        XCTAssertGreaterThan(prismN, 20)
        XCTAssertLessThan(prismBad, 1e-4, "★ a honeycomb is the same along the build direction")
        let e1 = simd_normalize(simd_cross(b, abs(b.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)))
        let inGroup: (SIMD3<Float>) -> Bool = { q in F.manualPoint(q, f).map { !$0.seam && $0.type == 1 } ?? false }
        let rl = Self.runs(f, pts, e1, keep: inGroup)
        print(String(format: "FLEX-P2 honeycomb: %d interior points; card d %.3f mm; walls across: %d runs, p05 %.3f p50 %.3f mm (2 beads = %.2f mm); prism max |Δ| %.2e over %d",
                     pts.count, card, rl.count, Self.pct(rl, 0.05), Self.pct(rl, 0.5), 2 * bw, prismBad, prismN))
        XCTAssertGreaterThan(rl.count, 50)
        XCTAssertGreaterThanOrEqual(Self.pct(rl, 0.05), 0.85 * 2 * bw, "★ the walls drawn there are 2 beads thick")

        // ★ the type seam (honeycomb 2 beads | gyroid 1 bead) is clean — RED control: P1's field on the same inputs
        let lines = Self.seamLines(f) { a, c in (Int(a + 0.5) & 1) != (Int(c + 0.5) & 1) }
        XCTAssertGreaterThan(lines.count, 100, "lines across the type seam")
        let (fixed, old) = seamTallies(f, lines)
        print("FLEX-P2 TYPE SEAM fragments over \(lines.count) lines: P2 \(fixed.line) · RED CONTROL (P1) \(old.line)")
        XCTAssertLessThanOrEqual(fixed.band, 1.5 * Swift.max(fixed.control, old.control), "★ the type seam shreds: \(fixed.line)")
        XCTAssertGreaterThanOrEqual(old.band, 3 * Swift.max(old.control, 1e-3), "★ RED CONTROL: P1's type switch must shred the seam")

        // RED CONTROL: the part's type and walls drawn there (M1's one lattice per part)
        FlexibleStageModel.controlOneLatticePerPart = true
        let red = try await rebuild(m, "his pad · P2 honeycomb · RED")
        XCTAssertNil(red.manualPiece)
        var redBad: Float = 0
        for p in pts { redBad = Swift.max(redBad, abs(F.wall(p, red) - F.wall(p + b * 0.7, red))) }
        let redRuns = Self.runs(red, pts, e1) { _ in true }
        print(String(format: "FLEX-P2 RED (one lattice per part): walls across p05 %.3f mm, prism max |Δ| %.3f", Self.pct(redRuns, 0.05), redBad))
        XCTAssertLessThan(Self.pct(redRuns, 0.05), 0.75 * 2 * bw, "RED control: the part's 1-bead gyroid is drawn there")
        XCTAssertGreaterThan(redBad, 0.05, "RED control: a gyroid is not prismatic")
        _ = pc
    }

    // MARK: 2 — the grade: 10 → 30 % through the depth (cells shrink with depth); Stepped (hard steps)

    func testTheGradeShrinksTheCellsAndSteppedStepsHard() async throws {
        let (r, m) = try await opened("his pad · P2 grade")
        let bw = r.project.printParams.strutLineWidthMM
        let g = try XCTUnwrap(m.squeezeGroups.first { $0.kind == .faces })
        m.setGroupOwnLattice(g.id, own: true)
        m.setManualType("gyroid", group: g.id)
        m.setManualBeads(1, group: g.id)
        m.setManualDensity(0.10, group: g.id)
        m.setManualGrade(on: true, group: g.id)
        m.setManualGradeBy("density", group: g.id)
        m.setManualGradeValue(end: true, 0.30, group: g.id)
        m.setManualGradeAlong("depth", group: g.id)
        m.setManualStepped(false, group: g.id)
        let f = try await rebuild(m, "his pad · P2 grade")
        let owners = m.manualGradeOwners()
        let field = try XCTUnwrap(m.lastCombinedField)

        /// Each owner's own depth per column (the deepest of its voxels there, every lattice voxel counted): a pinched face owns
        /// its half of the column.
        func ownDepths() -> [Int: [Int: Double]] {
            var out: [Int: [Int: Double]] = [:]
            for v in field.density.indices where field.density[v] >= 0 && v < field.owner.count {
                let o = field.owner[v]
                guard let ow = owners[o] else { continue }
                let p = SIMD3<Double>(field.origin) + (SIMD3<Double>(Double(v % field.nx), Double((v / field.nx) % field.ny), Double(v / (field.nx * field.ny))) + 0.5) * field.spacing
                guard let hit = FlexibleStackMembership.hit(p, ow.stack, cuts: ow.cuts) else { continue }
                out[o, default: [:]][hit.col] = Swift.max(out[o]?[hit.col] ?? 0, hit.depth)
            }
            return out
        }
        let own = ownDepths()
        /// (s through the owner's own depth, the point, the stack's load) for the group's voxels.
        func samples(_ f: FlexibleLatticeInputs) throws -> [(s: Double, p: SIMD3<Float>, load: SIMD3<Float>)] {
            var out: [(Double, SIMD3<Float>, SIMD3<Float>)] = []
            for v in try groupVoxels(m, f, g.id) {
                guard let ow = owners[field.owner[v]] else { continue }
                let p = Self.centre(f, v)
                guard let hit = FlexibleStackMembership.hit(SIMD3<Double>(p), ow.stack, cuts: ow.cuts),
                      let depth = own[field.owner[v]]?[hit.col], depth > 0 else { continue }
                out.append((hit.depth / depth, p, SIMD3<Float>(simd_normalize(ow.stack.load))))
            }
            return out
        }
        func cells(_ f: FlexibleLatticeInputs, _ ss: [(s: Double, p: SIMD3<Float>, load: SIMD3<Float>)]) -> [(Double, Float)] {
            ss.compactMap { x in F.manualPoint(x.p, f).flatMap { $0.seam ? nil : (x.s, $0.cell) } }
        }
        func quartiles(_ c: [(Double, Float)]) -> [Float] {
            (0..<4).map { q in Self.pct(c.filter { $0.0 >= Double(q) / 4 && $0.0 < Double(q + 1) / 4 }.map(\.1), 0.5) }
        }
        /// Wall crossings per mm along the load, over 8 mm lines centred at the samples in s's window.
        func crossings(_ f: FlexibleLatticeInputs, _ ss: [(s: Double, p: SIMD3<Float>, load: SIMD3<Float>)], _ lo: Double, _ hi: Double) -> Float {
            var n = 0, mm: Float = 0
            for (i, x) in ss.enumerated() where x.s >= lo && x.s < hi && i % 2 == 0 {
                var prev: Bool? = nil
                var tau: Float = -4
                while tau <= 4 {
                    let p = x.p + x.load * tau
                    if F.dPart(p, f) < -0.5, f.mask.sample(p) > 0.9 {
                        let s = F.wall(p, f) < 0
                        if let pv = prev, pv != s { n += 1 }
                        prev = s; mm += 0.02
                    } else { prev = nil }
                    tau += 0.02
                }
            }
            return Float(n) / Swift.max(mm, 1e-3)
        }
        let ss = try samples(f)
        XCTAssertGreaterThan(ss.count, 100, "the group's voxels with a depth")
        let c = cells(f, ss)
        let qs = quartiles(c)
        let face = qs[0], floor = qs[3]
        let want0 = Float(FlexibleManualMath.cellMM(density: 0.10, beads: 1, topology: "gyroid", beadWidthMM: bw))
        let want1 = Float(FlexibleManualMath.cellMM(density: 0.30, beads: 1, topology: "gyroid", beadWidthMM: bw))
        let xFace = crossings(f, ss, 0.05, 0.35), xFloor = crossings(f, ss, 0.65, 0.95)
        print(String(format: "FLEX-P2 grade 10→30 %% (Default): cell by quarter of the depth %.2f / %.2f / %.2f / %.2f mm (10 %% = %.2f, 30 %% = %.2f); walls crossed per mm face %.3f floor %.3f",
                     qs[0], qs[1], qs[2], qs[3], want0, want1, xFace, xFloor))
        XCTAssertLessThan(floor, 0.6 * face, "★ the cells shrink with depth")
        XCTAssertGreaterThan(qs[0], qs[1]); XCTAssertGreaterThan(qs[1], qs[2]); XCTAssertGreaterThan(qs[2], qs[3])
        // ★ the sim reads the same per-voxel density
        let req = try XCTUnwrap(m.lastFERequest)
        var simDiff: Float = 0, simLo: Float = 1, simHi: Float = 0
        for v in try groupVoxels(m, f, g.id) where v < req.rho.count {
            simDiff = Swift.max(simDiff, abs(req.rho[v] - field.density[v]))
            simLo = Swift.min(simLo, req.rho[v]); simHi = Swift.max(simHi, req.rho[v])
        }
        print(String(format: "FLEX-P2 the sim's ρ in the group: %.3f…%.3f, max |sim − drawn| %.2e", simLo, simHi, simDiff))
        XCTAssertEqual(simDiff, 0, "★ the sim reads the drawn density"); XCTAssertLessThan(simLo, 0.13); XCTAssertGreaterThan(simHi, 0.27)
        let defaultDistinct = Set(c.map { ($0.1 * 1000).rounded() }).count
        // every sample, seam cells included, a little inside its cell (the hardness measure below)
        let jitter = SIMD3<Float>(0.31, 0.17, 0.23)
        let defaultAll = ss.compactMap { F.manualPoint($0.p + jitter * f.rho.spacing, f)?.cell }

        // Stepped: exactly `steps` cells, hard (the change between bands within one voxel)
        m.setManualStepped(true, group: g.id)
        let st = try await rebuild(m, "his pad · P2 stepped")
        let sst = try samples(st)
        let cst = cells(st, sst)
        let distinct = Set(cst.map { ($0.1 * 100).rounded() })
        // the bands each owner was asked for: one per cell through ITS own depth (2…8)
        let lg = try XCTUnwrap(m.manualLattice(group: g.id))
        let mineOwners = Set(m.manualOwnerGroups().filter { $0.value == g.id }.map(\.key))
        var want = Set<Float>()
        var depth = 0.0, steps = 0
        for o in mineOwners {
            guard let cols = own[o], !cols.isEmpty else { continue }
            let mean = cols.values.reduce(0, +) / Double(cols.count)
            let n = FlexibleManualMath.steps(lg, depthMM: mean, beadWidthMM: bw)
            depth = Swift.max(depth, mean); steps = Swift.max(steps, n)
            for b in 0..<n {
                let rho = FlexibleManualMath.density(lg, at: (Double(b) + 0.5) / Double(n), steps: n, beadWidthMM: bw)
                want.insert((Float(FlexibleManualMath.cellMM(density: rho, beads: 1, topology: "gyroid", beadWidthMM: bw)) * 100).rounded())
            }
        }
        // hardness: every sample (seam cells included) draws one band's cell — only the thin seam between bands blends; a smooth
        // grade (RED control: Default) draws a band's cell almost nowhere
        let bands = want.map { $0 / 100 }
        func onBand(_ cs: [Float]) -> Double {
            Double(cs.filter { c in bands.contains { abs(c - $0) <= 0.02 * $0 } }.count) / Double(Swift.max(cs.count, 1))
        }
        let stAll = sst.compactMap { F.manualPoint($0.p + jitter * st.rho.spacing, st) }
        let seamShare = Double(stAll.filter(\.seam).count) / Double(Swift.max(stAll.count, 1))
        let hard = onBand(stAll.map(\.cell)), soft = onBand(defaultAll)
        print(String(format: "FLEX-P2 Stepped: %d bands asked (own depth %.1f mm); %d distinct cells drawn off the seams %@ (asked %@); on a band's cell: Stepped %.1f %% of %d samples (seam cells %.1f %%) · RED Default %.1f %% (%d distinct cells)",
                     steps, depth, distinct.count, "\(distinct.sorted().map { $0 / 100 })", "\(want.sorted().map { $0 / 100 })",
                     100 * hard, stAll.count, 100 * seamShare, 100 * soft, defaultDistinct))
        XCTAssertEqual(distinct, want, "★ Stepped: exactly the bands' cells (\(steps) bands)")
        XCTAssertGreaterThanOrEqual(steps, 2)
        XCTAssertGreaterThanOrEqual(hard, 0.85, "★ hard steps: almost every point draws exactly one band's cell")
        XCTAssertLessThan(soft, 0.5, "RED control (Default): a smooth grade is on a band's cell only by chance")
        XCTAssertGreaterThan(defaultDistinct, 4 * want.count, "RED control (Default): a smooth grade draws many cells")
        // the band seams are clean (gyroid | gyroid, same walls)
        let lines = Self.seamLines(st)
        let (fixed, old) = seamTallies(st, lines)
        print("FLEX-P2 STEPPED SEAMS fragments over \(lines.count) lines: P2 \(fixed.line) · P1 \(old.line)")
        XCTAssertLessThanOrEqual(fixed.band, 1.5 * Swift.max(fixed.control, old.control), "★ the band seams shred: \(fixed.line)")

        // RED CONTROL: the grade off — one density, one cell through the depth
        m.setManualGrade(on: false, group: g.id)
        let flat = try await rebuild(m, "his pad · P2 grade · RED")
        let sf = try samples(flat)
        let qf = quartiles(cells(flat, sf))
        let fFace = crossings(flat, sf, 0.05, 0.35), fFloor = crossings(flat, sf, 0.65, 0.95)
        print(String(format: "FLEX-P2 RED (grade off): cell by quarter %.2f / %.2f / %.2f / %.2f mm; walls crossed per mm face %.3f floor %.3f (floor/face %.2f; graded %.2f)",
                     qf[0], qf[1], qf[2], qf[3], fFace, fFloor, fFloor / Swift.max(fFace, 1e-6), xFloor / Swift.max(xFace, 1e-6)))
        XCTAssertGreaterThan(xFloor / Swift.max(xFace, 1e-6), 1.15 * fFloor / Swift.max(fFace, 1e-6),
                             "★ drawn: more walls per mm at the floor than at the face, beyond the uniform lattice's own ratio")
        XCTAssertGreaterThan(qf[3], 0.95 * qf[0], "RED control: the uniform lattice must not shrink with depth")
    }

    // MARK: 3 — a wall seam (gyroid 2 beads beside gyroid 1 bead) is clean

    func testAWallSeamIsClean() async throws {
        let (_, m) = try await opened("his pad · P2 wall seam")
        let g = try XCTUnwrap(m.squeezeGroups.first { $0.kind == .faces })
        m.setGroupOwnLattice(g.id, own: true)
        m.setManualType("gyroid", group: g.id)
        m.setManualBeads(2, group: g.id)
        m.setManualDensity(0.25, group: g.id)
        let f = try await rebuild(m, "his pad · P2 wall seam")
        let lines = Self.seamLines(f)
        XCTAssertGreaterThan(lines.count, 100, "lines across the wall seam")
        let (fixed, old) = seamTallies(f, lines)
        print("FLEX-P2 WALL SEAM fragments over \(lines.count) lines: P2 \(fixed.line) · RED CONTROL (P1) \(old.line)")
        XCTAssertLessThanOrEqual(fixed.band, 1.5 * Swift.max(fixed.control, old.control), "★ the wall seam shreds: \(fixed.line)")
        XCTAssertGreaterThanOrEqual(old.band, 3 * Swift.max(old.control, 1e-3), "★ RED CONTROL: P1's ladder across the group edge must shred")
    }

    // MARK: 4 — the GPU draws the pieces exactly as the Swift field (RED control: the pieces dropped)

    func testTheGPUDrawsThePiecesAsTheSwiftField() throws {
        let pass = try FlexibleLatticePass(device: try Fx.device())
        var f = Fx.boxInputs(.gyroid)
        let g = f.rho
        var w = g.values, t = g.values, rho = g.values, code = g.values
        for k in 0..<g.nz { for j in 0..<g.ny { for i in 0..<g.nx {
            let v = (k * g.ny + j) * g.nx + i
            let p = g.c0 + SIMD3<Float>(Float(i), Float(j), Float(k)) * g.spacing
            if p.x < 12 { w[v] = 0.45; t[v] = 0; rho[v] = 0.2; code[v] = 0 }                       // gyroid 1 bead, one density
            else if p.y >= 22 { w[v] = 0.9; t[v] = 1; rho[v] = 0.25; code[v] = 17 }                 // honeycomb 2 beads
            // (codes in T2's encoding, 8 · piece + 4 · stepped + 2 · graded + type: the bands carry the Stepped bit)
            else if p.x < 26 { w[v] = 0.9; t[v] = 0; code[v] = 26 }                                 // gyroid 2 beads, graded (the ramp)
            else { w[v] = 0.45; t[v] = 0; rho[v] = p.z < 10 ? 0.15 : 0.3; code[v] = p.z < 10 ? 36 : 44 }  // two Stepped bands
        } } }
        let x = FlexibleLatticeBuilder.manualAcross(rho: rho, code: code, nx: g.nx, ny: g.ny, nz: g.nz)
        func grid(_ a: [Float]) -> FlexGrid { FlexGrid(nx: g.nx, ny: g.ny, nz: g.nz, c0: g.c0, spacing: g.spacing, values: a) }
        f.rho = grid(rho)
        f.wallMM = 0.45; f.lMinMM = 3.0915 * 0.45 / 0.9; f.lMaxMM = 3.0915 * 0.9 / 0.05
        f.manualWall = grid(w); f.manualType = grid(t); f.manualPiece = grid(code)
        f.manualAcross = grid(x.across); f.manualOther = grid(x.other)
        pass.upload(Fx.layer(f, token: 52))
        let ref = try XCTUnwrap(pass.referenceInputs)
        XCTAssertNotNil(ref.manualPiece, "the pieces reach the GPU")
        // 400 spread points + 300 in seam cells
        var pts = Fx.probePoints(400)
        var seed: UInt64 = 0x51ED2701
        func next() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(seed >> 40) / Float(1 << 24) }
        var tries = 0
        var seamPts = 0
        while seamPts < 300 && tries < 100_000 {
            tries += 1
            let p = SIMD3<Float>(next() * 40, next() * 40, next() * 20)
            if F.manualPoint(p, ref)?.seam == true { pts.append(p); seamPts += 1 }
        }
        let gpu = try XCTUnwrap(pass.probe(pts))
        var worst: Float = 0, worstSeam: Float = 0
        for (i, p) in pts.enumerated() {
            let d = abs(gpu[i] - F.lattice(at: p, ref))
            worst = max(worst, d)
            if i >= 400 { worstSeam = max(worstSeam, d) }
        }
        var plain = ref; plain.manualPiece = nil; plain.manualAcross = nil; plain.manualOther = nil
        let pass2 = try FlexibleLatticePass(device: try Fx.device())
        pass2.upload(Fx.layer(plain, token: 53))
        let gpuP1 = try XCTUnwrap(pass2.probe(pts))
        let miss = pts.indices.map { abs(gpuP1[$0] - F.lattice(at: pts[$0], ref)) }.max() ?? 0
        print("FLEX-P2 GPU pieces: max |gpu − swift| = \(worst) mm over \(pts.count) points (\(seamPts) in seam cells, worst there \(worstSeam)); RED control (pieces dropped) \(miss) mm")
        XCTAssertEqual(seamPts, 300)
        XCTAssertLessThanOrEqual(worst, 5e-3, "★ the GPU's pieces and seams are the Swift field's")
        XCTAssertGreaterThan(miss, 0.05, "RED control (the pieces dropped) must miss")
    }
}
#endif
