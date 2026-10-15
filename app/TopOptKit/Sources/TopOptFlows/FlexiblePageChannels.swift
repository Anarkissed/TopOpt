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

    /// ★ ROUND 7 (M2): which drawn part triangles stay still for which pressed key — the SOLID rest of a face only partly
    /// latticed (the triangles on a Flexible sector's own face, outside its cuts). nil: none (no Flexible sector pressed).
    static func stillRule(regions: FlexibleRegions, mesh: ViewerMesh?, overlay: FlexibleOverlayMesh,
                          keys: [FlexFaceKey]) -> ((FlexFaceKey, Int) -> Bool)? {
        var sections: [Int: (faces: Set<Int>, cuts: [RegionCut])] = [:]
        if let set = regions.flexible, let mesh {
            for k in keys { if let pc = set.piece(k.region) {
                sections[k.region] = (Set(FaceRegionGeometry.members(of: pc.region, in: mesh).map { Int($0) }), pc.region.cuts)
            } }
        }
        guard !sections.isEmpty else { return nil }
        return { k, t in
            guard let sec = sections[k.region], t < overlay.keptFace.count, sec.faces.contains(overlay.keptFace[t]) else { return false }
            let c = overlay.keptCentroid[t]
            return !sec.cuts.allSatisfy { simd_dot(c - $0.point, simd_normalize($0.normal)) >= -1e-6 }
        }
    }

    /// ★ ROUND 7 (M2): the lattice sections' faint violet (the Squish page's "where a tap works").
    public static let sectionTintAlpha: Float = 0.35

    /// Everything MetalMeshView reads for the map: per-vertex tints, the dent (mm per flat
    /// vertex, before the renderer's scale), the ONE exaggeration k, and whether it loops.
    public struct Channels {
        public var tints: [Float]?
        public var dents: [Float]?
        public var exaggeration: Double
        public var animated: Bool
        /// The legend's one line ("What you drew · shown ×7"); empty when nothing is shown.
        public var legendLine: String
        /// ★ BATCH M (M5): the heat's value at every map vertex (mm; NaN: none) — what each corner
        /// was coloured by, so a tap reads the colour under it (FlexibleProbe.dentReading).
        public var mapValues: [Float]? = nil
        /// The heat's top end (mm): the value the ramp's red is.
        public var heatScaleMM: Double = 0
    }

    /// Per-column colours + the dent, from the model's current copies of core's results.
    /// The page calls this on every change (FlexibleStagePage.refreshChannels).
    /// `heat` false (the main page's Heat view off): the map quads take no colour — the dent
    /// still moves them, so the ghost itself squishes.
    /// `depthScaleMM`: the heat ramp's deepest end (nil: this lattice's own deepest) — ★ batch G
    /// verification: "Play all"'s per-group colours keep the page's ONE scale (the legend's).
    /// ★ BATCH M (M5, M2): the heat is coloured PER VERTEX, by the value at that corner (the corner
    /// mean the dent moves it by — `FlexibleOverlayMesh.mapCornerValues`), so it grades continuously
    /// across the map with no block and no hard cut; `mapValues` (the main page's 3D sim — FE mode)
    /// replaces those values: the sim's own dent at every vertex of the shown group's faces, which
    /// spreads out from each stamp and merges the foci. `controlColumnColours` (tests only): the old
    /// one colour per column — the red control of the blocks.
    public static func channels(model: FlexibleStageModel, overlay: FlexibleOverlayMesh?, xray: Bool,
                                drawnLattice: FlexibleGeneratedLattice?, heat: Bool = true,
                                depthScaleMM: Double? = nil, mapValues: [Float]? = nil,
                                controlColumnColours: Bool = false, groupColours: Bool = true,
                                roleMarks: Bool = true, heatRegions: Set<Int>? = nil, sectionTints: Bool = false) -> Channels {
        // part regions: loaded / resting / selected / linked other end — by REGION, so a split
        // sector is tinted on its own side of its cuts (FlexibleRegions).
        // ★ ROUND 4 (D2): no "conflict" tint — two faces on one stack are a pinch (one group) or
        // separate squeezes (two groups), never an error; with two or more squeeze groups a
        // pressed face's own part takes its GROUP's colour (FlexibleSqueezeGroups.palette, never
        // purple) — seen until its map quads cover it (the face list's dots carry it after)
        // ★ ROUND 6 (his img1): `groupColours` false on BOTH pages — a pressed face with no map is the plain
        // pressed colour; the group's colour is the Settings page's glass (FlexibleGroupWalls) and its dots
        let regions = model.regions
        let groups = model.squeezeGroups
        var regionTint: [(id: Int, tint: SIMD4<Float>)] = []   // later entries win
        // ★ ROUND 7 (M2, his img3 words): on the Squish page, where a tap works — every lattice piece of a face only partly
        // inside a face-prism wears the face-prism violet, faint, FIRST (a role or the selection over it wins); the solid
        // rest of the face stays the part's colour (the overlay cuts the face at the section's planes, so it stops there)
        if sectionTints, let set = regions.flexible, !set.partialRoots.isEmpty {
            let c = SIMD4<Float>(FlexibleStageStyle.facePrismTint, Self.sectionTintAlpha)
            for p in set.pieces where set.partialRoots[p.rootRegion] != nil && p.kind != .strip { regionTint.append((p.wireID, c)) }
        }
        // ★ BATCH V ("Role colours off" on the MAIN page — his answer of 2026-10-09, now a view setting): `roleMarks` false —
        // no pressed green, no resting cyan, no selected face or linked end on the part; only the dent heat on the maps. The
        // Settings page keeps them.
        for f in model.settings.faces where roleMarks {
            var c = f.isLoaded ? FlexibleColours.loadedFace : FlexibleColours.restingFace
            if groupColours, f.isLoaded, groups.count > 1, let g = groups.first(where: { $0.regions.contains(f.faceRegionID) }) {
                c = FlexibleColours.token(model.groupColour(g), FlexibleColours.loadedFace.w)   // ★ S1: his chosen colour
            }
            regionTint.append((f.faceRegionID, c))
        }
        if roleMarks, let r = model.selectedRegion {
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
        let scale = depthScaleMM ?? shown.maxDepth
        var colours: [FlexFaceKey: [SIMD4<Float>]] = [:]
        var numbers: [FlexFaceKey: [Double?]] = [:]
        for k in model.loadedKeys {
            guard let vals = shown.values[k] else { continue }
            numbers[k] = vals.map { if case .depth(let d) = $0 { return d } else { return nil } }
            let start = overlay.flatStart[k]
            colours[k] = vals.enumerated().map { c, v in
                // ★ FE mode: every column of the shown group the sim reaches is coloured by it (it
                // moves — a solid one too); a face the sim does not colour stays uncoloured
                if let fe = mapValues {
                    guard let start, start + c * 6 < fe.count, fe[start + c * 6].isFinite else { return SIMD4(0, 0, 0, 0) }
                    return FlexibleColours.depth(Double(fe[start + c * 6]), max: scale)
                }
                switch v {
                case .depth(let mm): return FlexibleColours.depth(mm, max: scale)
                case .noNumber: return FlexibleColours.noNumber
                case .solid: return SIMD4(0, 0, 0, 0)
                }
            }
        }
        // ★ the value at every map vertex: the sim's (FE), else the corner mean of the shown numbers
        let values = controlColumnColours ? nil : (mapValues ?? overlay.mapCornerValues(numbers, stacks: model.stacks))
        let vertexColour: ((Int) -> SIMD4<Float>?)? = values.map { vals in
            { v in v < vals.count && vals[v].isFinite ? FlexibleColours.depth(Double(vals[v]), max: scale) : nil }
        }
        // ★ R7-V (the Settings page's Heat view): only `heatRegions`' maps take the heat (nil: every pressed face's)
        let heated = heatRegions.map { only in colours.filter { only.contains($0.key.region) } } ?? colours
        var tints = overlay.tints(partTint: tintOf, columnColours: heat ? heated : [:], vertexColour: heat ? vertexColour : nil,
                                  ghost: xray ? FlexibleColours.ghost : nil)
        // ★ ROUND 7 (M2): the sections' violet reads through the X-ray ghost — flagged like the map (flags.y), not ghosted
        if sectionTints, regions.flexible?.partialRoots.isEmpty == false {
            let violet = SIMD4<Float>(FlexibleStageStyle.facePrismTint, Self.sectionTintAlpha)
            for t in 0..<overlay.keptFace.count {
                let v0 = t * 3 * 8
                guard v0 + 23 < tints.count,
                      SIMD4(tints[v0], tints[v0 + 1], tints[v0 + 2], tints[v0 + 3]) == violet else { continue }
                for j in 0..<3 { tints[v0 + j * 8 + 5] = 1; tints[v0 + j * 8 + 6] = 0 }
            }
        }
        guard shown.showsDent else {
            return Channels(tints: tints, dents: nil, exaggeration: 0, animated: false, legendLine: "", mapValues: values, heatScaleMM: scale)
        }
        var depths: [FlexFaceKey: [Double?]] = [:]
        for (k, vals) in shown.values {
            // ★ BATCH B: with a lattice drawn, only the faces whose squish is SHOWN (the four
            // largest) dent — the others hold still, as their walls do
            if let g = drawnLattice, !g.squishedKeys.contains(k) { continue }
            depths[k] = vals.map { if case .depth(let d) = $0 { return d } else { return nil } }
        }
        // ★ ROUND 7 (M2): the solid rest of a face only partly latticed stays still (its triangles on the section's own face,
        // outside the section's cuts) — a Flexible sector only; his Surface sectors and whole faces ride their ramp as before
        let still = stillRule(regions: regions, mesh: partMesh, overlay: overlay, keys: Array(depths.keys))
        let dents = overlay.displacements(depths: depths, stacks: model.stacks,
                                          partUVT: model.geometry.mapValues(\.partUVT), still: still)
        // ★ one k while the depth chip is dragged (FlexibleDepthChips freezes it on the model)
        let k = model.frozenExaggeration ?? shown.exaggeration
        return Channels(tints: tints, dents: dents, exaggeration: k, animated: shown.animated,
                        legendLine: "\(shown.label) · shown ×\(Int(k))", mapValues: values, heatScaleMM: scale)
    }
}
