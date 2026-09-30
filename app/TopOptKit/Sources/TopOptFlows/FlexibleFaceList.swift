// FlexibleFaceList — the faces set on the main page, listed on the Settings panel (task
// 2026-09-29-flexible-screens, round 4 batch D1; his img 1: "I think it should *list* the
// different faces that have been selected in the previous screen and when you tap on one,
// the values show up and get modified below to match the value saved to the face. And make
// it obvious that it's selectable.").
//
// ★ D2 REVIEW: the pressed faces are listed UNDER THEIR SQUEEZE GROUP'S HEADER ("Group 1 ·
// Squeeze [10 kg ✎]" — FlexibleSqueezeGroupHeader), the resting faces after them.
// ★ ONE BIG ROW PER FACE — "Top A · Pressed · 10 kg" / "Face 0 · Rests" — pressed faces first,
// each a 48 pt button with a chevron. A tap SELECTS that region (a split sector as itself,
// `FlexibleStageModel.select`) and the part shows it selected. Every row is one line
// (FlexibleRowCopy.faceRow).
// ★ THE SELECTED ROW OPENS IN PLACE (verification of D1 — his project's seven rows pushed the
// face's own rows below the panel on every iPad, so a tap seemed to move only the tick): its
// row becomes a CARD — filled, outlined in the accent — holding that face's rows
// (FlexibleFaceRows: [Pressed | Rests] on the row itself, then weight, Shape, depth), and the
// panel scrolls the card into view (FlexibleSettingsPanel.reveal). A face selected on the part
// that is not set yet opens first, with [Press it] [It rests here].

import SwiftUI
import TopOptDesign
import TopOptKit

struct FlexibleFaceList: View {
    @ObservedObject var model: FlexibleStageModel
    @Binding var padTarget: String?
    /// ★ ROUND 5 (S8): only these faces (a folder tab's — no group headers: the tab is the group);
    /// nil ⇒ every face under its group's header (round 4's list).
    var only: [Int]? = nil
    /// ★ ROUND 5 (S8): the group whose tab this is — a face not set yet, pressed here, joins it.
    var joinGroup: Int? = nil

    /// A row's height: big, obviously a button (the HIG's 44 and then some).
    static let rowHeight: CGFloat = 48
    /// The selected face's card (the panel scrolls to it).
    static func cardID(_ region: Int) -> String { "flexible-face-card-\(region)" }
    /// A squeeze group's header.
    static func groupID(_ number: Int) -> String { "flexible-group-header-\(number)" }

    struct Row: Equatable, Identifiable {
        let region: Int
        let line: String
        let pressed: Bool
        let selected: Bool
        /// ★ D2: the face's squeeze group's number, only while there are two or more (its dot
        /// takes the group's colour).
        var group: Int? = nil
        var id: Int { region }
    }

    /// Every face the Flexible settings hold (the main page's groups arrive here as pressed or
    /// resting faces — FlexibleMainPageLoads.adopt), pressed first, each in its saved order.
    @MainActor
    static func rows(model: FlexibleStageModel) -> [Row] {
        let faces = model.settings.faces
        let ordered = faces.filter(\.isLoaded) + faces.filter { !$0.isLoaded }
        let groups = model.squeezeGroups
        return ordered.map { f in
            Row(region: f.faceRegionID,
                line: FlexibleRowCopy.faceRow(name: model.faceName(f.faceRegionID), pressed: f.isLoaded, kg: f.weightKg,
                                              unit: model.weightUnit),
                pressed: f.isLoaded, selected: f.faceRegionID == model.selectedRegion,
                // ★ ROUND 5 (S1): its group's number always — the dot wears the group's CHOSEN colour
                group: groups.first { $0.regions.contains(f.faceRegionID) }?.number)
        }
    }

    /// ★ D2 REVIEW: the list IN SECTIONS — each squeeze group's header, then its pressed faces;
    /// then the resting faces (no header). A value, so a test reads the page's own order.
    struct Section: Identifiable {
        let group: FlexibleSqueezeGroupRows.Row?
        let rows: [Row]
        var id: Int { group?.number ?? 0 }
    }

