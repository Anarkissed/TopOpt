// FlexibleManualViews — round 7, MANUAL part M1: the toggle, the lattice rows, a group's own lattice, the view line
// (task 2026-09-29-flexible-screens; FlexibleManual for the values and the relation).
//
// ★ THE REDESIGN'S LOOK, REUSED (his "Just because it's manual doesn't mean we want it to look like shit"): the toggle is the
// panel's capsule chips (FlexChips), every value one FlexRow line with its FlexNumberBox (tap for the keypad, drag to scrub), the
// bead warning a FlexRow in the warning colour with its one-tap fix as the page's capsule fix button (FlexibleDeepestNoLatticeRow's),
// a group's override one quiet line with a quiet capsule (the [Reset all] look). No new style.

import SwiftUI
import TopOptDesign
import TopOptKit

/// ★ "at the very top of the Squish modal, it should have a toggle that says manual or auto": [Manual | Auto] on the card's header
/// line, beside [Reset all] (no extra height: the card's rows and the selected face's card keep their room at 11" landscape).
struct FlexibleManualToggle: View {
    @ObservedObject var model: FlexibleStageModel
    var body: some View {
        FlexChips(options: FlexibleManualCopy.modeOptions, selection: model.isManual ? "manual" : "auto",
                  id: "flexible-manual-mode", equalWidths: false) { v in model.setManual(v == "manual") }
            .fixedSize()
            .background(GeometryReader { g in
                Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["manualToggle": g.frame(in: .global)])
            }.allowsHitTesting(false))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("flexible-manual-mode")
    }
}

/// In Manual, with a view on: ONE line at the top of the open tab saying the view is the app's estimate from his values.
struct FlexibleManualViewLine: View {
    @ObservedObject var model: FlexibleStageModel
    var body: some View {
        if let line = model.manualViewLine {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "eye").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.accent.color)
                Text(line).font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Color.textSecondary.color)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            .frame(minHeight: 28)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("flexible-manual-view-line")
        }
    }
}

/// His four lines: Lattice [Gyroid | Honeycomb], Cell size, Density %, Walls (beads) — the part's (`group` nil) or a group's own;
/// then the bead warning with its one-tap fix when the walls are not a whole number of beads.
struct FlexibleManualLatticeRows: View {
    @ObservedObject var model: FlexibleStageModel
    let group: Int?
    @Binding var padTarget: String?

    private var keyTail: String { group.map { "g\($0)" } ?? "part" }

    var body: some View {
        if let l = model.manualLattice(group: group) {
            let beads = model.manualWalls(group: group) ?? 0
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                FlexRow(FlexibleManualCopy.lattice, info: FlexibleManualCopy.Info.lattice, id: "flexible-manual-type-\(keyTail)") {
                    FlexChips(options: FlexibleManualCopy.typeOptions, selection: l.topology, id: "flexible-manual-type-\(keyTail)",
                              equalWidths: false) { v in model.setManualType(v, group: group) }
                        .fixedSize()
                }
                FlexRow(FlexibleManualCopy.cell, info: FlexibleManualCopy.Info.cell, id: "flexible-manual-cell-\(keyTail)") {
                    FlexNumberBox(key: "manual-cell-\(keyTail)", title: FlexibleManualCopy.cell,
                                  spec: FlexNumberSpec(value: l.cellMM, unit: "mm", step: 0.5, range: FlexibleManualMath.cellRange,
                                                       decimals: FlexibleNumberSpecs.wholeOrTenth(l.cellMM)),
                                  padTarget: $padTarget, onNote: { model.toast = $0 }) { v in model.setManualCell(v, group: group) }
                }
                FlexRow(FlexibleManualCopy.density, info: FlexibleManualCopy.Info.density, id: "flexible-manual-density-\(keyTail)") {
                    FlexNumberBox(key: "manual-density-\(keyTail)", title: FlexibleManualCopy.density,
                                  spec: FlexNumberSpec(value: (l.density * 100).rounded(), unit: "%", step: 1,
                                                       range: (FlexibleManualMath.densityRange.lowerBound * 100)...(FlexibleManualMath.densityRange.upperBound * 100),
                                                       decimals: 0),
                                  padTarget: $padTarget, onNote: { model.toast = $0 }) { v in model.setManualDensity(v / 100, group: group) }
                }
                FlexRow(FlexibleManualCopy.walls, info: FlexibleManualCopy.Info.walls, id: "flexible-manual-walls-\(keyTail)",
                        warning: FlexibleManualCopy.wallsWarning(beads) != nil) {
                    FlexNumberBox(key: "manual-walls-\(keyTail)", title: FlexibleManualCopy.walls,
                                  spec: FlexNumberSpec(value: (beads * 10).rounded() / 10, unit: FlexibleManualCopy.wallsUnitFor((beads * 10).rounded() / 10), step: 1,
                                                       range: 1...8, decimals: FlexibleNumberSpecs.wholeOrTenth(beads)),
                                  padTarget: $padTarget, onNote: { model.toast = $0 }) { v in model.setManualWalls(v, group: group) }
                }
                if let w = FlexibleManualCopy.wallsWarning(beads) {
                    FlexRow(w, info: FlexibleManualCopy.Info.walls, id: "flexible-manual-walls-warning-\(keyTail)", warning: true) {
                        Button { model.fixManualWalls(group: group) } label: {
                            Text(FlexibleManualCopy.fixTitle(beads))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(DS.Color.textPrimary.color)
                                .padding(.horizontal, 12).padding(.vertical, 4)
                                .background(Capsule().fill(DS.Color.warning.color.opacity(0.35)))
                                .frame(minHeight: FlexibleTargets.least).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("flexible-manual-walls-fix-\(keyTail)")
                    }
                }
            }
        }
    }
}

