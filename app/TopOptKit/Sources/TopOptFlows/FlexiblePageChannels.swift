// FlexiblePageChannels — what the Flexible Settings page hands MetalMeshView: the overlay
// mesh (the part with every loaded face's column quads) and its per-vertex channels
// (task 2026-09-29-flexible-screens, round 3).
//
// ★ ONE PLACE, CALLED BY THE PAGE. These were private methods of FlexibleStagePage; they
// live here so a test can build EXACTLY the page's overlay on his restored project (memory:
// "value-type tests miss call sites" — FlexibleOverlayClipTests pins the page's call).

import Foundation
import simd
import TopOptKit

@MainActor
public enum FlexiblePageChannels {

    /// The overlay the page draws: every loaded face that has a stack and geometry, on the
    /// part CUT along every declared sector's planes — so each kept piece is on one side of
    /// every cut, and a sector's tint (and its map) stops exactly at the cut (round 3, item
    /// 2). nil only when there is neither a map nor a sector (the page then tints the part's
    /// own triangles, which no cut crosses).
    /// `maxEdgeMM` (the MAIN page, batch C verification): the part's triangles cut that fine for
    /// the Stress colours (FlexibleOverlayMesh.Subdivision — the dent's geometry is unchanged).
    public static func overlay(model: FlexibleStageModel, maxEdgeMM: Double? = nil) -> FlexibleOverlayMesh? {
        guard let part = model.project.viewerMesh else { return nil }
        let regions = model.regions
        let faces: [FlexibleOverlayFace] = model.loadedKeys.compactMap { k in
            guard let st = model.stacks[k], let g = model.geometry[k] else { return nil }
            return FlexibleOverlayFace(key: k, faces: Set(regions.faces(of: k.region, mesh: part)),
                                       cuts: regions.cuts(of: k.region), stack: st, centres: g.centres)
        }
        let planes = FlexibleFacePieces.planes(of: regions, mesh: part)
        guard !faces.isEmpty || !planes.isEmpty else { return nil }
        return FlexibleOverlayMesh.build(part: part, faces: faces, splitPlanes: planes, maxEdgeMM: maxEdgeMM)
    }

    /// Everything MetalMeshView reads for the map: per-vertex tints, the dent (mm per flat
    /// vertex, before the renderer's scale), the ONE exaggeration k, and whether it loops.
    public struct Channels {
        public var tints: [Float]?
        public var dents: [Float]?
        public var exaggeration: Double
        public var animated: Bool
        /// The legend's one line ("What you drew · shown ×7"); empty when nothing is shown.
        public var legendLine: String
    }

