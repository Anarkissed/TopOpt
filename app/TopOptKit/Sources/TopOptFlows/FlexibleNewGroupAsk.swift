// FlexibleNewGroupAsk — [+ New] with NOTHING pressed (after Reset all): a tap on a face starts Group 1 — ★ verify of R7-S:
// and with faces pressed, a tap on a face no group holds starts the NEXT group —, and where no
// main-page Load group gives that face a weight the keypad asks it — "How much weight presses here?" (task
// 2026-09-29-flexible-screens, round 7 batch S, 4h; his img4 words of 2026-10-14: "All that should be viewed is the
// "model" folder tab and the "New" one."). ONE line: the face and the group it starts; the keypad opens at once; the face is
// pressed when the pad closes with a weight (FlexibleStageModel.startNewGroup), never per keystroke.

import SwiftUI
import TopOptDesign
import TopOptKit

struct FlexibleNewGroupAsk: View {
    @ObservedObject var model: FlexibleStageModel
    @Binding var padTarget: String?
    let region: Int

    static func padKey(_ r: Int) -> String { "new-group-\(r)" }

    var body: some View {
        let key = Self.padKey(region)
        let next = model.squeezeGroups.count + 1   // the group it starts (Group 1 with nothing pressed)
        HStack(spacing: DS.Space.s) {
            Circle().fill(FlexibleSqueezeGroups.freeColour(in: model.settings, forNumber: next).rgba.color).frame(width: 10, height: 10)
            Text(FlexibleRowCopy.newGroupRow(names: [model.faceName(region)], number: next))
                .font(.system(size: 14, weight: .medium)).foregroundStyle(DS.Color.textPrimary.color)
                .lineLimit(1).minimumScaleFactor(0.85)
            Spacer(minLength: DS.Space.xs)
            Button { padTarget = key } label: {
                Image(systemName: "number").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.Color.accent.color)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(FlexibleRowCopy.askWeight)
        }
        .padding(.horizontal, DS.Space.m)
        .frame(minHeight: FlexibleFaceList.rowHeight)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Color.fillSelected.color))
        .modifier(FlexPadCommit(key: key, padTarget: $padTarget,
                                config: .init(title: FlexibleRowCopy.askWeight, unit: model.weightUnit.label, allowsDecimal: true),
                                seed: nil) { v in model.startNewGroup(region, kg: model.weightUnit.toKg(v)) })
        .onAppear { padTarget = key }
        .onChange(of: region) { padTarget = Self.padKey($0) }
        .accessibilityIdentifier("flexible-new-group-ask")
    }
}
