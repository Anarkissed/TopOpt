// LatticeStressTint.swift — ★ THE STRESS VIEW (maintainer, 2026-08-17).
//
// ★ HIS WORDS: "Once you save and exit, an FEA should run and a Stress view
// should now be accessible below the preview button."
//
// The solve already existed — `LatticeSimModel` has run one coarse linear FEA of
// the solid part through the bridge's `analyze_loadcase` seam since the lattice
// page shipped, and its per-voxel von Mises field is what the Sim density mode
// grades by. What did NOT exist was any way to LOOK at it. The number decided
// the lattice and the user could not see it.
//
// ★★ WHAT THIS VIEW IS HONEST ABOUT, STATED HERE RATHER THAN DISCOVERED LATER:
//
//   · it is the field of the SOLID part, not of the latticed one. That is the
//     field the grading law reads (core hands `v.von_mises_field` to
//     `grade_lattice`), so it is the right thing to show for "why is the lattice
//     denser here" — but it is not a certification of the lattice
//   · it is MACRO stress. Core's lattice certification runs on the homogenized
//     representation and reports latticed voxels' EFFECTIVE von Mises;
//     strut-level strength is a separate report and is not gated unless
//     `gate_on_strut_strength` is armed. A per-strut stress picture would be a
//     claim this pipeline does not make
//   · it is NORMALISED to the field's own peak. An absolute MPa scale would need
//     a legend per material and per load case; the question this view answers is
//     "where is the load going", which is a shape question

import Foundation
import simd
import TopOptKit

public enum LatticeStressTint {

    /// ★ EIGHT FLOATS PER VERTEX — rgba then flags — matching `SurfaceTint.buffer`
    /// exactly, because the renderer has ONE vertex-tint format and a second
    /// layout would be a second renderer.
    public static let floatsPerVertex = 8

    /// ★ THE COLOUR RAMP: cool where the part is idle, hot where the load runs.
    ///
    /// Deliberately NOT the density ramp. The density ramp is the LATTICE's
    /// colour language — it says "this much material" — and reusing it here would
    /// make two different quantities look like one. This is the stress ramp:
    /// blue ▸ cyan ▸ green ▸ amber ▸ red.
    public static func colour(fraction f: Double) -> SIMD4<Float> {
        let t = Swift.min(1, Swift.max(0, f))
        // Piecewise linear through five stops, which reads more evenly than a
        // hue sweep (a raw HSV rotation spends too much of its range in green).
        let stops: [(Double, SIMD3<Float>)] = [
            (0.00, SIMD3(0.15, 0.30, 0.85)),   // blue   — idle
            (0.25, SIMD3(0.10, 0.72, 0.86)),   // cyan
            (0.50, SIMD3(0.25, 0.80, 0.35)),   // green
            (0.75, SIMD3(0.98, 0.72, 0.15)),   // amber
            (1.00, SIMD3(0.92, 0.18, 0.16)),   // red    — peak
        ]
        for i in 1..<stops.count where t <= stops[i].0 {
            let (t0, c0) = stops[i - 1], (t1, c1) = stops[i]
            let u = Float((t - t0) / Swift.max(1e-9, t1 - t0))
            let c = c0 + (c1 - c0) * u
            return SIMD4(c.x, c.y, c.z, 1)
        }
        let c = stops[stops.count - 1].1
        return SIMD4(c.x, c.y, c.z, 1)
    }

    /// Sample the field at a model-space point, trilinearly. Returns nil outside
    /// the grid — a point the solve never covered has no stress to report, and
    /// inventing one would be the fabricated-number defect.
    public static func sample(_ field: LatticeDemandField,
                              at p: SIMD3<Double>) -> Double? {
        guard field.spacingMM > 0,
              field.nx > 0, field.ny > 0, field.nz > 0 else { return nil }
        let g = (p - field.origin) / field.spacingMM
        guard g.x >= 0, g.y >= 0, g.z >= 0,
              g.x <= Double(field.nx - 1), g.y <= Double(field.ny - 1),
              g.z <= Double(field.nz - 1) else { return nil }
        let i0 = Int(g.x), j0 = Int(g.y), k0 = Int(g.z)
        let i1 = Swift.min(i0 + 1, field.nx - 1)
        let j1 = Swift.min(j0 + 1, field.ny - 1)
        let k1 = Swift.min(k0 + 1, field.nz - 1)
        let fx = g.x - Double(i0), fy = g.y - Double(j0), fz = g.z - Double(k0)
        func at(_ i: Int, _ j: Int, _ k: Int) -> Double {
            Double(field.vonMises[i + field.nx * (j + field.ny * k)])
        }
        let c00 = at(i0, j0, k0) * (1 - fx) + at(i1, j0, k0) * fx
        let c10 = at(i0, j1, k0) * (1 - fx) + at(i1, j1, k0) * fx
        let c01 = at(i0, j0, k1) * (1 - fx) + at(i1, j0, k1) * fx
        let c11 = at(i0, j1, k1) * (1 - fx) + at(i1, j1, k1) * fx
        let c0 = c00 * (1 - fy) + c10 * fy
        let c1 = c01 * (1 - fy) + c11 * fy
        return c0 * (1 - fz) + c1 * fz
    }

