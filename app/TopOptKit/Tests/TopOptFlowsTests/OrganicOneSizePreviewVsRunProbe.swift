import XCTest
import Metal
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★ ORGANIC ONE SIZE — PREVIEW VS RUN (maintainer, 2026-10-03, ruling 5): "Organic single-size
/// Fit: the app sends a one-size window (cell_min_mm = cell_max_mm = the size) … Report whether
/// preview and run then match for that case." A MEASUREMENT, opt-in, on a COPY of his project:
///
///     ONESIZE_PROJECT_DIR=<copy of a project folder> ONESIZE_OUT=<dir> \
///     [ONESIZE_SIZES=4,6] [ONESIZE_STRUT=stated|unstated|both] [ONESIZE_BAKE=0] \
///     [ONESIZE_REPAIRS=0|1] swift test --skip-build --filter OrganicOneSizePreviewVsRunProbe
///
/// For each size s it sets the open project's lattice to Manual one size the way the wizard's
/// Manual pill does with the simulation off (`setSimulateStresses(false)`, `cellSizeMode =
/// .fit`, `organicPickedSeparationMM = s`, no grade), then:
///   1. writes the stage job (`makeLatticeRunRequest` → `RemoteRun.buildJobJSON`) with the
///      model beside it, and asks core's own parser whether it accepts it;
///   2. bakes the organic preview exactly as `WorkspacePlaceholder` assembles it
///      (`organicForBake` → the off-main resample/plan/rim/band block → `LatticeSDFScene`),
///      from the stage's own solve (`makeLatticeSimContext` → `analyzeSolidLoadCase`, what
///      `LatticeSimModel` runs), and prints the scene's DIAG lines and the drawn struts.
/// The job is then run through the CLI by hand; this file never runs core's CLI.
final class OrganicOneSizePreviewVsRunProbe: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        while u.path != "/" && !FileManager.default.fileExists(atPath: u.appendingPathComponent("core/src/materials/materials.json").path) {
            u = u.deletingLastPathComponent()
        }
        return u
    }()

    private static func q(_ v: [Double], _ f: Double) -> Double {
        guard !v.isEmpty else { return .nan }
        let s = v.sorted()
        return s[Swift.min(s.count - 1, Int(Double(s.count - 1) * f))]
    }

    @MainActor
    func testOneSizePreviewAndStageJob() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dirPath = env["ONESIZE_PROJECT_DIR"], let outPath = env["ONESIZE_OUT"] else {
            throw XCTSkip("ONESIZE_PROJECT_DIR, ONESIZE_OUT")
        }
        guard TopOptKit.latticeAlgorithmIsKnown("organic") else { throw XCTSkip("no organic on this core") }
        let sizes = (env["ONESIZE_SIZES"] ?? "4").split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        let strutModes: [String] = {
            switch env["ONESIZE_STRUT"] ?? "stated" {
            case "both": return ["stated", "unstated"]
            case "unstated": return ["unstated"]
            default: return ["stated"]
            }
        }()
        let bake = env["ONESIZE_BAKE"] != "0"
        let src = URL(fileURLWithPath: dirPath), out = URL(fileURLWithPath: outPath)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let snap = try JSONDecoder().decode(ProjectSnapshot.self, from: Data(contentsOf: src.appendingPathComponent("project.json")))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("onesize-\(UUID().uuidString)", isDirectory: true)
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
        model.open(try XCTUnwrap(model.recentProjects.first { $0.id == snap.id }, "the copy did not decode"))
        let pm = try XCTUnwrap(model.project)
        let mesh = try XCTUnwrap(pm.viewerMesh)
        let saved = pm.lattice
        print("ONESIZE-PROJECT \(pm.name) algorithm \(saved.algorithm) stage \(String(describing: saved.stageMode)) cells \(saved.cellSizeMode) sim \(saved.simulateStresses) density \(saved.densityMode) strut \(saved.organicStrutWidthMM) grow \(saved.organicGrowth) shapeFit \(saved.organicShapeFit) band \(saved.shapeFitBandMM) rim \(saved.organicSolidRimMM) repairs \(saved.organicShowRepairs) bead \(pm.printParams.strutLineWidthMM) resolution \(pm.quality.resolution) solveVoxel \(String(format: "%.3f", pm.solveVoxelMM))")
        try XCTSkipUnless(saved.algorithm == "organic", "not an organic project")

        // ── the stage's own solve, once (the field `latticeSim` holds; the run solves its own)
        var stageField: LatticeDemandField? = nil
        if bake, let ctx = model.makeLatticeSimContext() {
            let t0 = Date()
            let r = try TopOptKit.analyzeSolidLoadCase(
                modelPath: ctx.modelPath, material: ctx.material, materialsPath: ctx.materialsPath,
                rulesPath: ctx.rulesPath, resolution: ctx.resolution, anchorFaceIDs: ctx.anchorFaceIDs,
                loadGroups: ctx.loadGroups, buildDirection: ctx.buildDirection,
                faceRegions: ctx.faceRegions, anchorRegionIDs: ctx.anchorRegionIDs)
            stageField = LatticeDemandField(vonMises: r.vonMisesField, stressTensor: r.stressTensorField,
                                            nx: r.gridNX, ny: r.gridNY, nz: r.gridNZ, origin: r.gridOrigin,
                                            spacingMM: r.spacingMM, provenance: .solidSim(date: Date(), resolution: ctx.resolution))
            print(String(format: "ONESIZE-SOLVE resolution %d grid %d×%d×%d voxel %.3f mm tensor %d nonconvergent %d (%.1f s)",
                         ctx.resolution, r.gridNX, r.gridNY, r.gridNZ, r.spacingMM, r.stressTensorField.count,
                         r.nonConvergent ? 1 : 0, Date().timeIntervalSince(t0)))
        }

        for s in sizes {
            for strut in strutModes {
                var tag = String(format: "s%g-%@", s, strut)
                if env["ONESIZE_NOSLAB"] == "1" { tag += "-noslab" }
                if let b = env["ONESIZE_SEEDBOOST"] { tag += "-seed\(b)" }
                if env["ONESIZE_MIRROR_CORE"] == "1" { tag += "-mirrorcore" }
                let dir = out.appendingPathComponent(tag, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                // ── Manual, one size, the simulation off — the wizard's Manual pill
                var lat = saved
                lat.setSimulateStresses(false)
                lat.cellSizeMode = .fit
                lat.organicPickedSeparationMM = s
                lat.organicPickedGradeMM = []
                if strut == "unstated" { lat.organicStrutWidthMM = 0 }
                if let r = env["ONESIZE_REPAIRS"] { lat.organicShowRepairs = r == "1" }
                pm.lattice = lat
                let w = lat.organicPreviewSeparationWindowMM
                let rimPreview = lat.organicRunSolidRimMM(floorMM: pm.organicFloor.mm)
                print(String(format: "ONESIZE-SETTINGS %@ window %.3f–%.3f fallback %d needsStressSolve %d density %@ cells %@ strut %.3f shapeFit %d band %.2f strength %.2f rimSetting %.2f floor %.3f (%@) previewRim %.3f",
                             tag, w.lo, w.hi, lat.organicPreviewWindowIsFallback ? 1 : 0, lat.needsStressSolve ? 1 : 0,
                             "\(lat.densityMode)", "\(lat.cellSizeMode)", lat.organicStrutWidthMM, lat.organicShapeFit ? 1 : 0,
                             lat.shapeFitBandMM, lat.shapeFitGradeStrength, lat.organicSolidRimMM,
                             pm.organicFloor.mm, "\(pm.organicFloor)", rimPreview))

                // ── 1. the stage job, and core's parser on it
                let request = try XCTUnwrap(model.makeLatticeRunRequest(), "no stage job")
                let jobData = try RemoteRun.buildJobJSON(request)
                let schema = TopOptKit.jobSchemaError(jobData)
                XCTAssertNil(schema, "★ core refuses the one-size stage job: \(schema ?? "")")
                let pretty = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: jobData),
                                                        options: [.prettyPrinted, .sortedKeys])
                try pretty.write(to: dir.appendingPathComponent("job.json"))
                let modelName = (request.modelPath as NSString).lastPathComponent
                let modelDst = dir.appendingPathComponent(modelName)
                try? FileManager.default.removeItem(at: modelDst)
                try FileManager.default.copyItem(at: URL(fileURLWithPath: request.modelPath), to: modelDst)
                let job = try XCTUnwrap(JSONSerialization.jsonObject(with: jobData) as? [String: Any])
                let grading = job["grading"] as? [String: Any] ?? [:]
                let latBlock = job["lattice"] as? [String: Any] ?? [:]
                func show(_ d: [String: Any], _ keys: [String]) -> String {
                    keys.map { k in "\(k)=\(d[k].map { "\($0)" } ?? "—")" }.joined(separator: " ")
                }
                print("ONESIZE-JOB \(tag) mode \(job["mode"] ?? "—") resolution \(job["resolution"] ?? "—") schema \(schema ?? "accepted") | grading: \(show(grading, ["algorithm", "cell_mode", "cell_min_mm", "cell_max_mm", "cell_mm", "shape_grade", "shape_grade_band_mm", "min_extrudable_width_mm", "max_relative_density", "min_relative_density"])) | lattice: \(show(latBlock, ["organic_shape_fit", "organic_shape_fit_only", "organic_strut_width_mm", "organic_solid_rim_mm", "organic_growth", "organic_transfer_ties", "organic_structural_certification", "intent", "min_extrudable_width_mm"]))")
                let organicKeys = (grading.keys.filter { $0.hasPrefix("organic") || $0 == "intent" }.map { "grading.\($0)=\(grading[$0]!)" }
                                   + latBlock.keys.filter { $0.hasPrefix("organic") || $0 == "intent" }.map { "lattice.\($0)=\(latBlock[$0]!)" }).sorted()
                print("ONESIZE-JOB-ORGANIC-KEYS \(tag) \(organicKeys.joined(separator: " "))")
                XCTAssertEqual(grading["cell_mode"] as? String, "swept", "★ ruling 5: one size rides as a swept window")
                XCTAssertEqual(grading["cell_min_mm"] as? Double, s)
                XCTAssertEqual(grading["cell_max_mm"] as? Double, s)
                XCTAssertNil(grading["cell_mm"])

                guard bake else { continue }
                guard let f = stageField else { XCTFail("no stage solve"); continue }

                // ── 2. the preview, as WorkspacePlaceholder assembles it (lines ~4938-5300)
                func sf(_ f: LatticeDemandField) -> StressField {
                    StressField(nx: f.nx, ny: f.ny, nz: f.nz, origin: SIMD3<Float>(f.origin), spacing: Float(f.spacingMM), values: f.vonMises)
                }
                let field: StressField? = !lat.gradingMode.followsStress ? nil
                    : (lat.densityMode.needsSimulation ? sf(f) : LatticeSDFScene.demandField(from: pm.run.outcome))
                let wallStressField: StressField? = sf(f)
                let beadForBake = pm.printParams.strutLineWidthMM
                let emission = pm.latticeJobRegions()
                var regions = emission.regions
                // CONTROL (opt-in, NOT the app): ONESIZE_NOSLAB=1 keeps the job's whole prisms
                if !lat.wallThickness.isThrough, env["ONESIZE_NOSLAB"] != "1" {
                    for i in regions.indices where regions[i].role == .include && regions[i].kind == .face { regions[i].thickness = lat.wallThickness }
                }
                let params = lat.proxyParams(limits: TopOptKit.latticeLimits(topology: lat.topologyID), lineWidthMM: beadForBake)
                let span = params.densitySpan
                let gamma = Swift.max(0.05, params.gamma)
                let skinMM = lat.boundary.faceSkinMM(wallRingMM: pm.printParams.wallRingMM)
                let gradesFromSim = lat.densityMode.needsSimulation
                let stageMode = lat.stageMode ?? .structural
                let allowableMPa = model.yieldStrengthMPa(for: pm.material)
                guard !f.stressTensor.isEmpty, f.stressTensor.count == 6 * f.nx * f.ny * f.nz, beadForBake > 0 else {
                    XCTFail("no tensor / bead — the app would not trace"); continue
                }
                var organicIn: LatticeOrganicInput? = LatticeOrganicInput(
                    tensor: f.stressTensor, dims: (f.nx, f.ny, f.nz), originMM: SIMD3<Double>(f.origin),
                    spacingMM: f.spacingMM, minExtrudableWidthMM: beadForBake,
                    buildDirection: SIMD3<Double>(pm.buildOrientation.resolved(gravity: pm.force.gravity)),
                    separationMinMM: w.lo, separationMaxMM: w.hi,
                    rhoMin: span.lo, rhoMax: span.hi,
                    strutDiameterMM: lat.organicStrutWidthMM, grow: lat.organicGrowth,
                    layerHeightMM: pm.printParams.layerHeightMM,
                    overhangAngleDeg: lat.organicGrowth ? 0 : lat.organicOverhangDeg,
                    transferTies: lat.organicTransferTies, tieSwirl: lat.organicTieSwirl,
                    shapeFit: lat.organicShapeFit, shapeFitOnly: lat.organicShapeFitOnly,
                    anchorAtBoundary: lat.boundary == .covered,
                    showRepairs: lat.organicShowRepairs)
                let organicAutoWindow = lat.organicPreviewWindowIsFallback
                XCTAssertFalse(organicAutoWindow, "a one-size pick is not the Auto stand-in")
                let synthOn = lat.organicSyntheticStressesActive
                let previewVoxelMM = Double((mesh.bounds.max - mesh.bounds.min).max()) / 128
                if var o = organicIn,
                   let fine = OrganicTraceGrid.resample(tensor: o.tensor, dims: o.dims, originMM: o.originMM,
                                                        spacingMM: o.spacingMM, toVoxelMM: previewVoxelMM) {
                    print(String(format: "ONESIZE-PREVIEW-GRID %@ solve %.3f mm (%d×%d×%d) → trace %.3f mm (%d×%d×%d), ×%d",
                                 tag, o.spacingMM, o.dims.0, o.dims.1, o.dims.2, fine.spacingMM, fine.dims.0, fine.dims.1, fine.dims.2, fine.factor))
                    o.tensor = fine.tensor; o.dims = fine.dims; o.originMM = fine.originMM; o.spacingMM = fine.spacingMM
                    organicIn = o
                }
                organicIn?.seedBoost = lat.wallThickness.seedBoost
                // CONTROL (opt-in, NOT the app): ONESIZE_SEEDBOOST=1 is core's own tracer
                if let b = env["ONESIZE_SEEDBOOST"].flatMap(Double.init) { organicIn?.seedBoost = b }
                let wallDepthSteps = LatticeWallDepthSteps.forWalls(lat, regions: regions, beadMM: beadForBake)
                var synthPlan = OrganicSyntheticStress.Plan(regionIDs: [], regions: [], keyByID: [:])
                if let o = organicIn {
                    synthPlan = OrganicSyntheticStress.plan(regions: regions, dims: o.dims, originMM: o.originMM,
                                                            spacingMM: o.spacingMM, defaultFoci: lat.organicSyntheticFoci,
                                                            statedFoci: lat.selectableSyntheticFoci)
                }
                if var o = organicIn {
                    o.solidRimMM = Swift.max(0, rimPreview)
                    o.shapeBandMM = lat.organicShapeFit ? lat.shapeFitBandMM : 0
                    o.shapeBandStrength = lat.shapeFitGradeStrength
                    o.depthStaggerCellMM = lat.organicDepthStagger ? Swift.max(o.separationMinMM, o.separationMaxMM) : 0
                    // CONTROL (opt-in, NOT the app): ONESIZE_MIRROR_CORE=1 hands the tracer what the
                    // run uses at lo == hi — no shape fit (core's floor is cell_min_mm = s, so it
                    // shrinks nothing), no shape band (no organic job carries one), the JOB's rim
                    if env["ONESIZE_MIRROR_CORE"] == "1" {
                        o.shapeFit = false
                        o.shapeBandMM = 0
                        o.solidRimMM = Swift.max(0, (grading["organic_solid_rim_mm"] as? Double) ?? 0)
                    }
                    organicIn = o
                }
                if let o = organicIn {
                    print(String(format: "ONESIZE-PREVIEW-WINDOW %@ %.2f–%.2f mm · rim %.3f mm · shape band %.2f mm (strength %.2f) · strut %.3f · showRepairs %d · synth %d · seedBoost %.2f",
                                 tag, o.separationMinMM, o.separationMaxMM, o.solidRimMM, o.shapeBandMM, o.shapeBandStrength,
                                 o.strutDiameterMM, o.showRepairs ? 1 : 0, synthOn ? 1 : 0, o.seedBoost))
                }
                organicIn?.regionIDs = synthPlan.regionIDs
                if synthOn { organicIn?.syntheticRegions = synthPlan.regions }
                let includes = regions.filter { $0.role == .include }
                print("ONESIZE-PREVIEW-REGIONS \(tag) regions \(regions.count) includes \(includes.count) skipped \(emission.skippedFaces) planned voxels \(synthPlan.regionIDs.filter { $0 >= 1 }.count)")
                // the app's stages: traced first; the emitted set replaces it when repairs are wanted
                let stages: [Bool] = (organicIn?.showRepairs == true) ? [false, true] : [organicIn?.showRepairs ?? true]
                var report: [String: Any] = ["tag": tag, "size_mm": s, "strut": strut]
                for stageRepairs in stages {
                    var stageIn = organicIn
                    stageIn?.showRepairs = stageRepairs
                    let t0 = Date()
                    let scene = LatticeSDFScene(mesh: mesh, field: field, latticeID: params.latticeID,
                                                organicSpans: nil, organicReceipt: nil,
                                                stressField: sf(f),
                                                statedDensityGoverns: !gradesFromSim || stageMode == .aesthetic,
                                                allowQuilt: lat.allowQuilt, stageMode: stageMode, algorithm: lat.algorithm,
                                                allowableMPa: allowableMPa, boundaryFinishWritten: lat.singleCellMembers,
                                                organic: stageIn, regions: regions,
                                                rhoMin: span.lo, rhoMax: span.hi, gamma: gamma,
                                                whenEmpty: .latticeNothing, skinMM: skinMM,
                                                skippedFaces: emission.skippedFaces,
                                                skippedRegionNames: emission.skippedRegionNames,
                                                wallThicknessFloorMM: organicIn?.separationMinMM ?? 0,
                                                wallDepthSteps: wallDepthSteps, wallStressField: wallStressField,
                                                bandOverrides: lat.bandTreatments, octetBand: false,
                                                bandGradeMM: lat.gradingMode.fitsShape ? lat.shapeFitBandMM : 0,
                                                beadMM: beadForBake)
                    let secs = Date().timeIntervalSince(t0)
                    let caps = scene.organicCapsules
                    let diam = caps.map { 2 * Double($0.r) }
                    let lens = caps.map { Double(simd_length($0.b - $0.a)) }
                    let total = lens.reduce(0, +)
                    let atBead = diam.filter { abs($0 - beadForBake) < 1e-3 }.count
                    let stageTag = stageRepairs ? "repairs" : "traced"
                    print(String(format: "ONESIZE-PREVIEW-STRUTS %@ [%@] capsules %d length %.0f mm · diameter min %.3f p05 %.3f p50 %.3f p95 %.3f max %.3f · at the bead %.3f: %d · scene rim %.3f · %.1f s",
                                 tag, stageTag, caps.count, total, Self.q(diam, 0), Self.q(diam, 0.05), Self.q(diam, 0.5),
                                 Self.q(diam, 0.95), Self.q(diam, 1), beadForBake, atBead, scene.organicSolidRimMM, secs))
                    print("ONESIZE-PREVIEW-SUMMARY \(tag) [\(stageTag)] \(scene.organicSummary)")
                    if let why = scene.organicNotDrawnReason { print("ONESIZE-PREVIEW-NOT-DRAWN \(tag) [\(stageTag)] \(why)") }
                    report[stageTag] = [
                        "capsules": caps.count, "length_mm": total,
                        "diameter_min": Self.q(diam, 0), "diameter_p05": Self.q(diam, 0.05), "diameter_p50": Self.q(diam, 0.5),
                        "diameter_p95": Self.q(diam, 0.95), "diameter_max": Self.q(diam, 1), "at_bead": atBead,
                        "scene_rim_mm": scene.organicSolidRimMM, "seconds": secs, "summary": scene.organicSummary,
                    ] as [String: Any]
                }
                report["window"] = [w.lo, w.hi]
                report["preview_rim_mm"] = rimPreview
                report["job_rim_mm"] = latBlock["organic_solid_rim_mm"] ?? grading["organic_solid_rim_mm"] ?? NSNull()
                report["shape_band_mm"] = lat.organicShapeFit ? lat.shapeFitBandMM : 0
                let rj = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try rj.write(to: dir.appendingPathComponent("preview.json"))
            }
        }
        pm.lattice = saved
    }
}
