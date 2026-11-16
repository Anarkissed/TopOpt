// LatticeLayoutStressPageTests — Install 2, the page: Lattice Setup's grading reaches the new engine (his order 11-14: "not
// having density grading and a whole slew of other required settings"):
//   * "Grade the lattice" off (his 08-25: "No grade — one cell, one density"): core's uniform (RED CONTROL: a grade lays
//     Default Grade or Stepped);
//   * By stress: struts between Grade to and Grade from, the response his exponent, no Thickness under it (his 08-19);
//   * cell size by stress (his 08-19 "Cell size Auto should absolutely be *any* number - as needed based on the stress map"):
//     any cell mode but Manual, with a grade that follows stress;
//   * the reference: Structural = the printed yield over his Safety margin (his 11-14 carry-over); Aesthetic = the part's own;
//   * the rows' densities only in Per region;
//   * the Export carries the stress result as core reads it (TODEMAND), and needs it only when the settings grade by stress.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class LatticeLayoutStressPageTests: XCTestCase {

    func project() throws -> ProjectModel {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        _ = try FlexibleR7M1Fixtures.hisLiveLattice(r.project)
        return r.project
    }

    func testGradeTheLatticeOffIsOneCellOneDensity() throws {
        let p = try project()
        p.lattice.gradingMode = .full
        XCTAssertNotEqual(LatticeLayoutPreview.settings(p).algorithm, "uniform", "RED CONTROL: a grade lays graded cells")
        p.lattice.gradingMode = .none
        let s = LatticeLayoutPreview.settings(p)
        XCTAssertEqual(s.algorithm, "uniform", "★ No grade: core's uniform")
        XCTAssertFalse(s.gradeToShape, "★ and no shape grade")
        XCTAssertFalse(s.byStress || s.cellsByStress, "★ and nothing by stress")
    }

    func testByStressReachesTheEngineBetweenGradeToAndGradeFrom() throws {
        let p = try project()
        p.lattice.setSimulateStresses(true)
        p.lattice.gradingMode = .full
        p.lattice.densityMode = .sim
        p.lattice.minRelativeDensity = 0.1    // Grade to
        p.lattice.maxRelativeDensity = 0.6    // Grade from
        p.lattice.demandExponent = 0.5
        p.lattice.manualStrutThicknessMM = 1.2
        p.lattice.stageMode = .structural
        let s = LatticeLayoutPreview.settings(p, referenceMPa: 12.5)
        XCTAssertTrue(s.byStress, "★ By stress")
        XCTAssertLessThan(s.dialLight, s.dialHeavy, "★ Grade to is the light end, Grade from the heavy end")
        XCTAssertTrue((0.01...1).contains(s.dialLight) && (0.01...1).contains(s.dialHeavy), "★ on core's dial")
        XCTAssertEqual(s.response, 0.5, "★ his exponent")
        XCTAssertEqual(s.strutWidthMM, 0, "★ no typed Thickness under By stress")
        XCTAssertFalse(s.perRegion, "★ no row dials under By stress")
        XCTAssertEqual(s.referenceMPa, 12.5, "★ Structural: the printed yield over his margin")
        p.lattice.stageMode = .aesthetic
        XCTAssertEqual(LatticeLayoutPreview.settings(p, referenceMPa: 12.5).referenceMPa, 0, "★ Aesthetic: the part's own")
        // a shape-only grade gives one density
        p.lattice.gradingMode = .fitShape
        XCTAssertFalse(LatticeLayoutPreview.settings(p).byStress, "control: Shape only — one density everywhere")
        // the simulation off: no stress, and the typed Thickness counts again
        p.lattice.gradingMode = .full
        p.lattice.setSimulateStresses(false)
        p.lattice.manualStrutThicknessMM = 1.2
        let off = LatticeLayoutPreview.settings(p)
        XCTAssertFalse(off.byStress, "control: the simulation off")
        XCTAssertEqual(off.strutWidthMM, 1.2, "★ his Thickness with the simulation off")
    }

    func testCellSizeByStressInEveryCellModeButManual() throws {
        let p = try project()
        p.lattice.setSimulateStresses(true)
        p.lattice.gradingMode = .stressOnly
        p.lattice.cellSizeMode = .auto
        XCTAssertTrue(LatticeLayoutPreview.settings(p).cellsByStress, "★ Auto: sized by the stress map (his 08-19)")
        p.lattice.cellSizeMode = .fixed
        XCTAssertFalse(LatticeLayoutPreview.settings(p).cellsByStress, "★ Manual: one size, as he typed")
        p.lattice.cellSizeMode = .auto
        p.lattice.gradingMode = .fitShape
        XCTAssertFalse(LatticeLayoutPreview.settings(p).cellsByStress, "control: a shape-only grade")
        XCTAssertFalse(LatticeLayoutPreview.needsStress(p.lattice))
    }

    func testTheRowsDensitiesOnlyInPerRegion() throws {
        let p = try project()
        p.lattice.stageMode = .aesthetic
        p.lattice.densityMode = .uniform
        XCTAssertFalse(LatticeLayoutPreview.settings(p).perRegion, "★ Uniform: one density, even in Aesthetic")
        p.lattice.densityMode = .perRegion
        XCTAssertTrue(LatticeLayoutPreview.settings(p).perRegion, "★ Per region")
    }

    func testTheExportCarriesTheStressResult() throws {
        let f = LatticeDemandField(vonMises: [0, 1.5, 3, 4.5, 6, 7.5, 9, 10.5], nx: 2, ny: 2, nz: 2,
                                   origin: SIMD3(-1, -2, -3), spacingMM: 0.5, provenance: .solidSim(date: Date(), resolution: 64))
        let d = LatticeFileJob.demandFile(f)
        XCTAssertEqual(d.prefix(8), Data("TODEMAND".utf8), "★ core's magic")
        XCTAssertEqual(d.count, 8 + 4 * 4 + 8 * 4 + 4 * 8, "★ header and one float32 per voxel")
        let v = d.withUnsafeBytes { raw -> (Int32, Int32, Double, Double, Float) in
            (raw.loadUnaligned(fromByteOffset: 8, as: Int32.self), raw.loadUnaligned(fromByteOffset: 12, as: Int32.self),
             raw.loadUnaligned(fromByteOffset: 24, as: Double.self), raw.loadUnaligned(fromByteOffset: 48, as: Double.self),
             raw.loadUnaligned(fromByteOffset: 56 + 4 * 7, as: Float.self))
        }
        XCTAssertEqual(v.0, 1, "version 1")
        XCTAssertEqual(v.1, 2, "nx")
        XCTAssertEqual(v.2, -1, "the low corner's x")
        XCTAssertEqual(v.3, 0.5, "the spacing")
        XCTAssertEqual(v.4, 10.5, "the last voxel, x fastest")
        var s = LatticeLayoutSession.Settings()
        XCTAssertFalse(LatticeFileJob.needsStress(s), "control: nothing by stress needs no result")
        s.byStress = true
        s.perRegion = true
        XCTAssertTrue(LatticeFileJob.needsStress(s))
        let job = try XCTUnwrap(try JSONSerialization.jsonObject(with: LatticeFileJob.build(s, modelName: "m.step", demand: LatticeFileJob.demandName)) as? [String: Any])
        XCTAssertEqual(job["demand"] as? String, "demand.bin", "★ the stress result beside the job")
        let l = try XCTUnwrap(job["layout"] as? [String: Any])
        XCTAssertEqual(l["by_stress"] as? Bool, true)
        XCTAssertEqual(l["per_region"] as? Bool, false, "★ core refuses By stress with Per region")
        s.byStress = false
        s.regions = [.init(id: 1, faces: [3], depthMM: 4)]
        s.regions[0].own.cellsByStress = true
        XCTAssertTrue(LatticeFileJob.needsStress(s), "★ an area's own cell size by stress needs it too")
    }
}
#endif
