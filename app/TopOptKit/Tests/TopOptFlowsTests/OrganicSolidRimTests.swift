import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★★ GRADE TO SOLID (his instruction, 2026-09-07: "Build the grade to solid").
///
/// Core's grade-to-solid for a TRACED lattice is exactly one thing: the rim.
/// `grade_lattice`'s cells-per-member refusal — the rule that turns an octet voxel
/// solid — is explicitly skipped for organic, and organic's own spacing floors RAISE
/// the separation rather than solidifying anything. So `apply_organic_solid_rim` is the
/// whole of it, and this pins the mirror against core's arithmetic.
final class OrganicSolidRimTests: XCTestCase {

    /// A slab of candidates inside a solid block, one region, normal +Y.
    /// Sides are ±X and ±Z; ±Y is along the normal and must never be rimmed.
    private func fixture(nx: Int = 9, ny: Int = 3, nz: Int = 9)
        -> (cand: [Bool], solid: [Bool], rid: [Int32]) {
        let n = nx * ny * nz
        var cand = [Bool](repeating: false, count: n)
        var solid = [Bool](repeating: true, count: n)      // all material
        var rid = [Int32](repeating: 0, count: n)
        for k in 2..<(nz - 2) { for j in 0..<ny { for i in 2..<(nx - 2) {
            let e = (k * ny + j) * nx + i
            cand[e] = true; rid[e] = 1
        } } }
        _ = solid
        return (cand, solid, rid)
    }

    func testTheRimIsASideBandAndNeverRunsAlongTheNormal() {
        let (nx, ny, nz) = (9, 3, 9)
        let f = fixture()
        let rim = OrganicSolidRim.voxels(
            candidate: f.cand, solid: f.solid, regionID: f.rid,
            normals: [SIMD3<Double>(0, 1, 0)], nx: nx, ny: ny, nz: nz,
            voxelMM: 1.0, rimMM: 1.0)
        XCTAssertFalse(rim.isEmpty, "★ a band is created")
        let set = Set(rim)
        func at(_ i: Int, _ j: Int, _ k: Int) -> Int { (k * ny + j) * nx + i }
        // the candidate slab runs x,z in 2…6 — its side ring is rimmed
        XCTAssertTrue(set.contains(at(2, 1, 4)), "★ the -X side is solid")
        XCTAssertTrue(set.contains(at(6, 1, 4)), "★ the +X side is solid")
        XCTAssertTrue(set.contains(at(4, 1, 2)), "★ the -Z side is solid")
        XCTAssertFalse(set.contains(at(4, 1, 4)), "the middle stays lattice")
        // ±Y is the region normal — the floor and the open face — and is never rimmed,
        // so a voxel in the middle of the slab's TOP layer is untouched.
        XCTAssertFalse(set.contains(at(4, 0, 4)), "★ never along the normal")
        XCTAssertFalse(set.contains(at(4, 2, 4)), "★ never along the normal")
    }

    /// The band's width is `floor(rim / voxel)` steps, exactly as core counts them.
    func testTheBandWidthIsCoresStepCount() {
        let (nx, ny, nz) = (9, 3, 9)
        let f = fixture()
        func width(_ rimMM: Double, _ voxelMM: Double) -> Int {
            OrganicSolidRim.voxels(candidate: f.cand, solid: f.solid, regionID: f.rid,
                                   normals: [SIMD3<Double>(0, 1, 0)],
                                   nx: nx, ny: ny, nz: nz,
                                   voxelMM: voxelMM, rimMM: rimMM).count
        }
        let one = width(1.0, 1.0)       // floor(1/1) = 1 step  → the ring, plus one in
        let none = width(0.9, 1.0)      // floor(0.9/1) = 0     → the ring only
        let two = width(2.0, 1.0)       // floor(2/1) = 2 steps → two rings in
        XCTAssertGreaterThan(one, none, "a wider rim solidifies more")
        XCTAssertGreaterThan(two, one)
        XCTAssertEqual(width(0, 1), 0, "no rim, no band")
        XCTAssertEqual(width(1, 0), 0, "no grid, no band")
    }

