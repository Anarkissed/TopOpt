// FlexibleFaceStatsPopover — the (i) beside each face on the main Flexible page (task 2026-09-29-flexible-screens, round 7,
// batch R7-D2; his change (b) to B1, 2026-10-14: "I want an (i) next to each face that will show the details of the
// lattice that was in the previous design", and his correction the same day: "The per-face (i) shows ONLY: Cell, Density,
// Strut, Cells across. (Not Hands over, As lattice or Saved.)"; the reviewer's (e): the caption "The current preview's
// numbers at this depth." yes).
//
// ★ THE NUMBERS ARE THE LATTICE HE SEES (the review of R7-D2, 2026-10-18). R7-D2 built them from #354's slab card (the
// barrier preview's octet, `face_slab_preview`): "Cell 5.00 mm, Density 5 %" beside a legend that read "15 % · ≈8.7 mm …
// 21 % · ≈6.7 mm" for the same face — two numbers for one thing, his img1 complaint ("they should *always* be equal"), and
// the caption "The current preview's numbers at this depth." untrue. Now `rows(lattice:regions:depthMM:)` reads the
// Flexible lattice DRAWN inside that face's own prism (its include region(s), `LatticeRegionMask.contains`, over the
// lattice mask's voxels — the legend's own sample set): Density = the median ρ there, Cell = the cell drawn at that ρ
// (`FlexibleProbe.drawnCell`, the legend's formula, "≈" inside a blend) with its family, Strut = the wall it is drawn with,
// Cells across = depth ÷ cell. It holds FACTS, never a setting. No lattice yet (or no voxel of it in the face's prism) →
// "No numbers yet for this face". An Off face has no (i). No grams anywhere (his answer: hidden until core reports the real
// per-face lattice weight). `rows(card:…)` (#354's drawer) stays only as the tests' red control.

import SwiftUI
import TopOptDesign

public enum FlexibleFaceStats {
    /// His four, in the drawer's order.
    public static let labels = ["Cell", "Density", "Strut", "Cells across"]

    public struct Rows: Equatable, Sendable {
        public let rows: [LatticeDrawerRow]
        /// The drawer's estimate note under Cells across ("estimate, core checks it"), when it is the bake's estimate.
        public let note: String?
        /// ★ REVIEW OF R7-D2: the numbers behind the rows (the face's density and drawn cell), for the tests.
        public var rho: Double? = nil
        public var cellMM: Double? = nil
    }

    /// ★ REVIEW OF R7-D2: the (i)'s rows from the Flexible lattice drawn inside the face's own prism (`regions`: its include
    /// region(s) — a face cut into sections has one per section). nil without a voxel of the lattice in it.
    /// ★ ROUND 7: a voxel whose centre is outside the part is not counted (the mask now reaches past the surface);
    /// `countOutside` is a test's control only (the rule before).
    /// ★ R7-E1 (the top-lid fix's check): "outside" is CORE's own rule, as the mask decides it — the voxels the fill added
    /// (`FlexibleLatticeInputs.coreOutside`, coreEncloses) — not the app's voxel-made SDF, which reads part of the outermost
    /// voxel near an edge as outside (four of core's own voxels under his pad's Top edge at Fine) and called added voxels
    /// inside where the SDF rounds. `outsideBySDF` is a test's RED CONTROL only (0d8ae925's rule).
    public static func rows(lattice f: FlexibleLatticeInputs, regions: [LatticeRegionSpec], depthMM: Double,
                            countOutside: Bool = false, outsideBySDF: Bool = false) -> Rows? {
        guard !regions.isEmpty else { return nil }
        let m = f.mask
        let same = m.nx == f.rho.nx && m.ny == f.rho.ny && m.nz == f.rho.nz
        func sample(_ inside: (SIMD3<Double>) -> Bool) -> [Float] {
            var out: [Float] = []
            for n in 0..<m.values.count where m.values[n] >= 0.5 {
                let p = m.c0 + SIMD3<Float>(Float(n % m.nx), Float((n / m.nx) % m.ny), Float(n / (m.nx * m.ny))) * m.spacing
                // ★ ROUND 7 (his 2026-10-18 report): the mask now reaches past the surface (FlexibleLatticeBuilder.inputs) —
                // a voxel whose centre is outside the part is no lattice of the face's, so it is not counted. ★ R7-E1:
                // outside by core's rule (the voxels the fill added), not the app's SDF
                if !countOutside {
                    if outsideBySDF { guard FlexibleLatticeField.dPart(p, f) <= 0 else { continue } }
                    else if f.coreOutside.contains(n) { continue }   // (indexed on the mask grid)
                }
                guard inside(SIMD3<Double>(p)) else { continue }
                out.append(same ? f.rho.values[n] : f.rho.sample(p))
            }
            return out
        }
        // the lattice's own voxels in the face's prism (its slab where one was built), else anywhere in the declared prism
        var rhos = sample { p in regions.contains { LatticeRegionMask.contains(p, region: $0) } }
        if rhos.isEmpty { rhos = sample { p in regions.contains { LatticeRegionMask.contains(p, region: $0) } } }   // ★ SYNC #354 (89af86dd) COMPILE FIX ONLY: 2353efb4 folded containsWholePrism into contains (the lattice always fills the whole prism)
        guard !rhos.isEmpty else { return nil }
        rhos.sort()
        let rho = Double(rhos[rhos.count / 2])
        let cell = FlexibleProbe.drawnCell(rho: rho, f)
        let family = f.topology == .honeycomb ? "Honeycomb" : "Gyroid"
        let across = cell.mm > 0 ? depthMM / cell.mm : 0
        let rows = [LatticeDrawerRow(label: "Cell", value: String(format: "%@%.1f mm · %@", cell.blended ? "≈" : "", cell.mm, family)),
                    LatticeDrawerRow(label: "Density", value: String(format: "%.0f%%", rho * 100)),
                    LatticeDrawerRow(label: "Strut", value: String(format: "%.2f mm", Double(f.wallMM))),
                    LatticeDrawerRow(label: "Cells across", value: String(format: "%.1f", across))]
        var out = Rows(rows: rows, note: nil)
        out.rho = rho
        out.cellMM = cell.mm
        return out
    }

