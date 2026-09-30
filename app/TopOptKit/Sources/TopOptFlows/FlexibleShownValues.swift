// FlexibleShownValues — which numbers the heat map shows, and how its dent is drawn (task
// 2026-09-29-flexible-screens; moved out of FlexibleStagePage in round 3 so the main
// Flexible page can reuse it).
//
// ★ ROUND 3, ITEM 1 — "THE HEAT MAP BENDS IN 3D" (maintainer, 2026-09-29). The drawn map
// ALWAYS dents: statically while he edits (it holds still), on a loop 0 → full → 0 only once
// a lattice is drawn. The dent is his drawing (S × deepest squish), not a prediction, so it
// says "What you drew" (R7 holds). It needs no filament data, so a calibrate-first filament
// (9 of 10) bends too — its map comes from core's squish_fraction (FlexibleStageModel seeds
// `liveS` for every pressed face as its stack arrives).
// This overturns the pinned rule "a curve step shows the drawing, never an animated dent"
// (FlexibleSquishTests, rewritten deliberately; the curve steps themselves are gone).
//
// ★ ONE INTEGER EXAGGERATION k PER PAGE STATE (decisions): k = clamp(round(0.20 · extent /
// deepest), 1, 10), capped so no column's shown dent passes 0.65 of its own lattice depth
// (the dent never pushes through the far wall), and — with a lattice — by the shader's
// clamp (`maxSafeScale`). The legend says "shown ×k"; the depth prism uses the same k.
// ★ THE PRISM IS CAPPED TOO (verification of round 3): the prism is k × the DEEPEST squish
// (S = 1), not k × what the drawing reaches — a mostly-firm drawing (S 0.09 everywhere) got
// × 10 and a 30 mm prism out through a 20 mm part. `prismCap` holds k × deepest to 0.65 of
// every pressed column's lattice depth as well.
// ★ WHILE THE DEPTH CHIP IS DRAGGED the map is the drawing S × the NEW deepest (the
// designs still hold the old one until release), so the dent fills the prism as it moves.

import Foundation
import TopOptKit

/// One column's value on the overlay.
enum FlexShownValue { case depth(Double), noNumber, solid }

@MainActor
struct FlexibleShownValues {
    var values: [FlexFaceKey: [FlexShownValue]] = [:]
    var maxDepth = 0.0
    var showsDent = false
    /// The dent loops 0 → full → 0 (only while a lattice is drawn); otherwise it holds still.
    var animated = false
    var exaggeration = 1.0
    var label = ""

    /// The legend's one line: "What you drew · shown ×7".
    var legendLine: String { "\(label) · shown ×\(Int(exaggeration))" }

    /// Everything the numbers are read from: the model's copies of core's results. A plain
    /// value, so the rule below is testable without a model (FlexibleSquishTests, T15).
    struct Inputs {
        var loadedFaces: [FlexibleFaceSettings]
        var stacks: [FlexFaceKey: FlexStackInfo]
        var designs: [FlexFaceKey: FlexFaceDesignInfo]
        var liveS: [FlexFaceKey: [Double]]
        var checks: [UUID: FlexStampCheckInfo]
        var checkStamps: [FlexibleCheckStamp]
        var checkStampShown: UUID?
        var showBuildable: Bool
        /// The depth chip is being dragged: the designs are for the OLD deepest squish.
        var editingDepth = false
    }

    static func inputs(_ m: FlexibleStageModel) -> Inputs {
        Inputs(loadedFaces: m.settings.loadedFaces, stacks: m.stacks, designs: m.designs, liveS: m.liveS,
               checks: m.checks, checkStamps: m.settings.checkStamps, checkStampShown: m.checkStampShown,
               showBuildable: m.showBuildable, editingDepth: m.frozenExaggeration != nil)
    }

    init(model m: FlexibleStageModel, drawnLattice: FlexibleGeneratedLattice? = nil) {
        self.init(Self.inputs(m), drawnLattice: drawnLattice)
        // one k while the depth chip is dragged
        if let k = m.frozenExaggeration { exaggeration = k }
    }

