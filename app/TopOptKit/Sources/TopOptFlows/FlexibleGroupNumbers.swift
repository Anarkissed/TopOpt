// FlexibleGroupNumbers — beyond the eight group colours, a group's NUMBER (task
// 2026-09-29-flexible-screens, round 5 batch C5; his answer "Add more colour tokens", and the lead's
// "beyond the palette, cycle and show the group number on the tab and the faces").
//
// ★ WHEN: a group whose colour another group ALSO wears (group 9 wears group 1's green, group 10
// group 2's pink, …) shows its number — on its rail tab (the tab's dot becomes a disc with the
// number) and on each of its faces on the part. Only there: with eight groups or fewer every colour
// is its own (a pick another group wears SWAPS), so nothing is numbered — only what is necessary.
// The rule keys on the colours, never on a count, so an old file whose stored picks make two groups
// share is numbered too.
// ★ ON THE FACE THE NUMBER IS PAINTED INTO THE MAP, like the frame: the digits (a 3 × 5 font, one
// font pixel = `scale` columns) in the group's colour on a plate of the frame's near-black, written
// into the same per-column tints FlexibleGroupFrames paints. So it MOVES WITH THE DENT, is depth-
// tested, never ghosts, and is on both pages in every view and every "Play all" turn (D-R5-X1) for
// free. (A first cut drew SwiftUI discs over the part: on the C5 render a disc at a face's middle
// hung 15–20 mm above a ×5 dent and read as the wall BEHIND it — a disc cannot ride the dent frame by
// frame, the main page's loop runs inside the renderer.)
// ★ WHERE: the plate sits wholly on the face's heat — inside the frame and its gap — where the face
// squishes LEAST (the least summed drawn squish under it: it covers the dull part of the map, never
// the peak), the nearest to the face's middle among equals. Its UP is the part's up as it stands
// (the settle's −gravity) laid into the face; on a face that up is normal to (a top), the direction
// away from the default camera. Read from OUTSIDE the part (right × up = out of the face).
// The plate shrinks (a smaller scale) until it fits; a face too small for one stays unnumbered (its
// frame and the rail still say which group).

import SwiftUI
import simd
import TopOptDesign
import TopOptKit

public enum FlexibleGroupNumbers {

    /// The number's ink on every group colour (≥ 4.5 : 1 on each — FlexibleGroupPaletteTests).
    public static let ink = DS.Color.background
    /// A rail tab's numbered dot (pt).
    public static let railSize: CGFloat = 18

    /// The SHOWN numbers of the groups whose colour another group also wears.
    public static func shared(in s: FlexibleStageSettings) -> Set<Int> {
        let gs = FlexibleSqueezeGroups.groups(s)
        var byColour: [FlexibleGroupColour: [Int]] = [:]
        for g in gs { byColour[FlexibleSqueezeGroups.colourChoice(of: g, in: s), default: []].append(g.number) }
        return Set(byColour.values.filter { $0.count > 1 }.flatMap { $0 })
    }

    /// The number a group's rail tab shows in its dot (nil: a plain dot — its colour is its own).
    public static func railNumber(_ g: FlexibleSqueezeGroup, in s: FlexibleStageSettings) -> Int? {
        shared(in: s).contains(g.number) ? g.number : nil
    }

    // MARK: - the digits

    /// 3 × 5 digits, rows top to bottom ("1" lit).
    static let font: [Character: [String]] = [
        "0": ["111", "101", "101", "101", "111"], "1": ["010", "110", "010", "010", "111"],
        "2": ["111", "001", "111", "100", "111"], "3": ["111", "001", "111", "001", "111"],
        "4": ["101", "101", "111", "001", "001"], "5": ["111", "100", "111", "001", "111"],
        "6": ["111", "100", "111", "101", "111"], "7": ["111", "001", "010", "010", "010"],
        "8": ["111", "101", "111", "101", "111"], "9": ["111", "101", "111", "001", "111"],
    ]

