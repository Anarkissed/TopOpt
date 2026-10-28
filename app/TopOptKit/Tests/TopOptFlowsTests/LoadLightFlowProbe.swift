import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

/// Opt-in proof on HIS run (LIGHT_PROBE_JOB=<a worker job dir outside the repo>, LIGHT_PROBE_OUT=<scratch file>): the light
/// flow on his variant, from his load faces. Writes x y z arrival strength per STL vertex for a render. Never copies inputs.
final class LoadLightFlowProbe: XCTestCase {
    @MainActor
    func testLightFlowOnHisRun() throws {
        let env = ProcessInfo.processInfo.environment
        guard let job = env["LIGHT_PROBE_JOB"], let out = env["LIGHT_PROBE_OUT"] else { throw XCTSkip("LIGHT_PROBE_JOB not set") }
        let fields = try XCTUnwrap(RemoteFieldsContainer.parse(try Data(contentsOf: URL(fileURLWithPath: job + "/out/fields.bin"))))
        let v = try XCTUnwrap(fields.variants.first)
        let field = StressField(nx: fields.gridNx, ny: fields.gridNy, nz: fields.gridNz, origin: SIMD3<Float>(fields.gridOrigin),
                                spacing: Float(fields.spacing), values: v.vonMises)
        // the variant's STL (binary): every triangle corner is a flat vertex
        let stl = try Data(contentsOf: URL(fileURLWithPath: job + "/out/" + (env["LIGHT_PROBE_STL"] ?? "variant_002.stl")))
        let tris = Int(stl.subdata(in: 80..<84).withUnsafeBytes { $0.load(as: UInt32.self) })
        var pos: [Float] = []; pos.reserveCapacity(tris * 9)
        stl.withUnsafeBytes { b in
            for t in 0..<tris { for c in 0..<3 { for a in 0..<3 {
                pos.append(b.loadUnaligned(fromByteOffset: 84 + t * 50 + 12 + c * 12 + a * 4, as: Float.self))
            } } }
        }
        // his load faces' centroids, from his model
        let jobJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: job + "/job.json"))) as! [String: Any]
        let groups = (jobJSON["loads"] as! [String: Any])["groups"] as! [[String: Any]]
        let p = try FlexiblePressFixtures.project(path: job + "/model.step", name: "probe")
        let mesh = try XCTUnwrap(p.viewerMesh)
        // the app's seeding: triangle centres ON each load face (never a group's centroid)
        let loadFaces = Set(groups.flatMap { ($0["face_ids"] as! [NSNumber]).map { FaceID($0.int32Value) } })
        var seeds: [SIMD3<Float>] = [], seen: [FaceID: Int] = [:]
        for (t, f) in mesh.faceIDs.enumerated() where loadFaces.contains(f) {
            let n = seen[f, default: 0]; seen[f] = n + 1
            guard n % 4 == 0, n < 128 else { continue }
            let q = (0..<3).map { c -> SIMD3<Float> in let b = Int(mesh.indices[t * 3 + c]) * 3
                return SIMD3(mesh.positions[b], mesh.positions[b + 1], mesh.positions[b + 2]) }
            seeds.append((q[0] + q[1] + q[2]) / 3)
        }
        let t0 = Date()
        let lf = try XCTUnwrap(LoadLightFlow.build(positions: pos, field: field, seeds: seeds))
        let reached = lf.arrival.filter { $0 >= 0 }.count
        print("LIGHT-PROBE grid \(field.nx)x\(field.ny)x\(field.nz) printed \(field.values.filter { $0 > 0 }.count) · verts \(lf.arrival.count) reached \(reached) · seeds \(seeds.count) · build \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
        var s = ""
        for i in stride(from: 0, to: lf.arrival.count, by: 3) {
            s += "\(pos[3*i]) \(pos[3*i+1]) \(pos[3*i+2]) \(lf.arrival[i]) \(lf.strength[i])\n"
        }
        try s.write(toFile: out, atomically: true, encoding: .utf8)
        var seedsTxt = ""; for q in seeds { seedsTxt += "\(q.x) \(q.y) \(q.z)\n" }
        try seedsTxt.write(toFile: out + ".seeds", atomically: true, encoding: .utf8)
        let t1 = Date(); _ = lf.tints(phase: 0.5)
        print("LIGHT-PROBE one frame of tints: \(String(format: "%.1f", Date().timeIntervalSince(t1) * 1000)) ms")
    }
}
