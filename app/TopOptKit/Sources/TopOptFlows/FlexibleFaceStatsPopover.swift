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
        if rhos.isEmpty { rhos = sample { p in regions.contains { LatticeRegionMask.containsWholePrism(p, region: $0) } } }
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

/// ★ REVIEW OF R7-D2: where the (i)'s card goes. From the CHIP (its (i) sits inside the chip): BELOW the chip, lined up
/// with the (i) (the mockup's `placeInfo`), else above it, else beside it — never on it (R7-D2 put it right of the (i), on the
/// chip's own title and segment, at all four sizes). From the LIST: beside its (i), to the right (the mockup), off the list.
/// Each spot is kept 8 pt inside the screen and, where one is clear, off the page's keep-outs.
enum FlexibleFaceStatsPlacement {
    static let gap: CGFloat = 8
    /// The card's height before it is measured (the four rows, the caption, the title: 160 as drawn, a little to spare).
    static func estimatedHeight(rows: Bool) -> CGFloat { rows ? 172 : 96 }

    static func frame(anchor a: CGRect, chip: CGRect?, size: CGSize, viewport v: CGSize, keepOut: [CGRect]) -> CGRect {
        let w = size.width, h = size.height
        func fits(_ r: CGRect) -> Bool { r.minX >= gap - 0.5 && r.minY >= gap - 0.5 && r.maxX <= v.width - gap + 0.5 && r.maxY <= v.height - gap + 0.5 }
        func overlap(_ r: CGRect) -> CGFloat {
            keepOut.reduce(0) { acc, k in let i = r.intersection(k); return acc + (i.isNull ? 0 : i.width * i.height) }
        }
        func pick(_ cands: [CGRect], avoid: CGRect?) -> CGRect? {
            let ok = cands.filter { fits($0) && !(avoid?.intersects($0) ?? false) }
            return ok.first { overlap($0) == 0 } ?? ok.min { overlap($0) < overlap($1) }
        }
        if let c = chip {
            func xs(_ x: CGFloat) -> [CGFloat] { [x, c.minX, c.maxX - w].map { min(max(gap, $0), v.width - gap - w) } }
            let below = c.maxY + gap, above = c.minY - gap - h
            var cands: [CGRect] = []
            for x in xs(a.minX - 12) { cands.append(CGRect(x: x, y: below, width: w, height: h)) }   // below the chip (the mockup)
            for x in xs(a.minX - 12) { cands.append(CGRect(x: x, y: above, width: w, height: h)) }   // above it
            for y in [c.minY, c.maxY - h] {
                cands.append(CGRect(x: c.maxX + gap, y: y, width: w, height: h))                       // right of it
                cands.append(CGRect(x: c.minX - gap - w, y: y, width: w, height: h))                   // left of it
            }
            return pick(cands, avoid: c) ?? CGRect(x: min(max(gap, c.minX), v.width - gap - w), y: min(max(gap, below), v.height - gap - h), width: w, height: h)
        }
        // the list's (i): to the right of the panel it sits in (the mockup), its middle on the (i), else its top or bottom there,
        // else just above or below whatever is in the way there (the chip, at 11" portrait), the nearest first
        let host = keepOut.first { $0.contains(CGPoint(x: a.midX, y: a.midY)) }
        let x = max(a.maxX, host?.maxX ?? a.maxX) + gap
        var around: [CGFloat] = []
        for k in keepOut { around.append(k.minY - gap - h); around.append(k.maxY + gap) }
        let mid = a.midY - h / 2
        around.sort { abs($0 - mid) < abs($1 - mid) }
        let first: [CGFloat] = [mid, a.minY - 12, a.maxY + 12 - h]
        let top = v.height - gap - h
        let ys: [CGFloat] = (first + around).map { (y: CGFloat) -> CGFloat in min(max(gap, y), top) }
        let cands = ys.map { CGRect(x: x, y: $0, width: w, height: h) } + ys.map { CGRect(x: a.minX - gap - w, y: $0, width: w, height: h) }
        return pick(cands, avoid: nil) ?? CGRect(x: min(max(gap, x), v.width - gap - w), y: ys[0], width: w, height: h)
    }
}

/// The (i)'s card: the face's name, his four rows, the note, the one caption — drawn by the on-model layer beside the (i)
/// it opened from (the list's or the chip's).
struct FlexibleFaceStatsCard: View {
    let title: String
    let rows: FlexibleFaceStats.Rows?
    let close: () -> Void
    static let width: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "square.grid.3x3.fill").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(FlexibleStageStyle.facePrismToken.color)
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                        .foregroundStyle(DS.Color.textSecondary.color)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, -10).padding(.trailing, -10)
                .accessibilityLabel("Close the numbers")
                .accessibilityIdentifier("flexible-face-info-close")
            }
            if let rows {
                VStack(spacing: 6) {
                    ForEach(rows.rows, id: \.label) { r in
                        HStack {
                            Text(r.label).font(.system(size: 13)).foregroundStyle(DS.Color.textSecondary.color)
                            Spacer(minLength: DS.Space.s)
                            Text(r.value).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(DS.Color.textPrimary.color).lineLimit(1)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("flexible-face-info-row-\(r.label)")
                    }
                }
                if let n = rows.note {
                    Text(n).font(.system(size: 11.5)).foregroundStyle(DS.Color.textTertiary.color).lineLimit(1)
                }
                Text(FlexibleSelectionsCopy.statsCaption)
                    .font(.system(size: 11.5)).foregroundStyle(DS.Color.textTertiary.color)
                    .lineLimit(1).minimumScaleFactor(0.9)
                    .accessibilityIdentifier("flexible-face-info-caption")
            } else {
                Text(FlexibleSelectionsCopy.noNumbers)
                    .font(.system(size: 13)).foregroundStyle(DS.Color.textSecondary.color)
                    .accessibilityIdentifier("flexible-face-info-none")
            }
        }
        .padding(DS.Space.m)
        .frame(width: Self.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DS.Color.chipSolid.color.opacity(0.96))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .dsShadow(DS.Shadow.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flexible-face-info-card")
    }
}
