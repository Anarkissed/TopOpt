import XCTest
import Metal
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★ THE R7 PROOF (maintainer, 2026-10-03): "Prove on 68BF7B74 that the overlaps go from 1,367
/// to 0 and that the preview changes only in those cells." Opt-in. One process, one scene, one
/// texel grid: the bake with centre ownership OFF (declaration order, the bake before R7) and
/// ON, through the app's own renderer in `MetalMeshView.apply`'s order, then
///   - the plan's exact cross-region overlaps before and after (and per region pair);
///   - the texel diff, every changed texel mapped to the BEFORE plan's contested cells;
///   - the after-plan written as a job (`job_r7.json`) for `classify_plan.py`.
///
///     R7_PROJECT_DIR=<copy of a project folder> R7_OUT=<dir> swift test --filter LatticeR7OwnershipProof
final class LatticeR7OwnershipProof: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        while u.path != "/" && !FileManager.default.fileExists(atPath: u.appendingPathComponent("core/src/materials/materials.json").path) {
            u = u.deletingLastPathComponent()
        }
        return u
    }()

    /// Positive-volume overlaps between cells of different regions, with the region pairs.
    static func crossOverlaps(_ cells: [LatticeSteppedCell]) -> (count: Int, pairs: [String: Int], cells: Set<Int>) {
        var count = 0, pairs: [String: Int] = [:], involved = Set<Int>()
        let big = cells.map(\.sizeMM).max() ?? 1
        var buckets: [SIMD3<Int>: [Int]] = [:]
        func key(_ p: SIMD3<Double>) -> SIMD3<Int> {
            SIMD3<Int>(Int((p.x / big).rounded(.down)), Int((p.y / big).rounded(.down)), Int((p.z / big).rounded(.down)))
        }
        for (i, c) in cells.enumerated() { buckets[key(c.originMM), default: []].append(i) }
        for (i, a) in cells.enumerated() {
            let ka = key(a.originMM)
            for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
                for j in buckets[ka &+ SIMD3<Int>(dx, dy, dz)] ?? [] where j > i {
                    let b = cells[j]
                    guard a.region != b.region else { continue }
                    var o = true
                    for ax in 0..<3 where Swift.min(a.originMM[ax] + a.sizeMM, b.originMM[ax] + b.sizeMM)
                        - Swift.max(a.originMM[ax], b.originMM[ax]) <= 1e-6 { o = false }
                    guard o else { continue }
                    count += 1
                    pairs["(\(Swift.min(a.region, b.region)),\(Swift.max(a.region, b.region)))", default: 0] += 1
                    involved.insert(i); involved.insert(j)
                }
            }}}
        }
        return (count, pairs, involved)
    }

    @MainActor
    func testTheOverlapsAndTheTexelsBeforeAndAfter() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dirPath = env["R7_PROJECT_DIR"], let outPath = env["R7_OUT"] else { throw XCTSkip("R7_PROJECT_DIR, R7_OUT") }
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let src = URL(fileURLWithPath: dirPath), out = URL(fileURLWithPath: outPath)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let snap = try JSONDecoder().decode(ProjectSnapshot.self, from: Data(contentsOf: src.appendingPathComponent("project.json")))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("r7-proof-\(UUID().uuidString)", isDirectory: true)
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
        print("R7-PROJECT \(pm.name) algorithm \(lat.algorithm) stage \(String(describing: lat.stageMode)) step-halves \(lat.gradeStepsAreHalves) density \(lat.densityMode) cells \(lat.cellSizeMode)")
        try XCTSkipUnless(["doubled", "stepped"].contains(lat.algorithm), "R7 is the octree bake's (Default Grade / Stepped)")

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
        // ── the two bakes, one process, one scene
        func bakeOnce(ownership: Bool, token: Int) throws -> (LatticeCellField, [LatticeSteppedCell], [LatticeRegionSpec]) {
            LatticePreviewOccupancy.centreOwnershipEnabled = ownership
            baked = nil
            mr.setLatticeScene(s1, token: token)
            let b = try XCTUnwrap(baked, "the bake handed back no plan")
            let f = try XCTUnwrap(mr.latticeLayerForTests?.cellField, "no cell field")
            return (f, b.cells, b.regions)
        }
        let saved = LatticePreviewOccupancy.centreOwnershipEnabled
        defer { LatticePreviewOccupancy.centreOwnershipEnabled = saved }
        let (before, cellsBefore, regionsBefore) = try bakeOnce(ownership: false, token: 11)
        let (after, cellsAfter, _) = try bakeOnce(ownership: true, token: 12)
        let (again, cellsAgain, _) = try bakeOnce(ownership: true, token: 13)   // null control
        XCTAssertEqual(before.field.origin, after.field.origin, "★ the same texel grid (else the diff means nothing)")
        XCTAssertEqual([before.field.nx, before.field.ny, before.field.nz], [after.field.nx, after.field.ny, after.field.nz])
        XCTAssertEqual(after.steppedCellMM, again.steppedCellMM, "null control: two ON bakes agree")
        XCTAssertEqual(cellsAfter, cellsAgain)

        let ob = Self.crossOverlaps(cellsBefore), oa = Self.crossOverlaps(cellsAfter)
        print("R7-OVERLAPS before \(ob.count) \(ob.pairs.sorted { $0.key < $1.key }) | after \(oa.count) \(oa.pairs.sorted { $0.key < $1.key })")
        print("R7-CELLS before \(cellsBefore.count) after \(cellsAfter.count) | contested-before \(ob.cells.count)")

        // ── the texel diff, mapped to the BEFORE plan's contested cells
        let g = before.field
        let pitch = Double(g.spacing.x)
        let gorigin = SIMD3<Double>(g.origin)
        let boxes = ob.cells.map { cellsBefore[$0] }
        func inContested(_ p: SIMD3<Double>) -> Bool {
            boxes.contains { c in
                (0..<3).allSatisfy { ax in p[ax] >= c.originMM[ax] - 1e-9 && p[ax] <= c.originMM[ax] + c.sizeMM + 1e-9 }
            }
        }
        var changed = 0, inside = 0, outside = 0, outsideSamples: [String] = []
        for k in 0..<g.nz { for j in 0..<g.ny { for i in 0..<g.nx {
            let idx = (k * g.ny + j) * g.nx + i
            let differ = before.field.values[idx].bitPattern != after.field.values[idx].bitPattern
                || before.steppedCellMM[idx].bitPattern != after.steppedCellMM[idx].bitPattern
                || before.steppedPhase[idx].bitPattern != after.steppedPhase[idx].bitPattern
                || before.steppedOrigin[idx] != after.steppedOrigin[idx]
                || before.level[idx].bitPattern != after.level[idx].bitPattern
            guard differ else { continue }
            changed += 1
            let mid = gorigin + (SIMD3<Double>(Double(i), Double(j), Double(k)) + 0.5) * pitch
            if inContested(mid) { inside += 1 } else {
                outside += 1
                if outsideSamples.count < 8 { outsideSamples.append(String(format: "(%.2f,%.2f,%.2f) size %.2f→%.2f", mid.x, mid.y, mid.z, before.steppedCellMM[idx], after.steppedCellMM[idx])) }
            }
        }}}
        print("R7-TEXELS changed \(changed) inside-contested \(inside) outside \(outside) of \(g.nx * g.ny * g.nz) \(outsideSamples)")

        // ── the after-plan as a job, for classify_plan.py (core's check, every cell)
        let request = try XCTUnwrap(model.makeLatticeRunRequest(), "no stage job")
        func planJob(_ cells: [LatticeSteppedCell]) throws -> Data {
            let wire = LatticeSteppedCellWire.wire(cells, regions: regionsBefore)
            var job = try XCTUnwrap(JSONSerialization.jsonObject(with: RemoteRun.buildJobJSON(request, steppedPlans: false)) as? [String: Any])
            var lat = try XCTUnwrap(job["lattice"] as? [String: Any])
            lat["stepped_cells"] = wire.map { $0.wireDictionary }
            job["lattice"] = lat
            return try JSONSerialization.data(withJSONObject: job, options: [.prettyPrinted, .sortedKeys])
        }
        try planJob(cellsBefore).write(to: out.appendingPathComponent("job_r7_before.json"))
        try planJob(cellsAfter).write(to: out.appendingPathComponent("job_r7_after.json"))
        print("R7-JOBS \(out.path)")
    }
}