/// [Model] in Manual: the part's four lines under a section title.
struct FlexibleManualPartSection: View {
    @ObservedObject var model: FlexibleStageModel
    @Binding var padTarget: String?
    var body: some View {
        if model.isManual {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Divider().overlay(DS.Color.strokeSubtle.color).padding(.vertical, DS.Space.xs)
                FlexSectionTitle(text: FlexibleManualCopy.title)
                FlexibleManualLatticeRows(model: model, group: nil, padTarget: $padTarget)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("flexible-manual-part")
        }
    }
}

/// A group's card in Manual: ONE quiet line "Lattice · same as the part" [Set its own] — or "Lattice · its own" [Use the part's]
/// with its own four lines.
struct FlexibleManualGroupRow: View {
    @ObservedObject var model: FlexibleStageModel
    let group: FlexibleSqueezeGroup
    @Binding var padTarget: String?

    var body: some View {
        if model.isManual {
            let own = model.settings.manual?.hasOwn(group: group.id) == true
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "square.grid.3x3").font(.system(size: 13)).foregroundStyle(.secondary)
                    Text(own ? FlexibleManualCopy.ownLattice : FlexibleManualCopy.sameAsPart)
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.85)
                    Spacer(minLength: DS.Space.xs)
                    Button { model.setGroupOwnLattice(group.id, own: !own) } label: {
                        Text(own ? FlexibleManualCopy.useParts : FlexibleManualCopy.setOwn)
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.textSecondary.color)
                            .padding(.horizontal, 10).frame(height: 30)
                            .background(Capsule().fill(DS.Color.fillSubtle.color)
                                .overlay(Capsule().strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1)))
                            .contentShape(Capsule())
                            .frame(minWidth: FlexibleTargets.least, minHeight: FlexibleTargets.least)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("flexible-manual-group-\(group.number)-\(own ? "use-parts" : "set-own")")
                }
                if own { FlexibleManualLatticeRows(model: model, group: group.id, padTarget: $padTarget) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("flexible-manual-group-\(group.number)")
        }
    }
}

/// ★ MANUAL (M2, his picks of 2026-10-22: "depths and curves become the app's PREDICTION (read-only)"): a depth in Manual — ONE
/// FlexRow line in the card's own look ("Squishes ≈ 3.2 mm at 10 lb"), its (i) saying it is the app's estimate; no box, no keypad,
/// no scrub. Its frame reaches the page under `frameKey` (the hosted tests read it).
struct FlexibleManualEstimateRow: View {
    let text: String
    let info: String
    let id: String
    let frameKey: String
    var body: some View {
        FlexRow(text, info: info, id: id)
            .background(GeometryReader { g in
                Color.clear.preference(key: FlexibleKeepOutKey.self, value: [frameKey: g.frame(in: .global)])
            }.allowsHitTesting(false))
    }
}
