// FlexibleGroupColours — each squeeze group's OWN colour, chosen in its folder tab and worn by its
// faces on the model body, on the Settings page AND the main Flexible page (task
// 2026-09-29-flexible-screens, round 5 batch S1; his img 1: "The different groups should have
// different coloured faces on the model body, assigned in the settings modal." — and: "This should
// be in the settings page too").
//
// ★ THE PALETTE: four DS tokens, never purple (purple is the depth prism) — green, orange, red,
// blue. They stay apart from each other and read on the dark stage. BLUE IS LAST: the dent heat is
// deep blue → cyan → white (DS accentDeep → accentCyan → textPrimary), so a blue frame would sink
// into its own map; the first three groups never meet it by default. Cyan (the resting faces) and
// white (the selected face) are taken.
// ★ STORED PER GROUP (FlexibleStageSettings.groupColours, by the group's stored number); a new group
// takes the first colour no other group wears; picking a colour another group wears SWAPS the two
// (each group keeps its own); renumbering (a group removed) carries each colour with its group
// (FlexibleSqueezeGroups.normalise). Display only — never the lattice's key.
// ★ HOW THE COLOUR AND THE DENT HEAT SHARE A FACE (FlexibleGroupFrames): the pressed face's body IS
// its heat map (the overlay replaces the face with its column quads), so the heat keeps the inside
// and the group colour FRAMES it — a band of the face's outermost columns in the group colour, then
// one column of the stage's near-black between the frame and the heat. The frame reads at a glance
// in every view: a uniform band with a dark gap is nothing the heat ramp (or a rainbow) draws; it
// follows the face's own outline (a split sector is framed along its cut); it is opaque, so X-ray
// never ghosts it; it moves with the dent (same quads). A pressed face with no map yet takes the
// group colour on its body (FlexiblePageChannels' region tint).

import Foundation
import simd
import TopOptDesign
import TopOptKit

public enum FlexibleGroupColour: String, CaseIterable, Codable, Sendable, Identifiable {
    case green, orange, red, blue

    public var id: String { rawValue }

    /// The DS token.
    public var rgba: RGBA {
        switch self {
        case .green: return DS.Color.accentGreen
        case .orange: return DS.Color.warning
        case .red: return DS.Color.danger
        case .blue: return DS.Color.accent
        }
    }

    public var name: String { rawValue.capitalized }

    /// The default for group `number` (1-based): green, orange, red, blue, then round again.
    public static func byNumber(_ number: Int) -> FlexibleGroupColour {
        allCases[(max(1, number) - 1) % allCases.count]
    }
}

extension FlexibleSqueezeGroups {

    /// The colour group `g` wears in `s`: its stored pick, else its number's default.
    public static func colourChoice(of g: FlexibleSqueezeGroup, in s: FlexibleStageSettings) -> FlexibleGroupColour {
        s.groupColours?[String(g.id)].flatMap(FlexibleGroupColour.init(rawValue:)) ?? .byNumber(g.number)
    }

    /// The colour of the group SHOWN as `number` (the player's sims are numbered) in `s`.
    public static func colour(number: Int, in s: FlexibleStageSettings) -> RGBA {
        groups(s).first { $0.number == number }.map { colourChoice(of: $0, in: s).rgba } ?? FlexibleGroupColour.byNumber(number).rgba
    }

    /// Give group `id` the colour `c`; a group already wearing `c` takes `id`'s old colour (a swap).
    /// ★ S VERIFICATION: stored in NORMAL FORM (`canonical`) — re-picking the swatch a group wears,
    /// or picking another and then the original, leaves the settings EQUAL to before (the exit
    /// button said "Save & Exit" with nothing visibly changed).
    public static func setColour(_ c: FlexibleGroupColour, group id: Int, in s: inout FlexibleStageSettings) {
        let gs = groups(s)
        guard let g = gs.first(where: { $0.id == id }) else { return }
        let old = colourChoice(of: g, in: s)
        var map = s.groupColours ?? [:]
        for other in gs where other.id != id && colourChoice(of: other, in: s) == c {
            map[String(other.id)] = old.rawValue
        }
        map[String(id)] = c.rawValue
        s.groupColours = canonical(map, groups: gs)
    }

    /// ★ S VERIFICATION: the stored picks in normal form — only a colour that DIFFERS from its
    /// group's default (its number's), only for a group that exists; nil when none is left. Two
    /// settings that show the same colours are then equal.
    static func canonical(_ map: [String: String]?, groups gs: [FlexibleSqueezeGroup]) -> [String: String]? {
        guard let map, !map.isEmpty else { return nil }
        var out: [String: String] = [:]
        for g in gs {
            guard let v = map[String(g.id)], let c = FlexibleGroupColour(rawValue: v), c != .byNumber(g.number) else { continue }
            out[String(g.id)] = v
        }
        return out.isEmpty ? nil : out
    }

    /// The first colour no group in `s` wears (a new group's), else its number's default.
    public static func freeColour(in s: FlexibleStageSettings, forNumber n: Int) -> FlexibleGroupColour {
        let worn = Set(groups(s).map { colourChoice(of: $0, in: s) })
        return FlexibleGroupColour.allCases.first { !worn.contains($0) } ?? .byNumber(n)
    }

