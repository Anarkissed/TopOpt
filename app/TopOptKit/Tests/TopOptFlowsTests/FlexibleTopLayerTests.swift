// FlexibleTopLayerTests — his report of 2026-10-18 (~15:10, img_top_2 / img_top_3 / img_top_4): "For some reason, the top
// isn't being bent or removed when I have set the finish to 'none'. Can you look into this? The top layer just doesn't seem
// affected by anything..." — and, with the face-prism expanded over the Top: "it keeps the top layer."
//
// ★ ON HIS LIVE PAD: A1_0003 exactly as his simulator held it at 15:06 (committed beside the evidence:
// round7/batch_tl/his_live_A1_0003, its sums in his_live_A1_0003.SHA256SUMS) — quality Balanced, Finish None, Group C =
// Face 3 + Face 5 Lattice 25 mm — restored the app's way and built through Save & Exit's path.
//
// ★ THE CAUSE (the checked read-only diagnosis): core voxelizes the part at the quality's resolution (Balanced: 96 voxels on
// the longest side, h = 1.0417 mm) from the bounding box's corner, and counts a voxel only when its CENTRE is inside the
// part. His 20 mm pad is 19.2 voxels tall: the top layer's centre is at z = 20.31, outside, so that layer is Empty; the
// lattice mask's trilinear sample crosses ½ at z = 19.79 and the printed solid S = max(dPart, −dRegion) (Finish None) drew a
// 0.21 mm sheet over every pocket — the "lid". The sides and the Bottom are open because their last voxel centres lie
// inside the part. Fast (19.53) and Fine (19.92) have no such layer.
//
// ★ THE FIX (app only): FlexibleLatticeBuilder.inputs sets mask = 1 on each voxel whose centre is OUTSIDE the part and
// that has a lattice voxel as a 6-neighbour, with that neighbour's flood-filled ρ. dPart clips the walls at the surface, as
// at every other face; dSkin still decides the finish. Written BEFORE the code (the red run: round7/batch_tl/
// tl_red_run.txt). RED CONTROL inside each test: `maskToSurface: false` — the mask as core gives it.
// ★ "OUTSIDE" IS CORE'S OWN RULE (+Z winding at the voxel centre, voxelize.cpp), not the app's SDF > 0 the plan named: T2
// went red on the SDF version at Fine — the voxel-made SDF read four voxels under the Top's edge (centre 0.08 mm under the
// Top, 0.39 mm in from the side) as outside although core had kept them, and the region grew there.
//   T1  Balanced: S at (95, 50, 19.9) open; the whole Top over each pocket open at z = 19.9, the walls reach it (X-ray), the
//       middle of the Top solid; nothing below the top layer's reach moves, bit for bit; the legend's span, the (i)'s
//       numbers and what the squish sims read unchanged; overLattice only firmer.
//   T2  Fast and Fine: the inputs equal the control's (nothing added).
//   T3  Covered / Rim / Skin keep their kind over the pocket: Covered solid; Rim solid along the Top's edge and open in its
//       middle; Skin solid between the holes and open in them (today: the sheet everywhere).
//   T4  the MSL twin on his pad's own inputs (the top band and the part at large): within 5e-3 mm of the Swift field wherever
//       a surface can be drawn (the reference within 1 mm of 0), printed view and X-ray; anywhere, no worse than today.
//   T5 (FlexibleTopLayerHostedTests) the shipping renderer's offscreen frame of his pad, img_top_3's camera, before / after.
import XCTest
import CryptoKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
enum FlexibleTopLayerFixtures {

    static var liveDir: URL {
        FlexibleHisProject.repoRoot.appendingPathComponent(
            "docs/handoffs/evidence/2026-09-29-flexible-screens/round7/batch_tl/his_live_A1_0003", isDirectory: true)
    }
    /// His files as copied from the simulator (2026-10-18 15:06): never written.
    static let sums = ["model.stl": "53964b38e3354f5a613bcf6523796166749f97c3ea2296b2358b6f315229957a",
                       "project.json": "845215ad16638480ae494bda0cfd587c7914315db343908d3ef41b8803f12cff"]

    static func assertHisFiles() throws {
        for (f, want) in sums {
            let got = SHA256.hash(data: try Data(contentsOf: liveDir.appendingPathComponent(f))).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(got, want, "★ his live pad's \(f) moved")
        }
    }

