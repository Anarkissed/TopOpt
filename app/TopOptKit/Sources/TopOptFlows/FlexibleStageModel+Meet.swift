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
    /// Core's press verdicts for the open scene, by footprint + direction bits (AP2 review, A4).
    var verdicts: [String: FlexPressVerdict] = [:]
    /// How many times FlexibleMeet was built, and whether the last build ran on the main thread (AP2 review:
    /// pick mode must never build it there).
    var builds = 0
    var lastBuildOnMainThread: Bool?

    /// Forget core's answers when the scene they came from is not the open one.
    func follow(scene key: String) {
        guard sceneKey != key else { return }
        sceneKey = key
        adjacency = nil
        frames = [:]
        facts = nil
        factsKey = nil
        verdicts = [:]
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
        meetCache.builds += 1
        meetCache.lastBuildOnMainThread = Thread.isMainThread
        meetCache.geometryKey = key
        meetCache.geometry = g
        return g
    }

    /// ★ Which faces meet, built OFF the main actor (AP2 review: a 41 k-triangle part takes a second).
    public func meetOffMain() async -> FlexibleMeet? {
        meet   // AP2 REVIEW RED STUB: built on the calling (main) actor
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
        let key = try openSceneKey()
        let k = "\(region)|\(face ?? -1)|" + (direction.map { "\($0.x.bitPattern),\($0.y.bitPattern),\($0.z.bitPattern)" } ?? "-")
        if let f = meetCache.frames[k] { return f }
        let f = try await frameWorker.withScene { try $0.regionFrame(region, face: face, direction: direction) }
        if meetCache.sceneKey == key { meetCache.frames[k] = f }
        return f
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
        let tris = FlexibleMeetFacts.seamTriangles(meet)
        let loads = try await frameWorker.withScene { try $0.triangleLoads(tris) }
        var mismatch: String? = nil
        var byTri: [Int: SIMD3<Double>] = [:]
        if loads.triangleCount != mesh.triangleCount {
            mismatch = "core's part has \(loads.triangleCount) triangles, the page draws \(mesh.triangleCount)"
        } else {
            for (k, t) in tris.enumerated() {
                guard t < mesh.faceIDs.count, loads.faces[k] == Int(mesh.faceIDs[t]) else {
                    mismatch = "triangle \(t) is on face \(loads.faces[k]) in core's part, face \(t < mesh.faceIDs.count ? Int(mesh.faceIDs[t]) : -1) on the page"
                    break
                }
                if let l = loads.loads[k] { byTri[t] = l }
            }
        }
        let facts = FlexibleMeetFacts(adjacency: adjacency, frames: frames, triangleLoads: mismatch == nil ? byTri : [:], mismatch: mismatch)
        if meetCache.sceneKey == key {
            meetCache.facts = facts
            meetCache.factsKey = fkey
        }
        return facts
    }

    /// ★ CORE'S VERDICT on a press over `footprint` along `direction` (AP2 review, binding amendment A4: offer only
    /// directions core accepts).
    public func pressVerdict(_ footprint: [Int], direction: SIMD3<Double>?) async throws -> FlexPressVerdict {
        // AP2 REVIEW RED STUB: each member's core load against the direction (a Swift copy of core's rule, per member)
        var ok = true
        for r in footprint {
            let f = try await regionFrame(r)
            if let d = direction, simd_dot(f.load, d) <= 0 { ok = false }
        }
        let d = direction.map { simd_normalize($0) } ?? .zero
        return FlexPressVerdict(accepted: ok, reason: ok ? "" : "a member faces along the direction", load: d,
                                buildAngleDeg: 0, side: false, columns: 0)
    }

    /// ★ Every edge and corner of the part, numbered (FlexibleEdgeCandidates), from core's facts for the open scene.
    public func edgeCandidates() async throws -> FlexibleEdgeCandidates {
        let facts = try await meetFacts()
        guard let meet else { throw TopOptError(message: "The part has no mesh to read.") }
        return FlexibleEdgeCandidates.make(meet: meet, facts: facts, name: { [weak self] r in self?.name(r) ?? "face \(r)" })
    }
}
