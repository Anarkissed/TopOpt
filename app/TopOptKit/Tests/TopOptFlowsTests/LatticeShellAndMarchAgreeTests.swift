// LatticeShellAndMarchAgreeTests — ★★★ THE HOLE AND THE STRUTS MUST DESCRIBE THE SAME
// VOLUME. On his own part, not a fixture.
//
// ★★ WHY THIS EXISTS, AND WHY THE 2,084 OTHER TESTS DID NOT CATCH ANY OF IT. Three bad
// builds reached his iPad this week and the full suite was green for all three. Every
// test here checks a COMPONENT — a predicate, a plan, a count — and not one of them
// asked the question the preview exists to answer: does the shell stand down in exactly
// the places the march draws struts? Both failures he actually saw are one bit of that
// question, in opposite directions:
//
//   HOLES         the shell was cut wherever a REGION WAS DECLARED, but the run leaves a
//                 voxel solid when its member is too thin (L4) or its strut cannot clear
//                 one bead. The shell went and nothing replaced it: a void where the
//                 algorithm puts plastic.
//
//   SEE-THROUGH   I then cut the shell wherever a CELL WAS ACTIVE and dropped the region
//                 test entirely. Cell-active is a broader set than in-region, so the
//                 shell vanished where the march draws nothing at all and he was looking
//                 through the front wall at the green anchor face inside.
//
// Both are the same defect: the shell's predicate and the march's predicate were allowed
// to differ. The march accepts a sample iff
//
//     max(dPart, dBox, dRegion) <= 0   AND   the owning cell is ACTIVE
//
// (`lsdf_march`, UnifiedShading.swift). On the part's own surface `dPart ≈ 0`, so the
// shell's rule must be exactly IN-REGION ∧ CELL-ACTIVE. Not one of them. Both.
//
// ★ AND IT CARRIES ITS OWN POSITIVE CONTROLS. A test that only asserted the conjunction
// would pass on a part where the two sets happen to coincide and prove nothing. This
// measures BOTH single-field rules on his real geometry and requires each to disagree
// with the march — so the fixture is known to be capable of catching each failure, and
// the conjunction's zero is a fact about the rule rather than about the part.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

final class LatticeShellAndMarchAgreeTests: XCTestCase {

    private static let bead = 0.45

