// FlexibleExportPart — B9 (#362), Export part's plan (his Phase 3 note P4, round 2's J-8; ledger P4, J-8; the mockup's
// #flex-plan-export, #flex-plan-export-unbuilt, #flex-plan-export-nojoint).
//
// P4: "Why can't it just be a simple selector? The notification for it not having a built Print Plan is also BEHIND the
// modal." So:
//   * the plan is a plain selector, one segment per plan, each saying built or not built ("Plan A · built │ Plan B · not
//     built yet"); picking one changes what the export says at once; more than 4 scroll sideways;
//   * what the picked plan needs is said INSIDE the card, under the selector (design-system §4.11: nothing a sheet needs
//     shows behind it): "Plan B isn't built yet. Export builds it first." or "Plan B: Lattice ↔ Body has no joint yet"
//     with [Open Print plan];
//   * the main button reads "Build Plan B, then export" (J-8), dim while a seam has no joint.
// Building with joints is the engine's per-plan rebuild (E5 item 55), which waits (the reviewer's 20:54Z re-plan): the
// button says so in the card, as the Print plan's own Build does (FlexiblePrintPlanCopy.buildNeedsEngine). Nothing is
// built in the app, so no plan reads "built" until E5 lands.

import SwiftUI
import TopOptDesign

public enum FlexibleExportPlan {
    public struct Segment: Equatable, Sendable {
        public let id: UUID
        public let name: String
        public let built: Bool
        public var title: String { name + " \u{00B7} " + (built ? "built" : "not built yet") }
    }

    public enum Need: Equatable, Sendable {
        case ready
        case notBuilt(String)
        case noJoint(String)
    }

    public static let openPrintPlan = "Open Print plan"
    public static let printPlanLink = "Print plan \u{203A}"
    public static let maxShown = 4

    /// One segment per plan, in the plans' order.
    public static func segments(_ p: FlexiblePrintPlans) -> [Segment] {
        p.plans.map { Segment(id: $0.id, name: $0.name, built: $0.built) }
    }

    /// The plan export would use: the picked one, else the open one.
    public static func plan(_ p: FlexiblePrintPlans, chosen: UUID?) -> FlexiblePrintPlan {
        p.plans.first { $0.id == chosen } ?? p.plan
    }

    /// What the picked plan needs, said in the card: a seam with no joint first (Build can't run), then not built.
    public static func need(_ p: FlexiblePrintPlans, chosen: UUID?) -> Need {
        let plan = plan(p, chosen: chosen)
        if let seam = FlexiblePrintPlanRules.needing(p, in: plan).first {
            return .noJoint("\(plan.name): \(seam.name) has no joint yet")
        }
        return plan.built ? .ready : .notBuilt("\(plan.name) isn't built yet. Export builds it first.")
    }

    /// The main button (J-8): "Export Plan A" when built, else "Build Plan B, then export".
    public static func button(_ p: FlexiblePrintPlans, chosen: UUID?) -> String {
        let plan = plan(p, chosen: chosen)
        return plan.built ? "Export \(plan.name)" : "Build \(plan.name), then export"
    }

    /// Dim while a seam has no joint.
    public static func live(_ n: Need) -> Bool {
        if case .noJoint = n { return false }
        return true
    }
}

/// The selector, the need line and the main button, inside the card's Export step.
struct FlexibleExportPlanSelector: View {
    let plans: FlexiblePrintPlans
    let openPrintPlan: () -> Void
    @State private var chosen: UUID?
    @State private var note: String?

    var body: some View {
        let need = FlexibleExportPlan.need(plans, chosen: chosen)
        let picked = FlexibleExportPlan.plan(plans, chosen: chosen).id
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ScrollView(.horizontal, showsIndicators: plans.plans.count > FlexibleExportPlan.maxShown) {
                HStack(spacing: DS.Space.xs) {
                    ForEach(FlexibleExportPlan.segments(plans), id: \.id) { seg in
                        let on = seg.id == picked
                        Button { chosen = seg.id; note = nil } label: {
                            Text(seg.title).font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(on ? DS.Color.textPrimary.color : DS.Color.textSecondary.color)
                                .lineLimit(1)
                                .padding(.horizontal, DS.Space.m).frame(minHeight: 44)
                                .background(Capsule().fill(on ? DS.Color.fillSelected.color : DS.Color.chipSolid.color))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .accessibilityIdentifier("flexible-export-plan-\(seg.name)")
                        .background(CornerPairStyle.publish("exportPlan-\(seg.name)"))
                    }
                }
            }
            .accessibilityIdentifier("flexible-export-plan-selector")
            switch need {
            case .ready: EmptyView()
            case .notBuilt(let line):
                Text(line).font(.system(size: 13)).foregroundStyle(DS.Color.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("flexible-export-plan-need")
                    .background(CornerPairStyle.publish("exportPlanNeed"))
            case .noJoint(let line):
                HStack(spacing: DS.Space.s) {
                    Text(line).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.warning.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("flexible-export-plan-need")
                        .background(CornerPairStyle.publish("exportPlanNeed"))
                    Button(FlexibleExportPlan.openPrintPlan) { openPrintPlan() }
                        .buttonStyle(.plain).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.Color.accent.color).frame(minHeight: 44)
                        .accessibilityIdentifier("flexible-export-plan-open")
                        .background(CornerPairStyle.publish("exportPlanOpen"))
                }
            }
            let live = FlexibleExportPlan.live(need)
            Button { if live { note = FlexiblePrintPlanCopy.buildNeedsEngine } } label: {
                Text(FlexibleExportPlan.button(plans, chosen: chosen)).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(live ? Color.white : DS.Color.textDisabled.color)
                    .frame(maxWidth: .infinity).frame(minHeight: 44)
                    .background(Capsule().fill(live ? DS.Color.accent.color : DS.Color.fillDisabled.color))
            }
            .buttonStyle(.plain)
            .disabled(!live)
            .accessibilityIdentifier("flexible-export-plan-build")
            .background(CornerPairStyle.publish("exportPlanBuild"))
            if let note {
                Text(note).font(.system(size: 12.5)).foregroundStyle(DS.Color.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("flexible-export-plan-note")
                    .background(CornerPairStyle.publish("exportPlanNote"))
            }
            // ★ J-1: the Print plan from the card too (with a seam lacking its joint, [Open Print plan] is beside the need)
            if live {
                Button(FlexibleExportPlan.printPlanLink) { openPrintPlan() }
                    .buttonStyle(.plain).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Color.accent.color).frame(minHeight: 44)
                    .accessibilityIdentifier("flexible-export-plan-link")
                    .background(CornerPairStyle.publish("exportPlanLink"))
            }
        }
    }
}
