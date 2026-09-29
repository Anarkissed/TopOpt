import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★★ A WALL AT THE THRESHOLD GETS THE SAME VERDICT IN THE PREVIEW AND THE RUN
/// (maintainer, 2026-09-29, ruling C: "Stop zeroing dead walls in the app … pass core
/// the same tensor the run uses, and take the dead regions from core's report
/// (fully_synthetic > 0). Preview = run by construction … Add a parity test: a wall
/// right at the threshold gets the same verdict in the preview and the run").
///
/// ★ WHAT "THE RUN" IS HERE. No Swift test runs a real organic job, and a real job
/// cannot put a wall's p99 at exactly 0.005 MPa (the FEA sets it). The run's verdict is
/// its CALL: run_job.cpp's `synthesize_focal_stress(grid, candidate, voxel_region_id,
/// cfg, 0.02, out, kOrganicSyntheticDeadFloorMPa)`. The bridge makes that call verbatim
/// (`synthesize_as_the_run`) for every synthesis it does, and the source pin below
/// fails the moment either side changes. What this cannot prove: that the preview's
/// grid, resampled tensor and candidate set equal the run's — they do not, and never
/// will (different grids, the preview-only slab).
///
/// ★ THE FIXTURE sits exactly where the old paths disagreed. Grid 8×13×13 at 1 mm;
/// candidates i∈1…6, j,k∈1…11. All tensors uniaxial σxx = s (von Mises = s exactly).
///   wall 1 (i=1, 121 cand): 118×0.004, 1×0.005, 2×0.0055 → core p99 (rounded index 119) 0.0055: ALIVE
///                           the old Swift p99 (floor index 118) 0.005: dead
///   wall 2 (i=2, 121 cand): 119×0.004, 2×0.005 → p99 exactly 0.005 = thr: DEAD (inclusive)
///                           the old bridge folded the floor into the fraction and got
///                           thr = (0.005/0.038)·0.038 = 0.004999999999999999: alive
///   wall 3 (i=3, 121 cand + a 48-voxel tagged ring that is NOT candidate, at 0.006):
///                           core (candidates only) p99 0.005: DEAD; the old Swift rule
///                           counted the ring: alive
///   wall 4 (i=4…6, 363 cand): vM 0.0164 and one 0.038 voxel, the part's peak: ALIVE
/// thr = max(0.02 × 0.038, 0.005) = 0.005. The run's dead set is {2, 3}.
final class OrganicDeadWallParityTests: XCTestCase {

    struct Fixture {
        let nx = 8, ny = 13, nz = 13
        var candidate: [Bool]
        var regionIDs: [Int32]
        var tensor: [Double]
        let specs: [TopOptKit.OrganicSyntheticRegionSpec] =
            (1...4).map { .init(regionID: $0, faceID: 10 + $0, foci: 4) }
        var n: Int { nx * ny * nz }
    }

