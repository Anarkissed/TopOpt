// SurfaceTint.swift — ★ SEEING THE FACES, AND SEEING THE TWO HALVES OF A CUT ONE
// (task 2026-08-15-lattice-and-face-ui, Surface stage; maintainer 2026-08-14:
// "I need to see the different faces after the cut is made. And select each
// individually … All colours should be changed to something that is a slight hue
// of blue that shows that a face which has been grouped is selectable").
//
// ── THE PROBLEM A PER-FACE TINT CANNOT SOLVE ─────────────────────────────────
//
// The viewport tints by FACE ID: `setHighlights(faceTint: [FaceID: SIMD4<Float>])`.
// A cut does not create a face — LAYER 1 is never re-partitioned (PR 331, and
// every analytic-surface consumer depends on it). Both halves of a cut face keep
// the SAME face id, so a face->colour map CANNOT draw them differently, no matter
// what colour it is handed. That is why a committed cut changed nothing on screen.
//
// ★ BUT THE TINT BUFFER IS ALREADY PER-VERTEX. `buildTintBuffer` walks
// `flatFaceIDs[v]` and writes one RGBA per VERTEX — the face map is only how the
// colour is *chosen*, not how it is *stored*. So the halves can be coloured
// separately with no shader change and no new pipeline: choose per vertex instead,
// by testing the vertex against the region's own half-spaces (`RegionCut`, the
// point-and-normal a cut is persisted as).
//
// This file is that choice, as a pure function over value types: mesh + regions +
// groups + selection in, a flat RGBA-per-vertex array out. No Metal, no view — so
// the colour rule is asserted headlessly, on the exact geometry a cut produces.
//
// ── THE PALETTE (one hue, three states) ──────────────────────────────────────
//
// Everything is the same blue, separated by BRIGHTNESS rather than by hue, so the
// page reads as one material and the eye is not asked to learn four colours:
//
//   GROUPED, not selected  faint blue   "this face is selectable"
//   SELECTED               bright blue  "this is what an action will act on"
//   THE OTHER HALF         mid blue     the sibling of a selected cut piece, so a
//                                       cut is visible as two DIFFERENT pieces even
//                                       before either is chosen
//   ungrouped              no tint      it cannot be acted on (cuts and unions are
//                                       restricted to grouped faces)

import Foundation
import simd
import TopOptKit

public enum SurfaceTint {

    /// ★ ONE HUE, THREE DEPTHS. The states differ in DEPTH and saturation, not in
    /// colour: selectable is a pale wash, the selection is a deep saturated blue
    /// (maintainer: "for select, please make the blue a darker hue to show the
    /// selection - adding a nice glow might be good, too"), and the sibling of a
    /// selected piece sits between them so a cut reads as two DIFFERENT pieces.
    public static let grouped  = SIMD4<Float>(0.34, 0.56, 0.90, 0.26)
    public static let sibling  = SIMD4<Float>(0.26, 0.52, 0.92, 0.55)
    /// ★ DARK. A deep navy-blue at near-full alpha — it reads as a different
    /// material against the pale wash, not as "the same blue, slightly more".
    public static let selected = SIMD4<Float>(0.06, 0.25, 0.72, 0.95)

    /// ★ THE GLOW — the selected piece's own B-rep outline, drawn bright so the
    /// dark fill has an edge that lifts it off the body. The renderer already
    /// draws a line list for the wireframe; this is the same buffer with the
    /// selected region's edges in a brighter colour.
    public static let selectionGlow = SIMD4<Float>(0.42, 0.78, 1.00, 1.0)

    /// What one vertex is showing — the reason a colour was chosen, so the tests
    /// assert the RULE and not a triple of floats.
    public enum State: Equatable, Sendable {
        case untinted          // ungrouped: not actionable on this stage
        case grouped           // grouped and selectable
        case sibling           // the other half of the selected piece's parent
        case selected          // the piece an action will act on
    }

    public static func colour(_ s: State) -> SIMD4<Float> {
        switch s {
        case .untinted: return .zero
        case .grouped:  return grouped
        case .sibling:  return sibling
        case .selected: return selected
        }
    }

