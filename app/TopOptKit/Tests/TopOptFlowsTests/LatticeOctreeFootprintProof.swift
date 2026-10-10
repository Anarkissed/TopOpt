import XCTest
import Metal
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★ THE ANCHOR-FOOTPRINT PROOF ON HIS PROJECTS (maintainer, 2026-10-03: "Prove it with identical
/// bakes on two projects"). Opt-in: it restores ONE project folder (a COPY — never his store) the way
/// the app does and bakes the preview through the renderer FOUR times in one process:
///
///   control-1   footprints off (the whole-extent walks — the code before this change)
///   control-2   the same again (A/A: the bake must be deterministic or the A/B means nothing;
///               OCTREE_AA=0 skips it on the slow project)
///   footprint   footprints on (production)
///   red-inset   footprints on, every box shrunk by 4·baseMax + 4 mm (RED: must DIFFER)
///
/// and compares every output by bit pattern — every Float array, `steppedOrigin` lane by lane, the
/// cell plan, and all of the anchor search's volumes (every shift, both passes), not just the
/// winner. The per-arm summary (walk counts, seconds, sha256 per array) goes to
/// OCTREE_PROOF_OUT/<project id>.txt.
///
///     OCTREE_PROOF_DIR=<copy of a project folder> OCTREE_PROOF_OUT=<dir> [OCTREE_FIELD=none] \
///     [OCTREE_AA=0] swift test --skip-build --filter LatticeOctreeFootprintProof
///
/// The scene is LatticeDefaultGradePlanProof's (the app's order: the stage solve, the scene built
/// twice, `LatticeRegionCells`, the renderer fed in `MetalMeshView.apply`'s order) — but Stepped is
/// NOT skipped: native Stepped and Default Grade both bake through the octree.
final class LatticeOctreeFootprintProof: XCTestCase {
    typealias P = LatticePreviewOccupancy
    typealias Bake = LatticeOctreeFootprintTests.Bake

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        while u.path != "/" && !FileManager.default.fileExists(atPath: u.appendingPathComponent("core/src/materials/materials.json").path) {
            u = u.deletingLastPathComponent()
        }
        return u
    }()

    override func tearDown() {
        P.anchorFootprintEnabled = true
        P.placeFootprintEnabled = true
        P.footprintInsetForTestsMM = 0
        P.footprintSlackSlots = 1
        P.anchorWindowOverrideForTests = nil
        P.octreeBakeObserver = nil
        super.tearDown()
    }

    /// The app's DIAG line's fields, rebuilt from the stats (the renderer's own NSLog goes to stderr).
    static func diag(_ b: Bake) -> String {
        let st = b.stats
        let kept = st.slotsKept.keys.sorted(by: >).map { String(format: "%.2f=%d", $0, st.slotsKept[$0]!) }.joined(separator: " ")
        let why = st.why.keys.sorted().map { "\($0)=\(st.why[$0]!)" }.joined(separator: " ")
        func kv(_ d: [String: Int]) -> String { d.keys.sorted().map { "\($0)=\(d[$0]!)" }.joined(separator: ",") }
        return "pitch=\(String(format: "%.2f", st.pitchMM)) kept=[\(kept)] edge=\(st.slotsCut) texels=\(st.texelsPainted) "
            + "anchor=\(String(format: "(%.1f,%.1f,%.1f) in %.1fs", st.anchorShiftMM.x, st.anchorShiftMM.y, st.anchorShiftMM.z, st.anchorSeconds)) "
            + "drawnHi=\(b.field.drawnDensityHi) why=[\(why)] noLadder=\(st.noLadderRegions) t=\(String(format: "%.2f", st.seconds))s "
            + "walk=anchor:\(st.anchorSlotsWalked) place:\(st.placeSlotsWalked) shifts=\(st.anchorBaseVolumes.count) "
            + "children=\(st.anchorChildVolumes.count) fp=\(kv(st.footprintBounded)) unb=\(kv(st.footprintUnbounded)) "
            + "raster=\(String(format: "%.1f", st.rasterSeconds))s place=\(String(format: "%.1f", st.placeSeconds))s cells=\(b.field.steppedCells.count)"
    }

    @MainActor
    func testIdenticalBakesOnHisProject() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dirPath = env["OCTREE_PROOF_DIR"], let outPath = env["OCTREE_PROOF_OUT"] else {
            throw XCTSkip("OCTREE_PROOF_DIR, OCTREE_PROOF_OUT")
        }
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let src = URL(fileURLWithPath: dirPath), out = URL(fileURLWithPath: outPath)
        precondition(!src.path.contains("CoreSimulator"), "never his live store — a copy")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let snap = try JSONDecoder().decode(ProjectSnapshot.self, from: Data(contentsOf: src.appendingPathComponent("project.json")))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fp-proof-\(UUID().uuidString)", isDirectory: true)
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
        let header = "project \(snap.id.uuidString) \"\(pm.name)\" algorithm \(lat.algorithm) stage \(String(describing: lat.stageMode)) "
            + "step-halves \(lat.gradeStepsAreHalves) density \(lat.densityMode) cells \(lat.cellSizeMode) field \(env["OCTREE_FIELD"] ?? "stage")"
        print("FP-PROJECT " + header)
        try XCTSkipUnless(lat.algorithm == "stepped" || lat.algorithm == "doubled", "the octree bakes Stepped and Default Grade only")

        // ── the stage solve (the field the bake grades by) — LatticeDefaultGradePlanProof's, verbatim
        var stageField: LatticeDemandField? = nil
        if env["OCTREE_FIELD"] != "none", let ctx = model.makeLatticeSimContext() {
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
        let includes = regions.filter { $0.role == .include }.count
        print("FP-SCENE \(regions.count) region(s), \(includes) include(s), cells \(cells.map { String(format: "%.2f", $0) }.joined(separator: ","))")

        // ── the renderer, the app's order; every octree bake is captured by the observer
        guard let mr = MeshRenderer(device: device, sampleCount: 4) else { throw XCTSkip("renderer") }
        try XCTSkipUnless(mr.latticePipelinesDidBuild)
        var captured: [Bake] = []
        P.octreeBakeObserver = { f, st in captured.append(Bake(field: f, stats: st)) }
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

        var token = 0
        func arm(_ name: String, footprint: Bool, inset: Double = 0) throws -> (bake: Bake, setScene: Double) {
            P.anchorFootprintEnabled = footprint
            P.placeFootprintEnabled = footprint
            P.footprintInsetForTestsMM = inset
            defer { P.anchorFootprintEnabled = true; P.placeFootprintEnabled = true; P.footprintInsetForTestsMM = 0 }
            captured.removeAll()
            token += 1
            let t = Date()
            mr.setLatticeScene(s1, token: token)
            let secs = Date().timeIntervalSince(t)
            XCTAssertEqual(captured.count, 1, "\(name): one octree bake per scene")
            let b = try XCTUnwrap(captured.last, "\(name): the renderer baked no octree field")
            print("FP-ARM \(name) setScene \(String(format: "%.1f", secs))s | " + Self.diag(b))
            return (b, secs)
        }
        var lines = ["# anchor-footprint identical-bake proof (2026-10-03)", header,
                     "regions \(regions.count) (includes \(includes)); cells \(cells.map { String(format: "%.2f", $0) }.joined(separator: ","))"]
        func record(_ name: String, _ r: (bake: Bake, setScene: Double)) {
            lines.append("")
            lines.append("arm \(name): setScene \(String(format: "%.1f", r.setScene))s (whole rebake, renderer included)")
            lines.append("  stats: " + Self.diag(r.bake))
            lines.append("  sha256/16: " + LatticeOctreeFootprintTests.digests(r.bake).map { "\($0.0)=\($0.1)" }.joined(separator: " "))
        }
        let c1 = try arm("control-1", footprint: false)
        record("control-1", c1)
        var c2: (bake: Bake, setScene: Double)? = nil
        if env["OCTREE_AA"] != "0" {
            let r = try arm("control-2", footprint: false)
            record("control-2", r)
            c2 = r
        }
        let fp = try arm("footprint", footprint: true)
        record("footprint", fp)
        let baseMax = cells.max() ?? 0
        let red = try arm("red-inset", footprint: true, inset: 4 * baseMax + 4)
        record("red-inset (inset \(4 * baseMax + 4) mm)", red)

        let aa = c2.map { LatticeOctreeFootprintTests.differences(c1.bake, $0.bake) }
        let ab = LatticeOctreeFootprintTests.differences(c1.bake, fp.bake)
        let rd = LatticeOctreeFootprintTests.differences(c1.bake, red.bake)
        let movedRed = zip(c1.bake.stats.anchorBaseVolumes, red.bake.stats.anchorBaseVolumes).filter { $0.0.bitPattern != $0.1.bitPattern }.count
        let s = (c1.bake.stats, fp.bake.stats)
        lines.append("")
        lines.append("verdict")
        lines.append("  A/A control-1 vs control-2: " + (aa.map { $0.isEmpty ? "IDENTICAL" : "DIFFER \($0)" } ?? "skipped (OCTREE_AA=0)"))
        lines.append("  control-1 vs footprint: " + (ab.isEmpty ? "IDENTICAL (every array by bit pattern; \(s.0.anchorBaseVolumes.count) base volumes, \(s.0.anchorChildVolumes.count) children volumes, anchor, plan of \(fp.bake.field.steppedCells.count) cells)" : "DIFFER \(ab)"))
        lines.append("  RED control-1 vs red-inset: " + (rd.isEmpty ? "IDENTICAL (RED FAILED TO FIRE)" : "DIFFER \(rd); \(movedRed) of \(c1.bake.stats.anchorBaseVolumes.count) shift volumes moved"))
        lines.append(String(format: "  anchor search: walked %d -> %d slots (%.1f%%), %.1fs -> %.1fs", s.0.anchorSlotsWalked, s.1.anchorSlotsWalked,
                            100 * Double(s.1.anchorSlotsWalked) / Double(Swift.max(1, s.0.anchorSlotsWalked)), s.0.anchorSeconds, s.1.anchorSeconds))
        lines.append(String(format: "  level-0 walk: %d -> %d slots (%.1f%%), %.1fs -> %.1fs", s.0.placeSlotsWalked, s.1.placeSlotsWalked,
                            100 * Double(s.1.placeSlotsWalked) / Double(Swift.max(1, s.0.placeSlotsWalked)), s.0.placeSeconds, s.1.placeSeconds))
        lines.append(String(format: "  octree bake: %.1fs -> %.1fs; whole rebake (setScene) %.1fs -> %.1fs", s.0.seconds, s.1.seconds, c1.setScene, fp.setScene))
        let text = lines.joined(separator: "\n") + "\n"
        try text.write(to: out.appendingPathComponent("\(snap.id.uuidString).txt"), atomically: true, encoding: .utf8)
        print(text)

        if let aa { XCTAssertEqual(aa, [], "★ A/A: the control bake is deterministic") }
        XCTAssertEqual(ab, [], "★★ the footprint bake is BIT-IDENTICAL to the whole-extent walk")
        XCTAssertTrue(rd.contains("anchorBaseVolumes"), "★ RED: the inset must move the volumes: \(rd)")
        // a footprint may legitimately cover the whole part; it may never walk MORE
        XCTAssertLessThanOrEqual(s.1.anchorSlotsWalked, s.0.anchorSlotsWalked, "the search never walks more")
        XCTAssertLessThanOrEqual(s.1.placeSlotsWalked, s.0.placeSlotsWalked, "the level-0 walk never walks more")
    }
}
