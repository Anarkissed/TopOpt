import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★★ ITEM 2 (measured 2026-10-06 on his 102117B9, Manual one size): two of the organic preview's
/// gaps to the run were the APP's — the job and the preview read different numbers for one thing.
///   • The rim: the preview drew max(1.535 × bead, one voxel) = 1.705 mm (his 2026-09-08 rule); the
///     job sent the bead term alone, 0.691 mm, because the spec's floor field was never filled.
///   • The shape fit: core floors it at the job's `cell_min_mm` whenever the job carries a window
///     (run_job.cpp:4522, 4799-4801) — inert for one size; the preview passed no window and shrank
///     24,787 voxels to half the size.
@MainActor
final class OrganicPreviewMatchesTheJobTests: XCTestCase {

    private func organic(_ configure: (ProjectModel) -> Void) -> ProjectModel {
        let (p, _, _) = VariantFacePrismFixture.project(organic: true)
        configure(p)
        return p
    }

    private func jobGrading(_ p: ProjectModel) throws -> [String: Any] {
        let spec = try XCTUnwrap(p.latticeRunSpec(emission: p.latticeJobRegions()), "no run spec")
        return try XCTUnwrap(spec.gradingDictionary())
    }

    /// The job's automatic rim IS the preview's: the printability floor with its voxel term.
    func testTheJobsRimIsThePreviewsFloor() throws {
        for pick in [false, true] {
            let p = organic { p in
                p.lattice.organicSolidRimMM = -1
                if pick { p.lattice.setSimulateStresses(false); p.lattice.cellSizeMode = .fit
                          p.lattice.organicPickedSeparationMM = 4 }
            }
            let preview = p.lattice.organicRunSolidRimMM(floorMM: p.organicFloor.mm)
            let job = try XCTUnwrap(try jobGrading(p)["organic_solid_rim_mm"] as? Double, "the job states the rim")
            XCTAssertEqual(job, preview, accuracy: 1e-12, "★ one number: the job rims what the preview draws (pick \(pick))")
            // the positive control that the voxel term can bind: the floor is the larger of the two
            let bead = p.printParams.strutLineWidthMM
            XCTAssertEqual(p.organicFloor.mm, max(OrganicSizeCheck.printFloorPerBead * bead, p.solveVoxelMM), accuracy: 1e-9)
            print("ORGANIC-RIM pick \(pick): job \(job) preview \(preview) (bead term \(OrganicSizeCheck.printFloorPerBead * bead), voxel \(p.solveVoxelMM))")
        }
        // ★ WHERE THE VOXEL TERM BINDS — his part's case (1.705 mm voxel over a 0.69 mm bead term),
        // built here with a fine bead under this fixture's 0.156 mm voxel: the old job sent the bead
        // term (0.077 mm) while the preview drew the voxel. RED before 2026-10-08.
        let fine = organic { p in p.lattice.organicSolidRimMM = -1; p.printParams.strutLineWidthMM = 0.05 }
        XCTAssertGreaterThan(fine.solveVoxelMM, OrganicSizeCheck.printFloorPerBead * 0.05, "the voxel binds here")
        let fineJob = try XCTUnwrap(try jobGrading(fine)["organic_solid_rim_mm"] as? Double)
        XCTAssertEqual(fineJob, fine.organicFloor.mm, accuracy: 1e-12, "★ the job rims the voxel the preview draws")
        XCTAssertEqual(fineJob, fine.solveVoxelMM, accuracy: 1e-12)
        print("ORGANIC-RIM voxel-bound: job \(fineJob) preview \(fine.lattice.organicRunSolidRimMM(floorMM: fine.organicFloor.mm)) (bead term \(OrganicSizeCheck.printFloorPerBead * 0.05))")
        // a stated rim still wins, and 0 is still none
        let stated = organic { $0.lattice.organicSolidRimMM = 1.25 }
        XCTAssertEqual(try jobGrading(stated)["organic_solid_rim_mm"] as? Double, 1.25)
        let off = organic { $0.lattice.organicSolidRimMM = 0 }
        XCTAssertEqual(try jobGrading(off)["organic_solid_rim_mm"] as? Double, 0)
    }

    /// The window the preview's shape fit reads is the one the job carries, as core reads it.
    func testThePreviewReadsTheJobsWindow() throws {
        let one = organic { p in
            p.lattice.setSimulateStresses(false); p.lattice.cellSizeMode = .fit
            p.lattice.organicPickedSeparationMM = 4
        }
        let w = try XCTUnwrap(one.organicJobWindowMM, "a one-size pick carries the window (4, 4)")
        let g = try jobGrading(one)
        XCTAssertEqual(w.lo, g["cell_min_mm"] as? Double); XCTAssertEqual(w.hi, g["cell_max_mm"] as? Double)
        XCTAssertEqual(w.lo, 4); XCTAssertEqual(w.hi, 4)
        let grade = organic { p in
            p.lattice.setSimulateStresses(true); p.lattice.cellSizeMode = .fit
            p.lattice.organicPickedGradeMM = [3, 5]
        }
        XCTAssertEqual(grade.organicJobWindowMM?.lo, 3); XCTAssertEqual(grade.organicJobWindowMM?.hi, 5)
        let auto = organic { p in p.lattice.setSimulateStresses(true); p.lattice.cellSizeMode = .auto }
        XCTAssertNil(auto.organicJobWindowMM, "Auto states no window: core floors at half the spacing")
        // the wiring, from source
        var u = URL(fileURLWithPath: #filePath); for _ in 0..<3 { u.deleteLastPathComponent() }
        let metal = try String(contentsOf: u.appendingPathComponent("Sources/TopOptFlows/LatticeSDFMetal.swift"), encoding: .utf8)
        XCTAssertTrue(metal.contains("window: o.jobWindowMM, only: false,"), "★ the shape fit reads the job's window")
        let ws = try String(contentsOf: u.appendingPathComponent("Sources/TopOptFlows/WorkspacePlaceholder.swift"), encoding: .utf8)
        XCTAssertTrue(ws.contains("o.jobWindowMM = organicJobWindow"))
    }

    /// Core's rule on a slab: with the one-size window the fit shrinks nothing; with none it does
    /// (the control — the preview's old behaviour on 102117B9).
    func testOneSizeShapeFitShrinksNothingAsInCore() {
        let n = 12
        var cand = [Bool](repeating: false, count: n * n * n)
        for k in 2..<10 { for j in 0..<n { for i in 0..<n { cand[(k * n + j) * n + i] = true } } }
        let sep = [Double](repeating: 4, count: cand.count)
        let member = [Double](repeating: 8, count: cand.count)
        let none = OrganicShapeFit.apply(spacing: sep, candidate: cand, nx: n, ny: n, nz: n, voxelMM: 1,
                                         window: nil, only: false, memberMM: member,
                                         cellsAcrossMember: OrganicShapeFit.cellsAcrossMember)
        let one = OrganicShapeFit.apply(spacing: sep, candidate: cand, nx: n, ny: n, nz: n, voxelMM: 1,
                                        window: (4, 4), only: false, memberMM: member,
                                        cellsAcrossMember: OrganicShapeFit.cellsAcrossMember)
        XCTAssertGreaterThan(none.shrunk, 0, "control: with no window the boundary cap shrinks the edge")
        XCTAssertEqual(one.shrunk, 0, "★ one size: core's floor is the size itself — nothing shrinks")
        XCTAssertEqual(one.spacing, sep)
    }
}
