// StructuralAutoCalibration — ★ notes30 STRUCTURAL AUTO, the plan's calibration (scope.md 3.10), OPT-IN and HEAVY (under
// HEAVY.lock, one at a time): SA_CALIBRATE=<dir with S.step, T.step, M.step, K.step, C.step> (make_parts.py: the repo's own
// cube and cylinder scaled — never his parts), optionally SA_PARTS="S,T" and SA_MARGINS="1.5,1.75,2".
// Per part and Safety margin, the whole chain on this Mac's core, in process (LatticeFileButton.runHere, core's run_file_job
// with its strength check, exactly the Mac's): the stage solve; round 0 sized; check 1; round 1 re-sized from check 1's own
// lattice stress; check 2; and today's Structural Auto (the ramp) as the baseline. It prints one line per part and margin
// (the target, each check's verdict, margin and plastic, the round kept and what it saved against round 0, the baseline's)
// and writes them to <dir>/calibration[_<parts>].md. Nothing is asserted: the NO-GO bars are read off the table by the reviewer.
#if canImport(AppKit)
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class StructuralAutoCalibration: XCTestCase {
    struct Part {
        var name: String, file: String
        var anchorAxis: Int, anchorSign: Float     // the anchored face: the extreme along an axis
        var loadAxis: Int, loadSign: Float         // the loaded face
        var force: SIMD3<Double>
    }
    static let parts: [Part] = [
        Part(name: "S cube 60, side shear", file: "S.step", anchorAxis: 2, anchorSign: -1, loadAxis: 0, loadSign: 1,
             force: SIMD3(0, 0, -3000)),
        Part(name: "T beam 120, cantilever", file: "T.step", anchorAxis: 0, anchorSign: -1, loadAxis: 2, loadSign: 1,
             force: SIMD3(0, 0, -400)),
        Part(name: "M plate 90 x 30, pressed", file: "M.step", anchorAxis: 2, anchorSign: -1, loadAxis: 2, loadSign: 1,
             force: SIMD3(0, 0, -6000)),
        Part(name: "K column 100, side push", file: "K.step", anchorAxis: 2, anchorSign: -1, loadAxis: 2, loadSign: 1,
             force: SIMD3(500, 0, 0)),
        Part(name: "C cylinder 60 x 120, pressed", file: "C.step", anchorAxis: 2, anchorSign: -1, loadAxis: 2, loadSign: 1,
             force: SIMD3(0, 0, -4000)),
        Part(name: "B cylinder 60 x 120, side push", file: "C.step", anchorAxis: 2, anchorSign: -1, loadAxis: 2, loadSign: 1,
             force: SIMD3(300, 0, 0)),
    ]

    func testCalibrateTheSixParts() throws {
        guard let dir = ProcessInfo.processInfo.environment["SA_CALIBRATE"] else {
            throw XCTSkip("opt-in, heavy: SA_CALIBRATE=<parts dir> under HEAVY.lock")
        }
        let only = Set((ProcessInfo.processInfo.environment["SA_PARTS"] ?? "").split(separator: ",").map(String.init))
        let margins = (ProcessInfo.processInfo.environment["SA_MARGINS"] ?? "1.5,1.75,2")
            .split(separator: ",").compactMap { Double($0) }
        let core = FlexibleHisProject.repoRoot.appendingPathComponent("core")
        let materials = core.appendingPathComponent("src/materials/materials.json").path
        let rules = core.appendingPathComponent("src/settings/rules.json").path
        let fm = FileManager.default
        var lines = ["| part | target | check 1 | check 2 | kept | plastic vs round 0 | today's Auto | seconds |",
                     "|---|---|---|---|---|---|---|---|"]
        func write() {
            try? (["# Structural Auto calibration (SA1)", ""] + lines).joined(separator: "\n")
                .write(toFile: dir + "/calibration\(only.isEmpty ? "" : "_" + only.sorted().joined()).md", atomically: true, encoding: .utf8)
        }
        for part in Self.parts where only.isEmpty || only.contains(String(part.name.prefix(1))) {
            let work = fm.temporaryDirectory.appendingPathComponent("sa-cal-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: work) }
            let model = work.appendingPathComponent("part.step")
            try fm.copyItem(atPath: dir + "/" + part.file, toPath: model.path)
            let mesh = try TopOptKit.importMesh(path: model.path)
            func extreme(_ axis: Int, _ sign: Float) -> Int32? {
                let c = stride(from: axis, to: mesh.vertices.count, by: 3).map { mesh.vertices[$0] }
                return LatticePlaceChipsTests.face(mesh, axis: axis, sign: sign, at: sign > 0 ? (c.max() ?? 0) : (c.min() ?? 0))
            }
            let anchor = try XCTUnwrap(extreme(part.anchorAxis, part.anchorSign), "\(part.name): its anchored face")
            let load = try XCTUnwrap(extreme(part.loadAxis, part.loadSign), "\(part.name): its loaded face")
            let top = try XCTUnwrap(extreme(2, 1), "\(part.name): its top face")
            let zs = stride(from: 2, to: mesh.vertices.count, by: 3).map { mesh.vertices[$0] }
            let height = Double((zs.max() ?? 0) - (zs.min() ?? 0))
            // the stage's solve, as the page runs it
            let sim = try TopOptKit.analyzeSolidLoadCase(modelPath: model.path, material: "PA12", materialsPath: materials,
                                                         rulesPath: rules, resolution: 64, anchorFaceIDs: [Int(anchor)],
                                                         loadGroups: [.init(faceIDs: [Int(load)], force: part.force)])
            let stage = LatticeDemandField(vonMises: sim.vonMisesField, stressTensor: sim.stressTensorField, nx: sim.gridNX,
                                           ny: sim.gridNY, nz: sim.gridNZ, origin: sim.gridOrigin, spacingMM: sim.spacingMM,
                                           provenance: .solidSim(date: Date(), resolution: 64))
            for margin in margins {
                let t0 = Date()
                // the settings the page sends on Structural Auto: a face row under the top, Covered, cells as Auto lays them
                var s = LatticeLayoutSession.Settings()
                s.regions = [.init(id: 1, noLattice: false, faces: [top], depthMM: (0.75 * height).rounded(), expandMM: -3)]
                s.coverMM = -1
                s.algorithm = "default_grade"
                s.cellMaxMM = 12
                s.minCellsAcross = 5
                s.gradeToShape = true
                s.bandMM = 6
                s.cellSearch = true
                var today = s
                today.byStress = true
                today.cellsByStress = true
                today.referenceMPa = 38 * 0.75 / margin   // the printed yield over the margin (PA12)
                LatticeLayoutPreview.structuralAuto(&s)
                let inputs = StructuralAuto.Inputs(topology: "octet", yieldMPa: 38, zKnockdown: 0.75, up: SIMD3(0, 0, 1),
                                                   margin: margin)
                let r0 = try XCTUnwrap(StructuralAuto.size(stage, inputs, largestCellMM: 12), "\(part.name): round 0")
                let request = RunRequest(modelPath: model.path, material: "PA12", materialsPath: materials, rulesPath: rules,
                                         resolution: 64, projectName: "SA1 calibration", anchorFaceIDs: [Int(anchor)],
                                         loadGroups: [.init(faceIDs: [Int(load)], force: part.force)], minimizePlastic: true,
                                         buildDirection: SIMD3(0, 0, 1), infillPercent: 40, wallLoops: 3,
                                         wallLineWidthOuterMM: 0.45, wallLineWidthInnerMM: 0.45,
                                         lattice: LatticeSpec(topologyID: "octet", cellMM: 8, strutRadiusMM: 0.6,
                                                              generateRelativeDensity: 0.3, minRelativeDensity: 0.1,
                                                              maxRelativeDensity: 0.5, skin: "none", minExtrudableWidthMM: 0.45),
                                         jobMode: "lattice_part")
                var withMargin = request
                withMargin.safetyMargin = margin
                let strengthJob = try RemoteRun.buildJobJSON(withMargin)
                func check(_ settings: LatticeLayoutSession.Settings, _ demand: LatticeDemandField) -> LatticeFileRun.Made? {
                    guard let json = try? LatticeFileJob.build(settings, modelName: "part.step", demand: LatticeFileJob.demandName,
                                                               strengthJob: LatticeFileJob.strengthJobName) else { return nil }
                    let job = LatticeFileJob.ForPart(json: json, modelPath: model.path, demand: LatticeFileJob.demandFile(demand))
                    do { return try LatticeFileButton.runHere(job: job, strengthJob: strengthJob, materialsPath: materials,
                                                               rulesPath: rules) }
                    catch { print("SA-CAL \(part.name) \(margin): refused: \(error)"); return nil }
                }
                func said(_ m: LatticeFileRun.Made?) -> String {
                    guard let m else { return "refused" }
                    let r = LatticeFileButton.round(of: m)
                    return "\(r.passed ? "pass" : (m.report.strength?.verdict.rawValue ?? "?")) \(String(format: "%.2f", r.margin))x "
                        + "\(Int(m.report.plasticMM3)) mm³"
                }
                let m0 = check(s, r0.field)
                var m1: LatticeFileRun.Made?
                var saving: Double?
                if let m0, let c = StructuralAuto.CheckField.of(m0.fields),
                   let r1 = StructuralAuto.resize(check: c, stage: stage, round0: r0, inputs, largestCellMM: 12) {
                    saving = r1.saving
                    if StructuralAuto.next(afterCheck: 1, passed: LatticeFileButton.round(of: m0).passed, saving: r1.saving) == .anotherCheck {
                        m1 = check(s, r1.sized.field)
                    }
                }
                let rounds = [m0, m1].compactMap { $0 }.map(LatticeFileButton.round(of:))
                let k = StructuralAuto.kept(rounds)
                let base = check(today, stage)
                let p0 = m0?.report.plasticMM3 ?? 0
                let kept = rounds.indices.contains(k) ? rounds[k].plasticMM3 : 0
                let line = "| \(part.name) | \(Int((margin * 100).rounded())) % (sized for \(String(format: "%.2f", inputs.target))) | "
                    + "\(said(m0)) | \(m1.map { said($0) } ?? (saving.map { String(format: "not run (saves %.0f %%)", $0 * 100) } ?? "—")) | "
                    + "round \(k) | \(p0 > 0 ? String(format: "%+.1f %%", (kept / p0 - 1) * 100) : "—") | \(said(base)) | "
                    + "\(Int(Date().timeIntervalSince(t0))) |"
                print("SA-CAL " + line)
                lines.append(line)
                write()
            }
        }
        write()
    }
}
#endif
