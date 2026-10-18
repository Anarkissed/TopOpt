// FlexibleR7E1FollowUpTests — round 7, batch R7-E1, the three follow-ups that ride with the edge/corner flat prism:
//
//  (1) HIS ANSWER of 2026-10-18 ~15:50 (chat, binding): "On a Lattice group, Protect is LOCKED ON while any face of the group is
//      Lattice (a lattice can never be exposed to Topology)." — the B1 chip's role line (Flexible code only): Protect on a group
//      that reads Lattice cannot be tapped off; the tap writes nothing and says one line. RED CONTROL:
//      `FlexibleFaceCommits.controlProtectUnlocked` (the toggle before his answer: the group goes Pending).
//  (2) THE TOP-LID FIX'S CHECK (0d8ae925): the mask-to-surface fill (FlexibleLatticeBuilder.inputs) also adds an outside voxel
//      at an INSIDE corner whose other face-neighbour is SOLID and not lattice — the mask then crosses ½ inside that solid and
//      cuts a groove (up to half a voxel) into an UNSELECTED wall. Such a voxel is skipped now. Judged on a synthetic L-shaped
//      part (the lattice in one arm under the notch face, the other arm unselected) and on HIS live Balanced pad (unchanged).
//      RED CONTROL: `cornerRule: false` — the fill as 0d8ae925 made it.
//  (3) THE SAME CHECK: the (i) decides "outside the part" with CORE's own rule (the voxels the fill added — core's +Z winding
//      rule, coreEncloses), like the mask, not the app's voxel-made SDF. RED CONTROL: `outsideBySDF: true` (0d8ae925's rule).
//
// Written BEFORE the code, against stubs (the red run: round7/batch_e1/e1a_red_run.txt).
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleR7E1FollowUpTests: XCTestCase {

    override func tearDown() {
        FlexibleFaceCommits.controlProtectUnlocked = false
        super.tearDown()
    }

    // MARK: - (1) Protect is locked on while a face is Lattice

    /// His pad + his live lattice (Group C = Face 3 + Face 5: Protect + Lattice, 25 mm).
    func hisPad() throws -> (FlexibleHisProject.Restored, ProjectModel, UUID) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let c = try FlexibleR7M1Fixtures.hisLiveLattice(r.project)
        r.project.seedUndoBaseline()
        return (r, r.project, c)
    }

    /// What tapping [Protect] on Group C's role line must do while a face is Lattice, as a list of what is wrong (empty =
    /// right) — so the red control runs the very same check.
    func protectTapOnALatticeGroup() throws -> [String] {
        let (_, p, c) = try hisPad()
        var wrong: [String] = []
        if !FlexibleFaceCommits.readsLattice(c, p) { wrong.append("premise: Group C does not read Lattice") }
        let before = p.editSnapshot, past = p.undo.past.count
        let answer = FlexibleFaceCommits.setRole(.protect, group: c, project: p)
        if answer != .locked { wrong.append("the tap answered \(answer), not .locked") }
        if !p.force.isProtected(c) { wrong.append("Protect went OFF (the lattice is exposed to Topology)") }
        if p.editSnapshot != before { wrong.append("the tap wrote something") }
        if p.undo.past.count != past { wrong.append("the tap added an undo step") }
        if !FlexibleFaceCommits.protectLocked(c, p) { wrong.append("protectLocked is false on a Lattice group") }
        return wrong
    }

    func testProtectIsLockedOnWhileAnyFaceOfTheGroupIsLattice() throws {
        let wrong = try protectTapOnALatticeGroup()
        XCTAssertEqual(wrong, [], "★ Protect stays on while a face of the group is Lattice: \(wrong)")
        XCTAssertLessThanOrEqual(FlexibleSelectionsCopy.protectLocked.count, 44, "one line")
        XCTAssertEqual(FlexibleSelectionsCopy.protectLocked, "Protect stays on while a face is Lattice")

        // once no face is Lattice any more, Protect toggles again (it is the group's own choice)
        let (_, p, c) = try hisPad()
        FlexibleFaceCommits.setAll(.off, group: c, project: p)
        XCTAssertFalse(FlexibleFaceCommits.protectLocked(c, p), "no Lattice face: not locked")
        XCTAssertEqual(FlexibleFaceCommits.setRole(.protect, group: c, project: p), .done)
        XCTAssertFalse(p.force.isProtected(c), "Protect toggles off when no face is Lattice")
        XCTAssertEqual(FlexibleFaceCommits.setRole(.protect, group: c, project: p), .done)
        XCTAssertTrue(p.force.isProtected(c))
        // a Solid face is no lattice: still unlocked
        FlexibleFaceCommits.setState(.exclude, ref: .face(group: c, face: 3), group: c, project: p)
        XCTAssertFalse(FlexibleFaceCommits.protectLocked(c, p), "a Solid face does not lock Protect")
        // Lattice again: locked again
        FlexibleFaceCommits.setState(.include, ref: .face(group: c, face: 3), group: c, project: p)
        XCTAssertTrue(FlexibleFaceCommits.protectLocked(c, p), "★ a Lattice face locks Protect on")
        // a Load group with a Lattice face is not a "Lattice group" (its Protect is off; turning it on is always allowed)
        let top = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" })
        XCTAssertFalse(FlexibleFaceCommits.protectLocked(top.id, p), "the Top (a Load) is not locked")

        // ★ RED CONTROL: the toggle before his answer — the same check fails (Protect goes off, the group goes Pending)
        FlexibleFaceCommits.controlProtectUnlocked = true
        let control = try protectTapOnALatticeGroup()
        print("FLEX-E1-PL control (Protect unlocked): \(control)")
        XCTAssertTrue(control.contains("Protect went OFF (the lattice is exposed to Topology)"), "★ RED CONTROL: \(control)")
    }

    // MARK: - (2) an inside corner keeps the unselected wall solid

    /// A synthetic L, extruded 0…20 mm: outline (0,0) (40,0) (40,20) (20,20) (20,40) (0,40) — the +X arm (x > 20, y < 20) and
    /// the +Y arm (x < 20, y > 20) meet at the INSIDE corner (20, 20). Outward winding, faces 0 bottom, 1 top, 2…7 the sides.
    static func lMesh() -> ViewerMesh {
        let o: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(40, 0), SIMD2(40, 20), SIMD2(20, 20), SIMD2(20, 40), SIMD2(0, 40)]
        var v: [Float] = [], idx: [Int32] = [], ids: [Int32] = []
        func vert(_ p: SIMD2<Float>, _ z: Float) -> Int32 { v += [p.x, p.y, z]; return Int32(v.count / 3 - 1) }
        let caps: [(Int, Int, Int)] = [(0, 1, 2), (0, 2, 3), (0, 3, 4), (0, 4, 5)]   // the L, fanned from (0,0): all inside it
        for (a, b, c) in caps {
            let a0 = vert(o[a], 0), b0 = vert(o[b], 0), c0 = vert(o[c], 0)
            idx += [a0, c0, b0]; ids.append(0)                    // bottom, −Z
            let a1 = vert(o[a], 20), b1 = vert(o[b], 20), c1 = vert(o[c], 20)
            idx += [a1, b1, c1]; ids.append(1)                    // top, +Z
        }
        for i in 0..<o.count {
            let a = o[i], b = o[(i + 1) % o.count]
            let a0 = vert(a, 0), b0 = vert(b, 0), b1 = vert(b, 20), a1 = vert(a, 20)
            idx += [a0, b0, b1, a0, b1, a1]; ids += [Int32(2 + i), Int32(2 + i)]
        }
        return ViewerMesh(vertices: v, indices: idx, faceIDs: ids)
    }

    /// Core's grid over the L as core makes it at Balanced-like spacing (h = 40/38.4: the notch faces sit 0.2 voxel past a
    /// centre, as his pad's Top does), origin at the bounding box's corner. The lattice: the +X arm's voxels within 8 mm under
    /// the notch face y = 20 (a face-prism there), ρ 0.2; every other voxel −1 (solid inside, empty outside — core's field
    /// carries no lattice there either way).
    static func lField() -> FlexDensityField {
        let h = 40.0 / 38.4
        let nx = 39, ny = 39, nz = 20
        var d = [Float](repeating: -1, count: nx * ny * nz)
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx {
            let x = (Double(i) + 0.5) * h, y = (Double(j) + 0.5) * h, z = (Double(k) + 0.5) * h
            if x > 20, y < 20, y > 12, z < 20 { d[(k * ny + j) * nx + i] = 0.2 }
        } } }
        return FlexDensityField(nx: nx, ny: ny, nz: nz, spacing: h, origin: .zero, density: d,
                                owner: [Int](repeating: -1, count: nx * ny * nz))
    }

    static func lInputs(cornerRule: Bool, maskToSurface: Bool = true) throws -> FlexibleLatticeInputs {
        try FlexibleLatticeBuilder.inputs(field: lField(), part: lMesh(), topology: "gyroid", beadsPerWall: 1, beadWidthMM: 0.45,
                                          buildDir: SIMD3(0, 0, 1), skinOffFaces: [], finish: .none,
                                          maskToSurface: maskToSurface, cornerRule: cornerRule)
    }

    /// Points of the UNSELECTED +Y arm's wall within one voxel of the inside corner: x ∈ (20 − h, 20), y ∈ (20, 20 + h),
    /// z ∈ (2, 18) (off the top and bottom), every 0.05 mm in x and y, 1 mm in z — all inside the part, none in a face-prism.
    static func cornerWall() -> [SIMD3<Float>] {
        let h = Float(40.0 / 38.4)
        var out: [SIMD3<Float>] = []
        var z: Float = 2.5
        while z < 18 {
            var y: Float = 20.025
            while y < 20 + h {
                var x: Float = 20 - h + 0.025
                while x < 20 { out.append(SIMD3(x, y, z)); x += 0.05 }
                y += 0.05
            }
            z += 1
        }
        return out
    }

    /// How many of `pts` the lattice region claims (mask ≥ ½: open, walls drawn — with Finish None nothing keeps it solid).
    static func claimed(_ f: FlexibleLatticeInputs, _ pts: [SIMD3<Float>]) -> Int {
        pts.filter { FlexibleLatticeField.dRegion($0, f) < 0 }.count
    }

    func testAnInsideCornerKeepsTheUnselectedWallSolid() throws {
        let pts = Self.cornerWall()
        let fix = try Self.lInputs(cornerRule: true)
        let control = try Self.lInputs(cornerRule: false)          // the fill as 0d8ae925 made it
        let core = try Self.lInputs(cornerRule: true, maskToSurface: false)   // the mask as core gives it
        let mesh = Self.lMesh(), field = Self.lField()
        // premise: every sample is inside the part by core's own rule, and in the unselected arm
        let inside = pts.allSatisfy { p in p.x < 20 && p.y > 20 && p.y < 40 && p.z > 0 && p.z < 20 }
        XCTAssertTrue(inside, "premise: the samples lie in the +Y arm's wall")
        let nFix = Self.claimed(fix, pts), nControl = Self.claimed(control, pts), nCore = Self.claimed(core, pts)
        print("FLEX-E1-CR the L's inside corner, the unselected wall within one voxel (\(pts.count) points): claimed by the region — "
              + "fix \(nFix) · control (0d8ae925's fill) \(nControl) · core's own mask \(nCore)")
        XCTAssertGreaterThan(nControl, 0, "★ RED CONTROL: 0d8ae925's fill cuts a groove into the unselected wall at the inside corner")
        XCTAssertEqual(nFix, 0, "★ the unselected wall stays solid at the inside corner")
        XCTAssertEqual(nCore, 0, "premise: core's own mask claims none of it")
        // the notch face away from the corner still opens to the surface (the top-lid fix kept): x = 30, 0.1 mm under y = 20
        let open = SIMD3<Float>(30, 19.9, 10)
        XCTAssertLessThan(FlexibleLatticeField.dRegion(open, fix), 0, "★ the lattice still reaches the notch face away from the corner")
        XCTAssertGreaterThan(FlexibleLatticeField.dRegion(open, core), 0, "premise: core's mask alone stops short of it")
        // what is skipped: only voxels with a solid, non-lattice face-neighbour — counted, each one outside by core's rule
        let added = fix.coreOutside, addedControl = control.coreOutside
        print("FLEX-E1-CR voxels the fill adds: fix \(added.count) · control \(addedControl.count) · skipped \(addedControl.subtracting(added).count)")
        XCTAssertTrue(added.isSubset(of: addedControl), "the corner rule only skips")
        XCTAssertFalse(addedControl.subtracting(added).isEmpty, "it skips the corner's voxels")
        let insideFlags = FlexibleLatticeBuilder.coreEncloses(Array(addedControl), part: mesh, nx: field.nx, ny: field.ny,
                                                              origin: field.origin, h: field.spacing)
        XCTAssertFalse(insideFlags.contains(true), "every added voxel's centre is outside the part by core's rule")
        for v in addedControl.subtracting(added) {
            let i = v % field.nx, j = (v / field.nx) % field.ny
            let x = (Double(i) + 0.5) * field.spacing, y = (Double(j) + 0.5) * field.spacing
            XCTAssertTrue(x > 20 && x < 20 + field.spacing && y > 20 && y < 20 + field.spacing,
                          "a skipped voxel sits at the inside corner (centre \(x), \(y))")
        }
    }

    /// His live Balanced pad: the corner rule changes nothing (no added voxel there has a solid, non-lattice face-neighbour).
    func testHisLivePadIsUnchangedByTheCornerRule() async throws {
        let (r, _, m) = try await FlexibleTopLayerFixtures.hisLivePad(self)
        let p = r.project
        let field = try XCTUnwrap(m.lastCombinedField)
        let part = try XCTUnwrap(p.viewerMesh)
        let b = m.build
        func inputs(_ corner: Bool) throws -> FlexibleLatticeInputs {
            try FlexibleLatticeBuilder.inputs(field: field, part: part, topology: b.topology, beadsPerWall: b.beadsPerWall,
                                              beadWidthMM: b.beadWidthMM, buildDir: m.sceneInfo?.buildDir ?? SIMD3(0, 0, 1),
                                              skinOffFaces: [], finish: m.settings.finishMode, cornerRule: corner)
        }
        let fix = try inputs(true), control = try inputs(false)
        print("FLEX-E1-CR his live Balanced pad: added \(fix.coreOutside.count) (control \(control.coreOutside.count)) · mask identical \(fix.mask == control.mask) · ρ identical \(fix.rho == control.rho)")
        XCTAssertEqual(fix, control, "★ his pad: the inputs are byte-identical under the corner rule")
        XCTAssertEqual(fix.coreOutside.count, 4604, "★ the top-lid fix's 4 604 voxels, each one outside by core's rule")
        XCTAssertEqual(try XCTUnwrap(m.lattice).inputs, fix, "the stage built exactly these")
        await m.waitForIdle()
    }

    // MARK: - (3) the (i) decides "outside" by core's own rule

    /// A 40 × 40 × 20 block, the mask on everywhere, ρ 0.15 below z = 15 and 0.5 above. The face's prism: the top of the
    /// x < 20 half, 10 mm deep.
    func block(sdfOutsideTop: Bool, coreOutsideTop: Bool) -> FlexibleLatticeInputs {
        let n = (x: 40, y: 40, z: 20)
        var rho = [Float](repeating: 0.15, count: n.x * n.y * n.z), sdf = rho
        var outside = Set<Int>()
        for k in 0..<n.z { for j in 0..<n.y { for i in 0..<n.x {
            let v = (k * n.y + j) * n.x + i
            if k >= 15 {
                rho[v] = 0.5
                sdf[v] = sdfOutsideTop ? 1 : -1
                if coreOutsideTop { outside.insert(v) }
            } else { sdf[v] = -1 }
        } } }
        let c0 = SIMD3<Float>(0.5, 0.5, 0.5)
        let grid = FlexGrid(nx: n.x, ny: n.y, nz: n.z, c0: c0, spacing: 1, values: rho)
        var f = FlexibleLatticeInputs(topology: .gyroid, wallMM: 0.42, lMinMM: 1.4, lMaxMM: 25, honeycombCellMM: 4,
                                      buildDir: SIMD3(0, 0, 1), skinMM: 0.8, rho: grid,
                                      mask: FlexGrid(nx: n.x, ny: n.y, nz: n.z, c0: c0, spacing: 1, values: [Float](repeating: 1, count: rho.count)),
                                      partSDF: FlexGrid(nx: n.x, ny: n.y, nz: n.z, c0: c0, spacing: 1, values: sdf), skinDist: grid,
                                      boundsMin: .zero, boundsMax: SIMD3(40, 40, 20))
        f.coreOutside = outside
        return f
    }

    func face() -> LatticeRegionSpec {
        var face = LatticeRegionSpec(role: .include, kind: .face)
        face.origin = SIMD3(10, 20, 20); face.normal = SIMD3(0, 0, -1)
        face.halfUMM = 9.9; face.halfWMM = 9.9; face.depthMM = 10
        return face
    }

    func testTheInfoDecidesOutsideByCoresOwnRule() throws {
        // (a) the voxels the fill ADDED (outside by core's rule) where the app's SDF reads inside — not counted
        let added = block(sdfOutsideTop: false, coreOutsideTop: true)
        let a = try XCTUnwrap(FlexibleFaceStats.rows(lattice: added, regions: [face()], depthMM: 10))
        let aSDF = try XCTUnwrap(FlexibleFaceStats.rows(lattice: added, regions: [face()], depthMM: 10, outsideBySDF: true))
        print("FLEX-E1-I (a) added voxels the SDF calls inside: core's rule \(a.rows[1].value) · the SDF's \(aSDF.rows[1].value)")
        XCTAssertEqual(a.rows[1].value, "15%", "★ the voxels core's rule puts outside the part are not the face's lattice")
        XCTAssertEqual(aSDF.rows[1].value, "50%", "★ RED CONTROL: the app's SDF counts them")
        // (b) CORE'S OWN voxels that the voxel-made SDF reads as outside (his pad at Fine: four under the Top's edge) — counted
        let kept = block(sdfOutsideTop: true, coreOutsideTop: false)
        let b = try XCTUnwrap(FlexibleFaceStats.rows(lattice: kept, regions: [face()], depthMM: 10))
        let bSDF = try XCTUnwrap(FlexibleFaceStats.rows(lattice: kept, regions: [face()], depthMM: 10, outsideBySDF: true))
        print("FLEX-E1-I (b) core's voxels the SDF calls outside: core's rule \(b.rows[1].value) · the SDF's \(bSDF.rows[1].value)")
        XCTAssertEqual(b.rows[1].value, "50%", "★ core kept them: they are lattice, and the (i) counts them")
        XCTAssertEqual(bSDF.rows[1].value, "15%", "★ RED CONTROL: the app's SDF drops them")
        // the builder records exactly what it added, each outside by core's rule (the L)
        let l = try Self.lInputs(cornerRule: true)
        XCTAssertFalse(l.coreOutside.isEmpty, "the builder records the voxels it added")
        for v in l.coreOutside { XCTAssertGreaterThanOrEqual(l.mask.values[v], 0.5, "an added voxel is in the mask") }
        let lc = try Self.lInputs(cornerRule: true, maskToSurface: false)
        XCTAssertTrue(lc.coreOutside.isEmpty, "core's mask alone adds nothing")
    }
}
