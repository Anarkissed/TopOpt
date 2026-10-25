import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★★ PROBE (2026-09-29, the face-prism route): HIS STAND'S VARIANT JOB, BEFORE AND AFTER.
///
/// Writes the documents the variant's Lattice page submits — the re-lattice run, its forecast
/// and (organic) the Check-sizes probe — built exactly as `relatticeJobJSON` builds them, from
/// a retained optimize document (`VARIANT_ORIGINAL`, the job that produced the design file),
/// plus the stage's own `lattice_part` document for the hash. It prints each document's
/// region census (walls carried, face ids, outlines, frames, flags) and asks core's parser.
/// Running them on the design file is left to `topopt-cli lattice-variant`, outside the test.
///
/// From ruling (b) on it builds the spec with the page's own builder
/// (`ProjectModel.latticeRunSpec`), which does not exist at aecef72c: the route's before arms
/// (VARIANT_ARM=before/before2, at aecef72c) were measured with the commit-1 copy of this file,
/// which rebuilt the pre-(b) recipe inline. Two settings: his project as saved, and with the
/// one stated substitution algorithm = organic (the flags act only on organic).
///
/// Env: HIS_PROJECT_DIR (a copy of his project folder), VARIANT_ORIGINAL (the optimize
/// document), VARIANT_FINGERPRINT / VARIANT_FRACTION (the design file's variant),
/// VARIANT_PROBE_OUT, VARIANT_ARM (before | before2 | after).
final class VariantWallsStandProbe: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        while u.path != "/" && !FileManager.default.fileExists(atPath: u.appendingPathComponent("core/src/materials/materials.json").path) {
            u = u.deletingLastPathComponent()
        }
        return u
    }()

    @MainActor
    func testTheStandsVariantDocuments() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dirPath = env["HIS_PROJECT_DIR"], let outRoot = env["VARIANT_PROBE_OUT"],
              let arm = env["VARIANT_ARM"], let originalPath = env["VARIANT_ORIGINAL"],
              let fpText = env["VARIANT_FINGERPRINT"], let fp = UInt64(fpText),
              let vfText = env["VARIANT_FRACTION"], let vf = Double(vfText)
        else { throw XCTSkip("HIS_PROJECT_DIR, VARIANT_ORIGINAL, VARIANT_FINGERPRINT, VARIANT_FRACTION, VARIANT_PROBE_OUT, VARIANT_ARM") }
        let original = try Data(contentsOf: URL(fileURLWithPath: originalPath))
        let core = Self.repoRoot.appendingPathComponent("core")
        let materials = core.appendingPathComponent("src/materials/materials.json").path
        let rules = core.appendingPathComponent("src/settings/rules.json").path
        func sorted(_ o: Any) throws -> Data { try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .prettyPrinted]) }

        for setting in ["saved", "organic"] {
            // a fresh copy per setting: opening a project may write to it
            let src = URL(fileURLWithPath: dirPath)
            let snap = try JSONDecoder().decode(ProjectSnapshot.self, from: Data(contentsOf: src.appendingPathComponent("project.json")))
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("variant-probe-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let pdir = root.appendingPathComponent(snap.id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: pdir, withIntermediateDirectories: true)
            for f in try FileManager.default.contentsOfDirectory(atPath: src.path) {
                try FileManager.default.copyItem(at: src.appendingPathComponent(f), to: pdir.appendingPathComponent(f))
            }
            let model = AppModel(materialsPath: materials, rulesPath: rules, store: ProjectStore(rootDir: root))
            model.loadMaterials()
            model.open(try XCTUnwrap(model.recentProjects.first { $0.id == snap.id }))
            let pm = try XCTUnwrap(model.project)
            if setting == "organic" { pm.lattice.algorithm = "organic" }
            let lat = pm.lattice
            let tag = "VARIANT \(arm) \(setting)"
            print("\(tag) algorithm \(lat.algorithm) stage \(String(describing: lat.stageMode)) sim \(lat.simulateStresses) synth \(lat.organicSyntheticStresses) active \(lat.organicSyntheticStressesActive)")

            let outDir = URL(fileURLWithPath: outRoot).appendingPathComponent("\(arm)/\(setting)", isDirectory: true)
            try? FileManager.default.removeItem(at: outDir)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

            // ── the stage's own document (the hash the route must not move)
            let stage = pm.latticeJobRegions()
            for r in stage.regions {
                print(String(format: "%@ stage region %@ %@ face %@ key %@ depth %.2f synthetic %@ foci %@", tag,
                             r.role.rawValue, r.kind.rawValue, r.faceID.map(String.init) ?? "-", r.selectableKey ?? "-",
                             r.depthMM, r.syntheticStress ? "yes" : "no", r.syntheticFoci.map(String.init) ?? "-"))
            }
            let request = try XCTUnwrap(model.makeLatticeRunRequest(), "the stage job")
            let stageJSON = try RemoteRun.buildJobJSON(request)
            let stageDoc = try XCTUnwrap(JSONSerialization.jsonObject(with: stageJSON) as? [String: Any])
            try sorted(stageDoc).write(to: outDir.appendingPathComponent("stage.json"))
            let recommend = RelatticeRun.Recommend(mode: "auto", lookCellsAcross: lat.organicLookCellsAcross,
                                                   margin: LatticeSettings.organicRecommendMargin,
                                                   steps: LatticeSettings.organicRecommendSteps)
            if lat.algorithm == "organic" {
                // the stage's own Check sizes, for the dead set the variant's is compared with
                let stageProbe = try RelatticeRun.probeJob(stageJSON, cellsMM: LatticeSettings.organicProbeCellsMM,
                                                           gradesMM: LatticeSettings.organicProbeGradesMM,
                                                           recommend: recommend)
                try sorted(try JSONSerialization.jsonObject(with: stageProbe)).write(to: outDir.appendingPathComponent("stage_probe.json"))
            }

            // ── the variant's documents, as `relatticeJobJSON` builds them
            let variant = pm.variantLatticeJobRegions()
            // what the forecast drawer now pays per page pass (a DEBUG build: indicative only)
            var ms: [Double] = []
            for _ in 0..<7 {
                let t0 = DispatchTime.now().uptimeNanoseconds
                _ = pm.variantLatticeJobRegions()
                ms.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            }
            ms.sort()
            print(String(format: "%@ variant emission time (debug) min %.2f median %.2f max %.2f ms", tag, ms[0], ms[3], ms[6]))
            let names: [String]? = variant.skippedRegionNames
            print("\(tag) variant emission: \(variant.regions.count) region(s), "
                  + "\(variant.regions.filter { $0.kind == .face }.count) face prism(s), "
                  + "include \(variant.regions.filter { $0.role == .include }.count), "
                  + "skippedFaces \(variant.skippedFaces), skippedRegionNames \(names.map { "\($0)" } ?? "n/a")")
            // ★ ruling (b): the page's own builder (`relatticeJobJSON` calls it)
            let spec = pm.latticeRunSpec(emission: variant)
            let run = try RelatticeJobBuilder.build(original: original, designFingerprint: fp, achievedVolumeFraction: vf,
                                                    designFileName: "design.bin", lattice: spec)
            let forecast = try RelatticeJobBuilder.build(original: original, designFingerprint: fp, achievedVolumeFraction: vf,
                                                         designFileName: "design.bin", lattice: spec, forecastOnly: true)
            var docs: [(String, Data)] = [("variant_run", run), ("variant_forecast", forecast)]
            if lat.algorithm == "organic" {
                docs.append(("variant_probe", try RelatticeRun.probeJob(run, cellsMM: LatticeSettings.organicProbeCellsMM,
                                                                        gradesMM: LatticeSettings.organicProbeGradesMM,
                                                                        recommend: recommend)))
            }
            for (name, doc) in docs {
                let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: doc) as? [String: Any])
                try sorted(obj).write(to: outDir.appendingPathComponent("\(name).json"))
                let regions = ((obj["lattice"] as? [String: Any])?["regions"] as? [[String: Any]]) ?? []
                let faces = regions.filter { $0["kind"] as? String == "face" }
                let geo = faces.compactMap { $0["geometry"] as? [String: Any] }
                print("\(tag) \(name): \(regions.count) region(s) — "
                      + "include \(regions.filter { $0["role"] as? String == "include" }.count), "
                      + "exclude \(regions.filter { $0["role"] as? String == "exclude" }.count), "
                      + "face \(faces.count), bolt \(regions.filter { $0["kind"] as? String == "bolt" }.count); "
                      + "face_id \(regions.filter { $0["face_id"] != nil }.count), "
                      + "outline_uv \(geo.filter { $0["outline_uv"] != nil }.count), "
                      + "frame \(geo.filter { $0["frame_u"] != nil && $0["frame_w"] != nil }.count), "
                      + "synthetic \(regions.filter { $0["synthetic_stress"] as? Bool == true }.count) "
                      + "foci \(regions.compactMap { $0["synthetic_foci"] as? Int }); "
                      + "stepped_cells \(((obj["lattice"] as? [String: Any])?["stepped_cells"] as? [Any])?.count ?? 0); "
                      + "core's parser: \(TopOptKit.jobSchemaError(doc) ?? "accepts")")
            }
        }
        try Data("done\n".utf8).write(to: URL(fileURLWithPath: outRoot).appendingPathComponent("\(arm)/DONE"))   // LAST
    }
}
