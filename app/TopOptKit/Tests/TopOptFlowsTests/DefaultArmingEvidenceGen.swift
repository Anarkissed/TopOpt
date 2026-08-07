import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// R4 EVIDENCE GENERATOR — the two armed defaults, end to end, in BOTH
/// directions (task 2026-08-06-arm-projection-and-void-check).
///
/// ★ WHY THIS EXISTS AND WHY IT PRINTS RATHER THAN ASSERTS. R4's bar is
/// "demonstrably usable, not merely compiling", and it is on this project's
/// books because four consecutive PRs shipped app-side defects behind green
/// checks. A test that asserts against a path the maintainer cannot reach is
/// not evidence. So this dumps the ACTUAL BYTES `RemoteRun.buildJobJSON()`
/// produces for each of the four settings combinations, and the shell script
/// `evidence/2026-08-06-arm-projection-and-void-check/r4_end_to_end.sh` then
/// feeds those very bytes to the real `topopt-cli` and reads the effect out of
/// the result.
///
/// The bars themselves are in `DefaultArmingTests`. This is the record of what
/// travels.
@MainActor
final class DefaultArmingEvidenceGen: XCTestCase {

    private func jobJSON(projectCADFaces: Bool,
                         requireVoid: Bool) throws -> String {
        var s = LatticeSettings(enabled: true)
        s.densityMode = .uniform
        s.requireVoidReachesExterior = requireVoid
        let spec = try XCTUnwrap(s.runSpec(lineWidthMM: 0.45),
                                 "uniform lattice settings must produce a spec")
        let cfg = RemoteRunnerConfig(host: "127.0.0.1", port: 8757,
                                     expectedFingerprint: "test")
        let req = RunRequest(modelPath: "/tmp/l-bracket.step", material: "PLA",
                             materialsPath: "", rulesPath: "", resolution: 48,
                             projectName: "r4-arming", anchorFaceIDs: [3],
                             loadGroups: [TopOptKit.LoadGroupSpec(
                                faceIDs: [11], force: SIMD3(0, 0, -250))],
                             minimizePlastic: true, buildDirection: SIMD3(0, 0, 1),
                             infillPercent: 40, wallLoops: 3,
                             wallLineWidthOuterMM: 0.45,
                             wallLineWidthInnerMM: 0.45,
                             lattice: spec,
                             projectCADFaces: projectCADFaces)
        let run = RemoteRun(config: cfg, request: req,
                            progress: { _, _, _ in true }, onVariant: { _ in })
        let d = try run.buildJobJSON()
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: d) as? [String: Any])
        // Print only the two blocks that carry the keys — the rest of the job is
        // this app's ordinary load case and is covered elsewhere.
        let slim: [String: Any] = ["output": o["output"] ?? [:],
                                   "lattice": o["lattice"] ?? [:]]
        return String(data: try JSONSerialization.data(
            withJSONObject: slim, options: [.sortedKeys, .prettyPrinted]),
                      encoding: .utf8)!
    }

    func testWriteDefaultArmingReachabilityEvidence() throws {
        print("R4 === WHAT THE APP SENDS, from the REAL serializer ===")
        // ★ The four combinations are also WRITTEN TO DISK, so the shell half of
        // R4 can feed the app's OWN BYTES to the real topopt-cli rather than
        // re-authoring them. `TOPOPT_R4_OUT` is set by that script; without it
        // this generator just prints, so an ordinary `swift test` writes nothing.
        let outDir = ProcessInfo.processInfo.environment["TOPOPT_R4_OUT"]
        for (tag, cad, void) in [("both_on", true, true),
                                 ("cad_off", false, true),
                                 ("void_off", true, false),
                                 ("both_off", false, false)] {
            let s = try jobJSON(projectCADFaces: cad, requireVoid: void)
            print("R4 --- \(tag): project_cad_faces=\(cad) "
                  + "require_lattice_void_reaches_exterior=\(void) ---")
            print(s)
            if let d = outDir {
                try s.write(toFile: "\(d)/app_blocks_\(tag).json",
                            atomically: true, encoding: .utf8)
            }
        }

        // The RE-LATTICE path rebuilds the lattice block from scratch, so it is
        // dumped separately rather than assumed to match.
        var s = LatticeSettings(enabled: true)
        s.densityMode = .uniform
        for on in [true, false] {
            s.requireVoidReachesExterior = on
            let spec = try XCTUnwrap(s.runSpec(lineWidthMM: 0.45))
            let original = try JSONSerialization.data(
                withJSONObject: ["mode": "minimize_plastic", "model": "p.step",
                                 "material": "PLA", "resolution": 48,
                                 "output": ["report": "report.json",
                                            "mesh_format": "stl",
                                            "mesh_prefix": "variant",
                                            "project_cad_faces": true]],
                options: [.sortedKeys])
            let d = try RelatticeJobBuilder.build(
                original: original, designFingerprint: 0xDEAD_BEEF,
                achievedVolumeFraction: 0.42, designFileName: "design.bin",
                lattice: spec)
            let o = try XCTUnwrap(JSONSerialization.jsonObject(with: d) as? [String: Any])
            let lat = o["lattice"] as? [String: Any] ?? [:]
            print("R4 --- RE-LATTICE job, void rule \(on ? "ARMED" : "OFF") ---")
            print("R4 lattice.require_lattice_void_reaches_exterior = "
                  + String(describing: lat["require_lattice_void_reaches_exterior"]))
            print("R4 output block travels through unchanged: "
                  + String(describing: (o["output"] as? [String: Any])?["project_cad_faces"]))
        }
    }
}
