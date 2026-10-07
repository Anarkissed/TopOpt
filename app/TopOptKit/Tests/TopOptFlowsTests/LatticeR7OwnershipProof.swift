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
        var lastStats = LatticePreviewOccupancy.OctreeBakeStats()
        LatticePreviewOccupancy.octreeBakeObserver = { _, st in lastStats = st }
        func bakeOnce(ownership: Bool, stepDown: Bool = true, token: Int) throws
            -> (LatticeCellField, [LatticeSteppedCell], [LatticeRegionSpec], LatticePreviewOccupancy.OctreeBakeStats) {
            LatticePreviewOccupancy.centreOwnershipEnabled = ownership
            LatticePreviewOccupancy.stepDownEnabled = stepDown
            baked = nil
            mr.setLatticeScene(s1, token: token)
            let b = try XCTUnwrap(baked, "the bake handed back no plan")
            let f = try XCTUnwrap(mr.latticeLayerForTests?.cellField, "no cell field")
            return (f, b.cells, b.regions, lastStats)
        }
        let saved = LatticePreviewOccupancy.centreOwnershipEnabled
        let savedStep = LatticePreviewOccupancy.stepDownEnabled
        defer {
            LatticePreviewOccupancy.centreOwnershipEnabled = saved
            LatticePreviewOccupancy.stepDownEnabled = savedStep
            LatticePreviewOccupancy.octreeBakeObserver = nil
        }
        let (before, cellsBefore, regionsBefore, _) = try bakeOnce(ownership: false, token: 11)
        let (after, cellsAfter, _, stAfter) = try bakeOnce(ownership: true, token: 12)
        let (again, cellsAgain, _, _) = try bakeOnce(ownership: true, token: 13)   // null control
        // R7 as first landed (2026-10-05), a yielded cell's share left as air — the step-down's "before"
        let (noStep, cellsNoStep, _, stNoStep) = try bakeOnce(ownership: true, stepDown: false, token: 14)
        print("R7-STEPDOWN rounds \(stAfter.stepDownRounds) stepped down \(stAfter.cellsSteppedDown) dropped at the finest rung \(stAfter.cellsDroppedAtFinest) | contested \(stAfter.contestedCells) yielded in the final pass \(stAfter.cellsYielded) straddler pairs \(stAfter.straddlerPairs) | without the step-down: yielded \(stNoStep.cellsYielded)")
        XCTAssertEqual(before.field.origin, after.field.origin, "★ the same texel grid (else the diff means nothing)")
        XCTAssertEqual([before.field.nx, before.field.ny, before.field.nz], [after.field.nx, after.field.ny, after.field.nz])
        XCTAssertEqual(after.steppedCellMM, again.steppedCellMM, "null control: two ON bakes agree")
        XCTAssertEqual(cellsAfter, cellsAgain)

        // ── the bar (reviewer, 2026-10-05): every cross-region overlapping pair, split into
        //    (a) a cell's centre is owned by the OTHER region — must be 0 after;
        //    (b) a straddler — each centre is its own region's — allowed, counted and listed.
        func rank(_ r: Int, _ p: SIMD3<Double>) -> (Int, Double, Int) {
            let reg = regionsBefore[r]
            return (LatticeRegionMask.contains(p, region: reg) ? 0 : 1,
                    abs(simd_dot(p - reg.origin, LatticeRegionMask.unit(reg.normal))), r)
        }
        func owner(_ c: LatticeSteppedCell, among rs: [Int]) -> Int? {
            let centre = c.originMM + SIMD3<Double>(repeating: 0.5 * c.sizeMM)
            var best: (Int, Double, Int)? = nil
            for r in rs {
                let rr = rank(r, centre)
                guard rr.0 == 0 else { continue }          // only a prism that CONTAINS the centre owns it
                if let b = best {
                    if abs(rr.1 - b.1) > 1e-9 ? rr.1 < b.1 : rr.2 < b.2 { best = rr }
                } else { best = rr }
            }
            return best?.2
        }
        func split(_ cells: [LatticeSteppedCell]) -> (a: Int, b: Int, aPairs: [String: Int], bPairs: [String: Int], straddlers: [String]) {
            var a = 0, b = 0, ap: [String: Int] = [:], bp: [String: Int] = [:], list: [String] = []
            for (i, x) in cells.enumerated() { for j in (i + 1)..<cells.count where cells[j].region != x.region {
                let y = cells[j]
                var o = true
                for ax in 0..<3 where Swift.min(x.originMM[ax] + x.sizeMM, y.originMM[ax] + y.sizeMM)
                    - Swift.max(x.originMM[ax], y.originMM[ax]) <= 1e-6 { o = false }
                guard o else { continue }
                let rs = [x.region, y.region]
                let key = "(\(Swift.min(x.region, y.region)),\(Swift.max(x.region, y.region)))"
                if owner(x, among: rs) == y.region || owner(y, among: rs) == x.region {
                    a += 1; ap[key, default: 0] += 1
                } else {
                    b += 1; bp[key, default: 0] += 1
                    list.append(String(format: "r%d %.3f@(%.3f,%.3f,%.3f) × r%d %.3f@(%.3f,%.3f,%.3f)",
                                       x.region, x.sizeMM, x.originMM.x, x.originMM.y, x.originMM.z,
                                       y.region, y.sizeMM, y.originMM.x, y.originMM.y, y.originMM.z))
                }
            }}
            return (a, b, ap, bp, list)
        }
        let sb = split(cellsBefore), sa = split(cellsAfter)
        print("R7-PAIRS before (a) centre-owned-by-other \(sb.a) \(sb.aPairs.sorted { $0.key < $1.key }) | (b) straddlers \(sb.b) \(sb.bPairs.sorted { $0.key < $1.key })")
        print("R7-PAIRS after  (a) centre-owned-by-other \(sa.a) \(sa.aPairs.sorted { $0.key < $1.key }) | (b) straddlers \(sa.b) \(sa.bPairs.sorted { $0.key < $1.key })")
        print("R7-CELLS before \(cellsBefore.count) after \(cellsAfter.count)")
        XCTAssertEqual(sa.a, 0, "★ the bar: no overlap where a cell's centre is owned by another region")
        XCTAssertGreaterThan(sb.a, 0, "positive control: the declaration-order bake has such overlaps")
        try sa.straddlers.joined(separator: "\n").write(to: out.appendingPathComponent("r7_straddlers_after.txt"), atomically: true, encoding: .utf8)

        // ── the preview changes only where a texel's OWNER changed, or in a cell that stepped down
        let g = before.field
        let pitch = Double(g.spacing.x)
        let gorigin = SIMD3<Double>(g.origin)
        func ownerRegion(_ f: LatticeCellField, _ cells: [LatticeSteppedCell], _ idx: Int) -> Int {
            let ci = Int(f.steppedTexelCell[idx])
            return ci >= 0 && ci < cells.count ? cells[ci].region : -1
        }
        func ck(_ c: LatticeSteppedCell) -> String { "\(c.region)|\(c.originMM)|\(c.sizeMM)" }
        /// The texel's own cell, by the bake's texel → cell index (exact; a face-plane texel's
        /// middle sits up to a pitch OUTSIDE its cell's box, so a box test misses it).
        func cellOf(_ f: LatticeCellField, _ cells: [LatticeSteppedCell], _ idx: Int) -> LatticeSteppedCell? {
            let ci = Int(f.steppedTexelCell[idx])
            return ci >= 0 && ci < cells.count ? cells[ci] : nil
        }
        /// Every texel the rule-off bake and `after` disagree on, classified; returns the texels
        /// that changed outside any cell whose owner changed or that stepped down, and the air.
        func texelDiff(_ after: LatticeCellField, _ cellsAfter: [LatticeSteppedCell], _ tag: String)
            -> (sameOwnerElsewhere: Int, emptied: Int) {
            XCTAssertEqual(after.steppedTexelCell.count, g.nx * g.ny * g.nz)
            XCTAssertEqual(after.field.origin, g.origin, "★ the same texel grid (\(tag))")
            let afterKeys = Set(cellsAfter.map(ck))
            let gone = cellsBefore.filter { !afterKeys.contains(ck($0)) }
            let goneKeys = Set(gone.map(ck))
            let beforeKeys = Set(cellsBefore.map(ck))
            var sameOwnerInGone = 0, sameOwnerNewCell = 0
            var changed = 0, ownerChanged = 0, sameOwner = 0, samples: [String] = []
            var flows: [String: Int] = [:]
            var emptied: [String: Int] = [:]   // texels left with no cell, by whose space they are
            for k in 0..<g.nz { for j in 0..<g.ny { for i in 0..<g.nx {
                let idx = (k * g.ny + j) * g.nx + i
                let differ = before.field.values[idx].bitPattern != after.field.values[idx].bitPattern
                    || before.steppedCellMM[idx].bitPattern != after.steppedCellMM[idx].bitPattern
                    || before.steppedPhase[idx].bitPattern != after.steppedPhase[idx].bitPattern
                    || before.steppedOrigin[idx] != after.steppedOrigin[idx]
                    || before.level[idx].bitPattern != after.level[idx].bitPattern
                guard differ else { continue }
                changed += 1
                let ob = ownerRegion(before, cellsBefore, idx), oa = ownerRegion(after, cellsAfter, idx)
                if ob != oa {
                    ownerChanged += 1; flows["r\(ob)→r\(oa)", default: 0] += 1
                    if oa < 0, ob >= 0 {
                        // lattice → no cell: whose space is it, point by point (the same rank)?
                        let mid = gorigin + (SIMD3<Double>(Double(i), Double(j), Double(k)) + 0.5) * pitch
                        var best: (Int, Double, Int)? = nil
                        for r in regionsBefore.indices {
                            let rr = rank(r, mid)
                            guard rr.0 == 0 else { continue }
                            if let b = best { if abs(rr.1 - b.1) > 1e-9 ? rr.1 < b.1 : rr.2 < b.2 { best = rr } } else { best = rr }
                        }
                        let who = best.map { $0.2 == ob ? "its-own" : "r\($0.2)'s" } ?? "no-prism"
                        emptied[who, default: 0] += 1
                    }
                } else {
                    let mid = gorigin + (SIMD3<Double>(Double(i), Double(j), Double(k)) + 0.5) * pitch
                    let cb = cellOf(before, cellsBefore, idx), ca = cellOf(after, cellsAfter, idx)
                    // its cell before yielded (or stepped down), or its cell after is one the
                    // first-wins bake had left with no texel — both are cells whose owner changed
                    if let cb, goneKeys.contains(ck(cb)) { sameOwnerInGone += 1; continue }
                    if let ca, !beforeKeys.contains(ck(ca)) { sameOwnerNewCell += 1; continue }
                    sameOwner += 1
                    if samples.count < 8 {
                        samples.append(String(format: "(%.2f,%.2f,%.2f) r%d size %.2f→%.2f", mid.x, mid.y, mid.z, ob,
                                              before.steppedCellMM[idx], after.steppedCellMM[idx])
                                       + " cell \(cb.map(ck) ?? "-") → \(ca.map(ck) ?? "-")")
                    }
                }
            }}}
            let air = emptied.values.reduce(0, +)
            print("\(tag)-TEXELS changed \(changed) owner-changed \(ownerChanged) \(flows.sorted { $0.key < $1.key }) same-owner-inside-a-yielded-or-stepped-cell \(sameOwnerInGone) same-owner-in-a-new-cell \(sameOwnerNewCell) same-owner-elsewhere \(sameOwner) of \(g.nx * g.ny * g.nz) | cells gone \(gone.count) \(samples)")
            print("\(tag)-AIR texels left with no cell \(air) (\(String(format: "%.0f", Double(air) * pitch * pitch * pitch)) mm³ at pitch \(String(format: "%.3f", pitch))) by whose space: \(emptied.sorted { $0.key < $1.key })")
            return (sameOwner, air)
        }
        let dNo = texelDiff(noStep, cellsNoStep, "R7-NOSTEP")
        let dStep = texelDiff(after, cellsAfter, "R7")
        XCTAssertEqual(dStep.sameOwnerElsewhere, 0, "★ the preview changes only in cells whose owner changed or that stepped down")
        XCTAssertEqual(dNo.sameOwnerElsewhere, 0)
        XCTAssertLessThan(dStep.emptied, dNo.emptied, "★ the step-down fills the yielded cells' own share")
        XCTAssertEqual(split(cellsNoStep).a, 0, "R7 without the step-down keeps (a) at 0 too")

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
