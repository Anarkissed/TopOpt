// LatticeLayoutAreasPageTests — Install 2, the page: an area's own tab and a Lattice zone reach the new engine.
//   * an area's tab (B7 E3, LatticeSettings.areaGrading): its grade (None = one cell, one density), band and Strength go as
//     the region's own, on that area's Lattice regions only (control: the other areas state nothing);
//   * a zone's Finish (release (4): None, Rim, Skin, Covered) goes as the region's own Finish;
//   * a Lattice zone (B6 s3a) goes as core's Zone: a Box about its middle with unit axes at right angles and its half sizes, a
//     Cylinder along its axis (RED CONTROL: before Install 2 a zone was skipped).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class LatticeLayoutAreasPageTests: XCTestCase {

    func testAnAreasOwnTabReachesItsRegions() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        _ = try FlexibleR7M1Fixtures.hisLiveLattice(p)
        // an area the page lattices: a Lattice group (not a Protect skin) with a row asked for lattice
        let g = try XCTUnwrap(p.latticeGroups.first { g in
            !p.lattice.skinGroups.contains(g.id)
                && p.latticeSelectableRefs(g).contains { p.latticeSelectableRole($0, in: g.id) == .include }
        }, "premise: an area with a Lattice row")
        print("AREAS: \(p.latticeGroups.count) groups; area \(g.name); \(LatticeLayoutPreview.settings(p).regions.count) regions")
        XCTAssertTrue(LatticeLayoutPreview.settings(p).regions.allSatisfy { !$0.own.any && !$0.finish.any }, "premise: no area states anything")
        p.lattice.boundary = .none
        p.lattice.areaGrading[g.id] = LatticeAreaGrading(gradingMode: LatticeGradingMode.none, shapeFitBandMM: 3, shapeGradeStrength: 0.5,
                                                         outerFinish: "none", skin: "rim")
        let s = LatticeLayoutPreview.settings(p)
        let own = s.regions.filter { $0.own.any }
        XCTAssertFalse(own.isEmpty, "★ the area's regions state their own")
        XCTAssertTrue(own.allSatisfy { $0.own.algorithm == "uniform" && $0.own.gradeToShape == false }, "★ its No grade: one cell, one density")
        XCTAssertTrue(own.allSatisfy { $0.own.bandMM == 3 && $0.own.strength == 0.5 }, "★ its band and Strength")
        XCTAssertTrue(own.allSatisfy { $0.finish.rimMM == -1 && $0.finish.skin == false }, "★ its Finish: Rim")
        XCTAssertTrue(s.regions.filter { !$0.own.any }.allSatisfy { !$0.finish.any }, "control: the other areas state nothing")
        XCTAssertNil(LatticeLayoutPreview.notes(p.lattice).first { $0 == LatticeLayoutPreview.perAreaLine },
                     "★ per area is done: the line saying it is not is gone")
        // Covered
        p.lattice.areaGrading[g.id] = LatticeAreaGrading(outerFinish: "shell", skin: "none")
        XCTAssertTrue(LatticeLayoutPreview.settings(p).regions.contains { $0.finish.coverMM == (p.printParams.wallRingMM > 0 ? p.printParams.wallRingMM : -1) }, "★ Covered, at the printer's wall")
    }

    func testALatticeZoneIsItsShape() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil   // the Lattice stage's own list, where zones live
        let zid = try XCTUnwrap(p.addLatticeZone(), "premise: a zone")
        let mid = try XCTUnwrap(p.latticeZoneMiddle(zid))
        let size = try XCTUnwrap(p.latticeZoneSize(zid))
        let s = LatticeLayoutPreview.settings(p)
        let z = try XCTUnwrap(s.regions.compactMap(\.zone).first, "★ the zone goes as a shape (\(s.regions))")
        XCTAssertEqual(z.kind, .box)
        XCTAssertLessThan(simd_length(z.centre - mid), 1e-9, "★ about its middle")
        XCTAssertEqual(z.half.x, size.width / 2, accuracy: 1e-9)
        XCTAssertEqual(z.half.y, size.depth / 2, accuracy: 1e-9)
        XCTAssertEqual(z.half.z, size.height / 2, accuracy: 1e-9)
        XCTAssertEqual(z.axes.count, 3)
        for a in z.axes { XCTAssertEqual(simd_length(a), 1, accuracy: 1e-9, "★ unit axes") }
        XCTAssertEqual(simd_dot(z.axes[0], z.axes[1]), 0, accuracy: 1e-9, "★ at right angles")
        XCTAssertEqual(simd_dot(z.axes[0], z.axes[2]), 0, accuracy: 1e-9)
        XCTAssertEqual(simd_dot(z.axes[1], z.axes[2]), 0, accuracy: 1e-9)
        let region = try XCTUnwrap(s.regions.first { $0.zone != nil })
        XCTAssertTrue(region.faces.isEmpty, "★ no faces beside it (core leaves out a zone with faces)")
        p.setLatticeZoneShape(zid, .cylinder)
        let c = try XCTUnwrap(LatticeLayoutPreview.settings(p).regions.compactMap(\.zone).first)
        XCTAssertEqual(c.kind, .cylinder, "★ a Cylinder")
        XCTAssertLessThan(simd_length(c.centre - mid), 1e-9, "★ about the same middle")
        XCTAssertEqual(simd_length(c.axes[2]), 1, accuracy: 1e-9, "★ along its unit axis")
        // the job: region_zones, with its own key names
        let job = try XCTUnwrap(try JSONSerialization.jsonObject(with: LatticeFileJob.build(LatticeLayoutPreview.settings(p), modelName: "m.step")) as? [String: Any])
        let zones = try XCTUnwrap((job["layout"] as? [String: Any])?["region_zones"] as? [Any], "★ region_zones in the job")
        let cyl = try XCTUnwrap(zones.compactMap { $0 as? [String: Any] }.first)
        XCTAssertEqual(cyl["kind"] as? String, "cylinder")
        XCTAssertNotNil(cyl["radius_mm"] as? Double)
        XCTAssertNotNil(cyl["half_length_mm"] as? Double)
    }
}
#endif
