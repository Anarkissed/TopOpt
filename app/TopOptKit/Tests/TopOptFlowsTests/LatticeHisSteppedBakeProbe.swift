import XCTest
import Metal
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★ PROBE (2026-09-28): HIS OCTET (Stepped) PROJECT, restored the way the APP restores it —
/// `AppModel` + `ProjectStore` over a copy of his project folder (project.json, model.step,
/// results.plist) — with the STAGE'S OWN stress solve (`makeLatticeSimContext` →
/// `analyzeSolidLoadCase`, the field his bake grades by; results.plist is not it), the scene
/// built twice as the app does (its wall floor comes from the previous scene's cells), the
/// cells from `LatticeRegionCells` (the app's rule, shared), and the renderer fed in
/// `MetalMeshView.apply`'s order. Its DIAG lines are the app's own — compare them with his log.
///
/// Env: HIS_PROJECT_DIR (the folder), STAND_RENDER_DIR, HIS_VIEWS = "name,az,el,zoom,height;…",
/// HIS_BODY=0 (lattice-only frames only), HIS_FIELD=none (no solve), HIS_BAND_OVERRIDES.
final class LatticeHisSteppedBakeProbe: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        while u.path != "/" && !FileManager.default.fileExists(atPath: u.appendingPathComponent("core/src/materials/materials.json").path) {
            u = u.deletingLastPathComponent()
        }
        return u
    }()

    @MainActor
    func testRenderHisSteppedProject() throws {
        guard let dirPath = ProcessInfo.processInfo.environment["HIS_PROJECT_DIR"] else { throw XCTSkip("HIS_PROJECT_DIR") }
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let env = ProcessInfo.processInfo.environment
        let src = URL(fileURLWithPath: dirPath)
        let snap = try JSONDecoder().decode(ProjectSnapshot.self, from: Data(contentsOf: src.appendingPathComponent("project.json")))
        // his folder, under a store of our own
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("his-stepped-\(UUID().uuidString)", isDirectory: true)
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
        let recent = try XCTUnwrap(model.recentProjects.first { $0.id == snap.id })
        model.open(recent)
        let pm = try XCTUnwrap(model.project)
        let mesh = try XCTUnwrap(pm.viewerMesh)
        var lat = pm.lattice
        for item in (env["HIS_BAND_OVERRIDES"] ?? "").split(separator: ",") {
            let kv = item.split(separator: "=")
            if kv.count == 2 { lat.bandTreatments[String(kv[0])] = kv[1] == "1" }
        }
        let bead = pm.printParams.strutLineWidthMM
        print("HIS algorithm \(lat.algorithm) topology \(lat.topologyID) stage \(String(describing: lat.stageMode)) density \(lat.densityMode) cells \(lat.cellSizeMode) \(lat.cellMinMM)–\(lat.cellMaxMM) allowQuilt \(lat.allowQuilt) singleCell \(lat.singleCellMembers) boundary \(lat.boundary) band \(lat.shapeFitBandMM) grading \(lat.gradingMode) step \(lat.gradeStepStyle) bead \(bead) choices \(lat.bandTreatments)")

        // ── the stage solve (the field his bake grades by)
        var stageField: LatticeDemandField? = nil
        if env["HIS_FIELD"] != "none", let ctx = model.makeLatticeSimContext() {
            let r = try TopOptKit.analyzeSolidLoadCase(
                modelPath: ctx.modelPath, material: ctx.material, materialsPath: ctx.materialsPath,
                rulesPath: ctx.rulesPath, resolution: ctx.resolution, anchorFaceIDs: ctx.anchorFaceIDs,
                loadGroups: ctx.loadGroups, buildDirection: ctx.buildDirection,
                faceRegions: ctx.faceRegions, anchorRegionIDs: ctx.anchorRegionIDs)
            XCTAssertFalse(r.nonConvergent)
            stageField = LatticeDemandField(vonMises: r.vonMisesField, stressTensor: r.stressTensorField,
                                            nx: r.gridNX, ny: r.gridNY, nz: r.gridNZ, origin: r.gridOrigin,
                                            spacingMM: r.spacingMM, provenance: .solidSim(date: Date(), resolution: ctx.resolution))
            print("HIS solve \(r.gridNX)×\(r.gridNY)×\(r.gridNZ) @ \(r.spacingMM) mm")
        }
        func sf(_ f: LatticeDemandField) -> StressField {
            StressField(nx: f.nx, ny: f.ny, nz: f.nz, origin: SIMD3<Float>(f.origin), spacing: Float(f.spacingMM), values: f.vonMises)
        }
        let field: StressField? = !lat.gradingMode.followsStress ? nil
            : (lat.densityMode.needsSimulation && stageField != nil ? sf(stageField!) : LatticeSDFScene.demandField(from: pm.run.outcome))
        let wallStressField = stageField.map(sf) ?? LatticeSDFScene.demandField(from: pm.run.outcome)

        // ── the bake's inputs (WorkspacePlaceholder's preview bake)
        let params = lat.proxyParams(limits: TopOptKit.latticeLimits(topology: lat.topologyID), lineWidthMM: bead)
        let span = params.densitySpan
        let gamma = Swift.max(0.05, params.gamma)
        let emission = pm.latticeJobRegions()
        var regions = emission.regions
        if !lat.wallThickness.isThrough {
            for i in regions.indices where regions[i].role == .include && regions[i].kind == .face { regions[i].thickness = lat.wallThickness }
        }
        let stageMode = lat.stageMode ?? .structural
        let allowable = model.yieldStrengthMPa(for: pm.material)
        let skinMM = lat.boundary.faceSkinMM(wallRingMM: pm.printParams.wallRingMM)
        let steps = LatticeWallDepthSteps.forWalls(lat, regions: regions, beadMM: bead)
        func scene(_ floorCells: [Double]) -> LatticeSDFScene {
            LatticeSDFScene(mesh: mesh, field: field, latticeID: params.latticeID,
                            stressField: stageField.map(sf),
                            statedDensityGoverns: !lat.densityMode.needsSimulation || stageMode == .aesthetic,
                            allowQuilt: lat.allowQuilt, stageMode: stageMode, algorithm: lat.algorithm,
                            allowableMPa: allowable, boundaryFinishWritten: lat.singleCellMembers,
                            regions: regions, rhoMin: span.lo, rhoMax: span.hi, gamma: gamma,
                            whenEmpty: .latticeNothing, skinMM: skinMM, skippedFaces: emission.skippedFaces,
                            wallThicknessFloorMM: floorCells.filter { $0 > 0 }.min() ?? lat.cellMM,
                            wallDepthSteps: steps, wallStressField: wallStressField,
                            bandOverrides: lat.bandTreatments,
                            octetBand: env["HIS_OCTET_BAND"] != "0", bandGradeMM: lat.gradingMode.fitsShape ? lat.shapeFitBandMM : 0,
                            beadMM: bead)
        }
        let s0 = scene(LatticeRegionCells.steppedCellsMM(project: pm, scene: nil))
        let c1 = LatticeRegionCells.steppedCellsMM(project: pm, scene: s0)
        let s1 = scene(c1)
        let cells = LatticeRegionCells.steppedCellsMM(project: pm, scene: s1)
        let statedByFace = LatticeRegionCells.statedCellByFace(lat)
        let stated = regions.map { r -> Bool in r.faceID.map { statedByFace[$0] != nil } ?? false }
        print("HIS cells pass1 \(c1) · pass2 \(cells) · chips \(s1.bandDecisions.map(\.label))")

        // ── the renderer, in MetalMeshView.apply's order: params before the scene, one bake
        guard let mr = MeshRenderer(device: device, sampleCount: 4) else { throw XCTSkip("renderer") }
        try XCTSkipUnless(mr.latticePipelinesDidBuild)
        mr.setMesh(mesh)
        mr.showGround = false
        mr.beginSettle(to: pm.force.settleRotation ?? simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)), duration: 0)
        mr.latticeHidden = false
        mr.latticeParams = params
        mr.latticeLineWidthMM = bead
        mr.latticeBuildDirection = SIMD3<Double>(pm.buildOrientation.resolved(gravity: pm.force.gravity))
        mr.latticeLayerHeightMM = pm.printParams.layerHeightMM
        mr.latticeSteppedCellMM = cells
        mr.latticeSteppedShapeFit = lat.gradingMode.fitsShape
        mr.latticeSteppedDyadicSteps = lat.gradeStepStyle == .dyadic
        mr.latticeSteppedCellStated = stated
        mr.setLatticeScene(s1, token: 1)
        mr.latticeDressingLevel = lat.boundary.previewDressingLevel
        let layer = try XCTUnwrap(mr.latticeLayerForTests)

        // ── the explore callout at chosen points (density · strut · cell), as his tap reads it
        let lt = LatticeType.named(lat.topologyID)
        for (name, p) in [("face2 wall x100 z30", SIMD3<Double>(100, -43, 30)), ("face2 wall x60 z28", SIMD3<Double>(60, -43, 28)),
                          ("face2 leg z120", SIMD3<Double>(5, -43, 120)), ("face15 wall x100 z30", SIMD3<Double>(100, -2, 30)),
                          ("face23 leg z120", SIMD3<Double>(-5, -22, 120)), ("face23 foot z10", SIMD3<Double>(-8, -22, 10))] {
            let rho = Double(layer.bakedDensityAt(SIMD3<Float>(p))), cell = layer.bakedCellMMAt(SIMD3<Float>(p))
            let strut = cell > 0 ? 2 * lt.strutRadiusMM(relativeDensity: rho, cellMM: cell) : -1
            print(String(format: "HIS callout %@: density %.0f%% · strut %.2f mm · cell %.2f mm", name, 100 * rho, strut, cell))
        }

        // ── ★ tilted facets: material within 3 mm of the part's surface, inside a tilted include
        // prism, that the bake left without a cell — with the tilted span and without it
        func uncovered(_ label: String) {
            let po = s1.prismOccupancy
            var total = 0, bare = 0
            for (ri, r) in regions.enumerated() where r.role == .include && r.kind == .face {
                let n = LatticeRegionMask.unit(r.normal)
                guard Swift.max(abs(n.x), Swift.max(abs(n.y), abs(n.z))) < 0.99 else { continue }
                _ = ri
                for k in 0..<po.nz { for j in 0..<po.ny { for i in 0..<po.nx where po.values[(k * po.ny + j) * po.nx + i] > 0.5 {
                    let p = SIMD3<Double>(po.origin + SIMD3<Float>(Float(i), Float(j), Float(k)) * po.spacing)
                    guard LatticeRegionMask.containsWholePrism(p, region: r), s1.partMaterialSDF.sampleLinear(p) > -3 else { continue }
                    total += 1
                    if layer.bakedCellMMAt(SIMD3<Float>(p)) <= 0 { bare += 1 }
                } } }
            }
            print("HIS tilted facets \(label): near-surface material voxels \(total), without a cell \(bare)")
        }
        uncovered("span on")
        if env["HIS_TILT_CONTROL"] == "1" {
            LatticePreviewOccupancy.tiltedSpanEnabled = false
            mr.setLatticeScene(s1, token: 2)
            uncovered("span OFF (centre-plane anchoring)")
            LatticePreviewOccupancy.tiltedSpanEnabled = true
            mr.setLatticeScene(s1, token: 3)
        }

        // ── frames
        let out = env["STAND_RENDER_DIR"] ?? NSTemporaryDirectory()
        let views: [(String, Float, Float, Float, Float)] = env["HIS_VIEWS"].map { v in
            v.split(separator: ";").map { t in let c = t.split(separator: ","); return (String(c[0]), Float(c[1])!, Float(c[2])!, Float(c[3])!, Float(c[4])!) }
        } ?? (0..<8).map { ("az\($0)", Float($0) * 0.785, 0.35, 0.9, 0.5) }
        for body in (env["HIS_BODY"] == "0" ? [Float(0)] : [Float(1), 0]) {
            mr.setBodyAlpha(body)
            for (name, az, el, zoom, height) in views {
                LatticeQuiltFrameProbe.aim(mr, mesh.bounds, azimuth: az, elevation: el, zoom: zoom, height: height)
                guard let px = mr.renderOffscreen(size: 900, clear: MTLClearColor(red: 0.05, green: 0.06, blue: 0.1, alpha: 1)) else { continue }
                let path = out + "/oct_\(body > 0 ? "body" : "lattice")_\(name).png"
                LatticeQuiltFrameProbe.writePNG(px, size: 900, to: path)
                print("HIS frame → \(path)")
            }
        }
    }
}