    /// The per-vertex tint buffer for the whole mesh, or EMPTY when there is
    /// nothing honest to draw.
    ///
    /// ★ EMPTY IS A REAL ANSWER, and the caller must treat it as "draw the part
    /// normally" rather than "draw it black". A flat field (every voxel the same)
    /// is the case that matters: it happens when the solve found no load path,
    /// and normalising it would paint the entire part peak-red — a picture that
    /// looks like a finding and is an artefact of dividing by ~0.
    /// ★★ ONE ENTRY PER *DRAW* VERTEX — PER INDEX, NOT PER UNIQUE POSITION.
    ///
    /// ★ THIS IS WHY THE STRESS VIEW WAS A PURPLE BLOB (maintainer, 2026-08-18:
    /// "The stress view is still this purple blob"). The renderer draws a
    /// FLATTENED vertex list: `vertexDrawCount == mesh.flat.vertexCount`, one
    /// vertex per INDEX, so a shared corner appears once per triangle that uses
    /// it. `setVertexTints` checks `rgba.count == vertexDrawCount * 8` and, on a
    /// mismatch, SILENTLY discards the buffer and rebuilds the old one.
    ///
    /// My first cut sized this by `positions.count / 3` — unique positions — so
    /// on any welded mesh the count was wrong, the buffer was thrown away
    /// without a word, and what remained on screen was the ordinary body
    /// shading. `SurfaceTint.states` carries this exact warning in its own
    /// comment ("ONE STATE PER *DRAW* VERTEX, NOT PER UNIQUE POSITION") and I
    /// copied the layout from it without copying the rule.
    ///
    /// ★ A SILENT SIZE CHECK IS THE WORST KIND. Nothing logged, nothing threw,
    /// and the view looked plausible — just wrong. The count is derived from
    /// `indices` here so it cannot drift again.
    public static func buffer(mesh: ViewerMesh,
                              field: LatticeDemandField) -> [Float] {
        let n = mesh.indices.count            // ★ one per INDEX
        guard n > 0, !field.vonMises.isEmpty else { return [] }
        var peak = 0.0
        for v in field.vonMises { peak = Swift.max(peak, Double(v)) }
        guard peak > 1e-12 else { return [] }

        var out = [Float](repeating: 0, count: n * floatsPerVertex)
        for v in 0..<n {
            let src = Int(mesh.indices[v]) * 3
            guard src + 2 < mesh.positions.count else { continue }
            let p = SIMD3<Double>(Double(mesh.positions[src]),
                                  Double(mesh.positions[src + 1]),
                                  Double(mesh.positions[src + 2]))
            let c = colour(fraction: (sample(field, at: p) ?? 0) / peak)
            let b = v * floatsPerVertex
            out[b] = c.x; out[b + 1] = c.y; out[b + 2] = c.z; out[b + 3] = c.w
            // flags stay zero — this view runs no fragment-side half-space test.
        }
        return out
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: ★ THE LEGEND

    /// ★ A PLOT WITHOUT A SCALE IS A PICTURE (maintainer, 2026-08-18: "Please
    /// also add a legend on the right edge"). These are the stops the bar draws
    /// and the ramp interpolates — ONE source, so the key cannot disagree with
    /// the surface it is a key to.
    public static let legendStops = 24

    /// The bar's colours, hot at the top, in the order a vertical legend draws.
    public static func legendColours() -> [SIMD4<Float>] {
        (0..<legendStops).map {
            colour(fraction: 1 - Double($0) / Double(legendStops - 1))
        }
    }

    /// ★ THE TICK LABELS, IN MPa. The field is von Mises in MPa, so the scale is
    /// ABSOLUTE — "where is the load going" is a shape question, but "is this
    /// near yield" is not, and a normalised 0…1 axis cannot answer the second.
    public static func legendTicks(peakMPa: Double, count: Int = 5) -> [String] {
        guard peakMPa.isFinite, peakMPa > 0, count > 1 else { return [] }
        return (0..<count).map { i in
            let v = peakMPa * (1 - Double(i) / Double(count - 1))
            return v >= 100 ? String(format: "%.0f", v)
                 : v >= 10 ? String(format: "%.1f", v)
                 : String(format: "%.2f", v)
        }
    }

    /// The field's own peak, in MPa — what the legend's top tick reads.
    public static func peakMPa(_ field: LatticeDemandField) -> Double {
        var peak = 0.0
        for v in field.vonMises { peak = Swift.max(peak, Double(v)) }
        return peak
    }
}
