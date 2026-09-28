import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★★ HIS WALK, 2026-09-07 — the page that could not be touched, the switch that
/// would not stay off, and an "Auto cell-grade" that was not grading anything.
final class OrganicAutoGradeAndFreezeTests: XCTestCase {

    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TopOptFlows/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: the page-wide tap eater

    /// The top-banner modifier expands to the whole viewport so the capsule can be
    /// centred between the top clusters, and measures with a `Color.clear` background.
    /// `Color.clear` HIT-TESTS: while any banner was up, an invisible full-screen
    /// surface swallowed every touch. Harmless at one second, fatal at ten minutes.
    func testTheTopBannerDoesNotSwallowTheWholePage() throws {
        let ws = try source("WorkspacePlaceholder.swift")
        guard let r = ws.range(of: "private struct TopBannerGapCentred: ViewModifier {") else {
            return XCTFail("the banner modifier moved")
        }
        let body = String(ws[r.lowerBound...].prefix(3000))
        XCTAssertTrue(body.contains(".allowsHitTesting(false))"),
                      "★ the full-screen measuring background must not take touches")
        guard let g = body.range(of: ".background(GeometryReader") else {
            return XCTFail("the measuring background moved")
        }
        let after = String(body[g.lowerBound...].prefix(600))
        XCTAssertTrue(after.contains(".allowsHitTesting(false)"),
                      "★ …and it is THAT background which is disabled, not something else")
    }

    // MARK: the switch that would not stay off