    /// ★ THE PER-VERTEX STATE. This is the whole rule, and it is what the tests
    /// drive; `buffer` below is only its packing.
    ///
    /// - `groupedFaces`   every face the Topology page put in a group
    /// - `regions`        the region layer (a cut's children live here)
    /// - `selected`       the region an action will act on, if any
    /// `picked` are faces the user has multi-selected for a union — lit with the
    /// selection colour so a multi-select is VISIBLE ON THE MODEL, which is what
    /// makes a running count unnecessary.
    public static func states(mesh: ViewerMesh,
                              groupedFaces: Set<FaceID>,
                              regions: FaceRegionModel,
                              selected: RegionID?,
                              picked: Set<FaceID> = [],
                              fragmentTested: Set<FaceID> = []) -> [State] {
        // ★ ONE STATE PER *DRAW* VERTEX, NOT PER UNIQUE POSITION.
        //
        // The renderer draws a FLATTENED vertex list — `buildTintBuffer` walks
        // `vertexDrawCount` and reads `flatFaceIDs[v]`, one entry per INDEX, so a
        // shared corner appears once per triangle that uses it. A buffer sized to
        // the unique positions is a different length, and `setVertexTints` rejects
        // it: the tint silently did nothing, and the stage looked exactly as it did
        // before the colour existed. Found on device, not by the type system —
        // both are `[Float]`.
        let idx = mesh.indices
        guard !idx.isEmpty else { return [] }

        let selectedRegion = selected.flatMap { regions.region($0) }
        let siblings: [FaceRegion] = {
            guard let sel = selectedRegion, sel.isCut else { return [] }
            return regions.children(of: sel.parentID).filter { $0.id != sel.id }
        }()
        // ★ RESOLVED THROUGH A UNION. A union owns no faces of its own — it IS its
        // parts — so `members(of:)` on one returns NOTHING and the region lit
        // nothing at all: "after a union is made, the piece is no longer selectable
        // by ANY tool." Going through the leaves is the only way to ask a union
        // what it covers.
        let selectedFaces: Set<FaceID> = {
            guard let sel = selectedRegion else { return [] }
            var out: Set<FaceID> = []
            for leaf in regions.resolvedLeaves(sel.id) {
                guard let r = regions.region(leaf) else { continue }
                out.formUnion(FaceRegionGeometry.members(of: r, in: mesh))
            }
            return out
        }()

        var out = [State](repeating: .untinted, count: idx.count)
        var t = 0
        while t + 2 < idx.count {
            let tri = t / 3
            let f: Int32 = tri < mesh.faceIDs.count ? mesh.faceIDs[tri] : -1
            // ★ A PICKED FACE IS LIT WHETHER OR NOT IT IS GROUPED.
            //
            // This guard used to be `groupedFaces.contains(f)` alone, so a face the
            // union tool had picked but the Topology page had not grouped was added
            // to the set and drawn EXACTLY AS BEFORE — the tap registered and the
            // screen said nothing. Indistinguishable from a tap that did not
            // register, which is what "Union still isn't letting me multi-select"
            // looks like from the outside.
            guard f >= 0, groupedFaces.contains(f) || picked.contains(f)
            else { t += 3; continue }

            // ★ ONE STATE PER TRIANGLE, WRITTEN TO ALL THREE OF ITS VERTICES.
            //
            // Coloured per vertex, a triangle straddling the cut gets THREE
            // different colours and the GPU interpolates between them — the whole
            // surface reads as a smear, and the "edge" between the two halves is a
            // gradient that follows vertices rather than the plane. On a B-rep
            // tessellation with big triangles that is what it looks like: "Why does
            // it all seem to be a gradient? It looks ridiculous."
            //
            // Deciding once per triangle, from its CENTROID, makes every triangle a
            // FLAT colour. The fill is then honest — no smear — and the exact
            // boundary is drawn separately as a real line (`SurfaceCutLines`),
            // which is both crisper than any fill edge and visible in the
            // wireframe.
            var state = State.grouped
            if picked.contains(f) {
                state = .selected
            } else if let sel = selectedRegion, selectedFaces.contains(f),
                      !sel.isCut, !sel.isUnionOfParts {
                // ★ A SELECTED WHOLE FACE IS SELECTED. It has no half-spaces, so it
                // never reached the cut branch below and never reached the shader
                // either — it just stayed the pale selectable wash. "Select doesn't
                // make any face blue - it only highlights cut faces."
                state = .selected
            } else if let sel = selectedRegion, sel.isUnionOfParts,
                      selectedFaces.contains(f) {
                // ★ A UNION IS ONE PIECE — every face it covers lights as one, with
                // no internal boundary, which is what combining them meant.
                state = .selected
            } else if let sel = selectedRegion, selectedFaces.contains(f),
                      fragmentTested.contains(f) {
                // ★ THE PER-TRIANGLE CUT CLASSIFICATION ONLY EXISTS TO GIVE THE
                // SHADER A BASE. It is decided by a triangle's CENTROID, so on a
                // coarse face it is a wedge — the shattered-glass shape the
                // fragment test was built to replace.
                //
                // Applied where the shader will NOT run, that wedge is what you
                // see: switching to a tool that arms no test (union with nothing
                // picked) turned a cleanly selected face into a triangle. So it is
                // now confined to the faces the shader is actually given.
                var c = SIMD3<Double>(repeating: 0)
                for k in 0..<3 {
                    let vi = Int(idx[t + k]) * 3
                    guard vi + 2 < mesh.positions.count else { continue }
                    c += SIMD3<Double>(SIMD3<Float>(mesh.positions[vi],
                                                    mesh.positions[vi + 1],
                                                    mesh.positions[vi + 2]))
                }
                c /= 3
                if FaceRegionGeometry.inside(c, sel.cuts) {
                    state = .selected
                } else if siblings.contains(where: { FaceRegionGeometry.inside(c, $0.cuts) }) {
                    state = .sibling
                }
            }
            out[t] = state; out[t + 1] = state; out[t + 2] = state
            t += 3
        }
        return out
    }