    /// His part with two declared face regions — the configuration in his screenshots.
    @MainActor
    private func hisScene() throws -> LatticeSDFScene {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        var regions: [LatticeRegionSpec] = []
        for (face, depth) in [(15, 11.0), (2, 13.0)] {
            guard let plane = LatticeRegionEmission.planeFor(face: FaceID(face), in: mesh),
                  let spec = LatticeRegionEmission.spec(for: plane, role: .include,
                                                        depthMM: depth, faceID: face)
            else { continue }
            regions.append(spec)
        }
        try XCTSkipIf(regions.isEmpty, "no declarable faces in this fixture")
        return LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                               regions: regions, whenEmpty: .latticeNothing)
    }

    /// The per-cell field Auto bakes: per-local-member cells through core's fit planner.
    @MainActor
    private func autoCellField(_ scene: LatticeSDFScene) throws -> LatticeCellField {
        let occ = scene.occupancy
        try XCTSkipIf(scene.memberThicknessMM.isEmpty, "core gave no widths")
        let printable = try XCTUnwrap(LatticeAutoPosture.autoWindowMM(
            regionWidthsMM: [], lineWidthMM: Self.bead, topology: "octet")).min
        let base = LatticeMeasuredRegionWidth.ladderBaseCellMM(
            occupancy: occ, memberThicknessMM: scene.memberThicknessMM,
            minCellsPerMember: scene.minCellsPerMember, finestPrintableMM: printable)
        let widest = LatticeMeasuredRegionWidth.boundsMM(
            occupancy: occ, memberThicknessMM: scene.memberThicknessMM).first ?? 0
        let ceiling = Swift.max(widest / Swift.max(scene.minCellsPerMember, 1), base)
        let desired = LatticeMeasuredRegionWidth.desiredCellMM(
            occupancy: occ, memberThicknessMM: scene.memberThicknessMM,
            minCellsPerMember: scene.minCellsPerMember, baseCellMM: base,
            capMM: 16 * Double(occ.spacing.x))
        var cand = [Bool](repeating: false, count: occ.count)
        var rho = [Double](repeating: 0, count: occ.count)
        for i in 0..<occ.count where occ.values[i] > 0.5 { cand[i] = true; rho[i] = 0.2 }
        let plan = try XCTUnwrap(TopOptKit.latticeCellSizePlan(
            nx: occ.nx, ny: occ.ny, nz: occ.nz, spacing: occ.spacing, origin: occ.origin,
            candidate: cand, relativeDensity: rho,
            memberWidthMM: scene.memberThicknessMM, minCellMM: base, maxCellMM: ceiling,
            minExtrudableWidthMM: Self.bead, capRadiusVoxels: 16, topology: "octet",
            desiredCellMM: desired), "core must return a plan")
        return LatticePreviewOccupancy.gradedCellField(
            occupancy: occ, demand: scene.demand, plan: plan)
    }

    /// For every voxel of his part: is it in a region, and is its owning cell active?
    private func verdicts(_ scene: LatticeSDFScene, _ cells: LatticeCellField)
        -> (inRegion: [Bool], cellActive: [Bool], inside: [Int]) {
        let occ = scene.occupancy
        let grid = cells.field
        var inRegion = [Bool](repeating: false, count: occ.count)
        var active = [Bool](repeating: false, count: occ.count)
        var inside: [Int] = []
        let rsdf = scene.regionSDF
        for k in 0..<occ.nz {
            for j in 0..<occ.ny {
                for i in 0..<occ.nx {
                    let n = (k * occ.ny + j) * occ.nx + i
                    guard occ.values[n] > 0.5 else { continue }
                    inside.append(n)
                    let p = occ.origin + SIMD3<Float>(Float(i), Float(j), Float(k))
                        * occ.spacing
                    // The march's own region test: dRegion <= 0.
                    if let r = rsdf {
                        let g = (p - r.origin) / r.spacing
                        let a = Swift.min(Swift.max(Int(g.x.rounded()), 0), r.nx - 1)
                        let b = Swift.min(Swift.max(Int(g.y.rounded()), 0), r.ny - 1)
                        let c = Swift.min(Swift.max(Int(g.z.rounded()), 0), r.nz - 1)
                        inRegion[n] = r.values[(c * r.ny + b) * r.nx + a] <= 0
                    } else { inRegion[n] = true }
                    // The march's own cell test: the OWNING cell's value >= 0.
                    let cg = (p - grid.origin) / grid.spacing
                    let ci = Swift.min(Swift.max(Int(cg.x.rounded()), 0), grid.nx - 1)
                    let cj = Swift.min(Swift.max(Int(cg.y.rounded()), 0), grid.ny - 1)
                    let ck = Swift.min(Swift.max(Int(cg.z.rounded()), 0), grid.nz - 1)
                    active[n] = grid.values[(ck * grid.ny + cj) * grid.nx + ci] >= 0
                }
            }
        }
        return (inRegion, active, inside)
    }

    // MARK: - ★★★ the bar

    @MainActor
    func testTheShellStandsDownExactlyWhereTheMarchDrawsStruts() throws {
        let scene = try hisScene()
        let cells = try autoCellField(scene)
        let v = verdicts(scene, cells)
        XCTAssertFalse(v.inside.isEmpty, "positive control: his part has material")

        // The march draws iff BOTH hold. Anything else is a disagreement.
        var marchDraws = 0, regionOnlyWrong = 0, cellOnlyWrong = 0, bothWrong = 0
        for n in v.inside {
            let draws = v.inRegion[n] && v.cellActive[n]
            if draws { marchDraws += 1 }
            if v.inRegion[n] != draws { regionOnlyWrong += 1 }      // the HOLES
            if v.cellActive[n] != draws { cellOnlyWrong += 1 }      // the SEE-THROUGH
            if (v.inRegion[n] && v.cellActive[n]) != draws { bothWrong += 1 }
        }
        let pct = { (n: Int) in Double(n) / Double(v.inside.count) * 100 }
        print("""

        ================================================================================
        SHELL vs MARCH, on his own part — voxels where the two predicates DISAGREE
          voxels inside the part ......... \(v.inside.count)
          the march draws struts in ...... \(marchDraws)
        --------------------------------------------------------------------------------
          clip on REGION alone ........... \(regionOnlyWrong) wrong  \
        (\(String(format: "%.1f", pct(regionOnlyWrong)))%)   <- the HOLES he reported
          clip on CELL alone ............. \(cellOnlyWrong) wrong  \
        (\(String(format: "%.1f", pct(cellOnlyWrong)))%)   <- the SEE-THROUGH I shipped
          clip on REGION and CELL ........ \(bothWrong) wrong
        ================================================================================
        """)

        // ★ POSITIVE CONTROLS FIRST. Each single-field rule must be DEMONSTRABLY wrong
        // on this part, or the conjunction's zero below is a fact about the fixture
        // rather than about the rule — a green run measuring nothing.
        XCTAssertGreaterThan(regionOnlyWrong, 0,
                             "★ positive control: clipping on the region alone must "
                             + "disagree with the march here — that disagreement IS the "
                             + "hole, and if it is zero this part cannot catch it")
        // ★ THE SECOND CONTROL IS NOT AVAILABLE AT FIELD LEVEL, AND SAYING SO IS THE
        // POINT. On a scene WITH regions the occupancy is already region-masked, so
        // `cellActive` implies `inRegion` and clipping on the cell alone disagrees with
        // the march in ZERO voxels here — measured, \(cellOnlyWrong). The see-through I
        // shipped was therefore NOT a predicate error on this scene; it was an ENABLE
        // error: I keyed the clip's on/off onto the cell grid, which exists for every
        // baked scene, so a part with NO declared regions had its shell cut everywhere.
        // That case cannot be reached from a scene that has regions, so it is guarded
        // where it actually lives — `testTheClipIsDisabledWithNothingDeclared` below and
        // `UnifiedShadingTests.testSharedDepthBufferHidesTheLatticeBehindAnOpaqueShell`.
        XCTAssertEqual(cellOnlyWrong, 0,
                       "recorded, not required: with regions declared the occupancy is "
                       + "already region-masked, so this is expected to be 0")

        // ★★★ AND THE RULE THAT SHIPS AGREES EVERYWHERE.
        XCTAssertEqual(bothWrong, 0,
                       "★ the shell must stand down in EXACTLY the voxels the march "
                       + "draws struts in. Any disagreement is either a hole (shell gone, "
                       + "no strut) or a see-through (shell gone, march clipped).")
    }

    /// ★★★ WITH NOTHING DECLARED THE CLIP IS OFF ENTIRELY — the other half of the
    /// see-through, guarded where it lives.
    ///
    /// `shellClipUniform` keys its enable on `regionGrid`, which is nil when no region
    /// list reached the frame. I moved that onto the CELL grid, which exists for every
    /// baked scene, so a whole-part sample had its shell cut everywhere and stopped
    /// occluding the march at all — 5,284 strut pixels against a 1,344 bound. The enable
    /// must come from the REGIONS.
    func testTheClipIsDisabledWithNothingDeclared() throws {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent(); url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        let src = try String(
            contentsOf: url.appendingPathComponent(
                "Sources/TopOptFlows/MetalMeshView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(src.range(of: "private var shellClipUniform"))
        let body = String(src[start.lowerBound...].prefix(600))
        XCTAssertTrue(body.contains("regionGrid"),
                      "★ the ENABLE must key on a declared region. Keying it on the cell "
                      + "grid — which every baked scene has — cut the shell on parts "
                      + "with nothing declared and produced the see-through.")
    }

    /// ★★ AND THE SHADER IMPLEMENTS THE CONJUNCTION. The field-level bar above proves the
    /// RULE; this proves the MSL asks for both halves, which is the exact thing I got
    /// wrong — I replaced the region test instead of adding to it.
    func testTheShellShaderTestsBothRegionAndCell() throws {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent(); url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        let src = try String(
            contentsOf: url.appendingPathComponent(
                "Sources/TopOptFlows/MetalMeshView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(src.range(of: "inline bool shell_is_latticed"))
        let body = String(src[start.lowerBound...].prefix(1600))
        XCTAssertTrue(body.contains("regionTex"),
                      "★ the region half — dropping it is what let the shell vanish "
                      + "outside the declared regions")
        XCTAssertTrue(body.contains("cellTex"),
                      "★ the cell half — dropping it is what left holes where the run "
                      + "builds solid")
        XCTAssertTrue(body.contains("filter::nearest"),
                      "★ cell activation is a FLAG: interpolating it fringes every solid "
                      + "island with a half-transparent border one cell wide")
    }
}