    /// The (i)'s rows for one face — #354's drawer for that card at that depth, his four rows only; nil without a card.
    public static func rows(card: LatticeFaceCard?, depthMM: Double, held: Bool, reaches: Bool = true) -> Rows? {
        guard let card else { return nil }
        let d = LatticeRegionDrawer.make(card: card, depthMM: depthMM, held: held, latticeReachesTheRun: reaches)
        let mine = labels.compactMap { l in d.rows.first { $0.label == l } }
        guard !mine.isEmpty else { return nil }
        return Rows(rows: mine, note: mine.first { $0.label == "Cells across" }?.note)
    }

    /// The card for a face: its own (per selectable), else its group's.
    public static func card(_ ref: LatticeSelectableRef, group: UUID, cards: [String: LatticeFaceCard],
                            groupCards: [UUID: LatticeFaceCard]) -> LatticeFaceCard? {
        cards[ref.key] ?? groupCards[group]
    }
}

/// ★ notes30 (his one (i), notes29: "please follow the front-and-centre notification version across the ENTIRE APP"): what
/// a face's (i) shows under its words in the centred notification (AppPopups.help, raised by FlexibleInfoButton) — his four
/// rows of the lattice drawn at that face, read live (a lattice that lands while it is open shows at once), else "No numbers
/// yet for this face". The notification carries the face's name (`title`) and the caption; any tap closes it. It was a card
/// of its own beside the (i) (FlexibleFaceStatsCard, placed by FlexibleFaceStatsPlacement below the chip or beside the list,
/// with its own ✕); both went.
struct FlexibleFaceStatsRows: View {
    @ObservedObject var main: FlexibleMainStage
    let group: UUID
    let ref: LatticeSelectableRef

    /// The notification's title: the face's name and "lattice" (the old card's own title).
    static func title(_ name: String) -> String { name + " \u{00B7} lattice" }

    var body: some View {
        if let model = main.model {
            Live(main: main, model: model, group: group, ref: ref)
        } else {
            FlexibleFaceStatsNone()
        }
    }

    /// Drawn again when the stage's lattice changes (the model publishes it).
    private struct Live: View {
        let main: FlexibleMainStage
        @ObservedObject var model: FlexibleStageModel
        let group: UUID
        let ref: LatticeSelectableRef

        var body: some View {
            if let rows = main.faceStats(ref, group: group, project: model.project) {
                VStack(spacing: 8) {
                    ForEach(rows.rows, id: \.label) { r in
                        HStack {
                            Text(r.label).font(.system(size: 15)).foregroundStyle(DS.Color.textSecondary.color)
                            Spacer(minLength: DS.Space.s)
                            Text(r.value).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(DS.Color.textPrimary.color).lineLimit(1)
                        }
                        .said(r.label + " " + r.value)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("flexible-face-info-row-\(r.label)")
                    }
                    if let n = rows.note {
                        Text(n).font(.system(size: 13)).foregroundStyle(DS.Color.textTertiary.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("flexible-face-info-card")
            } else {
                FlexibleFaceStatsNone()
            }
        }
    }
}

/// No lattice drawn at the face yet.
private struct FlexibleFaceStatsNone: View {
    var body: some View {
        Text(FlexibleSelectionsCopy.noNumbers)
            .font(.system(size: 15)).foregroundStyle(DS.Color.textSecondary.color)
            .said(FlexibleSelectionsCopy.noNumbers)
            .accessibilityIdentifier("flexible-face-info-none")
    }
}