    /// A voxel whose only non-lattice neighbour is AIR is on the open face, not a wall.
    /// ★★★ REVERSED ON HIS INSTRUCTION, 2026-09-08: "Get the rim on ALL outlined
    /// faces." This used to assert the opposite — that an edge whose neighbour is AIR
    /// takes no rim, which is core's own rule in `apply_organic_solid_rim` and which I
    /// had mirrored. It is right for a side cut into a wall and wrong for every edge
    /// where the region runs out at the part's own surface: that edge is as much the
    /// outline as the sides are, the lattice ends there, and it is exactly where he
    /// expects a wall. His bottom edge was getting nothing.
    ///
    /// The one direction still exempt is the face NORMAL — the prism's front and back
    /// are open by design and walling them would hide the lattice — and that is what
    /// this now pins.
    func testTheOutlineTakesTheRimEvenWhereItMeetsAir() {
        let (nx, ny, nz) = (9, 3, 9)
        var f = fixture()
        // take the material away on -X: that side is now air, and it is still outline
        for k in 0..<nz { for j in 0..<ny { for i in 0..<2 {
            f.solid[(k * ny + j) * nx + i] = false
        } } }
        let set = Set(OrganicSolidRim.voxels(
            candidate: f.cand, solid: f.solid, regionID: f.rid,
            normals: [SIMD3<Double>(0, 1, 0)], nx: nx, ny: ny, nz: nz,
            voxelMM: 1.0, rimMM: 1.0))
        func at(_ i: Int, _ j: Int, _ k: Int) -> Int { (k * ny + j) * nx + i }
        XCTAssertTrue(set.contains(at(2, 1, 4)),
                      "★ an outline edge takes the rim whether solid or air lies beyond")
        XCTAssertTrue(set.contains(at(6, 1, 4)), "…and so does the +X wall")
        // ★ AND THE NORMAL IS STILL EXEMPT, asserted on its own fixture rather than
        // hoped for. One candidate voxel, entirely surrounded in-plane by more
        // candidates, whose ONLY non-candidate neighbours lie along ±Y — the region's
        // normal, the prism's front and back. It must take no rim: walling those would
        // hide the lattice behind its own outline.
        let (mx, my, mz) = (3, 3, 3)
        var cand = [Bool](repeating: false, count: mx * my * mz)
        var solid = [Bool](repeating: true, count: mx * my * mz)
        var rid = [Int32](repeating: 1, count: mx * my * mz)
        // the whole middle Y-slab is lattice, so in-plane every neighbour is lattice
        for k in 0..<mz { for i in 0..<mx {
            let e = (k * my + 1) * mx + i
            cand[e] = true; solid[e] = false
        } }
        _ = rid
        let normalOnly = OrganicSolidRim.voxels(
            candidate: cand, solid: solid, regionID: rid,
            normals: [SIMD3<Double>(0, 1, 0)], nx: mx, ny: my, nz: mz,
            voxelMM: 1.0, rimMM: 1.0)
        XCTAssertFalse(normalOnly.contains((1 * my + 1) * mx + 1),
                       "★ the prism's front and back are never walled")
    }

    /// The scene removes the band from the traced set and the shell keeps it, and the
    /// two agree about where the lattice stops.
    func testTheSceneStopsTracingInTheBandAndTheShellKeepsIt() throws {
        let sdf = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TopOptFlows/LatticeSDFMetal.swift"), encoding: .utf8)
        // ★★★ REVERSED 2026-09-08, on his instruction. The band used to be DELETED from
        // the candidate set, and that deletion is what left the gap he photographed:
        // "The struts are not continuing INTO the solid rim. Currently you are cutting
        // out WHOLE cells. don't do that." The band stays a candidate, the curves run
        // through it into the solid, and the wall is drawn over them.
        XCTAssertTrue(sdf.contains("solidRimVoxels = rim.count"),
                      "★ the band is COUNTED, never deleted")
        XCTAssertFalse(sdf.contains("for e in rim where cand[e] { cand[e] = false"),
                       "★ no cell is cut out of the candidate set for the rim")
        // ★ And the drawn band is the millimetres asked for. Rounding it up to a whole
        // design voxel drew ~1.6 mm for a 0.42 mm bead on his part — "the rim looks way
        // too big?" It was.
        XCTAssertTrue(sdf.contains("let band = o.solidRimMM"),
                      "★ the shell's band is the stated rim, not a voxel multiple")
        XCTAssertTrue(sdf.contains("e.inPlaneOffsetMM -= band"),
                      "★ …and the region field excludes it, so the wall draws solid there")
    }

    // MARK: the sample cube — edges, never faces

