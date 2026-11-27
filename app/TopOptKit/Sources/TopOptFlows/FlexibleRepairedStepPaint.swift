// FlexibleRepairedStepPaint — Paint is OFF on a part the STEP repair changed (PR #362, the reviewer's
// ruling of 2026-10-23 18:56, item 3, approved by the maintainer): "disabled on a part the repair
// changed, with ONE short line on the paint tool saying why (triangle numbers no longer match core's
// run mesh); every other part paints as today; lifts when core drops the slivers."
//
// Why: paint is a triangle-indexed sidecar (PaintModel → write_face_overrides). Core's run re-reads
// the STEP and tessellates it again itself, with the pole slivers (T1) or the broken face (T2) the
// repair removed, so a painted triangle number would land on a different triangle there.
//
// Wired by ONE line in WorkspacePlaceholder (hook H48, on the Paint chip's row). On every part the
// repair did not change the modifier returns the chip untouched.
import SwiftUI
import TopOptKit
import TopOptDesign

public enum FlexibleRepairedStepPaint {
    /// The one line on the paint tool (≤ 44 characters).
    public static let line = "Paint off · this STEP was repaired on import"

    /// Paint is offered unless the part at `path` came back repaired from its import.
    public static func paintAllowed(path: String?) -> Bool {
        guard let path else { return true }
        return !StepMeshRepair.wasRepaired(path: path)
    }
}

extension View {
    /// H48's gate: on a repaired STEP the Paint chip is disabled and carries the one line.
    func flexibleRepairedStepPaintGate(path: String?) -> some View {
        modifier(FlexibleRepairedStepPaintGate(allowed: FlexibleRepairedStepPaint.paintAllowed(path: path)))
    }
}

struct FlexibleRepairedStepPaintGate: ViewModifier {
    let allowed: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if allowed {
            content
        } else {
            VStack(alignment: .trailing, spacing: DS.Space.xs) {
                content.disabled(true).opacity(0.45)
                Text(FlexibleRepairedStepPaint.line)
                    .dsStyle(DS.TypeScale.footnote).fontWeight(.semibold)
                    .foregroundStyle(DS.Color.textSecondary.color)
                    .lineLimit(1)
                    .padding(.vertical, 4).padding(.horizontal, DS.Space.m)
                    .background(Capsule().fill(DS.Surface.panel.color))
            }
            .help("Core's run re-meshes this STEP, so painted triangle numbers would not match it.")
        }
    }
}
