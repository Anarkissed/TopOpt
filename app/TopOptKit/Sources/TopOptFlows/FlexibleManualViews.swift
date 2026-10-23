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

/// ★ P1 (his notes of 2026-10-23: "Each lattice should have the same set of settings as the entire model"): the SAME rows for the
/// part (`group` nil) and a group's own — Type; Walls (whole beads); Density ⇄ Cell size ⇄ Cells across (linked: edit one, the
/// others follow at his walls); Grade [Off | On] and, when on, Grade by, From, To, Along, Style; the facts line; on [Model] only,
/// Temperature. One FlexRow line each in the redesign's look (FlexChips, FlexNumberBox), ≤ 44 characters.
struct FlexibleManualLatticeRows: View {
    @ObservedObject var model: FlexibleStageModel
    let group: Int?
    @Binding var padTarget: String?

    private var keyTail: String { group.map { "g\($0)" } ?? "part" }

    /// The rows shown, in order (the hosted tests and the P1 tests read it).
    static func rows(group: Int?, gradeOn: Bool) -> [String] {
        var r = ["type", "walls", "density", "cell", "cellsAcross", "grade"]
        if gradeOn { r += ["gradeBy", "from", "to", "along", "style"] }
        r.append("facts")
        if group == nil { r.append("temperature") }
        return r
    }

    private func box(_ key: String, _ title: String, _ spec: FlexNumberSpec, _ set: @escaping (Double) -> Void) -> some View {
        FlexNumberBox(key: "manual-\(key)-\(keyTail)", title: title, spec: spec, padTarget: $padTarget,
                      onNote: { model.toast = $0 }) { set($0) }
    }
    private func chips(_ id: String, _ o: [(id: String, label: String)], _ sel: String, _ set: @escaping (String) -> Void) -> some View {
        FlexChips(options: o, selection: sel, id: "flexible-manual-\(id)-\(keyTail)", equalWidths: false) { set($0) }.fixedSize()
    }

