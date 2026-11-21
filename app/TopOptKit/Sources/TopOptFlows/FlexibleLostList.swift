// FlexibleLostList — "Upload new version" on a Flexible part, his pick 3 (2026-11-12): what found no face on the new model is
// KEPT AND FLAGGED. At the top of the Squish page's open tab, one row per lost item — its old name, what it was, [Pick its
// face] (an edge or corner press: [Pick its edge]) and [Remove] (asks first) — until each has a face or is removed. The run
// waits meanwhile (FlexibleReadiness, `lostOnNewModel`).
import SwiftUI
import TopOptDesign

struct FlexibleLostList: View {
    @ObservedObject var model: FlexibleStageModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            FlexWarningLine(text: FlexibleNewModelCopy.lostLine(model.lostItems.count), id: "flexible-lost-title")
            ForEach(Array(model.lostItems.enumerated()), id: \.offset) { n, item in
                row(n, item)
            }
        }
        .padding(.vertical, DS.Space.xs)
        .background(FlexibleCornerPairStyle.publish("lostList"))
    }

    private func row(_ n: Int, _ item: FlexibleLostItem) -> some View {
        let armed = model.lostPick == n
        return HStack(spacing: DS.Space.s) {
            Text(FlexibleNewModelCopy.row(name(item), what(item)))
                .font(.system(size: 13)).foregroundStyle(DS.Color.textPrimary.color)
                .lineLimit(1).minimumScaleFactor(0.85)
                .layoutPriority(1)
            Spacer(minLength: DS.Space.xs)
            Button { model.pickLost(n) } label: {
                Text(item.needsEdge ? FlexibleNewModelCopy.pickEdge : FlexibleNewModelCopy.pickFace)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle((armed ? DS.Color.textPrimary : DS.Color.accent).color)
                    .padding(.horizontal, 10).frame(height: FlexChips.chipHeight)
                    .background(Capsule().fill(armed ? DS.Color.fillSelected.color : Color.clear))
                    .frame(minWidth: FlexChips.target, minHeight: FlexChips.target).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(FlexibleTouch.publish("lostPick-\(n)"))
            .accessibilityIdentifier("flexible-lost-pick-\(n)")
            Button { FlexibleFixPopup.tap(.dropLost(n), model: model, scope: "lost") {} } label: {
                Text(FlexibleNewModelCopy.remove)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.textSecondary.color)
                    .frame(minWidth: FlexChips.target, minHeight: FlexChips.target).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(FlexibleTouch.publish("lostDrop-\(n)"))
            .accessibilityIdentifier("flexible-lost-drop-\(n)")
        }
        .frame(minHeight: 44)
    }

    /// Its OLD face is not on the new model (a name read off the new model could name another face), so a face is "A face"
    /// with what it was and its weight; an edge or corner press keeps its old label (never a face number — his rule 10-24).
    private func name(_ item: FlexibleLostItem) -> String {
        switch item {
        case .face: return FlexibleNewModelCopy.aFace
        case .press(let p): return p.strip?.label ?? FlexibleNewModelCopy.aFace
        }
    }

    private func what(_ item: FlexibleLostItem) -> String {
        switch item {
        case .face(let f):
            return f.isLoaded ? "\(FlexibleNewModelCopy.wasPressed), \(FlexibleRowCopy.kgNumber(f.weightKg)) kg" : FlexibleNewModelCopy.wasResting
        case .press(let p):
            guard let st = p.strip else { return FlexibleNewModelCopy.wasTilted }
            return st.kind == .corner ? FlexibleNewModelCopy.wasCorner : FlexibleNewModelCopy.wasEdge
        }
    }
}
