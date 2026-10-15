// FlexibleM2Fixtures — what round 7 batch M2's tests share (Flexible-only sectors: lattice sections under a face-prism,
// I2's strips off the Surface stage). His pad is A1_0003; HIS LIVE LATTICE (FlexibleR7M1Fixtures.hisLiveLattice: Group C =
// Face 3 + Face 5, Lattice at 25 mm) cuts the Top and Faces 0, 2 and 4 into 25 mm lattice bands.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
enum FlexibleM2Fixtures {
    typealias F1 = FlexibleR7M1Fixtures

    /// His pad on the main stage (the shared model), opened and settled; `live`: with his live lattice.
    static func pad(_ t: XCTestCase, live: Bool = true) async throws -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel) {
        try await F1.hisPad(t, live: live)
    }

    /// The pad's box (model mm).
    static func box(_ p: ProjectModel) -> (lo: SIMD3<Double>, hi: SIMD3<Double>) {
        let b = p.viewerMesh!.bounds
        return (SIMD3<Double>(b.min), SIMD3<Double>(b.max))
    }

    /// A point on the Top (z = the top), `x` mm from the box's −x side, in the middle of y.
    static func onTop(_ p: ProjectModel, x: Double) -> SIMD3<Double> {
        let b = box(p)
        return SIMD3(b.lo.x + x, (b.lo.y + b.hi.y) / 2, b.hi.z)
    }

    /// The area (mm²) of region `r` on face `face` (its cuts over the face's triangles).
    static func area(_ m: FlexibleStageModel, _ r: Int, face: Int) -> Double {
        FlexibleEdgeStrips.area(FlexibleEdgeStrips.triangles(face: face, mesh: m.project.viewerMesh!), m.regions.cuts(of: r))
    }

    /// The Flexible pieces on face `face`.
    static func pieces(_ m: FlexibleStageModel, face: Int) -> [FlexibleSector] {
        (m.regions.flexible?.pieces ?? []).filter { m.regions.faces(of: $0.wireID, mesh: m.project.viewerMesh) == [face] }
    }

    /// The scene open again on what the project says now, every loaded stack built, designs landed.
    static func reopen(_ m: FlexibleStageModel, _ what: String) async throws {
        await m.waitForIdle()
        if m.openedKey != m.currentSceneKey { m.openScene() }
        try await FlexibleHisProject.waitFor(240, "\(what): the part open again") {
            m.sceneState == .ready && m.openedKey == m.currentSceneKey
        }
        try await FlexibleAngledGoldens.settleAllowingRefusedStacks(m, what)
    }

    /// [+ New] → [Edges/corners], the list read and core's verdicts asked.
    @discardableResult
    static func pickMode(_ m: FlexibleStageModel) async throws -> FlexibleEdgePick {
        m.rail = .newGroup
        m.startEdgePick()
        try await FlexibleHisProject.waitFor(240, "the edges and corners listed") {
            m.edgePick.map { !$0.loading && !$0.checking } ?? false
        }
        await m.waitForIdle()
        return try XCTUnwrap(m.edgePick, "pick mode")
    }

    /// [Done] at `kg`, then the part open again.
    static func done(_ m: FlexibleStageModel, kg: Double = 5) async throws -> String? {
        m.setEdgePickWeight(kg)
        let why = await m.finishEdgePick()
        try await FlexibleHisProject.waitFor(240, "the part open again") { m.sceneState == .ready && m.openedKey == m.currentSceneKey }
        await m.waitForIdle()
        return why
    }

    /// The edge candidate whose member pieces lie on exactly `faces`.
    static func edge(_ m: FlexibleStageModel, _ p: FlexibleEdgePick, faces: Set<Int>) -> FlexibleEdgeCandidates.Candidate? {
        let mesh = m.project.viewerMesh
        return p.candidates.first { c in
            c.kind == .edge && Set(c.members.flatMap { m.regions.faces(of: $0, mesh: mesh) }) == faces
                && c.members.count == faces.count
        }
    }

    /// The Topology request's job and the lattice stage's (RemoteRun's bytes), and the Stress solve's regions.
    static func otherStages(_ app: AppModel) throws -> (topology: Data, stage: Data, stress: String) {
        // (sorted keys: RemoteRun writes a dictionary, whose order is not its bytes — the stage-hash goldens do the same)
        func sorted(_ d: Data) throws -> Data {
            try JSONSerialization.data(withJSONObject: try JSONSerialization.jsonObject(with: d), options: [.sortedKeys])
        }
        let topo = try sorted(try RemoteRun.buildJobJSON(try XCTUnwrap(app.makeRunRequest(), "the Topology request")))
        let stage = try sorted(try RemoteRun.buildJobJSON(try XCTUnwrap(app.makeLatticeRunRequest(), "the lattice stage's request")))
        let sim = try XCTUnwrap(app.makeLatticeSimContext(), "the Stress solve's context")
        return (topo, stage, "\(sim.faceRegions)")
    }

    /// How many `face_regions` entries a job declares (anywhere in the document).
    static func faceRegionCount(_ job: Data) throws -> Int {
        func walk(_ o: Any) -> Int? {
            if let d = o as? [String: Any] {
                if let a = d["face_regions"] as? [Any] { return a.count }
                for v in d.values { if let n = walk(v) { return n } }
            } else if let a = o as? [Any] {
                for v in a { if let n = walk(v) { return n } }
            }
            return nil
        }
        return walk(try JSONSerialization.jsonObject(with: job)) ?? 0
    }

    /// The include specs the Flexible stage reads (Selections' Lattice face-prisms).
    static func includes(_ p: ProjectModel) -> [LatticeRegionSpec] {
        p.latticeJobRegions().regions.filter { $0.role == .include }
    }

    /// Each send's face entries by face_region_id (sorted-key JSON), and its declared face_regions by id.
    static func sendEntries(_ m: FlexibleStageModel) throws -> [String: (faces: [Int: String], declared: [Int: String])] {
        var out: [String: (faces: [Int: String], declared: [Int: String])] = [:]
        for send in FlexibleAngledGoldens.sends(m) {
            let job = try m.runJobJSON(resting: Set(send.resting))
            let doc = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(job.utf8)) as? [String: Any])
            let loads = doc["loads"] as? [String: Any]
            let flex = try XCTUnwrap(loads?["flexible"] as? [String: Any] ?? doc["flexible"] as? [String: Any], "the flexible block")
            var faces: [Int: String] = [:], declared: [Int: String] = [:]
            for f in try XCTUnwrap(flex["faces"] as? [[String: Any]]) {
                let id = try XCTUnwrap(f["face_region_id"] as? Int)
                faces[id] = String(decoding: try JSONSerialization.data(withJSONObject: f, options: [.sortedKeys]), as: UTF8.self)
            }
            for r in (loads?["face_regions"] as? [[String: Any]]) ?? [] {
                guard let id = r["id"] as? Int else { continue }
                declared[id] = String(decoding: try JSONSerialization.data(withJSONObject: r, options: [.sortedKeys]), as: UTF8.self)
            }
            out[send.title] = (faces, declared)
        }
        return out
    }

    /// Is `p` inside every cut (closed, within `tol`)?
    static func inside(_ p: SIMD3<Double>, _ cuts: [RegionCut], tol: Double = 1e-6) -> Bool {
        cuts.allSatisfy { simd_dot(p - $0.point, simd_normalize($0.normal)) >= -tol }
    }
}
