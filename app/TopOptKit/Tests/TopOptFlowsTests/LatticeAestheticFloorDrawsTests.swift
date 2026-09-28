// LatticeAestheticFloorDrawsTests — ★★★ DOES THE MODE ACTUALLY MOVE THE PICTURE?
// (maintainer, 2026-08-21: "If aesthetic is selected then the floor number of cells can
// go down to 2".)
//
// ★ WHY THIS FILE EXISTS SEPARATELY FROM `LatticeStageModeTests`. That file checks the
// mode's NUMBERS against core's. This one checks that those numbers reach the geometry —
// the failure this branch has now hit three times is a setting that travels the whole way
// and draws nothing (`stressRGB` was always nil; `boundary` reached no shader; the
// prepass library never compiled). A mode that changes a floor nobody applies is the
// same defect wearing a new hat.
//
// ★★ AND THE OTHER HALF IS THE ONE THAT MATTERS MORE: the STRUCTURAL path must not have
// moved. Every bar in `LatticeMemberFloorTests` was measured against the certified floor;
// if wiring the aesthetic floor perturbed the structural bake, the certificate's picture
// changed to ship a cosmetic feature.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

final class LatticeAestheticFloorDrawsTests: XCTestCase {

    /// ABS. Only the ratio matters here, and the fixtures below state their stresses as
    /// fractions of it, so the exact figure never enters an assertion.
    private let allowableMPa = 40.0

    /// A field over the mesh's own box at a constant `fraction` of the allowable.
    private func field(_ mesh: ViewerMesh, fraction: Double) -> StressField {
        let b = mesh.bounds
        let lo = SIMD3<Float>(b.min), hi = SIMD3<Float>(b.max)
        let n = 16
        let span = hi - lo
        let spacing = max(span.x, max(span.y, span.z)) / Float(n - 1)
        return StressField(nx: n, ny: n, nz: n, origin: lo, spacing: spacing,
                           values: [Float](repeating: Float(fraction * allowableMPa),
                                           count: n * n * n))
    }