    /// `number` as font pixels: rows top to bottom, one blank column between digits.
    static func bitmap(_ number: Int) -> [[Bool]] {
        let glyphs = String(number).compactMap { font[$0] }
        return (0..<5).map { row in
            var out: [Bool] = []
            for (i, g) in glyphs.enumerated() {
                if i > 0 { out.append(false) }
                out += g[row].map { $0 == "1" }
            }
            return out
        }
    }

    /// A grid step (iu, iv).
    struct Step: Equatable { let du: Int, dv: Int }

    /// The plate's RIGHT and UP as grid steps: up = the ±u / ±v axis nearest `up` laid into the face
    /// (`fallback` where the face is nearly normal to it), right = up × out (read from outside).
    static func axes(_ st: FlexStackInfo, up: SIMD3<Double>, fallback: SIMD3<Double>) -> (right: Step, up: Step) {
        let out = -simd_normalize(st.load)
        func inPlane(_ v: SIMD3<Double>) -> SIMD3<Double> { v - simd_dot(v, out) * out }
        var u = inPlane(up)
        if simd_length(u) < 0.3 * max(1e-12, simd_length(up)) { u = inPlane(fallback) }
        let dirs: [(Step, SIMD3<Double>)] = [(Step(du: 1, dv: 0), st.xAxis), (Step(du: -1, dv: 0), -st.xAxis),
                                            (Step(du: 0, dv: 1), st.yAxis), (Step(du: 0, dv: -1), -st.yAxis)]
        let t = dirs.max { simd_dot($0.1, u) < simd_dot($1.1, u) }!
        let r = simd_cross(t.1, out)
        let rs = dirs.max { simd_dot($0.1, r) < simd_dot($1.1, r) }!
        return (rs.0, t.0)
    }

    /// The plate on one face: column index → lit (a digit) or not (the plate's near-black). nil when
    /// no plate fits on the face's heat. `squish`: the drawn map per column (the least is covered).
    static func plate(_ number: Int, _ st: FlexStackInfo, right r: Step, up t: Step, squish: [Double]?) -> [Int: Bool]? {
        let bmp = bitmap(number)
        guard let w = bmp.first?.count, w > 0, !st.columns.isEmpty else { return nil }
        let d = FlexibleGroupFrames.distances(st)
        let clear = FlexibleGroupFrames.width(nu: st.nu, nv: st.nv) + (FlexibleGroupFrames.hasGap(nu: st.nu, nv: st.nv) ? 1 : 0)
        func heat(_ iu: Int, _ iv: Int) -> Int? {
            let c = st.column(iu, iv)
            return c >= 0 && c < d.count && d[c] > clear && d[c] != Int.max ? c : nil
        }
        let meanU = Double(st.columns.map(\.iu).reduce(0, +)) / Double(st.columns.count)
        let meanV = Double(st.columns.map(\.iv).reduce(0, +)) / Double(st.columns.count)
        let biggest = max(1, Int(0.2 * Double(min(st.nu, st.nv)) / 5))   // the digits ≈ a fifth of the face's shorter side
        for s in stride(from: biggest, through: 1, by: -1) {
            let pw = w * s + 2 * s, ph = 5 * s + 2 * s           // the plate: the digits and a one-pixel rim
            var best: (cost: Double, dist: Double, cells: [Int: Bool])?
            for iv0 in 0..<st.nv { for iu0 in 0..<st.nu {
                // (iu0, iv0) is the plate's top-left in font space: a → right, b → down (−up)
                var cells: [Int: Bool] = [:], cost = 0.0, fits = true
                outer: for b in 0..<ph { for a in 0..<pw {
                    let iu = iu0 + a * r.du - b * t.du, iv = iv0 + a * r.dv - b * t.dv
                    guard let c = heat(iu, iv) else { fits = false; break outer }
                    let fx = a - s, fy = b - s
                    let lit = fx >= 0 && fy >= 0 && fx < w * s && fy < 5 * s && bmp[fy / s][fx / s]
                    cells[c] = lit
                    cost += squish.map { $0.indices.contains(c) ? $0[c] : 0 } ?? 0
                } }
                guard fits else { continue }
                let cu = Double(iu0) + Double(pw - 1) / 2 * Double(r.du) - Double(ph - 1) / 2 * Double(t.du)
                let cv = Double(iv0) + Double(pw - 1) / 2 * Double(r.dv) - Double(ph - 1) / 2 * Double(t.dv)
                let dist = (cu - meanU) * (cu - meanU) + (cv - meanV) * (cv - meanV)
                if best == nil || cost < best!.cost - 1e-9 || (abs(cost - best!.cost) <= 1e-9 && dist < best!.dist) {
                    best = (cost, dist, cells)
                }
            } }
            if let b = best { return b.cells }
        }
        return nil
    }

