// StageFloor.swift — ★ his iPad notes 2026-11-22 (img 44, 45): "The grid in the background does not line up correctly. This is
// the same issue across the entire app. It gets worse when the angle changes. Please fix this; ensure the grid is a perfect
// square, broken down into smaller perfect squares."
//
// Two grids were drawn: the stage's floor grid (`stage_fragment`, 2% of the part BELOW the part, lines at world multiples of
// extent/6) and, once gravity was set, the ground pass's line grid (just under the part, centred on the part, the same step):
// two grids at two heights and two phases, which slid against each other as the view turned. Now there is ONE floor, drawn by
// the stage alone: one height (the settled part's lowest point: it rests on it), one origin (the world's), square cells.
//
// ★ his iPad notes 2026-11-23 (on release 15), item 4: "Can you make the grid an infinitely shrinking view of squares? So I want
// to be able to see more and more squares the more I zoom in. And when I zoom out, it should hide the smallest of the squares."
// The squares are now powers of ten millimetres (… 0.1, 1, 10, 100 mm …), each split into 10 × 10 of the next finer — graph
// paper, the sizes a designer reads off a ruler (5 would give 25 mm and 125 mm squares nobody measures in). Which squares show
// depends on how much floor one pixel covers there (the zoom, and the distance along the floor): a level fades in once its
// squares are `firstShowsPx` pixels across, grows into a major line two decades later, and the finest fades out again as he
// zooms out — smoothly, never a pop. Lines stay one pixel wide at every level. Still ONE grid of perfect squares from the
// world's origin: every finer square lies exactly inside the coarser one, lined up at every angle.
//
// ★ item 1 (img 49): "At perfectly straight on, the background becomes this blue haze instead of showing a flat floor line and
// keeping the same black background." A level view looks at the floor edge-on (the orthographic view's rays are all level):
// the horizon glow, meant as a soft band near the horizon, covered the whole screen. Now the glow follows how much of the floor
// is seen as a plane (`planeWeight`, from the view's elevation), and a level view draws the floor as one thin line on the same
// black background.
import simd

struct StageFloor: Equatable {
    /// World height of the floor: the settled part's lowest point.
    var y: Float
    /// The floor's centre (x, z): the part's, where the grid's fade is measured from.
    var centre: SIMD2<Float>
    /// The part's larger footprint side (mm).
    var extent: Float
    /// Where the grid has faded out (as before: six part sizes from the centre).
    var fadeRadius: Float { extent * 6 }

    /// ★ notes24 item 4: each square splits into `split` × `split` squares of the next finer level.
    static let split: Float = 10
    /// The size the levels count from: level n's squares are `unit` × 10ⁿ mm (1 mm, 10 mm, 0.1 mm …).
    static let unit: Float = 1
    /// A level starts to show once its squares are this many pixels across (finer: a mat of lines, hidden).
    static let firstShowsPx: Float = 8
    /// A line's strength: the finest level's (`minorAlpha`) and a major line's (`majorAlpha`), as release 14 drew them.
    static let minorAlpha: Float = 0.16
    static let majorAlpha: Float = 0.50

    init(y: Float, centre: SIMD2<Float>, extent: Float) {
        self.y = y; self.centre = centre; self.extent = extent
    }

    /// A level's line strength by its rank: how many decades its squares are above the finest that can show (`ρ = n − ℓ`,
    /// ℓ = log10(pixelMM × firstShowsPx / unit)). 0 below 0; up to the minor strength by 0.6 (its squares 4 × the first size);
    /// up to a major line from 1 to 2 (ten to a hundred times it). Continuous in ρ, so the zoom never pops a line.
    /// The shader's `levelStrength` is this.
    static func strength(rank r: Float) -> Float {
        minorAlpha * smooth(0, 0.6, r) + (majorAlpha - minorAlpha) * smooth(1, 2, r)
    }

    /// The three levels drawn where one pixel covers `pixelMM` mm of floor, finest first: their squares' side (mm) and their
    /// lines' strength. A coarser level than these draws only lines these already draw (at the major strength).
    static func levels(pixelMM: Float) -> [(sideMM: Float, strength: Float)] {
        let l = log10f(Swift.max(pixelMM, 1e-12) * firstShowsPx / unit)
        let n0 = l.rounded(.up)
        let r0 = n0 - l
        return (0..<3).map { k in (unit * powf(10, n0 + Float(k)), strength(rank: r0 + Float(k))) }
    }

    /// The line strength at the floor point `xzMM` where a pixel covers `pixelMM` mm (one pixel wide lines, anti-aliased as
    /// the shader's `gridMask` does): the strongest of the levels drawn there. The CPU mirror of the shader, for the tests.
    static func lineStrength(atMM xz: SIMD2<Double>, pixelMM: Float) -> Float {
        var a: Float = 0
        for lv in levels(pixelMM: pixelMM) {
            let s = Double(lv.sideMM)
            func mask(_ c: Double) -> Double {
                let f = (c / s) - 0.5
                let g = abs((f - f.rounded(.down)) - 0.5) / (Double(pixelMM) / s)
                return 1 - Swift.min(g, 1)
            }
            a = Swift.max(a, lv.strength * Float(Swift.max(mask(xz.x), mask(xz.y))))
        }
        return a
    }

    /// ★ notes24 item 1: how much of the floor is seen as a plane, by the view's elevation (its sine, either side): 1 from
    /// about 10° up or down, 0 within about 2° of level, where the floor is seen edge-on. The horizon glow is scaled by it;
    /// the floor's edge-on line by what is left.
    static func planeWeight(elevationSine e: Float) -> Float {
        smooth(sinf(2 * .pi / 180), sinf(10 * .pi / 180), abs(e))
    }
    /// RED CONTROL (tests): the glow as before 11-23, whatever the elevation (the level view's blue haze).
    nonisolated(unsafe) static var controlHazeAtLevel = false

    /// The horizon glow's half width, in the ray's |y|: 0.14 through the lens; through the orthographic telephoto (whose rays
    /// all lie within half a degree of the view's own) the same share of the picture, so it never covers the whole screen.
    static func glowBand(drawFovY: Float, fovY: Float) -> Float {
        0.14 * tanf(drawFovY * 0.5) / Swift.max(tanf(fovY * 0.5), 1e-6)
    }

    private static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = Swift.min(Swift.max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
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
