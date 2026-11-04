// FlexibleStageModel+Meet — the stage model's side of "which faces meet" (task 2026-10-07, angled presses, batch
// AP2; final spec §5 "Model caches, loaded once per scene open: coreAdjacency and regionFrames (on demand)").
//
// ★ WHAT IS CACHED, AND FOR HOW LONG.
//   * `meet` — FlexibleMeet over the viewer mesh and the declared regions: rebuilt when the mesh or his sectors
//     change (the mesh signature + FlexibleRegions.key), never per frame. ★ AP2 REVIEW: pick mode builds it with
//     `meetOffMain()`, OFF the main actor (it is a pure value; a 41 k-triangle part takes about a second), and
//     every later reader — the sync `meet`, meetFacts, edgeCandidates — reuses that build;
//   * core's answers — face_adjacency, each region's frame (asked on demand, per region / face / direction), the
//     seam triangles' normals and core's verdict on a press — kept for the OPEN SCENE (its key, `openedKey`): a new
//     scene (a re-split, another resolution, another gravity) asks again. ★ AP2 REVIEW: they are read only while the
//     open scene IS the scene of the current regions (`openedKey == currentSceneKey`). A cut made after the open
//     (item 2's [Done], a Surface-stage split) leaves the old scene without the new sectors; until the part
//     re-opens every call throws "The part's faces changed …" instead of caching the old scene's answers.
// ★ ONE SOURCE: CORE. Every frame, normal, adjacency and verdict here is read through the bridge (FlexibleKit+Meet)
// from the scene the page opened; the model only decides when to ask and keeps the answers.

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

/// One FlexibleMeet build off the main actor, and the thread it ran on (handed back across the task).
private final class FlexibleMeetBuild: @unchecked Sendable {
    var meet: FlexibleMeet?
    var onMainThread = true

    func run(_ mesh: ViewerMesh, _ regions: FlexibleRegions) {
        meet = FlexibleMeet(mesh: mesh, regions: regions)
        onMainThread = Thread.isMainThread
    }
}

extension FlexibleStageModel {

    /// The geometry's key: the mesh it was built over and the declared regions.
    private func meetKey(_ mesh: ViewerMesh, _ regions: FlexibleRegions) -> String {
        "\(mesh.signature.contentHash)|\(mesh.signature.topologyHash)|\(mesh.faceIDs.count)|\(regions.key)"
    }

    /// ★ Which faces meet on the part the page draws (geometry only; core's facts are `meetFacts()`). nil before
    /// the part is imported. Builds on the CALLING actor when nothing is cached: pick mode calls `meetOffMain()`.
    public var meet: FlexibleMeet? {
        guard let mesh = project.viewerMesh else { return nil }
        let regions = self.regions
        let key = meetKey(mesh, regions)
        if meetCache.geometryKey == key, let g = meetCache.geometry { return g }
        let g = FlexibleMeet(mesh: mesh, regions: regions)
        meetCache.builds += 1
        meetCache.lastBuildOnMainThread = Thread.isMainThread
        meetCache.geometryKey = key
        meetCache.geometry = g
        return g
    }

    /// ★ Which faces meet, built OFF the main actor (AP2 review) and cached for every later reader. A regions
    /// change during the build: the answer is for the regions the call began with, and is not cached.
    public func meetOffMain() async -> FlexibleMeet? {
        guard let mesh = project.viewerMesh else { return nil }
        let regions = self.regions
        let key = meetKey(mesh, regions)
        if meetCache.geometryKey == key, let g = meetCache.geometry { return g }
        let build = FlexibleMeetBuild()
        await Task.detached(priority: .userInitiated) { build.run(mesh, regions) }.value
        guard let g = build.meet else { return nil }
        meetCache.builds += 1
        meetCache.lastBuildOnMainThread = build.onMainThread
        if let now = project.viewerMesh, meetKey(now, self.regions) == key {
            meetCache.geometryKey = key
            meetCache.geometry = g
        }
        return g
    }

    /// The open scene's key, or the refusal a caller shows: while it opens, and (AP2 review) while it is not the
    /// scene of the current regions.
    private func openSceneKey() throws -> String {
        guard sceneState == .ready, let k = openedKey else { throw TopOptError(message: "The part is still opening.") }
        guard k == currentSceneKey else {
            throw TopOptError(message: "The part's faces changed since it opened; core answers once it opens again.")
        }
        meetCache.follow(scene: k)
        return k
    }

