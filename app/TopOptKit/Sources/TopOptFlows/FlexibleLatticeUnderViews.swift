// FlexibleLatticeUnderViews — ★ BATCH E REVIEW: the Settings row a pressed face shows when there is
// no lattice under it at all (task 2026-09-29-flexible-screens).
//
// The "Deepest squish" row read "3.0 mm" on his saved pad's Top B while every edit — a typed 3, a
// drag of the 3D chip — was clamped to 0.5 mm with only "Kept within 0.1–0.5 mm". With no lattice
// under the face there is nothing to sink into: the row says so in ONE line, in the warning colour,
// with the one-tap fix beside it (the pop-up's own [Lattice under it]); the 3D chip is not drawn
// (FlexibleDepthChips) and the stored value is kept for when the lattice is there.

import SwiftUI
import TopOptKit
import TopOptDesign

struct FlexibleDeepestNoLatticeRow: View {
    @ObservedObject var model: FlexibleStageModel
    let region: Int

    var body: some View {
        FlexRow(FlexibleLatticeUnder.deepestNoLattice, info: FlexibleRowCopy.Info.deepest,
                id: "flexible-row-deepest", warning: true) {
            if model.latticeUnderPlan(region) != nil {
                Button { model.latticeUnder(region) } label: {
                    Text(FlexibleFix.latticeUnder(region).title { _ in "" })
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.Color.textPrimary.color)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(Capsule().fill(DS.Color.warning.color.opacity(0.35)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("flexible-deepest-lattice-under")
            }
        }
    }
}