    /// ★ A GROUPED FACE WEARS A HINT OF ITS GROUP'S OWN COLOUR (maintainer,
    /// 2026-08-15: "Let's make a distinction with a slight hue of the same colours
    /// of the groups in the TO page. So if it's red, make it a slightly red face").
    ///
    /// ★ AND IT IS A HINT, NOT THE COLOUR. The TO page's palette is saturated
    /// because there it IS the subject — which group a face belongs to. Here the
    /// subject is the surface, and group membership is context: enough hue to say
    /// "this one is in the red group", not enough to compete with the selection.
    /// Desaturated toward the stage's own wash and held at its alpha.
    public static func groupedHue(_ groupColour: SIMD3<Float>) -> SIMD4<Float> {
        let base = SIMD3<Float>(grouped.x, grouped.y, grouped.z)
        let mixed = base * 0.45 + groupColour * 0.55
        return SIMD4<Float>(mixed.x, mixed.y, mixed.z, grouped.w)
    }

    /// The flat RGBA-per-DRAW-VERTEX buffer the renderer uploads — the same length
    /// `buildTintBuffer` writes. Empty when nothing is tinted, so the stage costs
    /// nothing when it has nothing to say.
    public static func buffer(mesh: ViewerMesh,
                              groupedFaces: Set<FaceID>,
                              regions: FaceRegionModel,
                              selected: RegionID?,
                              picked: Set<FaceID> = [],
                              fragmentTested: Set<FaceID> = [],
                              groupColours: [FaceID: SIMD3<Float>] = [:]) -> [Float] {
        let s = states(mesh: mesh, groupedFaces: groupedFaces,
                       regions: regions, selected: selected, picked: picked,
                       fragmentTested: fragmentTested)
        guard s.contains(where: { $0 != .untinted }) else { return [] }

        // ★ EIGHT FLOATS PER DRAW VERTEX: rgba, then flags.
        //
        // `flags.x` marks a fragment of the SELECTED REGION's faces — the ones the
        // fragment stage tests against the cut plane. The CPU decides MEMBERSHIP
        // (a per-face fact); the GPU decides SIDE (a per-point fact). Splitting it
        // that way is what makes the boundary land exactly on the plane instead of
        // on whichever vertex or triangle edge happened to be nearest.
        // ★ WHICH FRAGMENTS THE SHADER TESTS — AND NO FALLBACK.
        //
        // This used to fall back to "test wherever the state is selected/sibling"
        // when the caller named no faces. That inverted the meaning in the one case
        // that matters: a union of ONLY whole faces names no tested faces, so every
        // picked face took the fallback, was marked as tested, and was drawn in the
        // neutral wash — while the shader's pick block never ran because there were
        // no chains to run it on. The result was a selection that lit for CUT
        // pieces and did nothing for ordinary faces, which is exactly how it was
        // reported: "the blue selection seems to only happen to CUT pieces".
        //
        // The set is now the whole truth: a face is fragment-tested iff it is IN it.
        var owner = [Int32](repeating: -1, count: s.count)
        var t = 0
        while t + 2 < mesh.indices.count {
            let tri = t / 3
            let f: Int32 = tri < mesh.faceIDs.count ? mesh.faceIDs[tri] : -1
            owner[t] = f; owner[t + 1] = f; owner[t + 2] = f
            t += 3
        }

        var out = [Float](repeating: 0, count: s.count * 8)
        for (i, st) in s.enumerated() {
            let tested = owner[i] >= 0 && fragmentTested.contains(owner[i])
            // Where the shader will decide, the base colour is the neutral wash;
            // where it will not, the per-triangle state IS the colour.
            var c = colour(tested ? .grouped : st)
            // ★ THE GROUP'S HUE, only where the state is the plain "selectable"
            // wash — a selected or sibling piece keeps the stage's own blue, which
            // is what says WHICH PIECE rather than which group.
            if !tested, st == .grouped, owner[i] >= 0,
               let gc = groupColours[owner[i]] {
                c = groupedHue(gc)
            }
            out[i * 8] = c.x; out[i * 8 + 1] = c.y
            out[i * 8 + 2] = c.z; out[i * 8 + 3] = c.w
            out[i * 8 + 4] = tested ? 1 : 0
        }
        return out
    }

