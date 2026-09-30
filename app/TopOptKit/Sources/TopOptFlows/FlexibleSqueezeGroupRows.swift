// FlexibleSqueezeGroupRows — the squeeze groups on the Settings panel's Face area, under the
// face list (task 2026-09-29-flexible-screens, round 4 batch D2; his img 4: "there needs to be a
// setting that says Groups faces together — preferably the face area in the settings").
//
// ★ ONE LINE PER GROUP, its faces and its ONE force: "Group 1 · Top A + 3 more · Squeeze 10 kg"
// with the group's colour (FlexibleSqueezeGroups.palette — the part's pressed faces take it
// too), a pencil for the force (the shared number pad; it writes the main page's Load groups
// back — FlexibleStageModel.setGroupForce) and, with two or more groups, an × that removes the
// group (its faces join the first other group). A face is MOVED from its card in the list
// (FlexibleFaceRows: "Squeeze group [1] [2] [+ New]"). With two or more groups that share
// material, one line says the firmer wins. Nothing here can block Exit.

import SwiftUI
import TopOptDesign
import TopOptKit

struct FlexibleSqueezeGroupRows: View {
    @ObservedObject var model: FlexibleStageModel
    @Binding var padTarget: String?

    /// One row as the panel shows it (a value, so a test reads the page's own lines).
    struct Row: Equatable, Identifiable {
        let id: Int
        let number: Int
        let line: String
        let kg: Double
        let removable: Bool
    }

    @MainActor
    static func rows(model: FlexibleStageModel) -> [Row] {
        let gs = model.squeezeGroups
        return gs.map { g in
            Row(id: g.id, number: g.number, line: model.groupLine(g), kg: model.groupForce(g)?.upperBound ?? 0,
                removable: gs.count > 1)
        }
    }

    var body: some View {
        let rows = Self.rows(model: model)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                FlexSectionTitle(text: FlexibleRowCopy.groupsTitle)
                    .padding(.top, DS.Space.xs)
                ForEach(rows) { row in
                    HStack(spacing: DS.Space.s) {
                        Circle().fill(FlexibleSqueezeGroups.colour(number: row.number).color)
                            .frame(width: 10, height: 10)
                        FlexRow(row.line, info: FlexibleRowCopy.Info.groups, id: "flexible-group-\(row.number)") {
                            FlexEditPill(key: "group-\(row.id)", title: FlexibleRowCopy.groupName(row.number) + " · squeeze",
                                         unit: "kg", value: row.kg, padTarget: $padTarget) { model.setGroupForce(row.id, kg: $0) }
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
                        }
                    }
                    .padding(.horizontal, DS.Space.m)
                    .frame(minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Color.fillSubtle.color))
                    // its frame reaches the page (the hosted test reads each group's ONE line)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["groupRow-\(row.number)": g.frame(in: .global)])
                    }.allowsHitTesting(false))
                }
                if rows.count > 1, model.groupsShareMaterial {
                    Text(FlexibleRowCopy.groupsShare)
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Color.textSecondary.color)
                        .lineLimit(1).minimumScaleFactor(0.85)
                        .accessibilityIdentifier("flexible-groups-share")
                }
            }
        }
    }
}

/// The selected pressed face's "Squeeze group [1] [2] [+ New]" row (in its card).
struct FlexibleFaceGroupRow: View {
    @ObservedObject var model: FlexibleStageModel
    let region: Int

    /// The chips: every group by its number, then "+ New" when the face shares its group.
    @MainActor
    static func options(model: FlexibleStageModel, region: Int) -> [(id: String, label: String)] {
        let gs = model.squeezeGroups
        let mine = model.squeezeGroup(of: region)
        var out = gs.map { (id: "\($0.id)", label: "\($0.number)") }
        if (mine?.regions.count ?? 0) > 1 { out.append((id: "new", label: FlexibleRowCopy.newGroupChip)) }
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