    func testShowPrintRepairsIsASavedSettingNotViewState() throws {
        var l = LatticeSettings(enabled: true)
        XCTAssertTrue(l.organicShowRepairs, "on by default — the file is what the run builds")
        l.organicShowRepairs = false
        let back = try JSONDecoder().decode(LatticeSettings.self,
                                            from: try JSONEncoder().encode(l))
        XCTAssertFalse(back.organicShowRepairs, "★ off must survive leaving the page")
        // An untouched project carries no key at all.
        let plain = try JSONEncoder().encode(LatticeSettings())
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: plain) as? [String: Any])
        XCTAssertNil(obj["organicShowRepairs"])
        let wz = try source("LatticeSetupWizard.swift")
        XCTAssertFalse(wz.contains("@State private var organicShowRepairs"),
                       "★ view state is reborn every time the page is built")
        XCTAssertTrue(wz.contains("private var organicShowRepairs: Bool { project.lattice.organicShowRepairs }"))
        XCTAssertTrue(wz.contains("project.lattice.organicShowRepairs.toggle()"))
    }

    // MARK: Auto grades by stress

    /// The separation must come from the tracer's OWN tensor, not from `demand` —
    /// which is nil under Auto, and whose absence was read as "widest spacing".
    func testTheSeparationIsGradedFromTheTensorNotFromDemand() throws {
        let sdf = try source("LatticeSDFMetal.swift")
        XCTAssertTrue(sdf.contains("let v = OrganicSyntheticStress.vonMises(o.tensor, at: e)"),
                      "★ graded from the tensor the tracer is handed")
        XCTAssertFalse(sdf.contains("let d = self.demand.map { Double($0.values[oi]) } ?? 0"),
                       "★ the demand fallback that meant 'coarsest everywhere' is gone")
        XCTAssertTrue(sdf.contains("if hi - lo < 1e-9 {"), "★ a single size is still uniform")
        XCTAssertTrue(sdf.contains("sep[e] = hi - (hi - lo) * t"))
    }

    /// Shape fit gets core's OTHER term. Without it the boundary cap alone only ever
    /// touched the outermost voxel ring.
    func testShapeFitCapsByTheMemberWidthToo() {
        // A block of 2 mm voxels with the interior 4x4x4 as candidates, so an inner
        // voxel is TWO voxels from the boundary. (A flat fixture would put every voxel
        // on a grid face, where the boundary cap bites on its own and proves nothing.)
        let nx = 6, ny = 6, nz = 6
        var cand = [Bool](repeating: false, count: nx * ny * nz)
        for k in 1...4 { for j in 1...4 { for i in 1...4 {
            cand[(k * ny + j) * nx + i] = true
        } } }
        let centre = (2 * ny + 2) * nx + 2
        let edge = (1 * ny + 1) * nx + 1
        let sep = [Double](repeating: 5.5, count: nx * ny * nz)
        let member = [Double](repeating: 8.0, count: nx * ny * nz)   // an 8 mm member
        let without = OrganicShapeFit.apply(spacing: sep, candidate: cand, nx: nx, ny: ny, nz: nz,
                                            voxelMM: 2.0, window: nil, only: false)
        let with = OrganicShapeFit.apply(spacing: sep, candidate: cand, nx: nx, ny: ny, nz: nz,
                                         voxelMM: 2.0, window: nil, only: false,
                                         memberMM: member, cellsAcrossMember: 2.0)
        // The centre is 2 voxels from the boundary: 2·2·2 = 8 mm, above 5.5 ⇒ untouched.
        XCTAssertEqual(without.spacing[centre], 5.5, accuracy: 1e-9,
                       "the boundary cap alone leaves the interior at the coarsest")
        XCTAssertEqual(without.spacing[edge], 4.0, accuracy: 1e-9,
                       "…it only ever touched the outermost ring")
        // With the member term: 8 / 2 = 4 mm ⇒ every candidate is capped, edge and centre.
        XCTAssertEqual(with.spacing[centre], 4.0, accuracy: 1e-9, "★ two cells across the member")
        XCTAssertEqual(with.spacing[edge], 4.0, accuracy: 1e-9)
        XCTAssertGreaterThan(with.shrunk, without.shrunk)
        XCTAssertEqual(OrganicShapeFit.cellsAcrossMember, 2.0)
    }

    // MARK: the two edge rules

    /// ★ THE RUN APPLIES NO RIM UNDER AUTO. run_job: `rim = organic_solid_rim_mm < 0
    /// ? cell_min_mm : organic_solid_rim_mm`, and this app writes `cell_min_mm` only
    /// when a GRADE was picked. The preview was taking the window's low end instead
    /// (3.96 mm on his stand) and eroding every face region by it.
    /// ★★★ THE RIM IS AN OUTLINE ONE STRUT WIDE (his walk, 2026-09-07, 22:40: "There is
    /// a HUGE rim and there isn't any grade to the rim. It just cuts off as if it's some
    /// other part altogether. The rim is meant to be an outline where the lattice would
    /// be too small to print … JUST at the ends of the lattice struts").
    ///
    /// −1 used to mean core's own convention, "one base cell". On his part that is
    /// 3.78 mm against a 1.6 mm design voxel: three voxel layers of solid all the way
    /// round every face. A rim that stands where the lattice stops is a STRUT wide.
    func testTheRimIsAStrutWideOutlineAndTheJobCarriesIt() {
        var l = LatticeSettings(enabled: true)
        l.algorithm = "organic"
        l.organicSolidRimMM = -1                    // the automatic outline
        XCTAssertEqual(l.organicRunSolidRimMM(floorMM: 0.42), 0.42,
                       "★ no stated rim ⇒ the printability floor")
        l.organicStrutWidthMM = 0.9
        XCTAssertEqual(l.organicRunSolidRimMM(floorMM: 0.42), 0.42,
                       "★ the stated strut must NOT move it — Thicker is live and must "
                       + "never re-trace")
        l.organicSolidRimMM = 1.25                  // stated outright
        XCTAssertEqual(l.organicRunSolidRimMM(floorMM: 0.42), 1.25)
        l.organicSolidRimMM = 0                     // off
        XCTAssertEqual(l.organicRunSolidRimMM(floorMM: 0.42), 0)
        // ★ AND IT IS NEVER A CELL AGAIN: a picked grade must not resurrect the old rule.
        l.organicSolidRimMM = -1
        l.organicPickedGradeMM = [3.78, 3.78]
        XCTAssertEqual(l.organicRunSolidRimMM(floorMM: 0.42), 0.42,
                       "★ the base cell is not the rim")
        let ws = try? String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TopOptFlows/WorkspacePlaceholder.swift"), encoding: .utf8)
        XCTAssertTrue(ws?.contains("project.lattice.organicRunSolidRimMM(") == true,
                      "★ the bake reads the run's rim, not the window")
        XCTAssertFalse(ws?.contains("Swift.min(o.separationMinMM, o.separationMaxMM) : 0)") == true,
                       "★ the window's low end is no longer a rim anywhere")
    }

    /// ★ CORE ANCHORS ON SOLID, NOT ONLY ON A SHELL:
    /// `anchor_at_region_boundary = shell_is_written || boundary_solid_fraction > 0.5`.
    /// The preview passed the shell rule alone, so every curve end that left the region
    /// was dangling and was trimmed back — the bare band at the top and the bottom.
    func testTheAnchorRuleIsCoresNotJustTheShell() throws {
        let sdf = try source("LatticeSDFMetal.swift")
        XCTAssertTrue(sdf.contains("var anchorAtBoundary = o.anchorAtBoundary"))
        XCTAssertTrue(sdf.contains("if frac > 0.5 { anchorAtBoundary = true }"),
                      "★ a region cut into solid material anchors on it")
        XCTAssertTrue(sdf.contains("anchorAtBoundary: anchorAtBoundary,"),
                      "★ …and that is what reaches the tracer")
        XCTAssertFalse(sdf.contains("anchorAtBoundary: o.anchorAtBoundary,"),
                       "★ the shell-only rule must not still be wired through")
    }

    /// The row answers one question: is this wall carrying load, and how much.
    func testTheWallRowIsTwoFacts() {
        var w = OrganicSyntheticStress.WallReport(key: "f:b", faceID: 15, voxels: 100,
                                                  fullySynthetic: 0, blended: 0, foci: 4)
        w.partPeakMPa = 0.024; w.wallP99MPa = 0.0203; w.allowableMPa = 37
        XCTAssertEqual(w.statusText, "unloaded · 0.0203 MPa")
        XCTAssertFalse(w.statusText.contains("%"), "no percentages")
        XCTAssertFalse(w.statusText.contains("allowable"), "no allowable")
        XCTAssertLessThanOrEqual(w.statusText.count, 28, w.statusText)
    }

    /// ★ THE GATE AND THE ROW MUST NOT DISAGREE. The row read the live report (which
    /// knows the part is idle) and said "unloaded"; the gate read the stored share and
    /// re-applied the 15 % test alone, so 84 % said "loaded" and the pills stayed grey.
    @MainActor func testTheStoredNumberCarriesTheVerdictNotTheRawShare() throws {
        let ws = try source("WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains("fractions[k] = w.carriesLoad ? w.stressShare : 0"),
                      "★ the verdict is stored, so the gate needs no context it lacks")
        // …and the gate then agrees with the row on his own numbers.
        var w = OrganicSyntheticStress.WallReport(key: "f:a", faceID: 2, voxels: 100,
                                                  fullySynthetic: 0, blended: 0, foci: 4)
        w.partPeakMPa = 0.024; w.wallP99MPa = 0.0203; w.allowableMPa = 37
        XCTAssertTrue(w.dead, "the row says unloaded")
        let p = ProjectModel(id: UUID(), name: "P", material: "PLA", process: .fdm,
                             importedFile: nil, importedMesh: nil)
        let ref = LatticeSelectableRef.face(group: UUID(), face: 15)
        p.recordLatticeWallStress([ref.key: w.carriesLoad ? w.stressShare : 0])
        XCTAssertEqual(p.latticeWallLoaded(ref), false, "★ and so does the gate")
        p.lattice.algorithm = "organic"
        p.lattice.stageMode = .aesthetic
        p.lattice.organicSyntheticStresses = true
        p.writeLatticeSyntheticFoci(ref, foci: 3)
        XCTAssertEqual(p.latticeSelectableSyntheticFoci(ref), 3, "★ the foci are accepted")
        XCTAssertEqual(p.latticeSyntheticWalls(), [ref.key: 3], "★ and the job marks the wall")
    }

    // MARK: the cached cube does not wait on a solve

    func testACachedCubeSkipsTheFiniteElementSolve() throws {
        let s = try source("OrganicSampleCube.swift")
        guard let hit = s.range(of: "if let hit {") else {
            return XCTFail("★ the cache-hit fast path is gone")
        }
        let fast = String(s[hit.lowerBound...].prefix(1600))
        XCTAssertTrue(fast.contains("OrganicVariantCache.bake("),
                      "★ the file's own spans are baked directly")
        XCTAssertTrue(fast.contains("organicBaked: baked"),
                      "★ …and handed over as pre-baked fields, which need no tensor")
        XCTAssertFalse(fast.contains("await field()"),
                       "★ no solve on the cached path")
        // The solve still exists for a topology nobody has traced yet.
        XCTAssertTrue(s.contains("guard let f = await field() else { return nil }"))
        guard let f = s.range(of: "guard let f = await field() else { return nil }"),
              let h = s.range(of: "if let hit {") else { return }
        XCTAssertLessThan(h.lowerBound, f.lowerBound, "★ the cache is consulted FIRST")
    }
}