    /// ★ THE PICKED PIECES AS HALF-SPACE CHAINS — one array of planes per piece,
    /// which is what lets the fragment stage draw exactly the piece that was
    /// tapped instead of the whole face it belongs to.
    ///
    /// A piece with NO cuts (a whole, uncut face) yields an empty chain; the caller
    /// drops those, because "inside no half-spaces" is trivially true everywhere
    /// and would light the entire part.
    public static func pickChains(_ ids: [RegionID],
                                  in regions: FaceRegionModel) -> [[SIMD4<Float>]] {
        ids.compactMap { id in
            guard let r = regions.region(id), !r.cuts.isEmpty else { return nil }
            return r.cuts.compactMap { cut in
                guard simd_length(cut.normal) > 1e-12 else { return nil }
                let n = simd_normalize(cut.normal)
                return SIMD4<Float>(SIMD3<Float>(n), Float(-simd_dot(n, cut.point)))
            }
        }
    }

    /// The plane the fragment stage tests, as (normal.xyz, -dot(normal, point)) —
    /// the selected region's OWN last cut. Nil when nothing is cut, and the shader
    /// then draws exactly as it did before this existed.
    public static func planeFor(_ selected: RegionID?,
                                in regions: FaceRegionModel) -> SIMD4<Float>? {
        guard let id = selected, let r = regions.region(id), let cut = r.cuts.last,
              simd_length(cut.normal) > 1e-12 else { return nil }
        // ★ THE REGION'S OWN SENSE. `splitManual` gives one child the normal and
        // the other its negation, so taking the cut AS STORED means the selected
        // side is always the `d >= 0` side — the shader needs no extra sign.
        let n = simd_normalize(cut.normal)
        return SIMD4<Float>(SIMD3<Float>(n), Float(-simd_dot(n, cut.point)))
    }

    /// ★ WHICH PIECE WAS TAPPED. Given the point the picker hit, the region a tap
    /// selects: the DEEPEST region whose members contain the face AND whose
    /// half-spaces contain the point — so tapping either side of a committed cut
    /// selects that side, which is the whole ask.
    ///
    /// Falls back to the deepest region containing the face when no cut region
    /// claims the point (an uncut face has exactly one region, or none).
    public static func regionAt(point: SIMD3<Double>, face: FaceID,
                                mesh: ViewerMesh, regions: FaceRegionModel) -> RegionID? {
        func depth(_ r: FaceRegion) -> Int {
            var d = 0, cur = r
            while let p = regions.region(cur.parentID) { d += 1; cur = p }
            return d
        }
        let holding = regions.regions
            .filter { FaceRegionGeometry.members(of: $0, in: mesh).contains(face) }
            .sorted { depth($0) > depth($1) }
        // A cut region wins only if the point is on ITS side.
        for r in holding where r.isCut {
            if FaceRegionGeometry.inside(point, r.cuts) { return r.id }
        }
        return holding.first(where: { !$0.isCut })?.id ?? holding.first?.id
    }
}