    /// Per-column colours + the dent, from the model's current copies of core's results.
    /// The page calls this on every change (FlexibleStagePage.refreshChannels).
    /// `heat` false (the main page's Heat view off): the map quads take no colour — the dent
    /// still moves them, so the ghost itself squishes.
    public static func channels(model: FlexibleStageModel, overlay: FlexibleOverlayMesh?, xray: Bool,
                                drawnLattice: FlexibleGeneratedLattice?, heat: Bool = true) -> Channels {
        // part regions: loaded / resting / selected / linked other end — by REGION, so a split
        // sector is tinted on its own side of its cuts (FlexibleRegions).
        // ★ ROUND 4 (D2): no "conflict" tint — two faces on one stack are a pinch (one group) or
        // separate squeezes (two groups), never an error; with two or more squeeze groups a
        // pressed face's own part takes its GROUP's colour (FlexibleSqueezeGroups.palette, never
        // purple) — seen until its map quads cover it (the face list's dots carry it after)
        let regions = model.regions
        let groups = model.squeezeGroups
        var regionTint: [(id: Int, tint: SIMD4<Float>)] = []   // later entries win
        for f in model.settings.faces {
            var c = f.isLoaded ? FlexibleColours.loadedFace : FlexibleColours.restingFace
            if f.isLoaded, groups.count > 1, let g = groups.first(where: { $0.regions.contains(f.faceRegionID) }) {
                c = FlexibleColours.token(FlexibleSqueezeGroups.colour(number: g.number), FlexibleColours.loadedFace.w)
            }
            regionTint.append((f.faceRegionID, c))
        }
        if let r = model.selectedRegion {
            if let st = model.stack(r) { for l in st.exitRegions { regionTint.append((l.id, FlexibleColours.linkedEnd)) } }
            regionTint.append((r, FlexibleColours.selectedFace))
        }
        let partMesh = model.project.viewerMesh
        let tintOf: (Int, SIMD3<Double>) -> SIMD4<Float>? = { face, centroid in
            var out: SIMD4<Float>?
            for e in regionTint where regions.contains(e.id, face: face, centroid: centroid, mesh: partMesh) {
                out = e.tint
            }
            return out
        }
        guard let overlay else {
            // no map and no sector: tint the part itself, per triangle (no cut crosses one)
            guard let mesh = partMesh else { return Channels(tints: nil, dents: nil, exaggeration: 0, animated: false, legendLine: "") }
            let n = mesh.flat.vertexCount
            var out = [Float](repeating: 0, count: n * 8)
            let ids = mesh.faceIDs
            func vtx(_ i: UInt32) -> SIMD3<Double> {
                let b = Int(i) * 3
                return SIMD3(Double(mesh.positions[b]), Double(mesh.positions[b + 1]), Double(mesh.positions[b + 2]))
            }
            for t in 0..<min(mesh.triangleCount, n / 3) where !regionTint.isEmpty {
                let fid = t < ids.count ? Int(ids[t]) : -1
                let c = (vtx(mesh.indices[3 * t]) + vtx(mesh.indices[3 * t + 1]) + vtx(mesh.indices[3 * t + 2])) / 3
                guard let col = tintOf(fid, c) else { continue }
                for j in 0..<3 {
                    let v = 3 * t + j
                    out[v * 8] = col.x; out[v * 8 + 1] = col.y; out[v * 8 + 2] = col.z; out[v * 8 + 3] = col.w
                }
            }
            if xray { FlexibleOverlayMesh.markGhost(&out, colour: FlexibleColours.ghost) }
            return Channels(tints: n > 0 ? out : nil, dents: nil, exaggeration: 0, animated: false, legendLine: "")
        }
        let shown = FlexibleShownValues(model: model, drawnLattice: drawnLattice)
        var colours: [FlexFaceKey: [SIMD4<Float>]] = [:]
        for k in model.loadedKeys {
            guard let vals = shown.values[k] else { continue }
            colours[k] = vals.map { v in
                switch v {
                case .depth(let mm): return FlexibleColours.depth(mm, max: shown.maxDepth)
                case .noNumber: return FlexibleColours.noNumber
                case .solid: return SIMD4(0, 0, 0, 0)
                }
            }
        }
        let tints = overlay.tints(partTint: tintOf, columnColours: heat ? colours : [:], ghost: xray ? FlexibleColours.ghost : nil)
        guard shown.showsDent else {
            return Channels(tints: tints, dents: nil, exaggeration: 0, animated: false, legendLine: "")
        }
        var depths: [FlexFaceKey: [Double?]] = [:]
        for (k, vals) in shown.values {
            // ★ BATCH B: with a lattice drawn, only the faces whose squish is SHOWN (the four
            // largest) dent — the others hold still, as their walls do
            if let g = drawnLattice, !g.squishedKeys.contains(k) { continue }
            depths[k] = vals.map { if case .depth(let d) = $0 { return d } else { return nil } }
        }
        let dents = overlay.displacements(depths: depths, stacks: model.stacks,
                                          partUVT: model.geometry.mapValues(\.partUVT))
        // ★ one k while the depth chip is dragged (FlexibleDepthChips freezes it on the model)
        let k = model.frozenExaggeration ?? shown.exaggeration
        return Channels(tints: tints, dents: dents, exaggeration: k, animated: shown.animated,
                        legendLine: "\(shown.label) · shown ×\(Int(k))")
    }
}