    /// His own part, with a region deep enough that the members cannot hold an 8 mm cell
    /// under the certified floor — the exact situation the mode was asked for.
    private func scene(mode: LatticeStageMode, field f: StressField?) throws
        -> LatticeSDFScene {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        var region = LatticeRegionFidelityTests.hisSlab(mesh, halfU: 200, halfW: 200)
        region.depthMM = 60
        return LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                               stressField: f, stageMode: mode,
                               allowableMPa: f == nil ? 0 : allowableMPa,
                               regions: [region], whenEmpty: .latticeNothing)
    }

    private func drawn(_ s: LatticeSDFScene, cellMM: Double) -> Int {
        LatticePreviewOccupancy.cellField(
            occupancy: s.occupancy, demand: s.demand, cellMM: cellMM,
            memberThickness: s.memberThicknessMM,
            minCellsPerMember: s.minCellsPerMember,
            cellsPerMemberFloor: s.cellsPerMemberFloorPerVoxel
        ).values.filter { $0 >= 0 }.count
    }

    /// ★★★ THE FEATURE, MEASURED. On an UNLOADED wall the aesthetic floor reaches 2, so
    /// an 8 mm cell needs 16 mm of member instead of 40 — and the preview draws the
    /// lattice the run would now build there.
    func testAestheticDrawsMoreOnAnUnloadedWall() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let quiet = field(mesh, fraction: 0.0)
        let structural = try scene(mode: .structural, field: quiet)
        let aesthetic = try scene(mode: .aesthetic, field: quiet)
        try XCTSkipIf(structural.memberThicknessMM.isEmpty, "core gave no thickness")

        XCTAssertTrue(structural.cellsPerMemberFloorPerVoxel.isEmpty,
                      "★ the structural path must carry NO per-voxel floor at all")
        XCTAssertFalse(aesthetic.cellsPerMemberFloorPerVoxel.isEmpty,
                       "★ the aesthetic floor never reached the scene — the mode would "
                       + "be a setting that travels the whole way and draws nothing")

        let s = drawn(structural, cellMM: 8)
        let a = drawn(aesthetic, cellMM: 8)
        // Positive control: there is material here, and the certified floor is biting.
        let ungated = LatticePreviewOccupancy.cellField(
            occupancy: structural.occupancy, demand: structural.demand, cellMM: 8)
            .values.filter { $0 >= 0 }.count
        XCTAssertGreaterThan(ungated, s,
                             "positive control: the certified floor removes cells here, "
                             + "so there is room for a relaxed floor to give some back")
        XCTAssertGreaterThan(a, s,
                             "★ aesthetic drew \(a) cells and structural \(s) — the "
                             + "relaxed floor changed nothing about the picture")
        XCTAssertLessThanOrEqual(a, ungated,
                                 "★ and it must never draw MORE than no floor at all")
        print("""

        ── the aesthetic floor on his part, 8.00 mm cell ─────────────
        no floor at all ......... \(ungated) cells
        aesthetic (floor -> 2) .. \(a) cells
        structural (floor 5) .... \(s) cells

        """)
    }

    /// ★★★ AND THE CERTIFIED PICTURE DID NOT MOVE. Byte-for-byte against a call made
    /// WITHOUT the new parameter — i.e. against the code every existing bar was measured
    /// on.
    func testTheStructuralBakeIsUnchangedByTheNewParameter() throws {
        let s = try scene(mode: .structural, field: nil)
        try XCTSkipIf(s.memberThicknessMM.isEmpty, "core gave no thickness")
        for cellMM in [2.0, 4.0, 8.0] {
            let old = LatticePreviewOccupancy.cellField(
                occupancy: s.occupancy, demand: s.demand, cellMM: cellMM,
                memberThickness: s.memberThicknessMM,
                minCellsPerMember: s.minCellsPerMember)
            let new = LatticePreviewOccupancy.cellField(
                occupancy: s.occupancy, demand: s.demand, cellMM: cellMM,
                memberThickness: s.memberThicknessMM,
                minCellsPerMember: s.minCellsPerMember,
                cellsPerMemberFloor: s.cellsPerMemberFloorPerVoxel)
            XCTAssertEqual(old.values, new.values,
                           "★ the structural bake MOVED at \(cellMM) mm — the certified "
                           + "picture must not change to ship a cosmetic mode")
        }
    }

    /// ★★★ SUPERSEDED (2026-08-21) — AESTHETIC NO LONGER WAITS FOR THE SOLVE.
    ///
    /// This used to require aesthetic-with-no-field to draw the CERTIFIED picture:
    /// "absence of measurement is not permission to relax". On his part that meant the
    /// pre-solve stage — the picture he actually looks at while setting the region up —
    /// drew the structural refusal, and the mode appeared to do nothing. His ruling is
    /// that the declared walls lattice regardless ("*WHEREVER* it is asked of us"), so
    /// the floor is now a constant and there is nothing for a missing field to withhold.
    func testAestheticRelaxesWithNoFieldAtAll() throws {
        let a = try scene(mode: .aesthetic, field: nil)
        let s = try scene(mode: .structural, field: nil)
        try XCTSkipIf(s.memberThicknessMM.isEmpty, "core gave no thickness")
        let hard = TopOptKit.latticeAestheticCellsPerMemberHardFloor(topology: "octet")
        let f = a.cellsPerMemberFloorPerVoxel.filter { $0 > 0 }
        XCTAssertFalse(f.isEmpty, "★ no field must no longer disarm the aesthetic floor")
        XCTAssertEqual(f.min() ?? 0, hard, accuracy: 1e-9)
        XCTAssertEqual(f.max() ?? 0, hard, accuracy: 1e-9, "★ and it is flat")
        XCTAssertTrue(s.cellsPerMemberFloorPerVoxel.isEmpty,
                      "★ structural is untouched — it still takes the accuracy floor")
        XCTAssertGreaterThanOrEqual(drawn(a, cellMM: 8), drawn(s, cellMM: 8),
                                    "★ and it draws at least as much as the certified one")
    }

    /// ★★★ SUPERSEDED (2026-08-21) — A PART AT ITS ALLOWABLE STILL GETS LATTICED.
    ///
    /// This used to require a member at yield to land on the ACCURACY floor, on the
    /// argument that the relaxation is bought with unused strength. That argument makes
    /// the mode an accuracy rule, and it is why his loaded walls went solid. An
    /// aesthetic lattice makes no strength claim — the receipt says so in core's own
    /// words — so there is nothing to buy it with, and the floor does not read the load.
    ///
    /// ★ WHAT IS STILL TRUE, AND IS NOW THE BAR: structural is unchanged at yield. The
    /// certified path must not have moved a voxel.
    func testAFullyWorkedPartIsStillRelaxedInAestheticAndUntouchedInStructural() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let atYield = field(mesh, fraction: 1.0)
        let a = try scene(mode: .aesthetic, field: atYield)
        let s = try scene(mode: .structural, field: atYield)
        try XCTSkipIf(s.memberThicknessMM.isEmpty, "core gave no thickness")
        let hard = TopOptKit.latticeAestheticCellsPerMemberHardFloor(topology: "octet")

        let floors = a.cellsPerMemberFloorPerVoxel.filter { $0 > 0 }
        XCTAssertFalse(floors.isEmpty, "positive control: floors were computed")
        XCTAssertEqual(floors.max() ?? 0, hard, accuracy: 1e-9,
                       "★ at the allowable the floor must STILL be the hard floor — "
                       + "aesthetic does not ration on how hard the wall is working")
        XCTAssertLessThan(hard, s.minCellsPerMember,
                          "positive control: the hard floor really is a relaxation")
        XCTAssertTrue(s.cellsPerMemberFloorPerVoxel.isEmpty,
                      "★ the CERTIFIED path must be untouched by any of this")
    }

    /// ★★★ AND IT REACHES THE **SWEPT** PLANNER (maintainer, 2026-08-21: "Do you have
    /// Aesthetic wired up the way it should be?").
    ///
    /// ★ IT DID NOT. `desired` was computed for AUTO and FIT and left EMPTY for swept,
    /// so on a swept job core applied its own accuracy floor of 5 and the mode changed
    /// nothing at all — on the one cell mode his project actually uses. This bar is on
    /// the DEMAND that reaches the planner, because that is where the gap was.
    func testTheAestheticFloorReachesTheSweptPlannerAndNotJustAutoAndFit() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let quiet = field(mesh, fraction: 0.0)
        let a = try scene(mode: .aesthetic, field: quiet)
        try XCTSkipIf(a.memberThicknessMM.isEmpty, "core gave no thickness")
        XCTAssertFalse(a.cellsPerMemberFloorPerVoxel.isEmpty, "positive control")

        // What a SWEPT job hands the planner: no per-local-member flag, no fit cells.
        // ★★ THE CONTROL COMES FROM THE **STRUCTURAL** SCENE NOW, AND THAT CHANGE IS
        // THE POINT. This used to build both arms from the aesthetic scene, relaxed by
        // handing one of them `perVoxelFloor` — which worked only while
        // `minCellsPerMember` was ALWAYS core's accuracy floor of 5 and the relaxation
        // lived in that array alone. It no longer is: the scene's floor is now the
        // MODE's floor, because every planner path divides by it and five of them were
        // still dividing by 5 (2026-08-22, the 2.20 mm cell). With both arms built from
        // the same scene the two are now identical by construction, and the bar was
        // comparing a thing with itself — a green run measuring nothing.
        let certifiedScene = try scene(mode: .structural, field: quiet)
        XCTAssertGreaterThan(certifiedScene.minCellsPerMember, a.minCellsPerMember,
                             "positive control: the two scenes must carry DIFFERENT "
                           + "floors, or this comparison is with itself again")
        let floors = a.cellsPerMemberFloorPerVoxel
        let relaxed = LatticeMeasuredRegionWidth.desiredCellMM(
            occupancy: a.occupancy, memberThicknessMM: a.memberThicknessMM,
            minCellsPerMember: a.minCellsPerMember,
            baseCellMM: 3.0, capMM: 8.0, perVoxelFloor: floors)
        let certified = LatticeMeasuredRegionWidth.desiredCellMM(
            occupancy: certifiedScene.occupancy,
            memberThicknessMM: certifiedScene.memberThicknessMM,
            minCellsPerMember: certifiedScene.minCellsPerMember,
            baseCellMM: 3.0, capMM: 8.0)
        let asked = relaxed.filter { $0 > 0 }
        let askedCertified = certified.filter { $0 > 0 }
        XCTAssertFalse(asked.isEmpty, "positive control: voxels ask for a cell")
        // The relaxed floor must ask for a COARSER cell somewhere — otherwise the mode
        // is inert on this path, which is exactly the defect.
        XCTAssertGreaterThan(asked.reduce(0, +) / Double(asked.count),
                             askedCertified.isEmpty ? 0
                                : askedCertified.reduce(0, +) / Double(askedCertified.count),
                             "★ the aesthetic floor asks for no coarser a cell than the "
                             + "certified one — on a swept job the mode would be inert")
        print("""

        ── swept demand, his part ───────────────────────────────────────
        voxels asking (certified floor) .. \(askedCertified.count)
        voxels asking (aesthetic floor) .. \(asked.count)
        mean cell asked, certified ....... \(askedCertified.isEmpty ? 0 : askedCertified.reduce(0,+)/Double(askedCertified.count)) mm
        mean cell asked, aesthetic ....... \(asked.reduce(0,+)/Double(asked.count)) mm
        ★ capped by HIS sweep window at .. 8.00 mm

        """)
    }

    /// ★★★ SUPERSEDED (2026-08-21) — THE FLOOR NO LONGER TRACKS THE FIELD AT ALL.
    ///
    /// It used to sit between the hard and accuracy floors on a half-worked part, which
    /// is what "graded rather than a switch" meant. The grading was the refusal. The bar
    /// now is that three very different fields produce the SAME floor — the strongest
    /// statement of his rule, and the one a re-armed adaptive path would fail.
    func testTheFloorIsTheSameOnAQuietAHalfWorkedAndAYieldingPart() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let hard = TopOptKit.latticeAestheticCellsPerMemberHardFloor(topology: "octet")
        var seen: [Double] = []
        for frac in [0.0, 0.5, 1.0] {
            let sc = try scene(mode: .aesthetic, field: field(mesh, fraction: frac))
            try XCTSkipIf(sc.memberThicknessMM.isEmpty, "core gave no thickness")
            let f = sc.cellsPerMemberFloorPerVoxel.filter { $0 > 0 }
            XCTAssertFalse(f.isEmpty, "positive control at \(frac)")
            XCTAssertEqual(f.min() ?? 0, hard, accuracy: 1e-9, "min moved at \(frac)")
            XCTAssertEqual(f.max() ?? 0, hard, accuracy: 1e-9, "max moved at \(frac)")
            seen.append(f.min() ?? 0)
        }
        print("floors at 0%/50%/100% of allowable: \(seen) — accuracy floor is "
              + "\(TopOptKit.latticeLimits(topology: "octet").minCellsPerMember)")
        XCTAssertEqual(Set(seen).count, 1, "★ the load still moves the aesthetic floor")
    }
}