    /// Carry each group's colour to its new number (`rank`: old stored id → new number); a group
    /// that no longer exists drops its colour. nil when nothing is stored.
    static func remapColours(_ colours: [String: String]?, rank: [Int: Int]) -> [String: String]? {
        guard let colours, !colours.isEmpty else { return colours }
        var out: [String: String] = [:]
        for (k, v) in colours {
            guard let old = Int(k), let n = rank[old] else { continue }
            out[String(n)] = v
        }
        return out.isEmpty ? nil : out
    }

    /// ★ S VERIFICATION: each group's colour AS IT IS SHOWN, by stored id — its pick, else the
    /// default of the number it is shown as. Every edit ends in `normalise`, so before an edit the
    /// stored ids ARE the shown numbers; `normalise` carries these (not only the stored picks), so
    /// a group that never had a pick keeps its colour too when an earlier group goes (a group
    /// made before round 5 changed colour there).
    static func shownColours(_ s: FlexibleStageSettings, ids: [Int]) -> [String: String] {
        var out: [String: String] = [:]
        for id in ids {
            out[String(id)] = s.groupColours?[String(id)].flatMap(FlexibleGroupColour.init(rawValue:))?.rawValue
                ?? FlexibleGroupColour.byNumber(id).rawValue
        }
        return out
    }
}

extension FlexibleStageModel {

    /// ★ S1: the colour group `g` wears (its pick, else its number's).
    public func groupColour(_ g: FlexibleSqueezeGroup) -> RGBA {
        FlexibleSqueezeGroups.colourChoice(of: g, in: settings).rgba
    }
    /// ★ S1: the colour of the group SHOWN as `number` (the player's sims, the list's dots).
    public func groupColour(number: Int) -> RGBA { FlexibleSqueezeGroups.colour(number: number, in: settings) }

    /// ★ S1: his pick in the group's folder tab (a colour another group wears swaps with it).
    /// Display only: the designs are not re-run and the lattice stays current.
    public func setGroupColour(_ groupID: Int, _ c: FlexibleGroupColour) {
        edit({ s in FlexibleSqueezeGroups.setColour(c, group: groupID, in: &s) }, recompute: false)
    }
}

/// ★ S1: the group colour's FRAME round each pressed face's map (see the file comment).
@MainActor
public enum FlexibleGroupFrames {

    /// The frame's width in columns: about 3 % of the face's longer side, at least one column — and
    /// never more than an eighth of its SHORTER side (a 64 × 13 side face keeps its heat).
    nonisolated static func width(nu: Int, nv: Int) -> Int {
        max(1, min(Int((0.03 * Double(max(nu, nv))).rounded()), min(nu, nv) / 8))
    }
    /// The dark gap only where the face has room for it (16 columns across its shorter side).
    nonisolated static func hasGap(nu: Int, nv: Int) -> Bool { min(nu, nv) >= 16 }

    /// How far each column is from the face's outline (1 = on it), in columns (8-neighbour steps
    /// through the face's own columns from a cell outside the face).
    nonisolated static func distances(_ st: FlexStackInfo) -> [Int] {
        var d = [Int](repeating: Int.max, count: st.columns.count)
        var queue: [Int] = []
        for (i, c) in st.columns.enumerated() {
            var edge = false
            for dv in -1...1 { for du in -1...1 where du != 0 || dv != 0 {
                if st.column(c.iu + du, c.iv + dv) < 0 { edge = true }
            } }
            if edge { d[i] = 1; queue.append(i) }
        }
        var head = 0
        while head < queue.count {
            let i = queue[head]; head += 1
            let c = st.columns[i]
            for dv in -1...1 { for du in -1...1 where du != 0 || dv != 0 {
                let j = st.column(c.iu + du, c.iv + dv)
                guard j >= 0, j < d.count, d[j] > d[i] + 1 else { continue }
                d[j] = d[i] + 1
                queue.append(j)
            } }
        }
        return d
    }

    /// Per column: the frame's colour band (`.frame`), the dark gap inside it (`.gap`), or the heat.
    enum Band: Equatable { case frame, gap, heat }
    nonisolated static func bands(_ st: FlexStackInfo) -> [Band] {
        let w = width(nu: st.nu, nv: st.nv), gap = hasGap(nu: st.nu, nv: st.nv)
        return distances(st).map { d in d <= w ? .frame : (gap && d == w + 1 ? .gap : .heat) }
    }

    /// The dark between the frame and the heat: the stage's own near-black.
    static let gapColour = FlexibleColours.token(DS.Color.chipSolid, 1)

    /// Paint every pressed face's frame, in its group's colour, into `tints` (8 floats per flat
    /// vertex of `overlay`'s mesh): opaque (flags.y = 1), never ghosted (flags.z = 0).
    static func paint(_ tints: inout [Float]?, overlay: FlexibleOverlayMesh?, model m: FlexibleStageModel) {
        guard var t = tints, let o = overlay else { return }
        paint(&t, overlay: o, model: m)
        tints = t
    }

    static func paint(_ t: inout [Float], overlay o: FlexibleOverlayMesh, model m: FlexibleStageModel) {
        let n = t.count / 8
        let s = m.settings
        for g in FlexibleSqueezeGroups.groups(s) {
            let c = FlexibleColours.token(FlexibleSqueezeGroups.colourChoice(of: g, in: s).rgba, 1)
            for r in g.regions {
                guard let k = m.key(r), let st = m.stacks[k], let start = o.flatStart[k] else { continue }
                for (i, b) in bands(st).enumerated() where b != .heat {
                    let col = b == .frame ? c : gapColour
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
    }
}
