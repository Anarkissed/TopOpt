import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

/// ★ EXACT PROTECT — THE PROOF's job (ruling 2026-10-26 23:44, step 3). Opt-in: EXACT_PROTECT_JOB=<a worker job dir> (his
/// latest Carriage Arms run). Reads his job.json and model.step, builds the keep regions the app would send for HIS protected
/// faces (ProtectKeepRegions, at his Protect depth), and writes `job_exact.json` beside a copy: his job, plus keep_regions,
/// at a coarse resolution (EXACT_PROTECT_RES, default 40) and with one conservative variant (no strengthen loop) so the one
/// CLI run is minutes, not his two hours. Never runs the CLI itself.
final class ExactProtectProofProbe: XCTestCase {
    @MainActor
    func testWriteTheProofJob() throws {
        guard let dir = ProcessInfo.processInfo.environment["EXACT_PROTECT_JOB"] else { throw XCTSkip("EXACT_PROTECT_JOB not set") }
        let out = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["EXACT_PROTECT_OUT"]))
        let res = Int(ProcessInfo.processInfo.environment["EXACT_PROTECT_RES"] ?? "40") ?? 40
        ProtectKeepRegions.orientedAvailable = true   // the release core (TO-core af6d19d9) takes the oriented form
        defer { ProtectKeepRegions.orientedAvailable = false }
        let src = URL(fileURLWithPath: dir)
        var job = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: src.appendingPathComponent("job.json"))) as? [String: Any])
        let p = try FlexiblePressFixtures.project(path: src.appendingPathComponent("model.step").path, name: "Carriage Arms")
        let mesh = try XCTUnwrap(p.viewerMesh)
        var loads = try XCTUnwrap(job["loads"] as? [String: Any])
        let depth = loads["face_protection_depth_mm"] as? Double ?? 3
        let prot = (loads["face_protections"] as? [Any] ?? []).compactMap { e -> ProtectKeepRegions.Face? in
            if let i = e as? Int { return .init(id: Int32(i), depthMM: depth) }
            if let o = e as? [String: Any], let i = o["face_id"] as? Int { return .init(id: Int32(i), depthMM: o["depth_mm"] as? Double ?? depth) }
            return nil
        }
        let e = mesh.bounds.max - mesh.bounds.min
        let voxel = Double(max(e.x, e.y, e.z)) / Double(res)
        let regions = ProtectKeepRegions.regions(prot, in: mesh, outwardMM: max(1, 1.5 * voxel))
        XCTAssertFalse(regions.isEmpty, "his protected faces give keep regions")
        // which of his faces became what (for the measurement script)
        var faces: [[String: Any]] = []
        for f in prot {
            guard let g = mesh.faceGeometry(f.id) else { continue }
            let r = ProtectKeepRegions.regions([f], in: mesh, outwardMM: max(1, 1.5 * voxel))
            faces.append(["face": Int(f.id), "kind": g.isCylinder ? "cylinder" : g.isPlane ? "plane" : "other",
                          "radius_mm": g.cylinderRadiusMM, "axis_point": [g.axisPoint.x, g.axisPoint.y, g.axisPoint.z],
                          "axis_dir": [g.axisDir.x, g.axisDir.y, g.axisDir.z],
                          "plane_normal": [g.planeNormal.x, g.planeNormal.y, g.planeNormal.z],
                          "plane_origin": [g.planeOrigin.x, g.planeOrigin.y, g.planeOrigin.z],
                          "bore": FaceTopology.isFastenerBore(f.id, in: mesh), "regions": r.map(\.json)])
        }
        job["keep_regions"] = regions.map(\.json)
        job["resolution"] = res
        // one conservative variant (minutes) — unless the proof IS the growth case (ruling 06:13: re-run on a strengthen job)
        if ProcessInfo.processInfo.environment["EXACT_PROTECT_KEEP_REDESIGN"] != "1" { loads.removeValue(forKey: "redesign") }
        job["loads"] = loads
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: src.appendingPathComponent("model.step"), to: out.appendingPathComponent("model.step"))
        try JSONSerialization.data(withJSONObject: job, options: [.prettyPrinted, .sortedKeys])
            .write(to: out.appendingPathComponent("job_exact.json"))
        try JSONSerialization.data(withJSONObject: ["voxel_mm": voxel, "depth_mm": depth, "faces": faces], options: [.prettyPrinted, .sortedKeys])
            .write(to: out.appendingPathComponent("faces.json"))
        print("EXACT-PROTECT proof job: \(regions.count) keep regions from \(prot.count) protected faces → \(out.path)")
    }
}