    /// The model's up (the part as it stands: −gravity after the settle) and the fallback for a face
    /// normal to it (away from the default camera), both in MODEL space.
    @MainActor
    static func upAndFallback(_ m: FlexibleStageModel) -> (SIMD3<Double>, SIMD3<Double>) {
        let settle = m.project.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let inv = settle.inverse
        let up = inv.act(SIMD3<Float>(0, 1, 0)), away = inv.act(SIMD3<Float>(0, 0, -1))
        return (SIMD3<Double>(Double(up.x), Double(up.y), Double(up.z)), SIMD3<Double>(Double(away.x), Double(away.y), Double(away.z)))
    }

    /// Paint every numbered group's plates into `t` (8 floats per flat vertex of `o`'s mesh), opaque and
    /// never ghosted, as the frames are. Returns how many columns were lit (for the tests).
    @MainActor @discardableResult
    static func paint(_ t: inout [Float], overlay o: FlexibleOverlayMesh, model m: FlexibleStageModel) -> Int {
        let s = m.settings
        let numbered = shared(in: s)
        guard !numbered.isEmpty else { return 0 }
        let (up, fallback) = upAndFallback(m)
        let n = t.count / 8
        var lit = 0
        for g in FlexibleSqueezeGroups.groups(s) where numbered.contains(g.number) {
            let c = FlexibleColours.token(FlexibleSqueezeGroups.colourChoice(of: g, in: s).rgba, 1)
            for r in g.regions {
                guard let k = m.key(r), let st = m.stacks[k], let start = o.flatStart[k] else { continue }
                let ax = axes(st, up: up, fallback: fallback)
                guard let cells = plate(g.number, st, right: ax.right, up: ax.up, squish: m.liveS[k]) else { continue }
                for (i, on) in cells {
                    let col = on ? c : FlexibleGroupFrames.gapColour
                    if on { lit += 1 }
                    for j in 0..<6 {
                        let v = start + i * 6 + j
                        guard v < n else { break }
                        t[v * 8] = col.x; t[v * 8 + 1] = col.y; t[v * 8 + 2] = col.z; t[v * 8 + 3] = col.w
                        t[v * 8 + 5] = 1   // opaque, like the map
                        t[v * 8 + 6] = 0   // never the X-ray ghost
                    }
                }
            }
        }
        return lit
    }
}

/// The rail tab's numbered dot: the group's colour with its number in the stage's near-black, ringed
/// in near-black (the frame's own gap).
struct FlexibleGroupNumberDisc: View {
    let colour: RGBA
    let number: Int
    var size: CGFloat = FlexibleGroupNumbers.railSize
    var body: some View {
        Circle().fill(colour.color)
            .overlay(Circle().strokeBorder(DS.Color.chipSolid.color, lineWidth: 1.5))
            .overlay(Text("\(number)")
                .font(.system(size: size * 0.55, weight: .bold, design: .rounded))
                .foregroundStyle(FlexibleGroupNumbers.ink.color)
                .lineLimit(1).minimumScaleFactor(0.6)
                .padding(.horizontal, 2))
            .frame(width: size, height: size)
            .accessibilityLabel(FlexibleRowCopy.groupName(number))
    }
}
