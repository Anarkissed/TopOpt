// FlexibleStageModel+Meet — the stage model's side of "which faces meet" (task 2026-10-07, angled presses, batch
// AP2; final spec §5 "Model caches, loaded once per scene open: coreAdjacency and regionFrames (on demand)").
//
// ★ WHAT IS CACHED, AND FOR HOW LONG.
//   * `meet` — FlexibleMeet over the viewer mesh and the declared regions: rebuilt when the mesh or his sectors
//     change (the mesh signature + FlexibleRegions.key), never per frame;
//   * core's answers — face_adjacency, each region's frame (asked on demand, per region / face / direction) and the
//     seam triangles' normals — kept for the OPEN SCENE (its key, `openedKey`): a new scene (a re-split, another
//     resolution, another gravity) asks again.
// ★ ONE SOURCE: CORE. Every frame, normal and adjacency here is read through the bridge (FlexibleKit+Meet) from the
// scene the page opened; the model only decides when to ask and keeps the answers.

// ★★ AP2 TESTS-FIRST STUBS: `regionFrame` is the spec's red variant (the viewer's Float face normal, no sector, no
// spread) and `meetFacts` reads no seam normal; the next commit asks core for both.

import Foundation
import simd
import TopOptKit

/// AP2's caches on the stage model (its one stored property `meetCache`).
final class FlexibleMeetCache {
    var geometryKey: String?
    var geometry: FlexibleMeet?
    var sceneKey: String?
    var adjacency: [[Int]]?
    var frames: [String: FlexRegionFrame] = [:]
    var factsKey: String?
    var facts: FlexibleMeetFacts?

    /// Forget core's answers when the scene they came from is not the open one.
    func follow(scene key: String) {
        guard sceneKey != key else { return }
        sceneKey = key
        adjacency = nil
        frames = [:]
        facts = nil
        factsKey = nil
    }
}

extension FlexibleStageModel {

    /// ★ Which faces meet on the part the page draws (geometry only; core's facts are `meetFacts()`). nil before
    /// the part is imported.
    public var meet: FlexibleMeet? {
        guard let mesh = project.viewerMesh else { return nil }
        let regions = self.regions
        let key = "\(mesh.signature.contentHash)|\(mesh.signature.topologyHash)|\(mesh.faceIDs.count)|\(regions.key)"
        if meetCache.geometryKey == key, let g = meetCache.geometry { return g }
        let g = FlexibleMeet(mesh: mesh, regions: regions)
        meetCache.geometryKey = key
        meetCache.geometry = g
        return g
    }

    /// The open scene's key, or the refusal a caller shows while it opens.
    private func openSceneKey() throws -> String {
        guard sceneState == .ready, let k = openedKey else { throw TopOptError(message: "The part is still opening.") }
        meetCache.follow(scene: k)
        return k
    }

    /// ★ Core's face_adjacency for the open scene (asked once per scene).
    public func coreAdjacency() async throws -> [[Int]] {
        let key = try openSceneKey()
        if let a = meetCache.adjacency { return a }
        let a = try await frameWorker.withScene { try $0.faceAdjacency() }
        if meetCache.sceneKey == key { meetCache.adjacency = a }
        return a
    }

    /// ★ Core's frame of declared region `region` (or of its member face `face`), along `direction` when given —
    /// face_frame_cut through the open scene; asked once per (region, face, direction bits) per scene.
    public func regionFrame(_ region: Int, face: Int? = nil, direction: SIMD3<Double>? = nil) async throws -> FlexRegionFrame {
        // ★ AP2 RED STUB: the viewer's Float normal (ViewerMesh.faceNormal), whole faces only
        _ = try openSceneKey()
        _ = (face, direction)
        guard !FlexibleRegions.isSector(region), let n = project.viewerMesh?.faceNormal(Int32(region)) else {
            return FlexRegionFrame(valid: false, reason: "no viewer normal", load: SIMD3(0, 0, -1), centroid: .zero, areaMM2: 0,
                                   buildAngleDeg: 0, side: false, normalSpreadDeg: 0, normalSpreadFlag: false, triangles: 0)
        }
        let load = -SIMD3<Double>(Double(n.x), Double(n.y), Double(n.z))
        return FlexRegionFrame(valid: true, reason: "", load: load, centroid: .zero, areaMM2: 0, buildAngleDeg: 0, side: false,
                               normalSpreadDeg: 0, normalSpreadFlag: false, triangles: 0)
    }

    /// ★ Everything FlexibleEdgeCandidates needs from core, for the open scene and the current regions: core's
    /// adjacency, core's frame of every piece, and core's normal of every seam triangle — the last only once core's
    /// model is checked to be the viewer mesh, triangle for triangle (count and face of each), else `mismatch` says
    /// why and nothing is decided on it.
    public func meetFacts() async throws -> FlexibleMeetFacts {
        let key = try openSceneKey()
        guard let meet, let mesh = project.viewerMesh else { throw TopOptError(message: "The part has no mesh to read.") }
        let fkey = key + "|" + (meetCache.geometryKey ?? "")
        if meetCache.factsKey == fkey, let f = meetCache.facts { return f }
        let adjacency = try await coreAdjacency()
        var frames: [Int: FlexRegionFrame] = [:]
        for p in meet.pieces {
            if let f = try? await regionFrame(p.id) { frames[p.id] = f }
        }
        // ★ AP2 RED STUB: no seam normal is read from core
        _ = mesh
        let mismatch: String? = nil
        let byTri: [Int: SIMD3<Double>] = [:]
        let facts = FlexibleMeetFacts(adjacency: adjacency, frames: frames, triangleLoads: mismatch == nil ? byTri : [:], mismatch: mismatch)
        if meetCache.sceneKey == key {
            meetCache.facts = facts
            meetCache.factsKey = fkey
        }
        return facts
    }

    /// ★ Every edge and corner of the part, numbered (FlexibleEdgeCandidates), from core's facts for the open scene.
    public func edgeCandidates() async throws -> FlexibleEdgeCandidates {
        let facts = try await meetFacts()
        guard let meet else { throw TopOptError(message: "The part has no mesh to read.") }
        return FlexibleEdgeCandidates.make(meet: meet, facts: facts, name: { [weak self] r in self?.name(r) ?? "face \(r)" })
    }
}
