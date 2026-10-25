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
        let bead = pm.printParams.strutLineWidthMM
        let params = lat.proxyParams(limits: TopOptKit.latticeLimits(topology: lat.topologyID), lineWidthMM: bead)
        let span = params.densitySpan
        let emission = pm.latticeJobRegions()
        var regions = emission.regions
        let stageMode = lat.stageMode ?? .structural
        func scene(_ floorCells: [Double]) -> LatticeSDFScene {
            LatticeSDFScene(mesh: mesh, field: field, latticeID: params.latticeID,
                            stressField: stageField.map(sf),
                            statedDensityGoverns: !lat.densityMode.needsSimulation || stageMode == .aesthetic,
                            allowQuilt: lat.allowQuilt, stageMode: stageMode, algorithm: lat.algorithm,
                            allowableMPa: model.yieldStrengthMPa(for: pm.material), boundaryFinishWritten: lat.singleCellMembers,
                            regions: regions, rhoMin: span.lo, rhoMax: span.hi, gamma: Swift.max(0.05, params.gamma),
                            whenEmpty: .latticeNothing, skinMM: lat.boundary.faceSkinMM(wallRingMM: pm.printParams.wallRingMM),
                            skippedFaces: emission.skippedFaces,
                            bandOverrides: lat.bandTreatments, octetBand: true,
                            bandGradeMM: lat.gradingMode.fitsShape ? lat.shapeFitBandMM : 0, beadMM: bead)
        }
        let s0 = scene(LatticeRegionCells.steppedCellsMM(project: pm, scene: nil))
        let s1 = scene(LatticeRegionCells.steppedCellsMM(project: pm, scene: s0))
        let choices = LatticeRegionCells.steppedCellChoices(project: pm, scene: s1)
        let cells = choices.cells
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
        mr.latticeSteppedCellBeforeBaseRuleMM = choices.beforeBaseRule   // ★ the guard on (b), as the app passes it
        mr.latticeSteppedShapeFit = lat.gradingMode.fitsShape
        mr.latticeSteppedDyadicSteps = lat.gradeStepsAreHalves
        mr.latticeSteppedCellStated = regions.map { r in r.faceID.map { statedByFace[$0] != nil } ?? false }
        // ★ K3 in the picture: DG_K3_SOLID=1 draws the uncovered prism space solid (the forced plan, built the way
        // core builds it), 0 draws it as air; unset = production's answer (plans off ⇒ air)
        if let k = env["DG_K3_SOLID"] { mr.latticeUncoveredPrintsSolid = k == "1" }
        print("DG-K3 uncovered prism space drawn \(mr.latticeUncoveredPrintsSolid.map { $0 ? "SOLID (forced)" : "as air (forced)" } ?? "per production") "
              + "| core carries K3: \(TopOptKit.corePrintsWhatThePlanLeavesSolid)")
        var bakedField: LatticeCellField? = nil
        let savedObserver = LatticePreviewOccupancy.octreeBakeObserver
        LatticePreviewOccupancy.octreeBakeObserver = { f, _ in bakedField = f }
        defer { LatticePreviewOccupancy.octreeBakeObserver = savedObserver }
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
            let po = s1.occupancy
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
                    && LatticeRegionMask.contains(p, region: b.regions[$0]) }) else { continue }
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
        // ★★ THE BEAM MEASURE (c) (the reviewer, 2026-10-10 23:32): "on 570B38E2's plan, how much of the preview's
        // 1.21 mm band is simply space the plan's cells leave uncovered, which K3 now prints solid, and how much the
        // shader draws OVER cut cells. That decides whether core needs a band of its own on a plan run at all."
        // The band: the part's material, inside a planned region's prism, within the bake's beam of the outline
        // (0 ≤ inPlaneDistance < beam — the expanded true edge, the datum pinned in LatticeOneOutlineTests), sampled
        // 0.25 mm in-plane × 0.5 mm in depth. Each sample: covered by NO plan cell (K3 prints it solid), inside a
        // CUT cell (one the outline cuts: the shader draws the band over its struts), or inside a WHOLE cell (the
        // bake's corner test runs eps = min(0.05·S, 0.2) mm in, so a whole cell may stand that far into the band).
        if env["DG_BAND"] == "1" {
            let occ = s1.occupancy
            let voxel = Double(Swift.max(occ.spacing.x, Swift.max(occ.spacing.y, occ.spacing.z)))
            let beam = LatticeSDFRenderer.outlineBeamMM(lineWidthMM: bead, voxelMM: voxel)
            let bucket = 8.0
            struct K: Hashable { let x: Int; let y: Int; let z: Int }
            func key(_ p: SIMD3<Double>) -> K { K(x: Int((p.x / bucket).rounded(.down)), y: Int((p.y / bucket).rounded(.down)), z: Int((p.z / bucket).rounded(.down))) }
            var grid: [K: [Int]] = [:]
            for (ci, c) in b.cells.enumerated() {
                let k0 = key(c.originMM), k1 = key(c.originMM + c.sizeMM)
                for x in k0.x...k1.x { for y in k0.y...k1.y { for z in k0.z...k1.z { grid[K(x: x, y: y, z: z), default: []].append(ci) } } }
            }
            let m = s1.partMaterialSDF
            func inMaterial(_ p: SIMD3<Double>) -> Bool {
                let g = (SIMD3<Float>(p) - m.origin) / m.spacing
                let a = Int(g.x.rounded()), bb = Int(g.y.rounded()), c = Int(g.z.rounded())
                guard a >= 0, a < m.nx, bb >= 0, bb < m.ny, c >= 0, c < m.nz else { return false }
                return m.values[(c * m.ny + bb) * m.nx + a] < 0
            }
            // a cell is CUT when some in-plane corner of it lies outside its region's polygon
            var cut = [Bool](repeating: false, count: b.cells.count)
            for (ci, c) in b.cells.enumerated() {
                let r = b.regions[c.region], nrm = LatticeRegionMask.unit(r.normal), (bu, bv) = LatticeRegionMask.basis(nrm)
                for cx in 0...1 { for cy in 0...1 { for cz in 0...1 {
                    let q = c.originMM + SIMD3(Double(cx), Double(cy), Double(cz)) * c.sizeMM - r.origin
                    if r.inPlaneDistance(SIMD2(simd_dot(q, bu), simd_dot(q, bv))) < 0 { cut[ci] = true }
                }}}
            }
            let du = 0.25, ds = 0.5, dv = du * du * ds
            var rows: [String] = []
            var tot = (band: 0.0, bare: 0.0, overCut: 0.0, overWhole: 0.0)
            for ri in Set(b.cells.map(\.region)).sorted() {
                let r = b.regions[ri], nrm = LatticeRegionMask.unit(r.normal), (bu, bv) = LatticeRegionMask.basis(nrm)
                var lo = SIMD2<Double>(repeating: 1e9), hi = SIMD2<Double>(repeating: -1e9)
                for loop in r.outlinePolygon { for q in loop { lo = simd_min(lo, q); hi = simd_max(hi, q) } }
                guard lo.x < hi.x else { continue }
                var band = 0, bare = 0, overCut = 0, overWhole = 0
                var u = lo.x + 0.5 * du
                while u < hi.x { var v = lo.y + 0.5 * du
                    while v < hi.y {
                        let d = r.inPlaneDistance(SIMD2(u, v))
                        if d >= 0, d < beam {
                            var sd = 0.5 * ds
                            while sd < r.depthMM {
                                let p = r.origin + bu * u + bv * v + nrm * sd
                                if inMaterial(p) {
                                    band += 1
                                    let covering = (grid[key(p)] ?? []).filter { ci in
                                        let c = b.cells[ci]
                                        return p.x >= c.originMM.x && p.x < c.originMM.x + c.sizeMM && p.y >= c.originMM.y
                                            && p.y < c.originMM.y + c.sizeMM && p.z >= c.originMM.z && p.z < c.originMM.z + c.sizeMM
                                    }
                                    if covering.isEmpty { bare += 1 }
                                    else if covering.contains(where: { cut[$0] }) { overCut += 1 } else { overWhole += 1 }
                                }
                                sd += ds
                            }
                        }
                        v += du
                    }
                    u += du
                }
                let id = b.regions[..<ri].filter { $0.role == .include }.count + 1
                func mm3(_ x: Int) -> Double { Double(x) * dv }
                func pc(_ x: Int) -> Double { band > 0 ? 100 * Double(x) / Double(band) : 0 }
                rows.append(String(format: "r%d band %.0f mm3 = uncovered %.0f (%.1f%%) + over cut cells %.0f (%.1f%%) + over whole cells %.0f (%.1f%%)",
                                   id, mm3(band), mm3(bare), pc(bare), mm3(overCut), pc(overCut), mm3(overWhole), pc(overWhole)))
                tot.band += mm3(band); tot.bare += mm3(bare); tot.overCut += mm3(overCut); tot.overWhole += mm3(overWhole)
            }
            print(String(format: "DG-BAND beam %.4f mm (voxel %.3f) | total %.0f mm3 = uncovered %.0f + over cut %.0f + over whole %.0f | ",
                         beam, voxel, tot.band, tot.bare, tot.overCut, tot.overWhole) + rows.joined(separator: " | "))
        }
        // ★★ THE PREVIEW'S VERDICT ON CELLS CORE LEFT EMPTY (the reviewer, 2026-10-11 03:28, item 4: "For each
        // IN_REGION one, say whether the PREVIEW draws struts in that cell (owner, band, clip). Any cell the picture
        // draws but core leaves empty is a mismatch"). DG_CELL_VERDICT=<json from classify_laid_ledger.py>. Per cell:
        // OWNER — texels of the bake's field this cell owns (0 ⇒ another cell/region draws there, or nothing);
        // BAND — the cell's in-plane distance from the expanded edge, nearest and farthest corner, against the beam
        // (farthest < beam ⇒ the band covers it whole); CLIP — the share of 7³ sample points inside the part's
        // material AND the region's prism (0 ⇒ the clip removes every strut). DRAWS ⇔ owner > 0 ∧ clip > 0 ∧ not
        // wholly in the band.
        if let path = env["DG_CELL_VERDICT"], let data = FileManager.default.contents(atPath: path),
           let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]], let f = bakedField {
            let incs = b.regions.indices.filter { b.regions[$0].role == .include }
            let voxel = Double(Swift.max(s1.occupancy.spacing.x, Swift.max(s1.occupancy.spacing.y, s1.occupancy.spacing.z)))
            let beam = LatticeSDFRenderer.outlineBeamMM(lineWidthMM: bead, voxelMM: voxel)
            let m = s1.partMaterialSDF
            func inMaterial(_ p: SIMD3<Double>) -> Bool {
                let g = (SIMD3<Float>(p) - m.origin) / m.spacing
                let a = Int(g.x.rounded()), bb = Int(g.y.rounded()), c = Int(g.z.rounded())
                guard a >= 0, a < m.nx, bb >= 0, bb < m.ny, c >= 0, c < m.nz else { return false }
                return m.values[(c * m.ny + bb) * m.nx + a] < 0
            }
            var owned = [Int: Int]()
            for t in f.steppedTexelCell where t >= 0 { owned[Int(t), default: 0] += 1 }
            var draws = 0, rows: [String] = [], tally = [String: Int]()
            for e in list {
                guard let rid = e["region_id"] as? Int, rid >= 1, rid <= incs.count,
                      let o = e["origin_mm"] as? [Double], o.count == 3, let size = e["size_mm"] as? Double else { continue }
                let ri = incs[rid - 1], r = b.regions[ri]
                let origin = SIMD3(o[0], o[1], o[2])
                let ci = f.steppedCells.firstIndex { c in
                    c.region == ri && abs(c.sizeMM - size) < 1e-4 && simd_length(c.originMM - origin) < 1e-3 }
                let owner = ci.map { owned[$0] ?? 0 } ?? -1
                let nrm = LatticeRegionMask.unit(r.normal), (bu, bv) = LatticeRegionMask.basis(nrm)
                var near = Double.greatestFiniteMagnitude, far = -Double.greatestFiniteMagnitude
                for cx in 0...1 { for cy in 0...1 { for cz in 0...1 {
                    let q = origin + SIMD3(Double(cx), Double(cy), Double(cz)) * size - r.origin
                    let d = r.inPlaneDistance(SIMD2(simd_dot(q, bu), simd_dot(q, bv)))
                    near = Swift.min(near, d); far = Swift.max(far, d)
                }}}
                var inside = 0
                for k in 0..<7 { for j in 0..<7 { for i in 0..<7 {
                    let p = origin + SIMD3(Double(i) + 0.5, Double(j) + 0.5, Double(k) + 0.5) * (size / 7)
                    if inMaterial(p), LatticeRegionMask.contains(p, region: r) { inside += 1 }
                }}}
                let clip = Double(inside) / 343
                let wholeBand = far < beam
                let drawn = owner > 0 && clip > 0 && !wholeBand
                if drawn { draws += 1 }
                let why = owner < 0 ? "NOT IN BAKE" : owner == 0 ? "NO TEXEL" : clip == 0 ? "CLIPPED" : wholeBand ? "IN BAND" : "DRAWN"
                tally[why, default: 0] += 1
                rows.append(String(format: "r%d %.3f mm at (%.2f, %.2f, %.2f): owner %d texels, band near %.2f far %.2f (beam %.2f), clip %.0f%% ⇒ %@",
                                   rid, size, o[0], o[1], o[2], owner, near, far, beam, 100 * clip, why))
            }
            print("DG-CELL-VERDICT \(list.count) IN_REGION cells core left empty: the preview DRAWS \(draws) | "
                  + tally.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
            for row in rows { print("DG-CELL \(row)") }
        }
        // ★ THE PICTURE (condition 1): the same views, before and after, through the app's own renderer
        if let dir = env["DG_RENDER_DIR"], !dir.isEmpty {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            // ★ DG_FOCUS="k,k|k,k,k" (1-based include ids; groups by '|'): frame each group's prisms, not the part
            let incs = b.regions.filter { $0.role == .include }
            var frames: [(String, MeshBounds)] = []
            for (gi, grp) in (env["DG_FOCUS"].map { $0.split(separator: "|").map(String.init) } ?? [""]).enumerated() {
                var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
                for k in grp.split(separator: ",").compactMap({ Int($0) }) where k >= 1 && k <= incs.count {
                    let r = incs[k - 1], n = LatticeRegionMask.unit(r.normal), (bu, bv) = LatticeRegionMask.basis(n)
                    for loop in r.outlineLoops { for q in loop { for d in [0.0, r.depthMM] {
                        let pt = SIMD3<Float>(r.origin + bu * q.x + bv * q.y + n * d)
                        lo = simd_min(lo, pt); hi = simd_max(hi, pt)
                    } } }
                }
                frames.append((grp.isEmpty ? "" : "f\(gi + 1)_", lo.x <= hi.x ? MeshBounds(min: lo, max: hi, isEmpty: false) : mesh.bounds))
            }
            let views: [(String, Float, Float, Float)] = env["DG_VIEWS"].map { v in
                v.split(separator: ";").map { t in let c = t.split(separator: ","); return (String(c[0]), Float(c[1])!, Float(c[2])!, Float(c[3])!) }
            } ?? [("front", 0.6, 0.35, 0.9), ("back", 3.74, 0.35, 0.9), ("top", 0.6, 1.2, 0.9)]
            for (prefix, frame) in frames {
                for body in [Float(1), 0] {
                    mr.setBodyAlpha(body)
                    for (name, az, el, zoom) in views {
                        LatticeQuiltFrameProbe.aim(mr, frame, azimuth: az, elevation: el, zoom: zoom, height: 0.5)
                        guard let px = mr.renderOffscreen(size: 1200, clear: MTLClearColor(red: 0.05, green: 0.06, blue: 0.1, alpha: 1)) else { continue }
                        let path = dir + "/\(prefix)\(body > 0 ? "part" : "lattice")_\(name).png"
                        LatticeQuiltFrameProbe.writePNG(px, size: 1200, to: path)
                        print("DG-RENDER \(path)")
                    }
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
