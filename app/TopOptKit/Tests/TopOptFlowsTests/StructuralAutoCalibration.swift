// StructuralAutoCalibration — ★ notes30 STRUCTURAL AUTO (his rework 11-27, "go for #2"), the 6-part table, OPT-IN and HEAVY
// (under HEAVY.lock, one at a time): SA_CALIBRATE=<dir with S.step, T.step, M.step, K.step, C.step> (make_parts.py: the repo's
// own cube and cylinder scaled — never his parts), optionally SA_PARTS="S,T" and SA_MARGINS="1.5,1.75,2".
// Per part and Safety margin, the press's whole chain on this Mac's core, in process (LatticeFileButton.runHere, core's
// run_file_job with its strength check, exactly the Mac's): the stage solve; CHECK 1 = today's Structural Auto, unchanged (it is
// also the baseline: today's Auto on the same part); short: the preview's own lay of today's settings, its cells and its
// struts and lattice voxels, StructuralAuto.thicken anchored to check 1's own weakest strut, CHECK 2 of the thickened lay; the
// file kept (the lightest that passes, else the stronger). Every part's loaded face carries a Protect skin at least two check
// voxels deep (his fix: the load never sits on open lattice the check cannot resolve). One line per part and margin, written to
// <dir>/calibration[_<parts>].md; nothing is asserted — the stop rule is read off the table. ★ His cube fix (11-27): the
// app's reading is anchored to the check's OWN weakest strut margin, as the app's chain does.
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
        Part(name: "M plate 96 x 48, pressed", file: "M.step", anchorAxis: 2, anchorSign: -1, loadAxis: 2, loadSign: 1,
             force: SIMD3(0, 0, -6000)),
        Part(name: "K column 100, side push", file: "K.step", anchorAxis: 2, anchorSign: -1, loadAxis: 2, loadSign: 1,
             force: SIMD3(500, 0, 0)),
        Part(name: "C cylinder 60 x 120, pressed", file: "C.step", anchorAxis: 2, anchorSign: -1, loadAxis: 2, loadSign: 1,
             force: SIMD3(0, 0, -4000)),
        Part(name: "B cylinder 60 x 120, side push", file: "C.step", anchorAxis: 2, anchorSign: -1, loadAxis: 2, loadSign: 1,
             force: SIMD3(300, 0, 0)),
    ]

    /// The layout the first file was made from, as the app reads it (the preview's own lay of today's settings on the stage's
    /// stress): its cells and struts, and core's map at the check grid's voxel centres. nil when any step fails.
    func layout(_ path: String, _ s: LatticeLayoutSession.Settings, _ stage: LatticeDemandField,
                _ c: StructuralAuto.CheckField) async -> StructuralAuto.Layout? {
        guard let session = try? await LatticeLayoutSession.open(path: path) else { return nil }
        defer { session.close() }
        guard (try? await session.setDemand(mpa: stage.vonMises, nx: stage.nx, ny: stage.ny, nz: stage.nz, origin: stage.origin,
                                            spacingMM: stage.spacingMM)) != nil,
              let r = try? await session.lay(s) else { return nil }
        let laid = LatticeLayoutColours.Laid(r, token: 1)
        var pts: [SIMD3<Float>] = []
        pts.reserveCapacity(c.nx * c.ny * c.nz)
        for k in 0..<c.nz { for j in 0..<c.ny { for i in 0..<c.nx {
            let p = c.origin + SIMD3(Double(i) + 0.5, Double(j) + 0.5, Double(k) + 0.5) * c.spacingMM
            pts.append(SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z)))
        } } }
        guard let w = try? await session.whereAt(pts), w.count == pts.count else { return nil }
        let m = w.map { $0.why == .lattice }
        print("SA-CAL layout: \(laid.cellCount) cells, \(laid.barCount) struts; \(m.filter { $0 }.count) of \(m.count) check voxels are lattice")
        return StructuralAuto.Layout(laid: laid, lattice: m)
    }

    func testCalibrateTheSixParts() async throws {
        guard let dir = ProcessInfo.processInfo.environment["SA_CALIBRATE"] else {
            throw XCTSkip("opt-in, heavy: SA_CALIBRATE=<parts dir> under HEAVY.lock")
        }
        let env = ProcessInfo.processInfo.environment
        let only = Set((env["SA_PARTS"] ?? "").split(separator: ",").map(String.init))
        let margins = (env["SA_MARGINS"] ?? "1.5,1.75,2").split(separator: ",").compactMap { Double($0) }
        let core = FlexibleHisProject.repoRoot.appendingPathComponent("core")
        let materials = core.appendingPathComponent("src/materials/materials.json").path
        let rules = core.appendingPathComponent("src/settings/rules.json").path
        let fm = FileManager.default
        var lines = ["| part | target | check 1 = today's Auto | short / thickened / at limit | law: weakest now → predicted | "
                     + "check 2 | kept | plastic added | seconds |",
                     "|---|---|---|---|---|---|---|---|---|"]
        func write() {
            try? (["# Structural Auto calibration (SA1, the rework: add-only thickening)", ""] + lines).joined(separator: "\n")
                .write(toFile: dir + "/calibration\(only.isEmpty ? "" : "_" + only.sorted().joined()).md", atomically: true,
                       encoding: .utf8)
        }
        for part in Self.parts where only.isEmpty || only.contains(String(part.name.prefix(1))) {
            let work = fm.temporaryDirectory.appendingPathComponent("sa-cal-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: work) }
            let model = work.appendingPathComponent("part.step")
            try fm.copyItem(atPath: dir + "/" + part.file, toPath: model.path)
            let mesh = try TopOptKit.importMesh(path: model.path)
            func coords(_ axis: Int) -> [Float] { stride(from: axis, to: mesh.vertices.count, by: 3).map { mesh.vertices[$0] } }
            func extreme(_ axis: Int, _ sign: Float) -> Int32? {
                let c = coords(axis)
                return LatticePlaceChipsTests.face(mesh, axis: axis, sign: sign, at: sign > 0 ? (c.max() ?? 0) : (c.min() ?? 0))
            }
            let anchor = try XCTUnwrap(extreme(part.anchorAxis, part.anchorSign), "\(part.name): its anchored face")
            let load = try XCTUnwrap(extreme(part.loadAxis, part.loadSign), "\(part.name): its loaded face")
            let top = try XCTUnwrap(extreme(2, 1), "\(part.name): its top face")
            let span = (0..<3).map { a in Double((coords(a).max() ?? 0) - (coords(a).min() ?? 0)) }
            let height = span[2]
            // the check's voxel (64 over the longest side); the loaded face's skin at least two of them deep, to half mm
            let checkVoxel = (span.max() ?? 0) / 64
            let skinMM = (2.5 * checkVoxel * 2).rounded(.up) / 2
            // the stage's solve, as the page runs it
            let sim = try TopOptKit.analyzeSolidLoadCase(modelPath: model.path, material: "PA12", materialsPath: materials,
                                                         rulesPath: rules, resolution: 64, anchorFaceIDs: [Int(anchor)],
                                                         loadGroups: [.init(faceIDs: [Int(load)], force: part.force)])
            // the load set so the SOLID part holds `solidMargin` times it (SA_SOLID_MARGIN, default 6): the lattice, not the
            // part, decides; the solve is linear, so its stress scales with the load
            let solidMargin = Double(env["SA_SOLID_MARGIN"] ?? "") ?? 6
            let k = sim.marginWorstCase.isFinite && sim.marginWorstCase > 0 ? sim.marginWorstCase / solidMargin : 1
            let force = part.force * k
            let stage = LatticeDemandField(vonMises: sim.vonMisesField.map { $0 * Float(k) },
                                           stressTensor: sim.stressTensorField.map { $0 * k }, nx: sim.gridNX,
                                           ny: sim.gridNY, nz: sim.gridNZ, origin: sim.gridOrigin, spacingMM: sim.spacingMM,
                                           provenance: .solidSim(date: Date(), resolution: 64))
            print("SA-CAL \(part.name): the solid holds \(String(format: "%.2f", sim.marginWorstCase))x at \(part.force); the load "
                  + "set to \(String(format: "%.0f", simd_length(force))) N (the solid at \(solidMargin)x); loaded face skin "
                  + "\(skinMM) mm (check voxel \(String(format: "%.2f", checkVoxel)) mm)")
            for margin in margins {
                let t0 = Date()
                // today's Structural Auto, as the page sends it: a face row under the top, Covered, the loaded face's skin,
                // cells as Auto lays them, By stress on the printed yield over the margin (PA12), cell size by stress
                var today = LatticeLayoutSession.Settings()
                today.regions = [.init(id: 1, noLattice: false, faces: [top], depthMM: (0.75 * height).rounded(), expandMM: -3)]
                today.protect = [.init(id: 2, faces: [load], depthMM: skinMM)]
                today.coverMM = -1
                today.algorithm = "default_grade"
                today.cellMaxMM = 12
                today.minCellsAcross = 5
                today.gradeToShape = true
                today.bandMM = 6
                today.cellSearch = true
                today.byStress = true
                today.cellsByStress = true
                today.referenceMPa = 38 * 0.75 / margin
                let inputs = StructuralAuto.Inputs(topology: "octet", yieldMPa: 38, zKnockdown: 0.75, up: SIMD3(0, 0, 1),
                                                   margin: margin)
                let request = RunRequest(modelPath: model.path, material: "PA12", materialsPath: materials, rulesPath: rules,
                                         resolution: 64, projectName: "SA1 calibration", anchorFaceIDs: [Int(anchor)],
                                         loadGroups: [.init(faceIDs: [Int(load)], force: force)], minimizePlastic: true,
                                         buildDirection: SIMD3(0, 0, 1), infillPercent: Int(env["SA_INFILL"] ?? "") ?? 100,
                                         wallLoops: 3, wallLineWidthOuterMM: 0.45, wallLineWidthInnerMM: 0.45,
                                         lattice: LatticeSpec(topologyID: "octet", cellMM: 8, strutRadiusMM: 0.6,
                                                              generateRelativeDensity: 0.3, minRelativeDensity: 0.1,
                                                              maxRelativeDensity: 0.5, skin: "none", minExtrudableWidthMM: 0.45),
                                         jobMode: "lattice_part")
                var withMargin = request
                withMargin.safetyMargin = margin
                let strengthJob = try RemoteRun.buildJobJSON(withMargin)
                func check(_ settings: LatticeLayoutSession.Settings, _ demand: LatticeDemandField) -> LatticeFileRun.Made? {
                    guard var json = try? LatticeFileJob.build(settings, modelName: "part.step", demand: LatticeFileJob.demandName,
                                                               strengthJob: LatticeFileJob.strengthJobName) else { return nil }
                    // SA_THREADS: the job's own thread count (outside HEAVY.lock: one)
                    if let t = Int(env["SA_THREADS"] ?? ""), var o = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] {
                        o["threads"] = t
                        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) { json = d }
                    }
                    let job = LatticeFileJob.ForPart(json: json, modelPath: model.path, demand: LatticeFileJob.demandFile(demand))
                    do { return try LatticeFileButton.runHere(job: job, strengthJob: strengthJob, materialsPath: materials,
                                                               rulesPath: rules) }
                    catch { print("SA-CAL \(part.name) \(margin): refused: \(error)"); return nil }
                }
                var reportN = 0
                func strutMargin(_ m: LatticeFileRun.Made?) -> Double? { m?.report.strength?.strutMargin }
                func said(_ m: LatticeFileRun.Made?) -> String {
                    guard let m else { return "refused" }
                    let r = LatticeFileButton.round(of: m)
                    reportN += 1
                    let rd = URL(fileURLWithPath: dir).appendingPathComponent("reports")
                    try? FileManager.default.createDirectory(at: rd, withIntermediateDirectories: true)
                    try? m.reportJSON.write(to: rd.appendingPathComponent("\(part.name.prefix(1))_\(Int(margin * 100))_\(reportN).json"))
                    let s = m.report.strength
                    let o = (try? JSONSerialization.jsonObject(with: m.reportJSON)) as? [String: Any]
                    let st = o?["strength"] as? [String: Any]
                    let credited = (st?["cells_credited"] as? NSNumber)?.intValue ?? 0
                    let none = (st?["cells_no_credit"] as? NSNumber)?.intValue ?? 0
                    return "\(r.passed ? "pass" : (s?.verdict.rawValue ?? "?")) \(String(format: "%.2f", r.margin))x "
                        + "(solid \(String(format: "%.2f", s?.marginWorstCase ?? 0)), struts "
                        + "\(s?.strutMargin.map { String(format: "%.2f", $0) } ?? "—")\(s?.failReason.map { ", \($0)" } ?? ""), "
                        + "credit \(credited)/\(credited + none)) \(Int(m.report.plasticMM3)) mm³"
                }
                // CHECK 1: today's Structural Auto, unchanged
                let m0 = check(today, stage)
                var m1: LatticeFileRun.Made?
                var t: StructuralAuto.Thickened?
                var why = ""
                if let m0, !LatticeFileButton.round(of: m0).passed {
                    if let c = StructuralAuto.CheckField.of(m0), let lay = await layout(model.path, today, stage, c) {
                        t = StructuralAuto.thicken(check: c, stage: stage, layout: lay, settings: today, inputs)
                        if let t { print("SA-CAL anchor: the check's own weakest over the app's reading = \(String(format: "%.3f", t.anchor))") }
                        if let t, t.thickenedCells > 0 { m1 = check(today, t.field) }   // CHECK 2
                        else { why = t == nil ? "nothing to read" : "nothing to thicken" }
                    } else { why = "no layout" }
                } else if m0 != nil { why = "check 1 passed" }
                let rounds = [m0, m1].compactMap { $0 }.map(LatticeFileButton.round(of:))
                let kept = StructuralAuto.kept(rounds)
                let p0 = rounds.first?.plasticMM3 ?? 0
                let added = rounds.indices.contains(kept) && p0 > 0 ? rounds[kept].plasticMM3 / p0 - 1 : 0
                let law = t.map { String(format: "%.2f → %.2f", $0.weakestNow, $0.weakestPredicted) } ?? "—"
                let rise: String
                if let t, let s0 = strutMargin(m0), let s1 = strutMargin(m1), t.weakestPredicted > s0 {
                    rise = String(format: " (struts rose %.2f of the %.2f predicted: %.0f %%)", s1 - s0, t.weakestPredicted - s0,
                                  (s1 - s0) / (t.weakestPredicted - s0) * 100)
                } else { rise = "" }
                let line = "| \(part.name) | \(Int((margin * 100).rounded())) % (short under \(String(format: "%.2f", inputs.target))) | "
                    + "\(said(m0)) | \(t.map { "\($0.shortCells) / \($0.thickenedCells) / \($0.cappedCells)" } ?? "—") | \(law) | "
                    + "\(m1.map { said($0) + rise } ?? (why.isEmpty ? "—" : why)) | "
                    + "\(rounds.isEmpty ? "—" : kept == 0 ? "check 1" : "check 2") | "
                    + "\(String(format: "%+.1f %%", added * 100)) | \(Int(Date().timeIntervalSince(t0))) |"
                print("SA-CAL " + line)
                lines.append(line)
                write()
            }
        }
        write()
    }
}
#endif