    var body: some View {
        if let l = model.manualLattice(group: group) {
            let bw = model.project.printParams.strutLineWidthMM
            let cell = FlexibleManualMath.cellMM(l, beadWidthMM: bw)
            let lo = FlexibleManualMath.cellMM(density: FlexibleManualMath.densityRange.upperBound, beads: l.beads, topology: l.topology, beadWidthMM: bw)
            let hi = FlexibleManualMath.cellMM(density: FlexibleManualMath.densityRange.lowerBound, beads: l.beads, topology: l.topology, beadWidthMM: bw)
            let rows = Self.rows(group: group, gradeOn: l.grade.on)
            let C = FlexibleManualCopy.self
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                FlexRow(C.lattice, info: C.Info.lattice, id: "flexible-manual-type-\(keyTail)") {
                    chips("type", C.typeOptions, l.topology) { model.setManualType($0, group: group) }
                }
                FlexRow(C.walls, info: C.Info.walls, id: "flexible-manual-walls-\(keyTail)") {
                    chips("walls", C.wallsOptions, String(l.beads)) { model.setManualBeads(Int($0) ?? 1, group: group) }
                }
                FlexRow(C.density, info: C.Info.density, id: "flexible-manual-density-\(keyTail)") {
                    box("density", C.density, FlexNumberSpec(value: (l.density * 1000).rounded() / 10, unit: "%", step: 1,
                                                             range: (FlexibleManualMath.densityRange.lowerBound * 100)...(FlexibleManualMath.densityRange.upperBound * 100),
                                                             decimals: FlexibleNumberSpecs.wholeOrTenth(l.density * 100))) {
                        model.setManualDensity($0 / 100, group: group)
                    }
                }
                FlexRow(C.cell, info: C.Info.cell, id: "flexible-manual-cell-\(keyTail)") {
                    box("cell", C.cell, FlexNumberSpec(value: (cell * 10).rounded() / 10, unit: "mm", step: 0.5, range: lo...hi, decimals: 1)) {
                        model.setManualCell($0, group: group)
                    }
                }
                if let n = model.manualCellsAcross(group: group), let d = model.manualDepthMM(group: group) {
                    FlexRow(C.cellsAcross, info: C.Info.cellsAcross, id: "flexible-manual-cells-\(keyTail)", warning: n < 2) {
                        box("cells", C.cellsAcross, FlexNumberSpec(value: (n * 10).rounded() / 10, unit: "", step: 0.5,
                                                                  range: Swift.max(0.1, d / hi)...Swift.max(0.2, d / lo), decimals: 1)) {
                            model.setManualCellsAcross($0, group: group)
                        }
                    }
                } else {
                    FlexRow(C.cellsAcross + " · no prism yet", info: C.Info.cellsAcross, id: "flexible-manual-cells-\(keyTail)")
                }
                FlexRow(C.grade, info: C.Info.grade, id: "flexible-manual-grade-\(keyTail)") {
                    chips("grade", C.gradeOptions, l.grade.on ? "on" : "off") { model.setManualGrade(on: $0 == "on", group: group) }
                }
                if rows.contains("gradeBy") {
                    let byCell = l.grade.by == "cell"
                    FlexRow(C.gradeBy, info: C.Info.grade, id: "flexible-manual-grade-by-\(keyTail)") {
                        chips("grade-by", C.gradeByOptions, l.grade.by) { model.setManualGradeBy($0, group: group) }
                    }
                    ForEach([false, true], id: \.self) { end in
                        let v = FlexibleManualMath.gradeValue(l, end: end, beadWidthMM: bw)
                        FlexRow(end ? C.to : C.from, info: C.Info.grade, id: "flexible-manual-grade-\(end ? "to" : "from")-\(keyTail)") {
                            box(end ? "to" : "from", end ? C.to : C.from,
                                byCell ? FlexNumberSpec(value: (v * 10).rounded() / 10, unit: "mm", step: 0.5, range: lo...hi, decimals: 1)
                                       : FlexNumberSpec(value: (v * 1000).rounded() / 10, unit: "%", step: 1,
                                                        range: (FlexibleManualMath.densityRange.lowerBound * 100)...(FlexibleManualMath.densityRange.upperBound * 100),
                                                        decimals: FlexibleNumberSpecs.wholeOrTenth(v * 100))) {
                                model.setManualGradeValue(end: end, byCell ? $0 : $0 / 100, group: group)
                            }
                        }
                    }
                    FlexRow(C.along, info: C.Info.along, id: "flexible-manual-along-\(keyTail)") {
                        chips("along", C.alongOptions, l.grade.along) { model.setManualGradeAlong($0, group: group) }
                    }
                    FlexRow(C.style, info: C.Info.style, id: "flexible-manual-style-\(keyTail)") {
                        chips("style", C.styleOptions, l.stepped ? "stepped" : "default") { model.setManualStepped($0 == "stepped", group: group) }
                    }
                }
                FlexibleManualFacts(model: model, group: group)
                if group == nil, let m = model.material, m.noPrediction == nil, !m.testedTempsC.isEmpty {
                    let t = model.manualTempC.map { String(Int($0)) } ?? ""
                    FlexRow(C.temperature, info: C.Info.temperature, id: "flexible-manual-temp") {
                        chips("temp", m.testedTempsC.map { (String(Int($0)), "\(Int($0)) °C") }, t) { v in
                            if let d = Double(v) { model.setManualTemp(d) }
                        }
                    }
                }
            }
        }
    }
}

/// ★ P1, THE FACTS LINE: what his values make, read only — quiet lines, a flag in the warning colour (never blocking).
struct FlexibleManualFacts: View {
    @ObservedObject var model: FlexibleStageModel
    let group: Int?
    var body: some View {
        let facts = model.manualFacts(group: group)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(facts.enumerated()), id: \.offset) { _, f in
                HStack(spacing: DS.Space.xs) {
                    Text(f.text)
                        .font(.system(size: 12, weight: f.warning ? .semibold : .regular))
                        .foregroundStyle(f.warning ? DS.Color.warning.color : DS.Color.textTertiary.color)
                        .lineLimit(1).minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("flexible-manual-facts-\(group.map { "g\($0)" } ?? "part")")
    }
}

/// [Model] in Manual: the part's rows under a section title.
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
/// with its own rows — the same set as the part's.
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
                else { FlexibleManualFacts(model: model, group: group.id) }   // ★ P1: its cells, its estimate, the data's span
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
