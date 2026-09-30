// FlexibleFaceList — the faces set on the main page, listed on the Settings panel (task
// 2026-09-29-flexible-screens, round 4 batch D1; his img 1: "I think it should *list* the
// different faces that have been selected in the previous screen and when you tap on one,
// the values show up and get modified below to match the value saved to the face. And make
// it obvious that it's selectable.").
//
// ★ ONE BIG ROW PER FACE — "Top A · Pressed · 10 kg" / "Face 0 · Rests" — pressed faces first,
// each a 48 pt button with a chevron; the selected one is filled, outlined in the accent and
// ticked. A tap SELECTS that region (a split sector as itself, `FlexibleStageModel.select`):
// the rows below it (Pressed / Rests, weight, Shape, depth) are that face's, and the part
// shows it selected. Every row is one line (FlexibleRowCopy.faceRow).

import SwiftUI
import TopOptDesign
import TopOptKit

struct FlexibleFaceList: View {
    @ObservedObject var model: FlexibleStageModel

    /// A row's height: big, obviously a button (the HIG's 44 and then some).
    static let rowHeight: CGFloat = 48

    struct Row: Equatable, Identifiable {
        let region: Int
        let line: String
        let pressed: Bool
        let selected: Bool
        var id: Int { region }
    }

    /// Every face the Flexible settings hold (the main page's groups arrive here as pressed or
    /// resting faces — FlexibleMainPageLoads.adopt), pressed first, each in its saved order.
    @MainActor
    static func rows(model: FlexibleStageModel) -> [Row] {
        let faces = model.settings.faces
        let ordered = faces.filter(\.isLoaded) + faces.filter { !$0.isLoaded }
        return ordered.map { f in
            Row(region: f.faceRegionID,
                line: FlexibleRowCopy.faceRow(name: model.faceName(f.faceRegionID), pressed: f.isLoaded, kg: f.weightKg),
                pressed: f.isLoaded, selected: f.faceRegionID == model.selectedRegion)
        }
    }

    var body: some View {
        let rows = Self.rows(model: model)
        VStack(alignment: .leading, spacing: 6) {
            if !rows.isEmpty {
                FlexSectionTitle(text: FlexibleRowCopy.facesTitle)
            }
            ForEach(rows) { row in
                Button { model.select(row.region) } label: { label(row) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("flexible-face-row-\(row.region)")
                    .accessibilityLabel(row.line)
                    .accessibilityAddTraits(row.selected ? [.isButton, .isSelected] : .isButton)
            }
            squeezeGroupRows
        }
    }

    private func label(_ row: Row) -> some View {
        HStack(spacing: DS.Space.s) {
            Circle()
                .fill((row.pressed ? DS.Color.accentGreen : DS.Color.accentCyan).color)
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

    // MARK: ★ SQUEEZE GROUPS (batch D2) — the group rows go HERE.
    // His img 4: "there needs to be a setting that says Groups faces together — preferably the
    // face area in the settings. The user should group all of them together, or group two sides
    // together with another two sides as a different group". D2 adds the group rows (a group's
    // faces, its ONE squeeze force — his answer 1: "Squeeze 10 kg" applies to every face in the
    // group, like two hands pressing equally; each face keeps its own curve) right under the
    // faces above. Nothing is drawn here until then.
    @ViewBuilder private var squeezeGroupRows: some View {
        EmptyView()
    }
}