    /// ★ Core's face_adjacency for the open scene (asked once per scene).
    public func coreAdjacency() async throws -> [[Int]] {
        try await adjacency(scene: try openSceneKey())
    }

    private func adjacency(scene key: String) async throws -> [[Int]] {
        if meetCache.sceneKey == key, let a = meetCache.adjacency { return a }
        let a = try await frameWorker.withScene { try $0.faceAdjacency() }
        if meetCache.sceneKey == key { meetCache.adjacency = a }
        return a
    }

    /// ★ Core's frame of declared region `region` (or of its member face `face`), along `direction` when given —
    /// face_frame_cut through the open scene; asked once per (region, face, direction bits) per scene.
    public func regionFrame(_ region: Int, face: Int? = nil, direction: SIMD3<Double>? = nil) async throws -> FlexRegionFrame {
        try await frame(region, face: face, direction: direction, scene: try openSceneKey())
    }

    private func frame(_ region: Int, face: Int?, direction: SIMD3<Double>?, scene key: String) async throws -> FlexRegionFrame {
        let k = "\(region)|\(face ?? -1)|" + Self.bits(direction)
        if meetCache.sceneKey == key, let f = meetCache.frames[k] { return f }
        let f = try await frameWorker.withScene { try $0.regionFrame(region, face: face, direction: direction) }
        if meetCache.sceneKey == key { meetCache.frames[k] = f }
        return f
    }

    private static func bits(_ d: SIMD3<Double>?) -> String {
        d.map { "\($0.x.bitPattern),\($0.y.bitPattern),\($0.z.bitPattern)" } ?? "-"
    }

    /// ★ CORE'S VERDICT on a press over `footprint` (declared regions, in this order) along `direction` (else the
    /// union's inward normal) — core's build_press_stack on the open scene, asked once per (footprint, direction
    /// bits) per scene (AP2 review; binding amendment A4: "offer only directions core accepts"). A refusal is an
    /// answer (`accepted == false`, core's words). This is the ONLY test of a direction: core checks every
    /// footprint triangle, and a check of each member's load is a coarser copy that core contradicts on curved
    /// members (M2's corner [33, 34, 57] along build Z: every member's load points in, core refuses).
    public func pressVerdict(_ footprint: [Int], direction: SIMD3<Double>?) async throws -> FlexPressVerdict {
        let key = try openSceneKey()
        let k = footprint.map(String.init).joined(separator: ",") + "|" + Self.bits(direction)
        if meetCache.sceneKey == key, let v = meetCache.verdicts[k] { return v }
        let v = try await frameWorker.withScene { try $0.pressVerdict(footprint, direction: direction) }
        if meetCache.sceneKey == key { meetCache.verdicts[k] = v }
        return v
    }

    /// ★ Everything FlexibleEdgeCandidates needs from core, for the open scene and the current regions: core's
    /// adjacency, core's frame of every piece, and core's normal of every seam triangle — the last only once core's
    /// model is checked to be the viewer mesh, triangle for triangle (count and face of each), else `mismatch` says
    /// why and nothing is decided on it.
    public func meetFacts() async throws -> FlexibleMeetFacts {
        let key = try openSceneKey()
        guard let meet = await meetOffMain(), let mesh = project.viewerMesh else {
            throw TopOptError(message: "The part has no mesh to read.")
        }
        let fkey = key + "|" + meetKey(mesh, regions)
        if meetCache.sceneKey == key, meetCache.factsKey == fkey, let f = meetCache.facts { return f }
        let adjacency = try await adjacency(scene: key)
        var frames: [Int: FlexRegionFrame] = [:]
        for p in meet.pieces {
            if let f = try? await frame(p.id, face: nil, direction: nil, scene: key) { frames[p.id] = f }
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

    /// ★ Every edge and corner of the part, numbered (FlexibleEdgeCandidates), from core's facts for the open scene;
    /// a member taken out of the Flexible setup (settings.removedRegions) is listed, never offered.
    public func edgeCandidates() async throws -> FlexibleEdgeCandidates {
        let facts = try await meetFacts()
        guard let meet = await meetOffMain() else { throw TopOptError(message: "The part has no mesh to read.") }
        return FlexibleEdgeCandidates.make(meet: meet, facts: facts, removed: Set(settings.removedRegions ?? []),
                                           name: { [weak self] r in self?.name(r) ?? "face \(r)" })
    }
}
