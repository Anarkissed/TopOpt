import XCTest
import Metal
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★ THE OWNER SWAP'S PARITY PROOF (reviewer, 2026-10-08, approved by the maintainer: "Swap R7's
/// owner to core's exported stepped_region_owner through the guarded bridge, with a parity test on
/// 68BF7B74"; rulings (a) and (b) the same day). Opt-in, on a COPY of his project, one process, one
/// scene, one texel grid, through the app's own renderer (the R7 proof's harness):
///   1. the bake under CORE's owner, twice (a null control), and under the Swift rule and under
///      declaration order (the RED arms);
///   2. CORE'S STRADDLER PREDICATE (stepped_plan.cpp:360-364) on every cross-region overlapping pair:
///      both centres owned, by core, by their own regions — 0 violations under core's owner, and
///      > 0 under declaration order (the RED control);
///   3. the Swift rule against core POINT BY POINT, at every cell centre and every painted texel's
///      middle, with each disagreement classified;
///   4. ruling (a)'s and (b)'s counts: contested cells core gives to no region / a third region;
///      shared texels to the owner, to a third claimant, emptied (owner 0), emptied (owner with no
///      cell there);
///   5. the plan as a job (`job_owner_core.json`, stepped_cells + slot_origin_mm), for #358's gate.
///
///     OWNER_PROJECT_DIR=<copy of a project folder> OWNER_OUT=<dir> swift test --filter LatticeCoreOwnerParityProof
final class LatticeCoreOwnerParityProof: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        while u.path != "/" && !FileManager.default.fileExists(atPath: u.appendingPathComponent("core/src/materials/materials.json").path) {
            u = u.deletingLastPathComponent()
        }
        return u
    }()

    @MainActor
    func testCoreOwnsEveryContestOn68BF7B74() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dirPath = env["OWNER_PROJECT_DIR"], let outPath = env["OWNER_OUT"] else { throw XCTSkip("OWNER_PROJECT_DIR, OWNER_OUT") }
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let src = URL(fileURLWithPath: dirPath), out = URL(fileURLWithPath: outPath)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let snap = try JSONDecoder().decode(ProjectSnapshot.self, from: Data(contentsOf: src.appendingPathComponent("project.json")))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("owner-proof-\(UUID().uuidString)", isDirectory: true)
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
        print("OWNER-PROJECT \(pm.name) algorithm \(lat.algorithm) stage \(String(describing: lat.stageMode)) step-halves \(lat.gradeStepsAreHalves) density \(lat.densityMode) cells \(lat.cellSizeMode)")
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
        var lastStats = LatticePreviewOccupancy.OctreeBakeStats()
        LatticePreviewOccupancy.octreeBakeObserver = { _, st in lastStats = st }
        func bakeOnce(ownership: Bool, core: Bool = true, stepDown: Bool = true, incremental: Bool = true, token: Int) throws
            -> (LatticeCellField, [LatticeSteppedCell], [LatticeRegionSpec], LatticePreviewOccupancy.OctreeBakeStats) {
            LatticePreviewOccupancy.centreOwnershipEnabled = ownership
            LatticePreviewOccupancy.coreOwnershipEnabled = core
            LatticePreviewOccupancy.stepDownEnabled = stepDown
            LatticePreviewOccupancy.stepDownIncremental = incremental
            baked = nil
            mr.setLatticeScene(s1, token: token)
            let b = try XCTUnwrap(baked, "the bake handed back no plan")
            let f = try XCTUnwrap(mr.latticeLayerForTests?.cellField, "no cell field")
            return (f, b.cells, b.regions, lastStats)
        }
        let saved = LatticePreviewOccupancy.centreOwnershipEnabled
        let savedCore = LatticePreviewOccupancy.coreOwnershipEnabled
        let savedStep = LatticePreviewOccupancy.stepDownEnabled
        let savedIncr = LatticePreviewOccupancy.stepDownIncremental
        defer {
            LatticePreviewOccupancy.centreOwnershipEnabled = saved
            LatticePreviewOccupancy.coreOwnershipEnabled = savedCore
            LatticePreviewOccupancy.stepDownEnabled = savedStep
            LatticePreviewOccupancy.stepDownIncremental = savedIncr
            LatticePreviewOccupancy.octreeBakeObserver = nil
        }
        let (coreField, cellsCore, regions0, stCore) = try bakeOnce(ownership: true, token: 21)
        let (coreAgain, cellsCoreAgain, _, _) = try bakeOnce(ownership: true, token: 22)        // null control
        let (swiftField, cellsSwift, _, stSwift) = try bakeOnce(ownership: true, core: false, token: 23)
        let (_, cellsDecl, _, _) = try bakeOnce(ownership: false, token: 24)                    // the RED arm
        XCTAssertNil(stCore.coreOwnerRefusal, "★ core answered every ownership question")
        XCTAssertGreaterThan(stCore.coreOwnerCalls, 0, "★ the bake asked core")
        XCTAssertEqual(coreAgain.steppedCellMM.map(\.bitPattern), coreField.steppedCellMM.map(\.bitPattern), "null control")
        XCTAssertEqual(cellsCoreAgain, cellsCore, "null control")
        XCTAssertEqual(coreField.field.origin, swiftField.field.origin, "the same texel grid")

        // ── core's owner of any points, as scene region indices (nil = no owner)
        let wire = regions0.map { $0.wireDictionary }
        let includeIndex = regions0.indices.filter { regions0[$0].role == .include }
        func coreOwners(_ pts: [SIMD3<Double>]) throws -> [Int?] {
            let r = try XCTUnwrap(TopOptKit.steppedRegionOwners(regions: wire, points: pts), TopOptKit.lastCoreRefusal ?? "no answer")
            XCTAssertEqual(r.includes, includeIndex.count, "★ core resolved every include the job declares")
            return r.owners.map { $0 >= 1 && $0 <= includeIndex.count ? includeIndex[$0 - 1] : nil }
        }
        func centre(_ c: LatticeSteppedCell) -> SIMD3<Double> { c.originMM + SIMD3<Double>(repeating: 0.5 * c.sizeMM) }

        // ── 2. core's straddler predicate on every cross-region overlapping pair
        func pairs(_ cells: [LatticeSteppedCell]) -> [(Int, Int)] {
            var out: [(Int, Int)] = []
            let big = cells.map(\.sizeMM).max() ?? 1
            var buckets: [SIMD3<Int>: [Int]] = [:]
            func key(_ p: SIMD3<Double>) -> SIMD3<Int> {
                SIMD3<Int>(Int((p.x / big).rounded(.down)), Int((p.y / big).rounded(.down)), Int((p.z / big).rounded(.down)))
            }
            for (i, c) in cells.enumerated() { buckets[key(c.originMM), default: []].append(i) }
            for (i, a) in cells.enumerated() {
                let ka = key(a.originMM)
                for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
                    for j in buckets[ka &+ SIMD3<Int>(dx, dy, dz)] ?? [] where j > i && cells[j].region != a.region {
                        let b = cells[j]
                        var o = true
                        for ax in 0..<3 where Swift.min(a.originMM[ax] + a.sizeMM, b.originMM[ax] + b.sizeMM)
                            - Swift.max(a.originMM[ax], b.originMM[ax]) <= 1e-6 { o = false }
                        if o { out.append((i, j)) }
                    }
                }}}
            }
            return out
        }
        func straddlerViolations(_ cells: [LatticeSteppedCell], _ tag: String) throws -> Int {
            let ps = pairs(cells)
            let involved = Array(Set(ps.flatMap { [$0.0, $0.1] })).sorted()
            let owners = try coreOwners(involved.map { centre(cells[$0]) })
            var ownerOf: [Int: Int?] = [:]
            for (n, i) in involved.enumerated() { ownerOf[i] = owners[n] }
            var bad = 0, byKind: [String: Int] = [:]
            for (i, j) in ps {
                let oi = ownerOf[i]!, oj = ownerOf[j]!
                guard oi != cells[i].region || oj != cells[j].region else { continue }
                bad += 1
                for (o, me) in [(oi, cells[i].region), (oj, cells[j].region)] where o != me {
                    byKind[o == nil ? "owner 0" : (o == cells[i].region || o == cells[j].region ? "the other region" : "a third region"), default: 0] += 1
                }
            }
            print("OWNER-PAIRS \(tag): cross-region overlapping pairs \(ps.count), core's predicate refuses \(bad) \(byKind.sorted { $0.key < $1.key })")
            return bad
        }
        XCTAssertEqual(try straddlerViolations(cellsCore, "core"), 0, "★ the bar: core accepts every straddler")
        let swiftBad = try straddlerViolations(cellsSwift, "swift-rule")
        XCTAssertGreaterThan(try straddlerViolations(cellsDecl, "declaration-order"), 0,
                             "RED control: the declaration-order bake has pairs core refuses")

        // ── 3. the Swift rule against core, point by point (cell centres and painted texels' middles)
        let g = coreField.field
        let pitch = Double(g.spacing.x), gorigin = SIMD3<Double>(g.origin)
        var pts = cellsCore.map(centre) + cellsSwift.map(centre)
        for idx in coreField.steppedTexelCell.indices where coreField.steppedTexelCell[idx] >= 0 {
            let i = idx % g.nx, j = (idx / g.nx) % g.ny, k = idx / (g.nx * g.ny)
            pts.append(gorigin + (SIMD3<Double>(Double(i), Double(j), Double(k)) + 0.5) * pitch)
        }
        let coreO = try coreOwners(pts)
        var agree = 0, kinds: [String: Int] = [:], samples: [String] = []
        for (n, p) in pts.enumerated() {
            let s = LatticePreviewOccupancy.owner(of: p, regions: regions0)
            if s == coreO[n] { agree += 1; continue }
            let k = s == nil ? "swift none, core r" : (coreO[n] == nil ? "core none, swift r" : "both own, differ")
            kinds[k, default: 0] += 1
            if samples.count < 12 {
                samples.append(String(format: "(%.3f,%.3f,%.3f) swift %@ core %@", p.x, p.y, p.z,
                                      s.map { "r\($0)" } ?? "-", coreO[n].map { "r\($0)" } ?? "-"))
            }
        }
        print("OWNER-PARITY points \(pts.count): agree \(agree), differ \(pts.count - agree) \(kinds.sorted { $0.key < $1.key }) \(samples)")

        // ── 4. the rulings' counts
        print("OWNER-RULING-A contested \(stCore.contestedCells) (final round) | yielded: owner 0 \(stCore.yieldedOwner0), a third region \(stCore.yieldedThirdRegion) | rounds \(stCore.stepDownRounds) stepped down \(stCore.cellsSteppedDown) dropped at the finest \(stCore.cellsDroppedAtFinest) | bridge calls \(stCore.coreOwnerCalls) points \(stCore.coreOwnerPoints)")
        print("OWNER-RULING-B shared texels \(stCore.sharedTexels): to core's owner \(stCore.sharedTexelsToOwner) (a third claimant \(stCore.sharedTexelsToThird)) | emptied: owner 0 \(stCore.sharedTexelsEmptiedOwner0), owner with no cell there \(stCore.sharedTexelsEmptiedOwnerNoCell)")
        print("OWNER-CELLS core \(cellsCore.count) swift-rule \(cellsSwift.count) (swift-rule straddlers core refuses \(swiftBad); swift-rule bake reassigned \(stSwift.texelsReassigned) texels) declaration-order \(cellsDecl.count)")

        // ── 5. the plan as a job: stepped_cells and slot_origin_mm through the ONE writer (switch forced on)
        let request = try XCTUnwrap(model.makeLatticeRunRequest(), "no stage job")
        var job = try XCTUnwrap(JSONSerialization.jsonObject(with: RemoteRun.buildJobJSON(request, steppedPlans: false)) as? [String: Any])
        var latBlock = try XCTUnwrap(job["lattice"] as? [String: Any])
        var spec = try XCTUnwrap(request.lattice)
        spec.steppedCells = LatticeSteppedCellWire.wire(cellsCore, regions: regions0)
        // ★ a Stepped plan rides only behind its own test switch (round 5); nil from the writer means
        // "sent" OR "not asked", so the cells on the block are what is reported (fixed 2026-10-08: the
        // first run reported "sent" for a job that carried none)
        let savedAnyStep = LatticeSteppedCellWire.anyStepPlansForTests
        LatticeSteppedCellWire.anyStepPlansForTests = spec.algorithm == "stepped"
        defer { LatticeSteppedCellWire.anyStepPlansForTests = savedAnyStep }
        let withheld = LatticeSteppedCellWire.writePlan(into: &latBlock, for: spec, wired: true, enabled: true)
        let carried = (latBlock["stepped_cells"] as? [Any])?.count ?? 0
        XCTAssertTrue(withheld != nil || carried == spec.steppedCells.count, "★ the job carries the whole plan, or says why not")
        job["lattice"] = latBlock
        try JSONSerialization.data(withJSONObject: job, options: [.prettyPrinted, .sortedKeys])
            .write(to: out.appendingPathComponent("job_owner_core.json"))
        print("OWNER-JOB \(out.path)/job_owner_core.json plan "
              + (withheld.map { "WITHHELD: \($0.reason)" } ?? (carried > 0 ? "sent (\(carried) cells)" : "NOT SENT")))
    }
}