    @MainActor
    static func sections(model: FlexibleStageModel) -> [Section] {
        let rows = rows(model: model)
        var out: [Section] = []
        var placed = Set<Int>()
        for g in FlexibleSqueezeGroupRows.rows(model: model) {
            let members = Set(g.regions)
            let mine = rows.filter { $0.pressed && members.contains($0.region) }
            mine.forEach { placed.insert($0.region) }
            out.append(Section(group: g, rows: mine))
        }
        let rest = rows.filter { !placed.contains($0.region) }
        if !rest.isEmpty { out.append(Section(group: nil, rows: rest)) }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlexSectionTitle(text: FlexibleRowCopy.facesTitle)
            if let r = model.selectedRegion {
                // a face tapped on the part that is not set yet: its card first
                if model.settings.face(r) == nil { card(r) }
            } else {
                FlexRow(FlexibleRowCopy.noFace, info: FlexibleRowCopy.Info.noFace, id: "flexible-row-noface")
            }
            if let only {
                // ★ ROUND 5 (S8): a folder tab's faces — the tab is the group (its header is the tab's)
                let keep = Set(only)
                ForEach(Self.rows(model: model).filter { keep.contains($0.region) }) { row in item(row) }
            } else {
                // ★ D2 REVIEW: each squeeze group's header ("Group 1 · Squeeze [10 kg ✎]"), its faces
                // right under it — then the resting faces
                ForEach(Self.sections(model: model)) { section in
                    if let g = section.group {
                        FlexibleSqueezeGroupHeader(model: model, row: g, padTarget: $padTarget)
                    }
                    ForEach(section.rows) { row in item(row) }
                }
            }
            if model.squeezeGroups.count > 1, model.groupsShareMaterial, model.groupMisses.isEmpty {
                Text(FlexibleRowCopy.groupsShare)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Color.textSecondary.color)
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .accessibilityIdentifier("flexible-groups-share")
            }
        }
        // the whole list's frame (the hosted test: where D2's group section began — under it)
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["faceList": g.frame(in: .global)])
        }.allowsHitTesting(false))
    }

    /// A face: the selected one open as its card, the others a big row that selects it.
    @ViewBuilder private func item(_ row: Row) -> some View {
        if row.selected {
            card(row.region)
        } else {
            Button { model.select(row.region) } label: { label(row) }
                .buttonStyle(.plain)
                .background(GeometryReader { g in
                    Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["faceRow-\(row.region)": g.frame(in: .global)])
                }.allowsHitTesting(false))
                .accessibilityIdentifier("flexible-face-row-\(row.region)")
                .accessibilityLabel(row.line)
                .accessibilityAddTraits(.isButton)
        }
    }

    /// ★ THE SELECTED FACE, OPEN IN PLACE: its rows inside its own row (filled, outlined in the
    /// accent). Its frame reaches the page ("faceCard") so a test can see it on the panel.
    private func card(_ region: Int) -> some View {
        FlexibleFaceRows(model: model, region: region, padTarget: $padTarget, joinGroup: joinGroup)
            .padding(.leading, DS.Space.m).padding(.trailing, DS.Space.s).padding(.bottom, DS.Space.xs)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Color.fillSelected.color))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(DS.Color.accent.color, lineWidth: 1.5))
            .background(GeometryReader { g in
                Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["faceCard": g.frame(in: .global)])
            }.allowsHitTesting(false))
            .id(Self.cardID(region))
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isSelected)
            .accessibilityIdentifier("flexible-face-card")
    }

    private func label(_ row: Row) -> some View {
        HStack(spacing: DS.Space.s) {
            Circle()
                .fill((row.pressed ? (row.group.map { model.groupColour(number: $0) } ?? DS.Color.accentGreen)
                       : DS.Color.accentCyan).color)
                .frame(width: 10, height: 10)
            Text(row.line)
                .font(.system(size: 14, weight: row.selected ? .semibold : .medium))
                .foregroundStyle((row.selected ? DS.Color.textPrimary : DS.Color.textSecondary).color)
                .lineLimit(1).minimumScaleFactor(0.85)
            Spacer(minLength: DS.Space.xs)
            Image(systemName: row.selected ? "checkmark.circle.fill" : "chevron.right")
                .font(.system(size: row.selected ? 16 : 13, weight: .semibold))
                .foregroundStyle((row.selected ? DS.Color.accent : DS.Color.textTertiary).color)
        }
        .padding(.horizontal, DS.Space.m)
        .frame(minHeight: Self.rowHeight)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill((row.selected ? DS.Color.fillSelected : DS.Color.fillSubtle).color))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder((row.selected ? DS.Color.accent : DS.Color.strokeSubtle).color, lineWidth: row.selected ? 1.5 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: ★ SQUEEZE GROUPS (round 4 batch D2; D2 review: headers IN the list)
    // His img 4: "there needs to be a setting that says Groups faces together — preferably the
    // face area in the settings. The user should group all of them together, or group two sides
    // together with another two sides as a different group". Each group's header carries its ONE
    // squeeze force (his answer 1) in its pill — FlexibleSqueezeGroupHeader; a face moves from
    // its card.
}