    init(_ m: Inputs, drawnLattice: FlexibleGeneratedLattice?) {
        // ★ WHILE THE LATTICE IS DRAWN, THE MAP AND THE DENT ARE THE LATTICE'S: the exact
        // depth arrays its squish faces were built from, so the dent and the walls squish by
        // one set of numbers. ONLY WHERE THE LATTICE OWNS THE MAP (no stamp shown): a shown
        // check stamp keeps "Dent under the stamp".
        if let g = drawnLattice, FlexibleLatticePreview.latticeShows(checkStampShown: m.checkStampShown) {
            for k in g.keys {
                guard let d = g.columnDepths[k] else { continue }
                let noLattice = g.columnNoLattice[k] ?? []
                values[k] = d.enumerated().map { i, x in
                    if i < noLattice.count, noLattice[i] { return .solid }
                    return x.map { .depth($0) } ?? .noNumber
                }
            }
            for v in values.values { for x in v { if case .depth(let d) = x { maxDepth = max(maxDepth, d) } } }
            // ★ BATCH B: a SHAPE-ONLY lattice was built from the drawing itself (no prediction)
            label = g.shapeOnly ? "What you drew" : "What the lattice was built from"
            showsDent = true
            animated = true
            let rule = Self.exaggerationRule(maxDepthMM: maxDepth, extentMM: g.extentMM)
            let thin = min(Self.thinCap(values: values, stacks: m.stacks) ?? rule,
                           Self.prismCap(loadedFaces: m.loadedFaces, stacks: m.stacks) ?? rule)
            exaggeration = Self.cappedExaggeration(rule: min(rule, thin), maxSafeScale: g.maxSafeScale)
            return
        }
        let checkID = m.checkStampShown
        for f in m.loadedFaces {
            let k = FlexFaceKey(region: f.faceRegionID, rotation: f.rotationDeg)
            guard let st = m.stacks[k] else { continue }
            if let id = checkID, let c = m.checks[id],
               m.checkStamps.contains(where: { $0.stamp.id == id && $0.faceRegionID == f.faceRegionID }) {
                values[k] = st.columns.indices.map { i in
                    if let d = c.depthMM[i] { return .depth(d) }
                    return c.status[i] == "beyond_data" ? .noNumber : .depth(0)
                }
                label = "Dent under the stamp"
                continue
            }
            if !m.editingDepth, let d = m.designs[k], d.refusal == nil {
                // core's own copy of the drawing (its target), or — after Generate — what can
                // be built; core's no-lattice columns stay unpainted
                values[k] = d.columns.map { c in
                    if c.status == "no_lattice" { return .solid }
                    if m.showBuildable { return c.buildableOK ? .depth(c.buildableDepthMM) : .noNumber }
                    return .depth(c.targetDepthMM)
                }
                if label.isEmpty { label = m.showBuildable ? "What can be built (estimate)" : "What you drew" }
            } else if let s = m.liveS[k] {
                // ★ THE DRAWN MAP, S × deepest: a drawing, not a prediction — any filament
                values[k] = s.map { .depth($0 * f.deepestMM) }
                if label.isEmpty { label = "What you drew" }
            }
        }
        // ★ ROUND 3: whatever is shown, dents — and holds still (no lattice drawn)
        showsDent = !values.isEmpty
        for v in values.values { for x in v { if case .depth(let d) = x { maxDepth = max(maxDepth, d) } } }
        // ONE SCALE FOR DRAWN AND BUILDABLE: coloured against the same maximum
        if checkID == nil, !m.editingDepth {
            for d in m.designs.values where d.refusal == nil {
                maxDepth = max(maxDepth, d.targetDepthRange?.upperBound ?? 0, d.buildableDepthRange?.upperBound ?? 0)
            }
        }
        let ext = m.stacks.values.map { max($0.uExtentMM, $0.vExtentMM) }.max() ?? 0
        let rule = Self.exaggerationRule(maxDepthMM: maxDepth, extentMM: ext)
        exaggeration = max(1, min(rule, Self.thinCap(values: values, stacks: m.stacks) ?? rule,
                                  Self.prismCap(loadedFaces: m.loadedFaces, stacks: m.stacks) ?? rule))
    }

    /// × 1…10, so the deepest squish reads as about a fifth of the face (an integer: the
    /// legend says "× N"). A 100 mm face at 3 mm: × 7.
    nonisolated static func exaggerationRule(maxDepthMM: Double, extentMM: Double) -> Double {
        guard maxDepthMM > 0, extentMM > 0 else { return 1 }
        return max(1, min(10, (0.20 * extentMM / maxDepthMM).rounded()))
    }

    /// The share of a column's own lattice depth the shown dent may reach.
    nonisolated static let thinShare = 0.65

    /// The largest integer k at which no column's shown dent (k × its depth) passes
    /// `thinShare` of that column's lattice depth — nil when nothing dents. Never below 1:
    /// at × 1 the dent is the drawing itself (the depth chip clamps it to the lattice depth).
    static func thinCap(values: [FlexFaceKey: [FlexShownValue]], stacks: [FlexFaceKey: FlexStackInfo]) -> Double? {
        var cap = Double.infinity
        for (k, v) in values {
            guard let st = stacks[k] else { continue }
            for (i, x) in v.enumerated() where i < st.columns.count {
                guard case .depth(let d) = x, d > 1e-9 else { continue }
                let l = st.columns[i].latticeMM
                guard l > 0 else { continue }
                cap = min(cap, thinCap(depthMM: d, latticeMM: l))
            }
        }
        return cap.isFinite ? cap : nil
    }

    /// The depth prism's own cap: k × a pressed face's DEEPEST squish (S = 1) stays within
    /// `thinShare` of each of its columns' lattice depth — the prism floor never leaves the part.
    /// nil when no pressed face has a stack.
    static func prismCap(loadedFaces: [FlexibleFaceSettings], stacks: [FlexFaceKey: FlexStackInfo]) -> Double? {
        var cap = Double.infinity
        for f in loadedFaces {
            guard let st = stacks[FlexFaceKey(region: f.faceRegionID, rotation: f.rotationDeg)] else { continue }
            let l = st.columns.map(\.latticeMM).filter { $0 > 0 }.min() ?? 0
            guard l > 0 else { continue }
            cap = min(cap, thinCap(depthMM: f.deepestMM, latticeMM: l))
        }
        return cap.isFinite ? cap : nil
    }

    /// One column: floor(0.65 · lattice depth / depth), at least 1.
    nonisolated static func thinCap(depthMM: Double, latticeMM: Double) -> Double {
        guard depthMM > 0 else { return .infinity }
        return max(1, (thinShare * latticeMM / depthMM).rounded(.down))
    }

    /// The rule, capped at the largest integer scale at which no column's face passes the
    /// shader's clamp (`[FlexibleSquishFace].maxSafeScale`) — never below × 1.
    nonisolated static func cappedExaggeration(rule: Double, maxSafeScale: Double) -> Double {
        guard maxSafeScale.isFinite else { return rule }
        return max(1, min(rule, maxSafeScale.rounded(.down)))
    }
}
