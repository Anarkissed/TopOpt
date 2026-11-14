// FlexibleStageModel+Reached — round 7 · U21 batch F "One depth number" (DEPTH-LABEL + AUTO-CURVE; his notes of 2026-10-21).
//   His words, Img9: "I set the squish to 7 in the modal and it shows 14 next to the model, after saying it can't go that far....
//   Please ensure that these are consistent. If it can't go to a depth, ensure that the depth it reverts to is labelled correctly in
//   both areas." Img10: "Why can't 'auto' ever meet my curve? … What does it take to meet my curve?"
// ONE source for "how deep core builds this face": core's buildable depths (the same columns the card's warning counts — the
// pinched halves' segments when the face is pinched, core's own design otherwise). The chip, the card's line, the Prisms view's
// floor tags and the Auto pane's per-face line all read `reached(region:)`. His box keeps what he typed (ruling G: nothing
// app-side stands in as a limit; no clamp).

import Foundation
import TopOptKit

/// A pressed face core builds short of his Deepest squish.
public struct FlexibleReached: Equatable, Sendable {
    /// Core's deepest buildable squish over the face's columns (mm).
    public let reachedMM: Double
    /// His Deepest squish (the box; never changed).
    public let deepestMM: Double
    /// The columns core cannot meet (too firm, too soft, beyond the data) — the card's count.
    public let shortColumns: Int
}

extension FlexibleStageModel {
    /// How far short of his depth core builds `region`, or nil: not pressed, no lattice of its own, no design yet, a refusal, or
    /// core reaches his depth (within 0.05 mm) — then the chip and the tags keep their plain "7.0 mm".
    public func reached(region r: Int) -> FlexibleReached? {
        if Self.controlNoReached { return nil }
        if isManual { return nil }   // ★ MANUAL (M2): no "Reaches 0.6 of 7.0 mm" — core's design is not shown in Manual
        guard !noFacePrismKnown, let f = settings.face(r), f.isLoaded, hasOwnLattice(r), let k = key(r), let d = designs[k], d.refusal == nil
        else { return nil }
        let short = shortColumns(region: r)
        guard short > 0 else { return nil }
        var best = 0.0
        if let sg = segments[k] {
            for v in sg.buildableDepthMM { if let v { best = max(best, v) } }
        } else {
            let n = min(d.columns.count, stacks[k]?.columns.count ?? d.columns.count)
            for i in 0..<n {
                let c = d.columns[i]
                if c.status != "no_lattice", c.buildableOK, c.buildableDepthMM.isFinite { best = max(best, c.buildableDepthMM) }
            }
        }
        guard best < f.deepestMM - 0.05 else { return nil }
        return FlexibleReached(reachedMM: best, deepestMM: f.deepestMM, shortColumns: short)
    }

    /// Core's buildable depth where it falls short of his depth (the one number), nil otherwise.
    public func reachedDepthMM(region r: Int) -> Double? { reached(region: r)?.reachedMM }

    /// The columns of `region` core cannot meet — the card's count (a pinched face's halves, else core's own counts).
    public func shortColumns(region r: Int) -> Int {
        guard let k = key(r) else { return 0 }
        if let sg = segments[k] { return sg.status.filter { $0 == "too_soft" || $0 == "too_firm" || $0 == "beyond_data" }.count }
        return designs[k].map { $0.tooFirm + $0.tooSoft + $0.beyondData } ?? 0
    }

    /// The depth a face's number shows wherever it is written on the model (its chip, its Prisms tag): "7.0 mm", or "0.6 of
    /// 7.0 mm" when core builds short.
    public func depthLabel(region r: Int, deepestMM: Double) -> String {
        // ★ MANUAL (M2): the app's estimate from his lattice ("≈ 3.2 mm"), never his box nor core's buildable depth
        if isManual { return FlexibleManualCopy.chipText(estimate(region: r)) }
        return reached(region: r).map { FlexibleRowCopy.reachedOf($0.reachedMM, $0.deepestMM) } ?? String(format: "%.1f mm", deepestMM)
    }

    /// ★ AUTO-CURVE: what Auto's failure list says it takes, from core's own counts — the face or press with the most columns
    /// out of reach, and the direction its dominant count points (nil: Auto meets the curve, or core listed nothing).
    public func autoBlocker(_ r: FlexRecommendationInfo?) -> FlexibleRowCopy.AutoBlocker? {
        guard let r, !r.reachable else { return nil }
        let worst = r.failures.max { a, b in
            let na = a.tooFirm + a.tooSoft + a.beyondData, nb = b.tooFirm + b.tooSoft + b.beyondData
            return na != nb ? na < nb : a.face > b.face
        }
        guard let w = worst else { return nil }
        return FlexibleRowCopy.AutoBlocker(name: autoName(w.face), tooFirm: w.tooFirm, tooSoft: w.tooSoft, beyondData: w.beyondData)
    }

    /// A failure's region in his words: a press's piece → the press ("Edge 12"), a lattice section → its face ("Face 6"),
    /// else the face's name.
    func autoName(_ id: Int) -> String {
        if let p = (settings.presses ?? []).first(where: { $0.regions.contains(id) }), let label = p.strip?.label { return label }
        if let piece = regions.flexible?.piece(id) { return displayName(piece.rootRegion) }
        return displayName(id)
    }

    /// ★ RED CONTROL only (U21 batch F): today's labels — no reached depth anywhere (the chip's "7.0 mm", "Can't reach your
    /// curve on 4549 columns").
    nonisolated(unsafe) static var controlNoReached = false
}
