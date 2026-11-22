// StageFloor.swift — ★ his iPad notes 2026-11-22 (img 44, 45): "The grid in the background does not line up correctly. This is
// the same issue across the entire app. It gets worse when the angle changes. Please fix this; ensure the grid is a perfect
// square, broken down into smaller perfect squares."
//
// Two grids were drawn: the stage's floor grid (`stage_fragment`, 2% of the part BELOW the part, lines at world multiples of
// extent/6) and, once gravity was set, the ground pass's line grid (just under the part, centred on the part, the same step):
// two grids at two heights and two phases, which slid against each other as the view turned. Now there is ONE floor, drawn by
// the stage alone: one height (the settled part's lowest point: it rests on it), one origin (the world's), square cells of a
// round size (1, 2 or 5 × 10ⁿ mm, from the part's size, never the camera's), and every 5th line a major one, so each major
// square is exactly 5 × 5 small squares.
import simd

struct StageFloor: Equatable {
    /// World height of the floor: the settled part's lowest point.
    var y: Float
    /// The floor's centre (x, z): the part's, where the grid's fade is measured from.
    var centre: SIMD2<Float>
    /// The part's larger footprint side (mm).
    var extent: Float
    /// The small squares' side (mm): 1, 2 or 5 × 10ⁿ.
    var minor: Float
    /// Small squares along a major square's side: a major line is exactly every 5th small line.
    static let minorPerMajor: Float = 5
    /// The major squares' side (mm).
    var major: Float { minor * Self.minorPerMajor }
    /// Where the grid has faded out (as before: six part sizes from the centre).
    var fadeRadius: Float { extent * 6 }

    init(y: Float, centre: SIMD2<Float>, extent: Float) {
        self.y = y; self.centre = centre; self.extent = extent
        minor = Self.minorSpacing(extent: extent)
    }

    /// The small squares' side for a part `extent` mm across: the largest of 1, 2, 5 × 10ⁿ mm that is at most a fifth of it
    /// (so a major square is at most the part's size). A real size, and the same while the part's size moves a little.
    static func minorSpacing(extent: Float) -> Float {
        let t = Double(extent) / 5
        guard t.isFinite, t > 0 else { return 1 }
        let eps = 1e-9
        var p = pow(10, floor(log10(t)))
        if p * 10 <= t * (1 + eps) { p *= 10 }   // log10 rounding at an exact power of ten
        if p > t * (1 + eps) { p /= 10 }
        for m in [5.0, 2.0, 1.0] where m * p <= t * (1 + eps) { return Float(m * p) }
        return Float(p)
    }

    /// The floor under a part: its settled footprint box (`lo`/`hi`, world) for the centre and size, and its lowest point —
    /// a hair below it (a ten-thousandth of the part, at least 0.001 mm), so the part's own underside never fights the shadow
    /// drawn on the floor.
    static func under(lo: SIMD3<Float>, hi: SIMD3<Float>, lowest: Float) -> StageFloor {
        let extent = Swift.max(hi.x - lo.x, hi.z - lo.z, 1e-3)
        return StageFloor(y: lowest - Swift.max(extent * 1e-4, 1e-3), centre: SIMD2((lo.x + hi.x) * 0.5, (lo.z + hi.z) * 0.5),
                          extent: extent)
    }

    /// The lowest world y of `positions` (xyz per vertex) under `model`: the part's own lowest point, not its box's corner
    /// (a part settled on a tilted face would float above a box corner's floor). nil: no vertices.
    static func lowest(positions: [Float], model: simd_float4x4) -> Float? {
        guard positions.count >= 3 else { return nil }
        let r = SIMD4<Float>(model.columns.0.y, model.columns.1.y, model.columns.2.y, model.columns.3.y)
        var y = Float.greatestFiniteMagnitude
        var i = 0
        while i + 2 < positions.count {
            y = Swift.min(y, r.x * positions[i] + r.y * positions[i + 1] + r.z * positions[i + 2] + r.w)
            i += 3
        }
        return y
    }
}