    static func fixture() -> Fixture {
        let nx = 8, ny = 13, nz = 13, n = nx * ny * nz
        var cand = [Bool](repeating: false, count: n)
        var ids = [Int32](repeating: 0, count: n)
        var t = [Double](repeating: 0, count: 6 * n)
        var c1 = 0, c2 = 0
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx {
            let e = (k * ny + j) * nx + i
            let interior = (1...11).contains(j) && (1...11).contains(k)
            switch i {
            case 1 where interior:
                ids[e] = 1; cand[e] = true
                t[6 * e] = c1 < 118 ? 0.004 : (c1 == 118 ? 0.005 : 0.0055); c1 += 1
            case 2 where interior:
                ids[e] = 2; cand[e] = true
                t[6 * e] = c2 < 119 ? 0.004 : 0.005; c2 += 1
            case 3:
                ids[e] = 3; cand[e] = interior
                t[6 * e] = interior ? 0.005 : 0.006
            case 4...6 where interior:
                ids[e] = 4; cand[e] = true
                if i == 5 && j == 6 && k == 6 {
                    t[6 * e] = 0.038
                } else {
                    t[6 * e] = 0.02; t[6 * e + 1] = 0.006; t[6 * e + 2] = 0.002
                }
            default: break
            }
        } } }
        return Fixture(candidate: cand, regionIDs: ids, tensor: t)
    }

    /// The deleted app rule, kept here ONLY as the control that proves the fixture
    /// discriminates: peak and p99 over every TAGGED voxel, p99 at the floor index.
    static func oldAppDeadSet(_ f: Fixture) -> Set<Int> {
        var peak = 0.0
        var byID: [Int: [Double]] = [:]
        for e in 0..<f.n where f.regionIDs[e] >= 1 {
            let v = OrganicSyntheticStress.vonMises(f.tensor, at: e)
            peak = max(peak, v); byID[Int(f.regionIDs[e]), default: []].append(v)
        }
        let thr = max(0.02 * peak, 0.005)
        return Set(byID.compactMap { id, vm in
            let s = vm.sorted(); return s[Int(0.99 * Double(s.count - 1))] <= thr ? id : nil })
    }

    func testAWallAtTheThresholdGetsTheRunsVerdictInThePreview() throws {
        guard TopOptKit.latticeAlgorithmIsKnown("organic") else { throw XCTSkip("no organic on this core") }
        let f = Self.fixture()

        // ── THE RUN'S VERDICT: its own call, through the bridge (pinned below)
        let run = try XCTUnwrap(TopOptKit.organicSyntheticReport(
            nx: f.nx, ny: f.ny, nz: f.nz, spacingMM: 1, origin: .zero,
            candidate: f.candidate, stressTensor: f.tensor, regionIDs: f.regionIDs,
            syntheticRegions: f.specs))
        let p99 = Dictionary(uniqueKeysWithValues: run.regions.map { ($0.regionID, $0.p99VonMises) })
        print("""

        ── a wall at the threshold ─────────────────────────────────────────
        run:   thr \(run.deadThreshold) (floor bound \(run.deadFloorBound)) · peak \(run.peakVonMises) · p99 \(p99.sorted { $0.key < $1.key }) · dead \(run.deadRegionIDs.sorted())
        old app rule: dead \(Self.oldAppDeadSet(f).sorted())
        """)
        XCTAssertEqual(run.peakVonMises, 0.038)
        XCTAssertEqual(run.deadThreshold, 0.005, "★ exactly — the floor is passed as core's dead_floor")
        XCTAssertTrue(run.deadFloorBound)
        XCTAssertEqual(p99[2], 0.005, "wall 2 sits EXACTLY at the threshold")
        XCTAssertEqual(p99[3], 0.005, "wall 3's candidates sit exactly at it too")
        XCTAssertEqual(p99[1], 0.0055)
        XCTAssertEqual(run.deadRegionIDs, [2, 3])
        XCTAssertEqual(Set(run.regions.filter(\.wholeRegion).map(\.regionID)), [2, 3],
                       "fully_synthetic > 0 and core's whole_region agree")

        // ── THE PREVIEW'S VERDICT: the scene's own function, on an input built as the
        // workspace builds it — the tensor untouched
        var input = LatticeOrganicInput(tensor: f.tensor, dims: (f.nx, f.ny, f.nz), originMM: .zero,
                                        spacingMM: 1, minExtrudableWidthMM: 0.42,
                                        buildDirection: SIMD3(0, 0, 1),
                                        separationMinMM: 3, separationMaxMM: 5, rhoMin: 0.05, rhoMax: 0.6)
        input.regionIDs = f.regionIDs
        input.syntheticRegions = f.specs
        let preview = try XCTUnwrap(LatticeSDFScene.coreDeadWallVerdict(candidate: f.candidate, input: input))
        XCTAssertEqual(preview.deadRegionIDs, run.deadRegionIDs, "★ the preview's dead walls are the run's")
        XCTAssertEqual(preview, run)

        // ── AND THE TRACE THE PREVIEW DRAWS synthesises on the same call
        let t = try XCTUnwrap(TopOptKit.organicTrace(
            nx: f.nx, ny: f.ny, nz: f.nz, spacingMM: 1, origin: .zero,
            candidate: f.candidate, stressTensor: f.tensor,
            separationMM: [Double](repeating: 4, count: f.n), minExtrudableWidthMM: 0.42,
            buildDirection: SIMD3(0, 0, 1), fieldDims: (2, 2, 2), fieldOrigin: .zero,
            fieldSpacingMM: 13, bandMM: 1, rhoMin: 0.05, rhoMax: 0.6,
            showRepairs: false, regionIDs: f.regionIDs, syntheticRegions: f.specs),
            "the preview's trace ran on the fixture")
        let traced = try XCTUnwrap(t.synthetic)
        XCTAssertEqual(traced.deadRegionIDs, run.deadRegionIDs, "★ the traced synthesis agrees")
        XCTAssertEqual(traced.deadThreshold, run.deadThreshold)
    }

    /// ★ POSITIVE CONTROLS THAT STAY IN THE SUITE: the fixture sits where both retired
    /// paths disagreed with the run, so a return to either would be caught.
    func testTheFixtureSitsWhereTheRetiredPathsDisagreed() {
        let f = Self.fixture()
        XCTAssertEqual(Self.oldAppDeadSet(f), [1, 2], "the deleted Swift rule: floor index, tagged voxels")
        XCTAssertLessThan((0.005 / 0.038) * 0.038, 0.005,
                          "the old bridge's folded threshold lands one ulp UNDER the floor on this peak")
    }

    /// ★ The run's call and the bridge's are the same call, and nothing in the app
    /// zeroes a wall any more.
    func testTheRunsCallIsTheOneThePreviewMakes() throws {
        let root: URL = {
            var u = URL(fileURLWithPath: #filePath); for _ in 0..<5 { u.deleteLastPathComponent() }
            return u
        }()
        func flat(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
                .split(whereSeparator: { $0 == " " || $0 == "\n" }).joined(separator: " ")
        }
        let run = try flat("core/src/cli/run_job.cpp")
        XCTAssertTrue(run.contains("synthesize_focal_stress(grid, candidate, voxel_region_id, cfg, 0.02, out, kOrganicSyntheticDeadFloorMPa)"),
                      "★ the run's call moved — re-read it and mirror it in the bridge")
        let bridge = try flat("app/TopOptKit/Sources/TopOptBridge/bridge.cpp")
        XCTAssertTrue(bridge.contains("topopt::synthesize_focal_stress(grid, cand, vr, cfg, 0.02, stress, topopt::kOrganicSyntheticDeadFloorMPa)"))
        XCTAssertEqual(bridge.components(separatedBy: "topopt::synthesize_focal_stress(").count - 1, 1,
                       "every synthesis goes through the one helper")
        XCTAssertFalse(bridge.contains("/ synth_peak"), "no threshold folded into the fraction")
        let ws = try flat("app/TopOptKit/Sources/TopOptFlows/WorkspacePlaceholder.swift")
        XCTAssertFalse(ws.contains("&organicIn!.tensor"), "the app zeroes no wall")
        let scene = try flat("app/TopOptKit/Sources/TopOptFlows/LatticeSDFMetal.swift")
        XCTAssertTrue(scene.contains("let rep = LatticeSDFScene.coreDeadWallVerdict(candidate: cand, input: o)"))
        XCTAssertTrue(scene.contains("deadRegionIDs = rep.deadRegionIDs"))
        XCTAssertTrue(scene.contains("exactIDs && !deadRegionIDs.isEmpty && deadRegionIDs.contains(Int(o.regionIDs[e]))"),
                      "the window's-middle grading reads core's dead set")
        XCTAssertEqual(TopOptKit.organicSyntheticDeadFloorMPa, OrganicSyntheticStress.deadMPaFloor,
                       "the wording's 0.005 is core's own floor")
        XCTAssertEqual(OrganicSyntheticStress.deadFraction, 0.02)
    }

    /// ★★ RULING 1 (2026-09-29): THE SELECTIONS ROW AND THE FOCI OFFER ARE CORE'S VERDICT —
    /// "the stand's 0.0203 MPa back wall is the test case". His stand peaks at 0.024 MPa
    /// against a 37 MPa allowable, so core's threshold is max(0.02 × 0.024, 0.005) =
    /// 0.005: the back wall (p99 0.0203) is left alone and CARRIES LOAD; the front wall
    /// (0.00411) is synthesised and is BARELY LOADED. Through the preview's own call.
    @MainActor func testTheStandsBackWallCarriesLoadByCoresVerdict() throws {
        guard TopOptKit.latticeAlgorithmIsKnown("organic") else { throw XCTSkip("no organic on this core") }
        let nx = 4, ny = 13, nz = 13, n = nx * ny * nz
        var cand = [Bool](repeating: false, count: n), ids = [Int32](repeating: 0, count: n)
        var t = [Double](repeating: 0, count: 6 * n)
        var backCount = 0
        for k in 1...11 { for j in 1...11 {
            let b = (k * ny + j) * nx + 1, f = (k * ny + j) * nx + 2
            cand[b] = true; ids[b] = 1; t[6 * b] = backCount == 60 ? 0.024 : 0.0203; backCount += 1
            cand[f] = true; ids[f] = 2; t[6 * f] = 0.00411
        } }
        let group = UUID()
        let back = LatticeSelectableRef.face(group: group, face: 15)
        let front = LatticeSelectableRef.face(group: group, face: 2)
        let other = LatticeSelectableRef.face(group: group, face: 9)
        let specs: [TopOptKit.OrganicSyntheticRegionSpec] = [.init(regionID: 1, faceID: 15, foci: 4),
                                                             .init(regionID: 2, faceID: 2, foci: 4)]
        let plan = OrganicSyntheticStress.Plan(regionIDs: ids, regions: specs,
                                               keyByID: [1: back.key, 2: front.key])
        var input = LatticeOrganicInput(tensor: t, dims: (nx, ny, nz), originMM: .zero, spacingMM: 1,
                                        minExtrudableWidthMM: 0.42, buildDirection: SIMD3(0, 0, 1),
                                        separationMinMM: 3, separationMaxMM: 5, rhoMin: 0.05, rhoMax: 0.6)
        input.regionIDs = ids
        input.syntheticRegions = specs
        let rep = try XCTUnwrap(LatticeSDFScene.coreDeadWallVerdict(candidate: cand, input: input))
        let p99 = Dictionary(uniqueKeysWithValues: rep.regions.map { ($0.regionID, $0.p99VonMises) })
        XCTAssertEqual(rep.peakVonMises, 0.024)
        XCTAssertEqual(rep.deadThreshold, 0.005); XCTAssertTrue(rep.deadFloorBound)
        XCTAssertEqual(p99[1], 0.0203, "the back wall's p99, as core measures it")
        XCTAssertEqual(rep.deadRegionIDs, [2], "core synthesises the front wall only")

        // ── recorded exactly as the bake records it, and read by the row and the offer
        let p = ProjectModel(id: UUID(), name: "P", material: "PLA", process: .fdm,
                             importedFile: nil, importedMesh: nil)
        p.lattice.algorithm = "organic"
        p.lattice.stageMode = .aesthetic
        p.lattice.organicSyntheticStresses = true
        p.recordLatticeWallVerdicts(OrganicSyntheticStress.wallReports(from: rep, plan: plan)
            .filter { $0.value.voxels > 0 }.mapValues(\.dead))
        XCTAssertEqual(p.latticeWallLoaded(back), true)
        XCTAssertEqual(p.latticeWallLoaded(back).map(OrganicSyntheticStress.wallWord(loaded:)), "Carries load")
        p.writeLatticeSyntheticFoci(back, foci: 3)
        XCTAssertNil(p.latticeSelectableSyntheticFoci(back), "★ no foci on the back wall")
        XCTAssertEqual(p.latticeWallLoaded(front), false)
        XCTAssertEqual(p.latticeWallLoaded(front).map(OrganicSyntheticStress.wallWord(loaded:)),
                       "Barely loaded — a made-up load can be added")
        p.writeLatticeSyntheticFoci(front, foci: 3)
        XCTAssertEqual(p.latticeSelectableSyntheticFoci(front), 3, "★ the front wall takes foci")
        XCTAssertNil(p.latticeWallLoaded(other), "never measured ⇒ no word")
        p.writeLatticeSyntheticFoci(other, foci: 2)
        XCTAssertEqual(p.latticeSelectableSyntheticFoci(other), 2, "…and the offer stays open")

        // ── control: the retired app rule called the back wall unloaded (the part is idle
        // against its allowable, 0.024 < 2 % of 37), which is what the ruling overturns
        let partPeakMPa: Double = 0.024, allowableMPa: Double = 37
        let retiredRuleCallsItUnloaded = partPeakMPa < 0.02 * allowableMPa
        XCTAssertTrue(retiredRuleCallsItUnloaded)
        XCTAssertNotEqual(retiredRuleCallsItUnloaded, !(try XCTUnwrap(p.latticeWallLoaded(back))),
                          "core disagrees on the back wall")

        // ── the row and the offer read that one value in the workspace, and no app rule remains
        var root = URL(fileURLWithPath: #filePath); for _ in 0..<5 { root.deleteLastPathComponent() }
        func src(_ f: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent("app/TopOptKit/Sources/TopOptFlows/\(f)"), encoding: .utf8)
        }
        let ws = try src("WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains("fociDisabled: project.latticeWallLoaded(ref) == true"))
        XCTAssertTrue(ws.contains("project.latticeWallLoaded(ref).map(OrganicSyntheticStress.wallWord(loaded:))"))
        for f in ["WorkspacePlaceholder.swift", "ProjectModel.swift", "OrganicSyntheticStress.swift", "LatticeSettings.swift"] {
            let t = try src(f)
            XCTAssertFalse(t.contains("loadedStressShare") || t.contains("carriesLoad") || t.contains("partIsLoaded"),
                           "★ the app's own loaded rule is gone from \(f)")
        }
    }

    /// ★★ RULING 2 (2026-09-29): every include wall is flagged and core decides. Before
    /// changing the job its code was read: a flagged wall with no count gets core's
    /// default of 4 foci it places itself, and a flagged wall that carries load is left
    /// untouched. Here: flagging the loaded walls changes no verdict, the threshold or
    /// the peak — core measures them over every candidate before it reads the flags.
    func testFlaggingALoadedWallChangesNoVerdict() throws {
        guard TopOptKit.latticeAlgorithmIsKnown("organic") else { throw XCTSkip("no organic on this core") }
        let f = Self.fixture()
        func report(_ flagged: [TopOptKit.OrganicSyntheticRegionSpec]) throws -> TopOptKit.OrganicSyntheticReport {
            try XCTUnwrap(TopOptKit.organicSyntheticReport(
                nx: f.nx, ny: f.ny, nz: f.nz, spacingMM: 1, origin: .zero, candidate: f.candidate,
                stressTensor: f.tensor, regionIDs: f.regionIDs, syntheticRegions: flagged))
        }
        let all = try report(f.specs)
        let deadOnly = try report(f.specs.filter { [2, 3].contains($0.regionID) })
        XCTAssertEqual(all.deadRegionIDs, deadOnly.deadRegionIDs)
        XCTAssertEqual(all.deadRegionIDs, [2, 3])
        XCTAssertEqual(all.deadThreshold, deadOnly.deadThreshold)
        XCTAssertEqual(all.peakVonMises, deadOnly.peakVonMises)
        for id in [1, 4] {
            let r = try XCTUnwrap(all.regions.first { $0.regionID == id })
            XCTAssertEqual(r.fullySynthetic, 0, "★ a flagged wall that carries load is left untouched")
            XCTAssertFalse(r.wholeRegion)
        }
        // core's default for a flagged wall with no count, read from its code
        var root = URL(fileURLWithPath: #filePath); for _ in 0..<5 { root.deleteLastPathComponent() }
        func flat(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
                .split(whereSeparator: { $0 == " " || $0 == "\n" }).joined(separator: " ")
        }
        XCTAssertTrue(try flat("core/include/topopt/job.hpp").contains("int synthetic_foci = 4;"),
                      "core's default count")
        XCTAssertTrue(try flat("core/src/cli/job.cpp").contains("if (const JsonValue* fv = find_key(rv, \"synthetic_foci\"))"),
                      "the count is optional in the job")
        XCTAssertTrue(try flat("core/src/mesh/organic_lattice.cpp").contains("if (!rr.whole_region) { rep.per_region.push_back(rr); continue; }"),
                      "a flagged wall that carries load is skipped")
        XCTAssertEqual(LatticeSettings().organicSyntheticFoci, 4, "the app's default is core's")
    }

    /// ★ Ruling B: the (i) says what is applied, in his words.
    func testTheUnloadedWallsInfoSaysWhatIsApplied() {
        let t = LatticeSetupWizard.infoSynthetic
        XCTAssertTrue(t.hasPrefix("A wall the load barely reaches can be given a made-up load so it still gets a pattern. "), t)
        XCTAssertTrue(t.contains("It's only applied where the wall's real stress is tiny — at or under 2 % of the "
                                 + "part's peak, or 0.005 MPa. A wall that carries load is left alone."), t)
        XCTAssertTrue(t.contains("in its row under Selections"))
        XCTAssertTrue(t.contains("Colours are comparable within a face, never between two."))
        for gone in ["median", "5%", "never reaches", "schema"] { XCTAssertFalse(t.contains(gone), gone) }
    }

    /// Item 1: the variants cached before `bead_is_stated` are retired.
    func testTheCacheRetiredTheCalibratedStatedWidthVariants() {
        XCTAssertGreaterThanOrEqual(OrganicVariantCache.layoutVersion, 6)
    }
}
