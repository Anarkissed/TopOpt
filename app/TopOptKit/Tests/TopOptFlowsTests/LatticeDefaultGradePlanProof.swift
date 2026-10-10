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
        // ★ WHICH OUTLINE THE CUT CELLS ARE CLIPPED AGAINST (the reviewer, 2026-10-10, item 4). The bake
        // paints a cut cell's texels by the signed distance to the RAW face outline (`outlineLoops`),
        // grown by the in-plane expand on every edge and continued across diverging seams; the wire's
        // `outline_uv` is `wireOutlineLoops` (the expand as a mitred offset on true edges, the seam push
        // as a constant). They are the same polygon exactly when the wire moved no vertex off the raw
        // outline: expand 0 and no diverging seam.
        var outlineRows: [String] = []
        var rid = 0
        for r in b.regions where r.role == .include {
            rid += 1
            guard r.kind == .face, !r.outlineLoops.isEmpty else { outlineRows.append("r\(rid) no outline (rectangle)"); continue }
            let seamFlags = r.outlineSeams.flatMap { $0 }
            let tilts = r.outlineSeamTilt.flatMap { $0 }
            let diverging = zip(seamFlags, tilts).filter { $0.0 && $0.1 > 1e-9 }.count
            var moved = 0.0
            for loop in r.wireOutlineLoops { for q in loop {
                moved = Swift.max(moved, abs(LatticeFaceOutline.signedDistance(q, loops: r.outlineLoops)))
            }}
            outlineRows.append(String(format: "r%d expand=%.3f seams=%d diverging=%d wireMovedOffRaw=%.4fmm",
                                      rid, r.inPlaneOffsetMM, seamFlags.filter { $0 }.count, diverging, moved))
        }
        print("DG-OUTLINE " + outlineRows.joined(separator: " | "))
        // ★★ NO TWO CELLS OF ONE REGION OVERLAP, on his projects (the reviewer, 2026-10-10 20:05/20:20)
        let overlaps = LatticeSteppedCell.sameRegionOverlaps(b.cells)
        print("DG-OVERLAPS \(overlaps.count) same-region pair(s)"
              + (overlaps.first.map { o in String(format: " | first: region %d, %.4g mm × %.4g mm, shared %.4f × %.4f × %.4f mm",
                                                   o.region, b.cells[o.a].sizeMM, b.cells[o.b].sizeMM,
                                                   o.extentMM.x, o.extentMM.y, o.extentMM.z) } ?? ""))
        XCTAssertEqual(overlaps.count, 0, "★ no two cells of one region overlap")
        // ★ PER REGION: the plan's sizes, and the UNCOVERED volume — the region's prism material that no plan
        // cell covers (the reviewer, 2026-10-10 20:20, condition 2: a slot part no chain covers is treated as
        // the back strip is; report it per region before and after the packer fix). Counted on the scene's
        // prism-clipped occupancy at its own voxel; a voxel any region's cell covers is covered.
        do {
            let po = s1.prismOccupancy
            let h = Double(Swift.max(po.spacing.x, Swift.max(po.spacing.y, po.spacing.z)))
            let bucket = 8.0
            struct K: Hashable { let x: Int; let y: Int; let z: Int }
            func key(_ p: SIMD3<Double>) -> K { K(x: Int((p.x / bucket).rounded(.down)), y: Int((p.y / bucket).rounded(.down)), z: Int((p.z / bucket).rounded(.down))) }
            var grid: [K: [Int]] = [:]
            for (ci, c) in b.cells.enumerated() {
                let k0 = key(c.originMM), k1 = key(c.originMM + c.sizeMM)
                for x in k0.x...k1.x { for y in k0.y...k1.y { for z in k0.z...k1.z { grid[K(x: x, y: y, z: z), default: []].append(ci) } } }
            }
            var prismVox = [Int: Int](), bare = [Int: Int]()
            for k in 0..<po.nz { for j in 0..<po.ny { for i in 0..<po.nx where po.values[(k * po.ny + j) * po.nx + i] > 0.5 {
                let p = SIMD3<Double>(po.origin + SIMD3<Float>(Float(i) + 0.5, Float(j) + 0.5, Float(k) + 0.5) * po.spacing)
                guard let ri = b.regions.indices.first(where: { b.regions[$0].role == .include && b.regions[$0].kind == .face
                    && LatticeRegionMask.containsWholePrism(p, region: b.regions[$0]) }) else { continue }
                prismVox[ri, default: 0] += 1
                let covered = (grid[key(p)] ?? []).contains { ci in
                    let c = b.cells[ci]
                    return p.x >= c.originMM.x && p.x < c.originMM.x + c.sizeMM && p.y >= c.originMM.y && p.y < c.originMM.y + c.sizeMM
                        && p.z >= c.originMM.z && p.z < c.originMM.z + c.sizeMM
                }
                if !covered { bare[ri, default: 0] += 1 }
            }}}
            var rows: [String] = []
            var id = 0
            for (ri, r) in b.regions.enumerated() where r.role == .include {
                id += 1
                let cells = b.cells.filter { $0.region == ri }
                let hist = Dictionary(grouping: cells, by: { ($0.sizeMM * 100).rounded() / 100 }).mapValues(\.count)
                    .sorted { $0.key > $1.key }.map { String(format: "%.2f=%d", $0.key, $0.value) }.joined(separator: " ")
                let pv = prismVox[ri] ?? 0, bv = bare[ri] ?? 0
                rows.append(String(format: "r%d cells=%d [%@] prism=%.0f mm3 uncovered=%.0f mm3 (%.2f%%)", id, cells.count, hist,
                                   Double(pv) * h * h * h, Double(bv) * h * h * h, pv > 0 ? 100 * Double(bv) / Double(pv) : 0))
            }
            print(String(format: "DG-REGIONS voxel=%.3f mm | ", h) + rows.joined(separator: " | "))
        }
        // ★ THE PICTURE (condition 1): the same views, before and after, through the app's own renderer
        if let dir = env["DG_RENDER_DIR"] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for body in [Float(1), 0] {
                mr.setBodyAlpha(body)
                for (name, az, el) in [("front", Float(0.6), Float(0.35)), ("back", Float(3.74), Float(0.35)), ("top", Float(0.6), Float(1.2))] {
                    LatticeQuiltFrameProbe.aim(mr, mesh.bounds, azimuth: az, elevation: el, zoom: 0.9, height: 0.5)
                    guard let px = mr.renderOffscreen(size: 1200, clear: MTLClearColor(red: 0.05, green: 0.06, blue: 0.1, alpha: 1)) else { continue }
                    let path = dir + "/\(body > 0 ? "part" : "lattice")_\(name).png"
                    LatticeQuiltFrameProbe.writePNG(px, size: 1200, to: path)
                    print("DG-RENDER \(path)")
                }
            }
        }

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
            if case .failure(let why) = LatticeSteppedCellWire.plannedRegions(lat.steppedCells, regions: lat.regions) {
                print("DG-WITHHELD \(why.reason) | \(why)")
                // ★ FOR #358's K2 (the reviewer, 2026-10-08: "slot_origin_mm becomes a grid phase, with
                // depth measured from the region's own plane"): the plan the app withholds, written as
                // the job K2 must accept — every planned region stamped with the bake's grid point,
                // on its plane or not. The app never sends this; core at 36f5fdde refuses it.
                var k2 = try XCTUnwrap(JSONSerialization.jsonObject(with: withPlan) as? [String: Any])
                var lk = try XCTUnwrap(k2["lattice"] as? [String: Any])
                lk["stepped_cells"] = lat.steppedCells.map { $0.wireDictionary }
                var grid: [Int: SIMD3<Double>] = [:], base: [Int: Double] = [:]
                for c in lat.steppedCells {
                    if let so = c.slotOriginMM, grid[c.regionID] == nil { grid[c.regionID] = so }
                    if let b = c.planBaseCellMM, base[c.regionID] == nil { base[c.regionID] = b }
                }
                if var regs = lk["regions"] as? [[String: Any]] {
                    var id = 0
                    for (i, r) in lat.regions.enumerated() where r.role == .include {
                        id += 1
                        guard var g = regs[i]["geometry"] as? [String: Any] else { continue }
                        if let so = grid[id] { g["slot_origin_mm"] = [so.x, so.y, so.z] }
                        if let b = base[id] { g["plan_base_cell_mm"] = b }
                        regs[i]["geometry"] = g
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
        // the planned regions' grids (slot_origin_mm, 2026-10-08) and bases (plan_base_cell_mm, K1,
        // 2026-10-09) ride with the plan
        var stamped = 0
        var bases: [String] = []
        if var regs = la["regions"] as? [[String: Any]] {
            for i in regs.indices {
                guard var g = regs[i]["geometry"] as? [String: Any] else { continue }
                if let b = g.removeValue(forKey: "plan_base_cell_mm") as? Double {
                    bases.append("job region \(i + 1): \(String(format: "%.4f", b)) mm")
                }
                if g.removeValue(forKey: "slot_origin_mm") != nil { stamped += 1 }
                regs[i]["geometry"] = g
            }
            la["regions"] = regs
        }
        a["lattice"] = la
        print("DG-SLOT-ORIGINS \(stamped) region(s) carry slot_origin_mm")
        print("DG-PLAN-BASES \(bases.count) region(s) carry plan_base_cell_mm | " + bases.joined(separator: "; "))
        XCTAssertEqual(try pretty(JSONSerialization.data(withJSONObject: a)), try pretty(noPlan),
                       "★ the jobs differ only by the plan and its regions' grids")
        XCTAssertNil((n["lattice"] as? [String: Any])?["stepped_cells"], "production sends no plan")
        print("DG-JOBS \(out.path) model \(modelName)")
    }
}
