// FlexibleSqueezeGroupRows — the squeeze groups on the Settings panel's Face area (task
// 2026-09-29-flexible-screens, round 4 batch D2; his img 4: "there needs to be a setting that says
// Groups faces together — preferably the face area in the settings").
//
// ★ D2 REVIEW: EACH GROUP IS A HEADER IN THE FACE LIST, its faces beneath it. D2 put one line per
// group UNDER all seven face rows — "Group 1 · Top A + Top B · Squeeze 10 kg" beside a pencil, an
// × and an (i) in a 372 pt row — and SwiftUI cut the line to "Group 1 · Top A + Top B · Squ…": the
// ONE force, the very number the section exists to show, never showed. And under an open face
// card the section sat below the panel's fold in landscape. Now:
//   * the header is "Group 1 · Squeeze" (just "Squeeze" with one pressed face) with the FORCE IN
//     ITS PILL — "[10 kg ✎]", the shared number pad; it writes the main page's Load groups back
//     (FlexibleStageModel.setGroupForce) — then, with two or more groups, an × (its faces join
//     the first other group at ITS force) and the (i);
//   * the group's faces are listed right under it (FlexibleFaceList), so the grouping is seen,
//     and the header of the face he works on sits right above its card;
//   * a group that will squish less than designed once the lattice carries every group says so
//     under its header in one warning line (FlexibleGroupEstimate — before Exit);
//   * group colours: the dot, the faces' dots, the open card's dot.
// A face is MOVED from its card (FlexibleFaceGroupRow: "Squeeze group [1] [2] [+ New]"). Nothing
// here can block Exit.

import SwiftUI
import TopOptDesign
import TopOptKit

enum FlexibleSqueezeGroupRows {

    /// One group header as the panel shows it (a value, so a test reads the page's own lines).
    struct Row: Equatable, Identifiable {
        let id: Int
        let number: Int
        /// "Group 1 · Squeeze" / "Squeeze".
        let line: String
        /// The force in the pill: "10 kg" / "6–10 kg".
        let value: String
        /// The pad's seed.
        let kg: Double
        let removable: Bool
        /// Under the header, when the group will squish less than designed (the firmer wins).
        let miss: String?
        let regions: [Int]
    }

    /// Test control only: the D2 header's long line ("Group 1 · Top A + Top B · Squeeze 10 kg"),
    /// to prove the hosted width measurement sees a cut line.
    @MainActor static var controlLongLine = false

    @MainActor
    static func rows(model: FlexibleStageModel) -> [Row] {
        let gs = model.squeezeGroups
        let single = model.settings.loadedFaces.count == 1
        return gs.map { g in
            let force = model.groupForce(g)
            let line = controlLongLine ? model.groupLine(g) : FlexibleRowCopy.groupHeader(number: g.number, single: single)
            return Row(id: g.id, number: g.number, line: line, value: FlexibleRowCopy.squeezeValue(force),
                       kg: force?.upperBound ?? 0, removable: gs.count > 1,
                       miss: model.groupMiss(g.id).map {
                           FlexibleRowCopy.groupMissLine(asBuiltMM: $0.asBuiltMM, designedMM: $0.designedMM, firmer: $0.firmerNumber)
                       },
                       regions: g.regions)
        }
    }
}

/// ★ ONE GROUP'S HEADER in the face list: its dot, "Group 1 · Squeeze", [10 kg ✎], × and (i).
struct FlexibleSqueezeGroupHeader: View {
    @ObservedObject var model: FlexibleStageModel
    let row: FlexibleSqueezeGroupRows.Row
    @Binding var padTarget: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: DS.Space.s) {
                Circle().fill(model.groupColour(number: row.number).color)
                    .frame(width: 10, height: 10)
                Text(row.line)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary.color)
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .layoutPriority(1)
                    // the line's own frame (the hosted test measures it against the words)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["groupLine-\(row.number)": g.frame(in: .global)])
                    }.allowsHitTesting(false))
                    .accessibilityIdentifier("flexible-group-\(row.number)-line")
                Spacer(minLength: DS.Space.xs)
                // ★ ROUND 5 (S3 / S4): the force in a number box, in the page's unit (the pencil pill went)
                let unit = model.weightUnit
                FlexNumberBox(key: "group-\(row.id)", title: FlexibleRowCopy.groupName(row.number) + " · squeeze",
                              spec: FlexibleNumberSpecs.weight(kg: row.kg, unit: unit), padTarget: $padTarget,
                              units: FlexibleWeightUnit.allCases, onUnit: { model.setWeightUnit($0) },
                              onNote: { model.toast = $0 }) { v in
                    model.setGroupForce(row.id, kg: unit.toKg(v))
                }
                if row.removable {
                    Button { model.removeGroup(row.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DS.Color.textTertiary.color)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["groupRemove-\(row.number)": g.frame(in: .global)])
                    }.allowsHitTesting(false))
                    .accessibilityLabel("Remove \(FlexibleRowCopy.groupName(row.number))")
                    .accessibilityIdentifier("flexible-group-remove-\(row.number)")
                }
                FlexInfoButton(title: FlexibleRowCopy.groupName(row.number), text: FlexibleRowCopy.Info.groups,
                               id: "flexible-group-\(row.number)-info")
            }
            .frame(minHeight: 44)
            if let miss = row.miss {
                FlexWarningLine(text: miss, id: "flexible-group-\(row.number)-miss")
                    .padding(.leading, 18)
            }
        }
        .padding(.horizontal, DS.Space.m)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(model.groupColour(number: row.number).color.opacity(0.10)))
        // its frame reaches the page (the hosted test checks it is on the panel)
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["groupRow-\(row.number)": g.frame(in: .global)])
        }.allowsHitTesting(false))
        .id(FlexibleFaceList.groupID(row.number))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flexible-group-\(row.number)")
    }
}

// ★ ROUND 5 (S3, "The pencil buttons go"): D2's value pill ("[10 kg ✎]", FlexValuePill) is gone —
// the force is a FlexNumberBox (FlexibleNumberBox.swift).

/// The selected pressed face's "Squeeze group [1] [2] [+ New]" row (in its card).
struct FlexibleFaceGroupRow: View {
    @ObservedObject var model: FlexibleStageModel
    let region: Int

    /// The chips: every group by its number, then "+ New" when the face's group holds a face
    /// outside its HAND (★ D2 review: a main-page Load group's faces move together).
    @MainActor
    static func options(model: FlexibleStageModel, region: Int) -> [(id: String, label: String)] {
        let gs = model.squeezeGroups
        let mine = model.squeezeGroup(of: region)
        let hand = Set(model.hand(of: region))
        var out = gs.map { (id: "\($0.id)", label: "\($0.number)") }
        if mine?.regions.contains(where: { !hand.contains($0) }) == true {
            out.append((id: "new", label: FlexibleRowCopy.newGroupChip))
        }
        return out
    }

    var body: some View {
        if let mine = model.squeezeGroup(of: region), model.settings.loadedFaces.count > 1 {
            FlexRow(FlexibleRowCopy.groupRow, info: FlexibleRowCopy.Info.groupRow, id: "flexible-row-group") {
                FlexChips(options: Self.options(model: model, region: region), selection: "\(mine.id)",
                          id: "flexible-group", equalWidths: false) { v in
                    if v == "new" { model.newGroup(with: region) } else if let g = Int(v) { model.moveToGroup(region, g) }
                }
                .fixedSize()
                .background(GeometryReader { g in
                    Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["groupChips": g.frame(in: .global)])
                }.allowsHitTesting(false))
            }
        }
    }
}
