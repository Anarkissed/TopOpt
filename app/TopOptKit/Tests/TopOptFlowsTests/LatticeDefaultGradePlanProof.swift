import XCTest
import Metal
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★ THE DEFAULT GRADE PLAN PROOF (maintainer, 2026-10-02, ruling 4): "run it; don't conclude by
/// reading." Opt-in instrumentation — it bakes the preview's plan for ONE project folder (a COPY;
/// converted copies are labelled by the caller) exactly as the app does, and writes the stage job
/// twice from one process: WITH the plan (the seam forced on) and WITHOUT it (production: plans
/// off). The two must differ only by `lattice.stepped_cells`. It prints the plan's histogram in
/// CORE's own format (stepped_plan.cpp: sizes descending, "%.2f=%zu"), so the CLI's
/// "[stepped] doubled (halves) plan: …" line can be compared byte for byte.
///
///     DG_PROJECT_DIR=<copy of a project folder> DG_OUT=<dir> [DG_FIELD=none] \
///     swift test --filter LatticeDefaultGradePlanProof
///
/// The bake mirrors LatticeHisSteppedBakeProbe (the app's own order: the stage solve, the scene
/// built twice, `LatticeRegionCells`, the renderer fed in `MetalMeshView.apply`'s order), with
/// the app's algorithm gate (raw stepped/doubled) and its R4 rule (halves by the algorithm).
final class LatticeDefaultGradePlanProof: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        while u.path != "/" && !FileManager.default.fileExists(atPath: u.appendingPathComponent("core/src/materials/materials.json").path) {
            u = u.deletingLastPathComponent()
        }
        return u
    }()

    /// Core's histogram line for a list of cells (stepped_plan.cpp:241-250).
    static func coreHistogram(_ cells: [LatticeSteppedCellWire]) -> String {
        var count: [Double: Int] = [:]
        for c in cells { count[c.sizeMM, default: 0] += 1 }
        return count.keys.sorted(by: >).map { String(format: "%.2f=%d", $0, count[$0]!) }.joined(separator: " ")
    }

    @MainActor
    func testBakeThePlanAndWriteBothJobs() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dirPath = env["DG_PROJECT_DIR"], let outPath = env["DG_OUT"] else { throw XCTSkip("DG_PROJECT_DIR, DG_OUT") }
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let src = URL(fileURLWithPath: dirPath), out = URL(fileURLWithPath: outPath)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let snap = try JSONDecoder().decode(ProjectSnapshot.self, from: Data(contentsOf: src.appendingPathComponent("project.json")))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dg-proof-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdir = root.appendingPathComponent(snap.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: pdir, withIntermediateDirectories: true)
        for f in try FileManager.default.contentsOfDirectory(atPath: src.path) {
            try FileManager.default.copyItem(at: src.appendingPathComponent(f), to: pdir.appendingPathComponent(f))
        }
        let core = Self.repoRoot.appendingPathComponent("core")
        let model = AppModel(materialsPath: core.appendingPathComponent("src/materials/materials.json").path,
                             rulesPath: core.appendingPathComponent("src/settings/rules.json").path,
                             store: ProjectStore(rootDir: root))
        model.loadMaterials()
        model.open(try XCTUnwrap(model.recentProjects.first { $0.id == snap.id }))
        let pm = try XCTUnwrap(model.project)
        let mesh = try XCTUnwrap(pm.viewerMesh)
        let lat = pm.lattice
        print("DG-PROJECT \(pm.name) algorithm \(lat.algorithm) stage \(String(describing: lat.stageMode)) step-halves \(lat.gradeStepsAreHalves) density \(lat.densityMode) cells \(lat.cellSizeMode)")
        // ★ round 5: Aesthetic Stepped too, behind its test switch (DG_ANY_STEP=1)
        try XCTSkipUnless(lat.algorithm == "doubled" || (lat.algorithm == "stepped" && env["DG_ANY_STEP"] == "1"),
                          "not a Default Grade project (convert the copy first), nor Stepped with DG_ANY_STEP=1")

        // ── the stage solve (the field the bake grades by)
        var stageField: LatticeDemandField? = nil
        if env["DG_FIELD"] != "none", let ctx = model.makeLatticeSimContext() {
            let r = try TopOptKit.analyzeSolidLoadCase(
                modelPath: ctx.modelPath, material: ctx.material, materialsPath: ctx.materialsPath,
                rulesPath: ctx.rulesPath, resolution: ctx.resolution, anchorFaceIDs: ctx.anchorFaceIDs,
                loadGroups: ctx.loadGroups, buildDirection: ctx.buildDirection,
                faceRegions: ctx.faceRegions, anchorRegionIDs: ctx.anchorRegionIDs)
            stageField = LatticeDemandField(vonMises: r.vonMisesField, stressTensor: r.stressTensorField,
                                            nx: r.gridNX, ny: r.gridNY, nz: r.gridNZ, origin: r.gridOrigin,
                                            spacingMM: r.spacingMM, provenance: .solidSim(date: Date(), resolution: ctx.resolution))
        }
        func sf(_ f: LatticeDemandField) -> StressField {
            StressField(nx: f.nx, ny: f.ny, nz: f.nz, origin: SIMD3<Float>(f.origin), spacing: Float(f.spacingMM), values: f.vonMises)
        }
        let field: StressField? = !lat.gradingMode.followsStress ? nil
            : (lat.densityMode.needsSimulation && stageField != nil ? sf(stageField!) : LatticeSDFScene.demandField(from: pm.run.outcome))
        let wallStressField = stageField.map(sf) ?? LatticeSDFScene.demandField(from: pm.run.outcome)
        let bead = pm.printParams.strutLineWidthMM
        let params = lat.proxyParams(limits: TopOptKit.latticeLimits(topology: lat.topologyID), lineWidthMM: bead)
        let span = params.densitySpan
        let emission = pm.latticeJobRegions()
        var regions = emission.regions
        if !lat.wallThickness.isThrough {
            for i in regions.indices where regions[i].role == .include && regions[i].kind == .face { regions[i].thickness = lat.wallThickness }
        }
        let stageMode = lat.stageMode ?? .structural
        let steps = LatticeWallDepthSteps.forWalls(lat, regions: regions, beadMM: bead)
        func scene(_ floorCells: [Double]) -> LatticeSDFScene {
            LatticeSDFScene(mesh: mesh, field: field, latticeID: params.latticeID,
                            stressField: stageField.map(sf),
                            statedDensityGoverns: !lat.densityMode.needsSimulation || stageMode == .aesthetic,
                            allowQuilt: lat.allowQuilt, stageMode: stageMode, algorithm: lat.algorithm,
                            allowableMPa: model.yieldStrengthMPa(for: pm.material), boundaryFinishWritten: lat.singleCellMembers,
                            regions: regions, rhoMin: span.lo, rhoMax: span.hi, gamma: Swift.max(0.05, params.gamma),
                            whenEmpty: .latticeNothing, skinMM: lat.boundary.faceSkinMM(wallRingMM: pm.printParams.wallRingMM),
                            skippedFaces: emission.skippedFaces,
                            wallThicknessFloorMM: floorCells.filter { $0 > 0 }.min() ?? lat.cellMM,
                            wallDepthSteps: steps, wallStressField: wallStressField,
                            bandOverrides: lat.bandTreatments, octetBand: true,
                            bandGradeMM: lat.gradingMode.fitsShape ? lat.shapeFitBandMM : 0, beadMM: bead)
        }
        let s0 = scene(LatticeRegionCells.steppedCellsMM(project: pm, scene: nil))
        let s1 = scene(LatticeRegionCells.steppedCellsMM(project: pm, scene: s0))
        let cells = LatticeRegionCells.steppedCellsMM(project: pm, scene: s1)
        let statedByFace = LatticeRegionCells.statedCellByFace(lat)

        // ── the renderer, the app's order; the plan arrives through the same callback
        guard let mr = MeshRenderer(device: device, sampleCount: 4) else { throw XCTSkip("renderer") }
        try XCTSkipUnless(mr.latticePipelinesDidBuild)
        var baked: (cells: [LatticeSteppedCell], regions: [LatticeRegionSpec])? = nil
        mr.onLatticeCellsBaked = { c, r in baked = (c, r) }
        mr.setMesh(mesh)
        mr.showGround = false
        mr.latticeHidden = false
        mr.latticeParams = params
        mr.latticeLineWidthMM = bead
        mr.latticeBuildDirection = SIMD3<Double>(pm.buildOrientation.resolved(gravity: pm.force.gravity))
        mr.latticeLayerHeightMM = pm.printParams.layerHeightMM
        mr.latticeSteppedCellMM = cells
        mr.latticeSteppedShapeFit = lat.gradingMode.fitsShape
        mr.latticeSteppedDyadicSteps = lat.gradeStepsAreHalves
        mr.latticeSteppedCellStated = regions.map { r in r.faceID.map { statedByFace[$0] != nil } ?? false }
        mr.setLatticeScene(s1, token: 1)
        let b = try XCTUnwrap(baked, "the bake handed back no plan")
        let plan = LatticeSteppedCellWire.wire(b.cells, regions: b.regions)
        pm.latticePreviewSteppedCells = plan
        let perRegion = Dictionary(grouping: plan, by: \.regionID).mapValues(\.count).sorted { $0.key < $1.key }
        let includeCount = b.regions.filter { $0.role == .include }.count
        print("DG-PLAN \(pm.lattice.algorithm): \(plan.count) cell(s) over \(includeCount) region(s) | \(Self.coreHistogram(plan))")
        print("DG-PLAN per region: \(perRegion.map { "r\($0.key)=\($0.value)" }.joined(separator: " "))")

        // ── the stage job, with and without the plan, from ONE process (no hash-order drift)
        let request = try XCTUnwrap(model.makeLatticeRunRequest(), "no stage job")
        // ★ round 5 (2026-10-08): Aesthetic Stepped's any-step plan rides behind its own test switch
        let savedAnyStep = LatticeSteppedCellWire.anyStepPlansForTests
        LatticeSteppedCellWire.anyStepPlansForTests = env["DG_ANY_STEP"] == "1"
        defer { LatticeSteppedCellWire.anyStepPlansForTests = savedAnyStep }
        func pretty(_ d: Data) throws -> Data {
            try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: d), options: [.prettyPrinted, .sortedKeys])
        }
        let withPlan = try RemoteRun.buildJobJSON(request, steppedPlans: true)
        let noPlan = try RemoteRun.buildJobJSON(request, steppedPlans: false)
        try pretty(withPlan).write(to: out.appendingPathComponent("job_plan.json"))
        try pretty(noPlan).write(to: out.appendingPathComponent("job_noplan.json"))
        let modelName = (request.modelPath as NSString).lastPathComponent
        let modelDst = out.appendingPathComponent(modelName)
        try? FileManager.default.removeItem(at: modelDst)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: request.modelPath), to: modelDst)
        // the two differ ONLY by lattice.stepped_cells
        var a = try XCTUnwrap(JSONSerialization.jsonObject(with: withPlan) as? [String: Any])
        let n = try XCTUnwrap(JSONSerialization.jsonObject(with: noPlan) as? [String: Any])
        var la = try XCTUnwrap(a["lattice"] as? [String: Any])
        if la["stepped_cells"] == nil {
            // ★ withheld: the job carries no plan core would refuse — say why, in the app's words
            let lat = try XCTUnwrap(request.lattice)
            if case .failure(let why) = LatticeSteppedCellWire.slotOrigins(lat.steppedCells, regions: lat.regions,
                                                                           slotOriginWired: TopOptKit.regionSlotOriginWired) {
                print("DG-WITHHELD \(why.reason) | \(why)")
                // ★ FOR #358's K2 (the reviewer, 2026-10-08: "slot_origin_mm becomes a grid phase, with
                // depth measured from the region's own plane"): the plan the app withholds, written as
                // the job K2 must accept — every planned region stamped with the bake's grid point,
                // on its plane or not. The app never sends this; core at 36f5fdde refuses it.
                var k2 = try XCTUnwrap(JSONSerialization.jsonObject(with: withPlan) as? [String: Any])
                var lk = try XCTUnwrap(k2["lattice"] as? [String: Any])
                lk["stepped_cells"] = lat.steppedCells.map { $0.wireDictionary }
                var grid: [Int: SIMD3<Double>] = [:]
                for c in lat.steppedCells { if let so = c.slotOriginMM, grid[c.regionID] == nil { grid[c.regionID] = so } }
                if var regs = lk["regions"] as? [[String: Any]] {
                    var id = 0
                    for (i, r) in lat.regions.enumerated() where r.role == .include {
                        id += 1
                        guard let so = grid[id], var g = regs[i]["geometry"] as? [String: Any] else { continue }
                        g["slot_origin_mm"] = [so.x, so.y, so.z]; regs[i]["geometry"] = g
                    }
                    lk["regions"] = regs
                }
                k2["lattice"] = lk
                try pretty(JSONSerialization.data(withJSONObject: k2)).write(to: out.appendingPathComponent("job_plan_k2.json"))
                print("DG-K2-JOB job_plan_k2.json: \(lat.steppedCells.count) cells, \(grid.count) regions stamped (withheld by the app)")
            } else {
                print("DG-WITHHELD the switch did not send the plan (algorithm \(lat.algorithm), wired \(TopOptKit.steppedCellsWired))")
            }
        } else {
            XCTAssertEqual((la["stepped_cells"] as? [Any])?.count, plan.count, "★ the plan rides the job whole")
        }
        la.removeValue(forKey: "stepped_cells")
        // the planned regions' grids (slot_origin_mm, 2026-10-08) ride with the plan
        var stamped = 0
        if var regs = la["regions"] as? [[String: Any]] {
            for i in regs.indices {
                guard var g = regs[i]["geometry"] as? [String: Any], g.removeValue(forKey: "slot_origin_mm") != nil else { continue }
                stamped += 1; regs[i]["geometry"] = g
            }
            la["regions"] = regs
        }
        a["lattice"] = la
        print("DG-SLOT-ORIGINS \(stamped) region(s) carry slot_origin_mm")
        XCTAssertEqual(try pretty(JSONSerialization.data(withJSONObject: a)), try pretty(noPlan),
                       "★ the jobs differ only by the plan and its regions' grids")
        XCTAssertNil((n["lattice"] as? [String: Any])?["stepped_cells"], "production sends no plan")
        print("DG-JOBS \(out.path) model \(modelName)")
    }
}
