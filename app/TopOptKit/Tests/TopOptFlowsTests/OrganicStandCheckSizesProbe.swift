import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★★ PROBE (2026-09-29, ruling 1): HIS STAND'S CHECK-SIZES RESULT, BEFORE AND AFTER THE
/// SYNTHETIC-STRESS FLAGS — "so we see what moved on the dead walls".
///
/// ★ WHAT THIS CAN AND CANNOT MEASURE. The app's own Check sizes runs on a VARIANT's
/// re-lattice job, and that job emits placed primitives only (faces are never carried to a
/// variant, `variantRegions`): his stand's walls are faces 15 and 2 and face region 101, so
/// its re-lattice job carries NO wall and is byte-identical before and after (printed
/// below). What CAN be measured is core's own size probe on his walls: the probe runs inside
/// `lattice_one_variant` for the whole-part job too, so this runs the stage's `lattice_part`
/// document with the wizard's Check-sizes keys, once with every include wall flagged (AFTER,
/// what the job carries now) and once with the flags stripped (BEFORE) — the only
/// difference, asserted. A proxy for the app's button, labelled as one.
///
/// Env: HIS_PROJECT_DIR (a copy of his project folder), STAND_PROBE_OUT, STAND_ARM
/// (before | after | before2 — the repeat is the noise floor). One arm per process.
final class OrganicStandCheckSizesProbe: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        while u.path != "/" && !FileManager.default.fileExists(atPath: u.appendingPathComponent("core/src/materials/materials.json").path) {
            u = u.deletingLastPathComponent()
        }
        return u
    }()

    @MainActor
    func testTheStandsCheckSizesArm() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dirPath = env["HIS_PROJECT_DIR"], let outRoot = env["STAND_PROBE_OUT"],
              let arm = env["STAND_ARM"] else { throw XCTSkip("HIS_PROJECT_DIR, STAND_PROBE_OUT, STAND_ARM") }
        let src = URL(fileURLWithPath: dirPath)
        let snap = try JSONDecoder().decode(ProjectSnapshot.self, from: Data(contentsOf: src.appendingPathComponent("project.json")))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stand-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdir = root.appendingPathComponent(snap.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: pdir, withIntermediateDirectories: true)
        for f in try FileManager.default.contentsOfDirectory(atPath: src.path) {
            try FileManager.default.copyItem(at: src.appendingPathComponent(f), to: pdir.appendingPathComponent(f))
        }
        let core = Self.repoRoot.appendingPathComponent("core")
        let materials = core.appendingPathComponent("src/materials/materials.json").path
        let rules = core.appendingPathComponent("src/settings/rules.json").path
        let model = AppModel(materialsPath: materials, rulesPath: rules, store: ProjectStore(rootDir: root))
        model.loadMaterials()
        model.open(try XCTUnwrap(model.recentProjects.first { $0.id == snap.id }))
        let pm = try XCTUnwrap(model.project)

        // ── his settings, with ONE stated substitution: the lattice is organic
        print("STAND saved algorithm \(pm.lattice.algorithm) → organic (the one substitution)")
        pm.lattice.algorithm = "organic"
        let lat = pm.lattice
        print("STAND stage \(String(describing: lat.stageMode)) sim \(lat.simulateStresses) synth \(lat.organicSyntheticStresses) active \(lat.organicSyntheticStressesActive) foci default \(lat.organicSyntheticFoci) stated \(lat.selectableSyntheticFoci) look \(lat.organicLookCellsAcross)")

        // ── the app's own Check-sizes job: the variant's regions
        let variant = pm.variantLatticeJobRegions()
        print("STAND re-lattice (variant) job: \(variant.regions.count) region(s), \(variant.skippedFaces) face selection(s) not carried")

        // ── the stage job, AFTER (flags as the job carries them now) and BEFORE (stripped)
        for r in pm.latticeJobRegions().regions where r.role == .include {
            print(String(format: "STAND include face %@ key %@ depth %.2f synthetic %@ foci %@",
                         r.faceID.map(String.init) ?? "-", r.selectableKey ?? "-", r.depthMM,
                         r.syntheticStress ? "yes" : "no", r.syntheticFoci.map(String.init) ?? "-"))
        }
        let request = try XCTUnwrap(model.makeLatticeRunRequest(), "the stage job")
        var after = try XCTUnwrap(JSONSerialization.jsonObject(with: try RemoteRun.buildJobJSON(request)) as? [String: Any])
        var latBlock = try XCTUnwrap(after["lattice"] as? [String: Any])
        let regions = try XCTUnwrap(latBlock["regions"] as? [[String: Any]])
        let includes = regions.filter { $0["role"] as? String == "include" }
        XCTAssertFalse(includes.isEmpty)
        XCTAssertTrue(includes.allSatisfy { $0["synthetic_stress"] as? Bool == true },
                      "★ positive control: AFTER must carry the flags, or it measures nothing")
        var before = after
        var stripped = latBlock
        stripped["regions"] = regions.map { r -> [String: Any] in
            var r = r; r.removeValue(forKey: "synthetic_stress"); r.removeValue(forKey: "synthetic_foci"); return r
        }
        before["lattice"] = stripped
        func sorted(_ o: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) }
        // the only difference is the flags
        var afterStripped = after; afterStripped["lattice"] = stripped
        XCTAssertEqual(try sorted(afterStripped), try sorted(before))
        latBlock["regions"] = regions; after["lattice"] = latBlock

        // ── the wizard's Check-sizes keys (LatticeSetupWizard: the probe's cells and grades)
        let recommend = RelatticeRun.Recommend(mode: "auto", lookCellsAcross: lat.organicLookCellsAcross,
                                               margin: LatticeSettings.organicRecommendMargin,
                                               steps: LatticeSettings.organicRecommendSteps)
        let chosen = arm.hasPrefix("after") ? after : before
        var job = try RelatticeRun.probeJob(try sorted(chosen), cellsMM: LatticeSettings.organicProbeCellsMM,
                                            gradesMM: LatticeSettings.organicProbeGradesMM, recommend: recommend)
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: job) as? [String: Any])
        obj["model"] = "model.step"
        job = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .prettyPrinted])

        let armDir = URL(fileURLWithPath: outRoot).appendingPathComponent(arm, isDirectory: true)
        try? FileManager.default.removeItem(at: armDir)
        try FileManager.default.createDirectory(at: armDir.appendingPathComponent("out"), withIntermediateDirectories: true)
        try job.write(to: armDir.appendingPathComponent("job.json"))
        try FileManager.default.copyItem(at: src.appendingPathComponent("model.step"), to: armDir.appendingPathComponent("model.step"))
        FileHandle.standardError.write(Data("===== ARM \(arm) =====\n".utf8))
        _ = try TopOptKit.runLatticeJob(jobPath: armDir.appendingPathComponent("job.json").path, jobDir: armDir.path,
                                        outDir: armDir.appendingPathComponent("out").path,
                                        materialsPath: materials, rulesPath: rules)
        let probe = try XCTUnwrap(OrganicForecast.parse(try Data(contentsOf: armDir.appendingPathComponent("out/organic_probe.json"))),
                                  "the probe's file parses")
        for c in probe.candidates {
            print(String(format: "STAND %@ cand %.2f–%.2f curves %d comps %d traced %.0f rooted %.3f voxels %d aes %@ predicted %@",
                         arm, c.cellMinMM, c.cellMaxMM, c.curves, c.components, c.tracedLengthMM, c.rootedLengthFraction,
                         c.candidateVoxels, c.approvedAesthetic ? "yes" : "no",
                         c.predicted.map { $0.ran ? "ran" : "not run: \($0.reason)" } ?? "none"))
        }
        try Data("done\n".utf8).write(to: armDir.appendingPathComponent("DONE"))   // the completion marker, LAST
    }
}