    /// ★ A block has no outline, so its EDGES take the band: a voxel seeds only when it
    /// is open on two DIFFERENT axes. A voxel in the middle of a face is open on one and
    /// is left alone, so every face still sees through to the lattice.
    func testTheCubeGetsTwelveBarsAndItsFacesStayOpen() {
        let n = 9
        var cand = [Bool](repeating: false, count: n * n * n)
        for k in 1..<(n - 1) { for j in 1..<(n - 1) { for i in 1..<(n - 1) {
            cand[(k * n + j) * n + i] = true
        } } }
        func at(_ i: Int, _ j: Int, _ k: Int) -> Int { (k * n + j) * n + i }
        let set = Set(OrganicSolidRim.edgeVoxels(candidate: cand, nx: n, ny: n, nz: n,
                                                 voxelMM: 1.0, rimMM: 0.5))
        XCTAssertFalse(set.isEmpty)
        // a corner of the block is open on three axes — solid
        XCTAssertTrue(set.contains(at(1, 1, 1)), "★ the corner is a bar")
        // an edge (open on two axes) — solid
        XCTAssertTrue(set.contains(at(1, 1, 4)), "★ the edge is a bar")
        // the MIDDLE OF A FACE is open on one axis only — it must stay lattice
        XCTAssertFalse(set.contains(at(1, 4, 4)), "★ a face is never walled in")
        XCTAssertFalse(set.contains(at(4, 1, 4)), "★ …on any axis")
        XCTAssertFalse(set.contains(at(4, 4, 1)))
        // and the interior is untouched
        XCTAssertFalse(set.contains(at(4, 4, 4)))
        // no rim, no bars
        XCTAssertTrue(OrganicSolidRim.edgeVoxels(candidate: cand, nx: n, ny: n, nz: n,
                                                 voxelMM: 1.0, rimMM: 0).isEmpty)
    }

    /// The sample carries the rim, and a sample WITHOUT one still finds the variants
    /// this build ships — adding it to the key unconditionally would orphan all four.
    func testTheRimEntersTheCacheKeyOnlyWhenThereIsOne() {
        var s = LatticeSettings(enabled: true)
        s.algorithm = "organic"
        // ★ THE SAMPLE'S DEFAULT RIM IS THE BEAD (2026-09-07): an outline at the block's
        // edges one strut wide, which is what the run applies and what he asked to see.
        var withRim = OrganicSampleCube.Picks(settings: s, layerHeightMM: 0.2)
        // ★ THE PRINTABILITY FLOOR (his ruling, 2026-09-08), not the bead: on the cube
        // that is `max(1.535 × 0.42, 20/64)` = 0.645 mm, the bead term binding because
        // the cube's grid is fine. Below it the grade cannot thin, so that band is solid.
        let cubeFloor = OrganicSizeCheck.floor(beadMM: OrganicSampleCube.printedBeadMM,
                                               voxelMM: OrganicSampleCube.edgeMM / 64).mm
        XCTAssertEqual(withRim.solidRimMM, cubeFloor, accuracy: 1e-9,
                       "Auto: the outline is the printability floor")
        let shipped = OrganicVariantCache.key(picks: withRim, fieldIdentity: OrganicSampleCube.fieldIdentity)
        var rimless = withRim
        rimless.solidRimMM = 0
        XCTAssertNotEqual(OrganicVariantCache.key(picks: rimless, fieldIdentity: OrganicSampleCube.fieldIdentity),
                          shipped, "★ a rim is a different topology")
        var wider = withRim
        wider.solidRimMM = 2
        XCTAssertNotEqual(OrganicVariantCache.key(picks: wider, fieldIdentity: OrganicSampleCube.fieldIdentity),
                          shipped, "★ …and so is a wider one")
        // ★ AND THE STATED STRUT DOES NOT MOVE IT. Thicker is a live radius on the
        // renderer; letting the rim read it would make it a topology change and re-trace
        // the sample on every drag.
        s.organicStrutWidthMM = 0.9
        XCTAssertEqual(OrganicSampleCube.Picks(settings: s, layerHeightMM: 0.2).solidRimMM,
                       cubeFloor, accuracy: 1e-9)
    }

    /// Under Auto the rim exists because the Look slider's window supplies `cell_min`.
    func testAutoHasARimOnceTheLookWindowIsPicked() throws {
        let ws = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TopOptFlows/WorkspacePlaceholder.swift"), encoding: .utf8)
        XCTAssertTrue(ws.contains("OrganicAutoWindow.window(percent: organicLookPercent, band: band)"),
                      "★ the Look slider picks the Auto window")
        // ★ AND THE RIM IS ONE STRUT, NOT ONE CELL (2026-09-07). The window's low end
        // was the huge hard-edged band; see `testTheRimIsAStrutWideOutlineAndTheJobCarriesIt`.
        XCTAssertTrue(ws.contains("o.solidRimMM = Swift.max(0, organicRimSetting)"),
                      "★ one rule for every mode, and it is not the window")
        // A stated rim still wins, and 0 still means none.
        var l = LatticeSettings(enabled: true)
        l.algorithm = "organic"
        l.organicSolidRimMM = 1.25
        XCTAssertEqual(l.organicRunSolidRimMM(floorMM: 0.42), 1.25)
        l.organicSolidRimMM = 0
        XCTAssertEqual(l.organicRunSolidRimMM(floorMM: 0.42), 0)
    }
}
