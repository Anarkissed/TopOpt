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

    /// ★★ ABSENCE OF MEASUREMENT IS NOT PERMISSION TO RELAX. Aesthetic with no field —
    /// which is the pre-solve stage — must draw exactly the certified picture.
    func testAestheticWithNoFieldDrawsTheCertifiedPicture() throws {
        let a = try scene(mode: .aesthetic, field: nil)
        let s = try scene(mode: .structural, field: nil)
        try XCTSkipIf(s.memberThicknessMM.isEmpty, "core gave no thickness")
        XCTAssertTrue(a.cellsPerMemberFloorPerVoxel.isEmpty,
                      "★ no field means no utilisation means no relaxation")
        XCTAssertEqual(drawn(a, cellMM: 8), drawn(s, cellMM: 8))
    }

    /// ★★ AND A PART AT ITS ALLOWABLE GETS NOTHING BACK. The relaxation is bought with
    /// unused strength; a member already at yield has none to spend, so aesthetic must
    /// land on the accuracy floor there. This is the bar that would fail if the
    /// utilisation were read from the field's own peak (which is 1.0 everywhere on a
    /// uniform field, whatever the stress) instead of from the allowable.
    func testAFullyWorkedPartGetsTheAccuracyFloorEvenInAesthetic() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let atYield = field(mesh, fraction: 1.0)
        let a = try scene(mode: .aesthetic, field: atYield)
        let s = try scene(mode: .structural, field: atYield)
        try XCTSkipIf(s.memberThicknessMM.isEmpty, "core gave no thickness")

        let floors = a.cellsPerMemberFloorPerVoxel.filter { $0 > 0 }
        XCTAssertFalse(floors.isEmpty, "positive control: floors were computed")
        XCTAssertEqual(floors.min() ?? 0, s.minCellsPerMember, accuracy: 1e-9,
                       "★ at the allowable the aesthetic floor must equal the accuracy "
                       + "floor — a member at yield has no unused strength to spend")
        XCTAssertEqual(drawn(a, cellMM: 8), drawn(s, cellMM: 8),
                       "★ and the picture must be the certified one")
    }

    /// ★ THE FLOOR TRACKS THE FIELD, not just its presence — a half-worked part sits
    /// between the two, so the rule is graded rather than a switch.
    func testTheFloorSitsBetweenTheTwoOnAHalfWorkedPart() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let half = try scene(mode: .aesthetic, field: field(mesh, fraction: 0.5))
        try XCTSkipIf(half.memberThicknessMM.isEmpty, "core gave no thickness")
        let hard = TopOptKit.latticeAestheticCellsPerMemberHardFloor(topology: "octet")
        let f = half.cellsPerMemberFloorPerVoxel.filter { $0 > 0 }
        XCTAssertFalse(f.isEmpty, "positive control")
        let lo = f.min() ?? 0
        XCTAssertGreaterThanOrEqual(lo, hard)
        XCTAssertLessThanOrEqual(lo, half.minCellsPerMember)
        print("half-worked: floor \(lo) between hard \(hard) and accuracy "
              + "\(half.minCellsPerMember)")
    }
}
