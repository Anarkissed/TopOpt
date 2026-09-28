import XCTest
import Metal
import simd
import TopOptKit
@testable import TopOptFlows

/// ★ PROBE (2026-09-26): HIS PROJECT, restored from its own `project.json` + `model.step`
/// (copy them to $HIS_PROJECT_DIR), regions and wall depths from the app's own functions,
/// the organic trace from core's synthetic focal field (his walls 15 and 23 are UNLOADED and
/// zeroed in the app; wall 2 keeps an FEA tensor this probe does not have), his settle
/// (gravity −Z), and his colours. Frames with the body drawn and lattice-only.
/// Env: HIS_PROJECT_DIR, STAND_RENDER_DIR, HIS_VIEWS = "name,az,el,zoom,height;…".
final class LatticeHisProjectRenderProbe: XCTestCase {
    @MainActor
    func testRenderHisProject() throws {
        guard let dirPath = ProcessInfo.processInfo.environment["HIS_PROJECT_DIR"] else { throw XCTSkip("HIS_PROJECT_DIR") }
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let dir = URL(fileURLWithPath: dirPath)
        let snap = try JSONDecoder().decode(ProjectSnapshot.self, from: Data(contentsOf: dir.appendingPathComponent("project.json")))
        let stepPath = dir.appendingPathComponent("model.step").path
        let im = try TopOptKit.importMesh(path: stepPath)
        let file = ImportedFile(name: "model.step", path: stepPath, triangleCount: im.triangleCount, faceCount: im.faceCount,
                                watertight: im.watertight, pseudoFaces: im.pseudoFaces)
        let pm = ProjectModel(restoring: snap, importedFile: file, importedMesh: im)
        let mesh = ViewerMesh(vertices: im.vertices, indices: im.indices, faceIDs: im.faceIDs, faceGeometry: im.faceGeometry)
        let lat = pm.lattice
        let regions = pm.latticeJobRegions().regions
        let steps = LatticeWallDepthSteps.forWalls(lat, regions: regions, beadMM: pm.printParams.strutLineWidthMM)
        let voxel = Double((mesh.bounds.max - mesh.bounds.min).max()) / 128
        let b = mesh.bounds
        let dims = (Int((Double(b.max.x - b.min.x) / voxel).rounded(.up)) + 1,
                    Int((Double(b.max.y - b.min.y) / voxel).rounded(.up)) + 1,
                    Int((Double(b.max.z - b.min.z) / voxel).rounded(.up)) + 1)
        let origin = SIMD3<Double>(Double(b.min.x), Double(b.min.y), Double(b.min.z))
        var o = LatticeOrganicInput(tensor: [Double](repeating: 0, count: 6 * dims.0 * dims.1 * dims.2), dims: dims,
                                    originMM: origin, spacingMM: voxel, minExtrudableWidthMM: pm.printParams.strutLineWidthMM,
                                    buildDirection: SIMD3(0, 0, 1), separationMinMM: 1.71, separationMaxMM: 3.87,
                                    rhoMin: 0.05, rhoMax: 0.9, showRepairs: false)
        o.solidRimMM = 3.41
        o.shapeFit = lat.organicShapeFit
        o.shapeBandMM = lat.organicShapeFit ? lat.shapeFitBandMM : 0
        o.shapeBandStrength = lat.shapeFitGradeStrength
        o.transferTies = lat.organicTransferTies
        o.overhangFillet = lat.organicOverhangFillet
        let plan = OrganicSyntheticStress.plan(regions: regions, dims: dims, originMM: origin, spacingMM: voxel,
                                               defaultFoci: lat.organicSyntheticFoci, statedFoci: lat.selectableSyntheticFoci)
        o.regionIDs = plan.regionIDs
        o.syntheticRegions = plan.regions
        o.deadRegionIDs = Set(plan.regions.map { Int($0.regionID) })
        // ★ his chip choices, as the app hands them (`lat.bandTreatments`), plus HIS_BAND_OVERRIDES
        // = "face:20=0,cap:<key>=1" (1 = solid) on top
        var overrides = lat.bandTreatments
        for item in (ProcessInfo.processInfo.environment["HIS_BAND_OVERRIDES"] ?? "").split(separator: ",") {
            let kv = item.split(separator: "=")
            if kv.count == 2 { overrides[String(kv[0])] = kv[1] == "1" }
        }
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: lat.topologyID, stageMode: .aesthetic,
                                    algorithm: "organic", organic: o, regions: regions, whenEmpty: .latticeNothing,
                                    wallDepthSteps: steps, bandOverrides: overrides, beadMM: pm.printParams.strutLineWidthMM)
        print("HIS regions \(regions.count) · capsules \(scene.organicCapsules.count) · chips \(scene.bandDecisions.count) · choices \(overrides)")
        for d in scene.bandDecisions {
            print("HIS chip \(d.key) \(d.label) members \(d.memberKeys) default \(d.defaultSolid ? "solid" : "open") now \(d.solid ? "solid" : "open")")
        }

        guard let mr = MeshRenderer(device: device, sampleCount: 4) else { throw XCTSkip("renderer") }
        try XCTSkipUnless(mr.latticePipelinesDidBuild)
        mr.setMesh(mesh)
        mr.showGround = false
        mr.beginSettle(to: LatticeQuiltFrameProbe.settle, duration: 0)
        mr.latticeHidden = false
        mr.latticeParams = { var p = lat.proxyParams(limits: TopOptKit.latticeLimits(topology: lat.topologyID)); p.cellMM = 8; return p }()
        mr.latticeLineWidthMM = pm.printParams.strutLineWidthMM
        mr.setLatticeScene(scene, token: 1)
        mr.latticeDressingLevel = lat.boundary.previewDressingLevel
        let out = ProcessInfo.processInfo.environment["STAND_RENDER_DIR"] ?? NSTemporaryDirectory()
        let views: [(String, Float, Float, Float, Float)] = ProcessInfo.processInfo.environment["HIS_VIEWS"].map { v in
            v.split(separator: ";").map { t in let c = t.split(separator: ","); return (String(c[0]), Float(c[1])!, Float(c[2])!, Float(c[3])!, Float(c[4])!) }
        } ?? (0..<8).map { ("az\($0)", Float($0) * 0.785, 0.35, 0.9, 0.5) }
        for body in (ProcessInfo.processInfo.environment["HIS_BODY"] == "0" ? [Float(0)] : [Float(1), 0]) {
            mr.setBodyAlpha(body)
            for (name, az, el, zoom, height) in views {
                LatticeQuiltFrameProbe.aim(mr, mesh.bounds, azimuth: az, elevation: el, zoom: zoom, height: height)
                guard let px = mr.renderOffscreen(size: 900, clear: MTLClearColor(red: 0.05, green: 0.06, blue: 0.1, alpha: 1)) else { continue }
                let path = out + "/his_\(body > 0 ? "body" : "lattice")_\(name).png"
                LatticeQuiltFrameProbe.writePNG(px, size: 900, to: path)
                print("HIS frame → \(path)")
            }
        }
    }
}