    /// His live pad on a main stage, its lattice built (Save & Exit's path), the combined field kept. `quality`: another
    /// quality in a temporary copy of his project.json (nil = as he saved it, Balanced). `finish`: another finish.
    static func hisLivePad(_ test: XCTestCase, quality: String? = nil, finish: FlexibleFinish? = nil) async throws
        -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel) {
        try assertHisFiles()
        var src = liveDir
        if let q = quality {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("his-live-\(q)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            test.addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
            try FileManager.default.copyItem(at: liveDir.appendingPathComponent("model.stl"), to: tmp.appendingPathComponent("model.stl"))
            let json = try String(contentsOf: liveDir.appendingPathComponent("project.json"), encoding: .utf8)
            XCTAssertEqual(json.components(separatedBy: "\"quality\":\"balanced\"").count, 2, "premise: his project says Balanced once")
            try json.replacingOccurrences(of: "\"quality\":\"balanced\"", with: "\"quality\":\"\(q)\"")
                .write(to: tmp.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)
            src = tmp
        }
        let r = try FlexibleHisProject.restore(src, asSaved: true)
        test.addTeardownBlock { r.cleanup() }
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        m.keepCombinedField = true
        if let finish { m.edit { $0.finish = finish.rawValue } }
        test.addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his live pad")
        s.didExitSettings()
        s.apply(r.project, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(240, "the lattice") { m.lattice != nil && !m.latticeBuilding && !m.latticeIsStale }
        s.heat = false
        s.refresh()
        return (r, s, m)
    }

    /// The inputs the stage built, made again from the kept field — `maskToSurface: false` is the RED CONTROL (the mask as
    /// core gives it: today's).
    static func inputs(_ m: FlexibleStageModel, _ p: ProjectModel, maskToSurface: Bool, finish: FlexibleFinish? = nil) throws -> FlexibleLatticeInputs {
        let field = try XCTUnwrap(m.lastCombinedField, "the kept combined field")
        let part = try XCTUnwrap(p.viewerMesh)
        let b = m.build
        return try FlexibleLatticeBuilder.inputs(field: field, part: part, topology: b.topology, beadsPerWall: b.beadsPerWall,
                                                 beadWidthMM: b.beadWidthMM, buildDir: m.sceneInfo?.buildDir ?? SIMD3(0, 0, 1),
                                                 skinOffFaces: [], finish: finish ?? m.settings.finishMode,
                                                 maskToSurface: maskToSurface)
    }

    /// The Top's plan, sampled every `step` mm: each point over a POCKET (core's own mask, at its last solid layer, ≥ 0.999 a
    /// whole voxel round it) or over the SOLID middle (≤ 0.001 a whole voxel round it). From the control. `margin`: kept off
    /// the Top's outer edges — the preview's part SDF is voxel-made and reads its outermost texel (0.79 mm here) as outside
    /// near an edge (x = 99.75, z = 19.9: +0.85 mm — the known clipped rim, memory "the preview clips the outermost ~2 mm"),
    /// the same before and after; T3 checks the whole Top, edges included, for Covered.
    static func plan(_ control: FlexibleLatticeInputs, step: Float = 0.5, margin: Float = 1) -> (pocket: [SIMD2<Float>], solid: [SIMD2<Float>], lastLayerZ: Float) {
        let mk = control.mask, sp = mk.spacing
        // the last layer holding a lattice voxel
        var kTop = 0
        for k in 0..<mk.nz { for n in 0..<(mk.nx * mk.ny) where mk.values[k * mk.nx * mk.ny + n] >= 0.5 { kTop = k; break } }
        let z = mk.c0.z + Float(kTop) * sp
        var pocket: [SIMD2<Float>] = [], solid: [SIMD2<Float>] = []
        let lo = control.boundsMin + margin, hi = control.boundsMax - margin
        var y = lo.y + step / 2
        while y < hi.y {
            var x = lo.x + step / 2
            while x < hi.x {
                var mn: Float = 1, mx: Float = 0
                for dy in [-sp, 0, sp] { for dx in [-sp, 0, sp] {
                    let v = mk.sample(SIMD3(x + dx, y + dy, z)); mn = min(mn, v); mx = max(mx, v)
                } }
                if mn >= 0.999 { pocket.append(SIMD2(x, y)) } else if mx <= 0.001 { solid.append(SIMD2(x, y)) }
                x += step
            }
            y += step
        }
        return (pocket, solid, z)
    }
}

@MainActor
final class FlexibleTopLayerTests: XCTestCase {
    typealias F = FlexibleTopLayerFixtures
    /// The diagnosis's probe: over Face 5's pocket, 0.1 mm under the Top.
    static let probe = SIMD3<Float>(95, 50, 19.9)

    // MARK: - T1: Balanced — the Top over each pocket opens

    func testHisBalancedPadTheTopOverEachPocketIsOpen() async throws {
        let (r, _, m) = try await F.hisLivePad(self)
        let p = r.project
        let g = try XCTUnwrap(m.lattice)
        let field = try XCTUnwrap(m.lastCombinedField)
        // premises: his project as he left it — Balanced, None; core's grid 96 × 96 × 20 at 1.0417 mm, its top layer's centre
        // above the part
        XCTAssertEqual(p.quality, .balanced, "premise: Balanced (his toolbar: \"Balan…\")")
        XCTAssertEqual(m.settings.finishMode, .none, "premise: Finish None")
        XCTAssertEqual(field.nz, 20, "premise: 20 layers")
        XCTAssertEqual(field.spacing, 100.0 / 96, accuracy: 1e-6, "premise: h = 100/96 mm")
        let partTop = Double(try XCTUnwrap(p.viewerMesh).bounds.max.z)
        XCTAssertEqual(partTop, 20, accuracy: 1e-4)
        XCTAssertGreaterThan(field.origin.z + (Double(field.nz) - 0.5) * field.spacing, partTop, "premise: the top layer's centre lies above the part")
        let fix = try F.inputs(m, p, maskToSurface: true)
        let control = try F.inputs(m, p, maskToSurface: false)
        XCTAssertEqual(fix, g.inputs, "the stage's inputs are the builder's (the same arguments)")

        // ★ the diagnosis's probe — RED today (the sheet, ≈ −0.1)
        let sFix = FlexibleLatticeField.terms(at: Self.probe, fix).printed
        let sCtl = FlexibleLatticeField.terms(at: Self.probe, control).printed
        XCTAssertGreaterThan(sFix, 0, "★ S at (95, 50, 19.9) is OPEN (no sheet over Face 5's pocket)")
        XCTAssertLessThan(sCtl, 0, "★ RED CONTROL: the mask as core gives it draws the 0.21 mm sheet there")

        // ★ the whole Top over each pocket, and its middle
        let plan = F.plan(control)
        XCTAssertGreaterThan(plan.pocket.count, 2000, "premise: the two pockets reach the Top (\(plan.pocket.count) points)")
        XCTAssertGreaterThan(plan.solid.count, 2000, "premise: the solid middle (\(plan.solid.count) points)")
        var shut = 0, wallsFix = 0, wallsCtl = 0, sheetCtl = 0, middleOpen = 0
        for q in plan.pocket {
            for z: Float in [19.85, 19.9, 19.95, 19.99] {
                let pt = SIMD3(q.x, q.y, z)
                let tf = FlexibleLatticeField.terms(at: pt, fix), tc = FlexibleLatticeField.terms(at: pt, control)
                if tf.printed <= 0 { shut += 1 }
                if tc.printed < 0 { sheetCtl += 1 }
                if z == 19.9 { if tf.walls < 0 { wallsFix += 1 }; if tc.walls < 0 { wallsCtl += 1 } }
            }
        }
        for q in plan.solid where FlexibleLatticeField.terms(at: SIMD3(q.x, q.y, 19.9), fix).printed >= 0 { middleOpen += 1 }
        let wallShare = Double(wallsFix) / Double(plan.pocket.count)
        print("FLEX-TL-T1 his Balanced pad: S(95, 50, 19.9) fix \(sFix) mm, control \(sCtl) mm · the Top over the pockets (\(plan.pocket.count) points × 4 heights): printed solid at \(shut) (control: \(sheetCtl)) · walls at z 19.9: \(wallsFix) (\(String(format: "%.1f", 100 * wallShare)) %; control \(wallsCtl)) · the middle (\(plan.solid.count)): open at \(middleOpen)")
        XCTAssertEqual(shut, 0, "★ the Top over each pocket is open, 0.15 … 0.01 mm under it")
        XCTAssertEqual(sheetCtl, plan.pocket.count * 4, "★ RED CONTROL: the sheet covers every pocket point today")
        XCTAssertGreaterThan(wallShare, 0.10, "★ X-ray: the walls reach the Top (they stopped at 19.79)")
        XCTAssertEqual(wallsCtl, 0, "★ RED CONTROL: no wall above 19.79 today")
        XCTAssertEqual(middleOpen, 0, "★ the middle of the Top stays solid")

        // ★ what moved: one voxel above each lattice voxel of core's last solid layer, nothing else; each with its ρ
        let nx = fix.mask.nx, ny = fix.mask.ny, nz = fix.mask.nz
        var added: [Int] = [], lastLayer = 0
        for n in fix.mask.values.indices where fix.mask.values[n] != control.mask.values[n] { added.append(n) }
        for n in 0..<(nx * ny) where control.mask.values[(nz - 2) * nx * ny + n] >= 0.5 { lastLayer += 1 }
        XCTAssertEqual(added.count, lastLayer, "★ one voxel above each lattice voxel of the last solid layer (\(lastLayer))")
        for n in added {
            XCTAssertEqual(n / (nx * ny), nz - 1, "only the top layer moves")
            XCTAssertEqual(fix.mask.values[n], 1)
            XCTAssertEqual(fix.rho.values[n], fix.rho.values[n - nx * ny], "its ρ is the lattice voxel's below it")
        }
        XCTAssertEqual(fix.partSDF, control.partSDF)
        XCTAssertEqual(fix.skinDist, control.skinDist)
        // nothing below the top layer's reach moves, bit for bit (walls, region, printed field)
        let below = fix.mask.c0.z + Float(nz - 2) * fix.mask.spacing
        var moved = 0
        for pt in Self.points(9000, lo: fix.boundsMin - 1, hi: SIMD3(fix.boundsMax.x + 1, fix.boundsMax.y + 1, below - 1e-3)) {
            let a = FlexibleLatticeField.terms(at: pt, fix), b = FlexibleLatticeField.terms(at: pt, control)
            if a.walls != b.walls || a.printed != b.printed { moved += 1 }
        }
        XCTAssertEqual(moved, 0, "★ below the top layer's reach the field is bit-identical")
        // the readers: the legend's span, the (i)'s numbers, the squish sims' ρ, overLattice
        XCTAssertEqual(FlexibleProbe.latticeSpan(fix), FlexibleProbe.latticeSpan(control), "the legend's span is unchanged")
        let groupC = try XCTUnwrap(p.selection.groups.first { $0.name == "Group C" }, "his Group C")
        for face: FaceID in [3, 5] {
            let key = LatticeSelectableRef.face(group: groupC.id, face: face).key
            let specs = m.includeSpecs.filter { $0.selectableKey == key }
            XCTAssertFalse(specs.isEmpty, "premise: Face \(face)'s prism")
            let a = FlexibleFaceStats.rows(lattice: fix, regions: specs, depthMM: 25)
            let b = FlexibleFaceStats.rows(lattice: control, regions: specs, depthMM: 25, countOutside: true)   // today's rule on today's mask
            XCTAssertNotNil(a)
            let ra: [LatticeDrawerRow] = a?.rows ?? [], rb: [LatticeDrawerRow] = b?.rows ?? []
            XCTAssertEqual(ra, rb, "★ Face \(face)'s (i): the same numbers (the voxels outside the part are not counted)")
            let rhoA: Double = a?.rho ?? -1, rhoB: Double = b?.rho ?? -2
            XCTAssertEqual(rhoA, rhoB)
        }
        var simsRead = 0
        for v in field.density.indices where field.density[v] >= 0 {
            simsRead += 1
            XCTAssertEqual(fix.rho.values[v], control.rho.values[v], "the squish sims read the same ρ (FlexibleFERequest)")
        }
        XCTAssertGreaterThan(simsRead, 1000)
        let mesh = try XCTUnwrap(m.project.viewerMesh)
        let oa = FlexibleMainTints.overLattice(mesh: mesh, lattice: fix), ob = FlexibleMainTints.overLattice(mesh: mesh, lattice: control)
        let lost = zip(oa, ob).filter { !$0 && $1 }.count, gained = zip(oa, ob).filter { $0 && !$1 }.count
        print("FLEX-TL-T1 added \(added.count) voxels (the last solid layer's lattice voxels: \(lastLayer)) · overLattice: \(gained) vertices gained, \(lost) lost of \(oa.count) · the (i) and the span unchanged")
        XCTAssertEqual(lost, 0, "overLattice only gets firmer")
    }

    /// T1b — the (i) counts only voxels inside the part (synthetic): a 40 × 40 × 20 block, ρ 0.15, with its top 5 mm marked
    /// OUTSIDE the part (SDF > 0) at ρ 0.5 — as the voxels the mask now adds beyond a surface. The face's prism (the top of
    /// the x < 20 half, 10 mm deep) reads 15 %. RED CONTROL: counting them (the rule before) reads 50 %.
    func testTheInfoSkipsVoxelsOutsideThePart() throws {
        let n = (x: 40, y: 40, z: 20)
        var rho = [Float](repeating: 0.15, count: n.x * n.y * n.z), sdf = rho
        for k in 0..<n.z { for j in 0..<n.y { for i in 0..<n.x {
            let v = (k * n.y + j) * n.x + i
            if k >= 15 { rho[v] = 0.5; sdf[v] = 1 } else { sdf[v] = -1 }
        } } }
        let c0 = SIMD3<Float>(0.5, 0.5, 0.5)
        let grid = FlexGrid(nx: n.x, ny: n.y, nz: n.z, c0: c0, spacing: 1, values: rho)
        var f = FlexibleLatticeInputs(topology: .gyroid, wallMM: 0.42, lMinMM: 1.4, lMaxMM: 25, honeycombCellMM: 4,
                                      buildDir: SIMD3(0, 0, 1), skinMM: 0.8, rho: grid,
                                      mask: FlexGrid(nx: n.x, ny: n.y, nz: n.z, c0: c0, spacing: 1, values: [Float](repeating: 1, count: rho.count)),
                                      partSDF: FlexGrid(nx: n.x, ny: n.y, nz: n.z, c0: c0, spacing: 1, values: sdf), skinDist: grid,
                                      boundsMin: .zero, boundsMax: SIMD3(40, 40, 20))
        // ★ RE-PINNED (round 7, R7-E1 — the top-lid fix's check: the (i) decides "outside" with core's own rule, like the mask,
        // not the app's SDF): the voxels marked outside are now the ones the fill ADDED (`coreOutside`, as the builder records
        // them), not only SDF > 0. Was: the SDF alone (no `coreOutside`). The numbers checked are unchanged.
        f.coreOutside = Set((0..<rho.count).filter { $0 / (n.x * n.y) >= 15 })
        var face = LatticeRegionSpec(role: .include, kind: .face)
        face.origin = SIMD3(10, 20, 20); face.normal = SIMD3(0, 0, -1)
        face.halfUMM = 9.9; face.halfWMM = 9.9; face.depthMM = 10
        let rows = try XCTUnwrap(FlexibleFaceStats.rows(lattice: f, regions: [face], depthMM: 10))
        XCTAssertEqual(rows.rows[1].value, "15%", "★ the (i) counts only the voxels inside the part")
        let before = try XCTUnwrap(FlexibleFaceStats.rows(lattice: f, regions: [face], depthMM: 10, countOutside: true))
        XCTAssertEqual(before.rows[1].value, "50%", "★ RED CONTROL: counting the voxels outside the part moves the median")
    }

    // MARK: - T2: Fast and Fine — nothing added

    func testFastAndFineAreUnchanged() async throws {
        for q in ["fast", "fine"] {
            let (r, _, m) = try await F.hisLivePad(self, quality: q)
            let p = r.project
            XCTAssertEqual(p.quality.rawValue, q, "premise: \(q)")
            let field = try XCTUnwrap(m.lastCombinedField)
            XCTAssertLessThan(field.origin.z + (Double(field.nz) - 0.5) * field.spacing, 20, "premise (\(q)): the top layer's centre lies inside the part")
            let fix = try F.inputs(m, p, maskToSurface: true), control = try F.inputs(m, p, maskToSurface: false)
            XCTAssertEqual(fix, control, "★ \(q): the inputs are byte-identical (no voxel centre outside the part next to the lattice)")
            XCTAssertEqual(try XCTUnwrap(m.lattice).inputs, fix)
            // the (i) skips voxels outside the part (the app's SDF): at this quality it reads what it read before
            let groupC = try XCTUnwrap(p.selection.groups.first { $0.name == "Group C" }, "his Group C")
            for face: FaceID in [3, 5] {
                let key = LatticeSelectableRef.face(group: groupC.id, face: face).key
                let specs = m.includeSpecs.filter { $0.selectableKey == key }
                let a = FlexibleFaceStats.rows(lattice: fix, regions: specs, depthMM: 25)
                XCTAssertNotNil(a, "\(q): Face \(face) has numbers")
                let today = FlexibleFaceStats.rows(lattice: control, regions: specs, depthMM: 25, countOutside: true)   // today's rule on today's mask
                let ra: [LatticeDrawerRow] = a?.rows ?? [], rt: [LatticeDrawerRow] = today?.rows ?? []
                XCTAssertEqual(ra, rt, "★ \(q): Face \(face)'s (i) reads what it read before")
            }
            let s = FlexibleLatticeField.terms(at: Self.probe, fix).printed
            print("FLEX-TL-T2 \(q): grid \(field.nx) × \(field.ny) × \(field.nz) at \(field.spacing) mm, last centre z \(field.origin.z + (Double(field.nz) - 0.5) * field.spacing) · inputs identical to the control · S(95, 50, 19.9) \(s) mm")
            XCTAssertGreaterThan(s, 0, "\(q): the Top over the pocket was already open")
            await m.waitForIdle()
        }
    }

    // MARK: - T3: Covered / Rim / Skin keep their kind

    func testCoveredRimAndSkinKeepTheirKindOverThePocket() async throws {
        let (r, _, m) = try await F.hisLivePad(self)
        let p = r.project
        let plan = F.plan(try F.inputs(m, p, maskToSurface: false))
        var lines: [String] = []
        for finish in [FlexibleFinish.covered, .rim, .skin] {
            let fix = try F.inputs(m, p, maskToSurface: true, finish: finish)
            let control = try F.inputs(m, p, maskToSurface: false, finish: finish)
            // 0.15 … 0.05 mm under the Top over the pocket: where the finish keeps solid (dSkin > 0.05) and where it leaves the
            // lattice open (dSkin < −0.05)
            var keep = 0, keepSolidFix = 0, keepSolidCtl = 0, open = 0, openFix = 0, openCtl = 0
            for q in plan.pocket {
                for z: Float in [19.85, 19.9, 19.95] {
                    let pt = SIMD3(q.x, q.y, z)
                    let d = FlexibleLatticeField.dSkin(pt, fix)
                    XCTAssertEqual(d, FlexibleLatticeField.dSkin(pt, control), "the finish's own field is untouched")
                    let sf = FlexibleLatticeField.terms(at: pt, fix).printed, sc = FlexibleLatticeField.terms(at: pt, control).printed
                    if d > 0.05 { keep += 1; if sf < 0 { keepSolidFix += 1 }; if sc < 0 { keepSolidCtl += 1 } }
                    if d < -0.05 { open += 1; if sf > 0 { openFix += 1 }; if sc > 0 { openCtl += 1 } }
                }
            }
            lines.append("\(finish.rawValue): the finish keeps \(keep) points solid (fix \(keepSolidFix), control \(keepSolidCtl)) and leaves \(open) open (fix open \(openFix), control open \(openCtl))")
            XCTAssertEqual(keepSolidFix, keep, "★ \(finish.rawValue): where the finish keeps solid, solid (dSkin still decides)")
            XCTAssertEqual(keepSolidCtl, keep, "\(finish.rawValue): …as today")
            XCTAssertEqual(openFix, open, "★ \(finish.rawValue): where the finish leaves the lattice open, open")
            XCTAssertEqual(openCtl, 0, "★ RED CONTROL (\(finish.rawValue)): today the sheet shuts it")
            switch finish {
            case .covered:
                XCTAssertEqual(open, 0, "Covered: a solid skin over the whole pocket")
                XCTAssertEqual(keep, plan.pocket.count * 3)
                // ★ Covered's look over the WHOLE Top band, its edges included: the walls (X-ray's field) and the printed
                // solid come out on the same side of 0 everywhere, before and after
                var flips = 0, n = 0
                var y: Float = 0.25
                while y < 100 {
                    var x: Float = 0.25
                    while x < 100 {
                        for z: Float in [19.2, 19.5, 19.8, 19.9, 19.95, 19.99] {
                            let pt = SIMD3(x, y, z)
                            let a = FlexibleLatticeField.terms(at: pt, fix), b = FlexibleLatticeField.terms(at: pt, control)
                            n += 1
                            if (a.walls < 0) != (b.walls < 0) || (a.printed < 0) != (b.printed < 0) { flips += 1 }
                        }
                        x += 0.5
                    }
                    y += 0.5
                }
                lines.append("covered over the whole Top band (\(n) points, edges included): \(flips) change side")
                XCTAssertEqual(flips, 0, "★ Covered keeps its look over the whole Top, edges included (and in X-ray)")
            case .rim, .skin:
                XCTAssertGreaterThan(keep, 150, "\(finish.rawValue): part of the Top over the pocket stays solid (the edge band / between the holes)")
                XCTAssertGreaterThan(open, 1500, "\(finish.rawValue): …and part opens (the middle / the holes)")
            case .none: break
            }
        }
        print("FLEX-TL-T3 his Balanced pad, the Top over the pockets (0.15 … 0.05 mm under it):\n  " + lines.joined(separator: "\n  "))
    }

    // MARK: - T4: the MSL twin on his pad's own inputs

    #if canImport(Metal)
    func testThePrintedTwinsAgreeOnHisPadsTopBand() async throws {
        let (r, _, m) = try await F.hisLivePad(self)
        // the top band (the gap that was the sheet, and the walls' last millimetre) over the whole Top, and the part at large
        var pts = Self.points(3000, lo: SIMD3(0, 0, 18.5), hi: SIMD3(100, 100, 20.5), seed: 0x70_9_1A7E5)
        pts += Self.points(1000, lo: SIMD3(-1, -1, -1), hi: SIMD3(101, 101, 21), seed: 0x70_9_1A7E6)
        pts.append(Self.probe)
        var lines: [String] = []
        var near: [Bool: Float] = [:], all: [Bool: Float] = [:]
        for surface in [true, false] {
            let f = try F.inputs(m, r.project, maskToSurface: surface)
            let pass = try FlexibleLatticePass(device: try FlexibleLatticeFixtures.device())
            pass.upload(FlexibleLatticeFixtures.layer(f, token: surface ? 7001 : 7002))
            let ref = try XCTUnwrap(pass.referenceInputs)
            pass.printed = true
            let gpuP = try XCTUnwrap(pass.probe(pts))
            pass.printed = false
            let gpu = try XCTUnwrap(pass.probe(pts))
            // NEAR a surface the march can draw (the reference within 1 mm of 0): the bar; everywhere: reported
            var wNear: Float = 0, wAll: Float = 0, nNear = 0
            for (i, pt) in pts.enumerated() {
                for (g, sw) in [(gpuP[i], FlexibleLatticeField.lattice(at: pt, ref, printed: true)), (gpu[i], FlexibleLatticeField.lattice(at: pt, ref))] {
                    let e = abs(g - sw)
                    wAll = max(wAll, e)
                    if abs(sw) < 1 { wNear = max(wNear, e); nNear += 1 }
                }
            }
            near[surface] = wNear; all[surface] = wAll
            lines.append("\(surface ? "fix" : "control (today)"): max |gpu − swift| near a surface \(wNear) mm (\(nNear) samples, printed + X-ray), anywhere \(wAll) mm; the printed field at (95, 50, 19.9): gpu \(gpuP.last!) swift \(FlexibleLatticeField.lattice(at: Self.probe, ref, printed: true))")
        }
        print("FLEX-TL-T4 his Balanced pad, \(pts.count) points (3000 in the top band):\n  " + lines.joined(separator: "\n  "))
        XCTAssertLessThanOrEqual(near[true] ?? 1, FlexibleLatticePassTests.parityMM, "★ the twins agree on his pad wherever a surface can be drawn")
        // anywhere (far outside the part, where the half-float SDF of a value of several mm rounds): no worse than today
        XCTAssertLessThanOrEqual(all[true] ?? 1, (all[false] ?? 0) + 1e-4, "the fix adds no disagreement anywhere")
    }
    #endif

    /// Deterministic points in a box (an LCG).
    static func points(_ count: Int, lo: SIMD3<Float>, hi: SIMD3<Float>, seed: UInt64 = 0x7_0_9_1A7E4) -> [SIMD3<Float>] {
        var s = seed
        func next() -> Float { s = s &* 6364136223846793005 &+ 1442695040888963407; return Float(s >> 40) / Float(1 << 24) }
        return (0..<count).map { _ in lo + (hi - lo) * SIMD3(next(), next(), next()) }
    }
}

#if canImport(MetalKit) && canImport(AppKit)
import AppKit
import MetalKit
import TopOptDesign

/// img_top_3's camera (his main Lattice page, 2026-10-18 15:07: the pad from the front-right corner, the Top in view).
let flexTopLayerCam = FlexibleRound6Tests.Cam(name: "img_top_3", azimuth: .pi / 4, elevation: 0.62, zoom: 1)

@MainActor
final class FlexibleTopLayerHostedTests: XCTestCase {
    typealias F = FlexibleTopLayerFixtures
    struct Frame { let px: [UInt8]; let n: Int }

    func frame(_ s: FlexibleMainStage, _ p: ProjectModel, cam: FlexibleRound6Tests.Cam, n: Int, layer: FlexibleLatticeLayerInputs?,
               device: MTLDevice) throws -> Frame {
        let settle = p.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let mr = try FlexibleRound6EvidenceProbe().renderer(
            mesh: try XCTUnwrap(s.mesh(p, on: .lattice)), tints: s.tints(p, on: .lattice, roles: [:], stress: nil),
            dents: s.dents(p, on: .lattice), scale: s.dentScale(p, on: .lattice), bodyAlpha: s.bodyAlpha(p, on: .lattice) ?? 1,
            settle: settle, cam: cam, device: device, items: [], layer: layer)
        let bg = DS.Color.background
        return Frame(px: try XCTUnwrap(mr.renderOffscreen(size: n, clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1))), n: n)
    }

    func projection(_ s: FlexibleMainStage, _ p: ProjectModel, cam: FlexibleRound6Tests.Cam, n: Int, device: MTLDevice) throws -> CameraProjection {
        let settle = p.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let mr = try FlexibleRound6EvidenceProbe().renderer(mesh: try XCTUnwrap(s.mesh(p, on: .lattice)), tints: nil, dents: nil, scale: 0,
                                                            bodyAlpha: 1, settle: settle, cam: cam, device: device, items: [])
        return CameraProjection(viewProjection: mr.clipFromModel(aspect: 1), viewportSize: CGSize(width: n, height: n))
    }

    /// Opt-in (FLEX_TL_DUMP=<dir>): a frame as a PNG.
    static func dump(_ f: Frame, _ name: String) {
        guard let d = ProcessInfo.processInfo.environment["FLEX_TL_DUMP"] else { return }
        var rgba = f.px
        for i in stride(from: 0, to: rgba.count, by: 4) { rgba.swapAt(i, i + 2); rgba[i + 3] = 255 }
        guard let ctx = CGContext(data: &rgba, width: f.n, height: f.n, bitsPerComponent: 8, bytesPerRow: f.n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let img = ctx.makeImage() else { return }
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: d).appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }

    // MARK: - T5: the shipping renderer, his pad at Balanced, Finish None, img_top_3's camera — before / after

    func testHisTopOverThePocketsRendersOpen() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let (r, s, m) = try await F.hisLivePad(self)
        let p = r.project
        XCTAssertEqual(m.settings.finishMode, .none, "premise: Finish None")
        XCTAssertFalse(s.xrayOn, "premise: the default view (X-ray off)")
        XCTAssertTrue(s.printedView, "premise: the printed view")
        let control = try F.inputs(m, p, maskToSurface: false)
        let plan = F.plan(control, step: 1)
        var lines: [String] = []
        for (cam, n) in [(flexTopLayerCam, 900), (flexTopLayerCam, 1600)] {
            let after = try XCTUnwrap(s.layer(p, stage: .lattice, pageUp: false))
            var before = after
            before.lattice = control
            before.token += 1_000_000
            let fa = try frame(s, p, cam: cam, n: n, layer: after, device: device)
            let fb = try frame(s, p, cam: cam, n: n, layer: before, device: device)
            Self.dump(fa, "T5_\(cam.name)_\(n)_after.png")
            Self.dump(fb, "T5_\(cam.name)_\(n)_before.png")
            // the Top's pixels over the pockets and over the middle (the plan's points at z = 20, projected; a pixel of each)
            let proj = try projection(s, p, cam: cam, n: n, device: device)
            func pixels(_ pts: [SIMD2<Float>]) -> Set<Int> {
                var out = Set<Int>()
                for q in pts {
                    guard let c = proj.project(SIMD3(q.x, q.y, 20)) else { continue }
                    let x = Int(c.x.rounded(.down)), y = Int(c.y.rounded(.down))
                    if x >= 0, y >= 0, x < n, y < n { out.insert(y * n + x) }
                }
                return out
            }
            let pocket = pixels(plan.pocket), middle = pixels(plan.solid)
            let dPocket = pocket.filter { FlexibleR7X1HostedTests.deltaE(fa.px, fb.px, $0) > 3 }.count
            let dMiddle = middle.filter { FlexibleR7X1HostedTests.deltaE(fa.px, fb.px, $0) > 3 }.count
            let sPocket = Double(dPocket) / Double(max(1, pocket.count)), sMiddle = Double(dMiddle) / Double(max(1, middle.count))
            lines.append("\(cam.name) n \(n): the Top over the pockets \(String(format: "%.1f", 100 * sPocket)) % of \(pocket.count) px changed (the sheet → the walls and the voids) · the middle \(String(format: "%.2f", 100 * sMiddle)) % of \(middle.count) px changed")
            XCTAssertGreaterThan(pocket.count, 500, "premise: the pockets' Top is on screen")
            XCTAssertGreaterThan(middle.count, 500, "premise: the middle is on screen")
            XCTAssertGreaterThanOrEqual(sPocket, 0.40, "★ \(cam.name) n \(n): the Top over the pockets opens (the sheet is gone)")
            XCTAssertLessThanOrEqual(sMiddle, 0.02, "★ \(cam.name) n \(n): the middle of the Top stays the solid it was")
        }
        // X-ray (reported, and written for looking): the walls now reach the Top instead of stopping 0.21 mm under it — T1 pins
        // it in numbers
        s.xrayOn = true
        let xa = try XCTUnwrap(s.layer(p, stage: .lattice, pageUp: false))
        var xb = xa
        xb.lattice = control
        xb.token += 1_000_000
        let fxa = try frame(s, p, cam: flexTopLayerCam, n: 1600, layer: xa, device: device)
        let fxb = try frame(s, p, cam: flexTopLayerCam, n: 1600, layer: xb, device: device)
        s.xrayOn = false
        Self.dump(fxa, "T5_xray_1600_after.png")
        Self.dump(fxb, "T5_xray_1600_before.png")
        let changed = (0..<(1600 * 1600)).filter { FlexibleR7X1HostedTests.deltaE(fxa.px, fxb.px, $0) > 3 }.count
        lines.append("X-ray n 1600: \(changed) px changed (\(String(format: "%.2f", 100 * Double(changed) / (1600.0 * 1600.0))) % of the frame)")
        print("FLEX-TL-T5 his Balanced pad, Finish None, Heat off, X-ray off (before = the mask as core gives it):\n  " + lines.joined(separator: "\n  "))
    }
}
#endif
