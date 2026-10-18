// FlexibleEdgePickViews — round 6 item 2 on the Settings page (task 2026-10-08): [+ New] asks [Faces] [Edges/corners]
// on one line; Edges/corners turns the tab into the PICK CARD (the list: one numbered row per edge and corner, its dot
// in its colour on the model; the group's one squeeze force; the "keeps the rest" lines; [Done · N picked] [Cancel]);
// an edges/corners group's tab lists its presses with their flat prism's boxes (★ R7-E1: no Strip width); and on the model
// the candidates are
// drawn — 6 pt strokes and 14 pt dots in their colours, a numbered tag on each (≥ 44 pt to hit), picked ones in the
// group's colour, thicker, with ✓; faint and untagged when they face away. One line per setting (≤ 44 characters).

import SwiftUI
import simd
import TopOptDesign
import TopOptKit

extension FlexibleRowCopy.Info {
    public static let newKind = "Faces: a group of faces pressed straight in, as before. Edges/corners: pick where faces meet; each gets a flat prism you drag in from the edge. The faces' own groups keep the rest. A group holds one or the other."
    public static let edgePick = "Every edge and corner of the part, in colours that never repeat on touching ones, numbered as here. Tap a row or tap the part; tap the same spot again to reach the next one there. Grey rows can't be pressed — the line says why."
    /// ★ R7-E1: the flat prism's rows.
    public static let flatDepth = "How deep the flat prism presses in along its arrow at the edge (the corner). Deeper reaches wider on every face. It stops where the lattice ends (core's columns) and where a face would keep none of itself."
    public static let flatTilt = "Tips the arrow toward one face or the other. 0° is core's halfway; a drag snaps back to it within 3°."
    public static let flatTwist = "Twists the flat prism along the edge: one end presses deeper. It stops when the shallow end reaches 0 mm."
    public static let flatUpDown = "Tips the arrow more into the top face or more into the sides. 0° is core's halfway."
    public static let flatLeftRight = "Swings the arrow between the two side faces. 0° is core's halfway."
}

// MARK: - [+ New]: which kind

/// The [+ New] tab: [Faces] [Edges/corners] on one line, then the faces' list (as before) or the pick card.
struct FlexibleNewGroupKindLine: View {
    @ObservedObject var model: FlexibleStageModel
    var body: some View {
        FlexChips(options: [("faces", FlexibleRowCopy.newKindFaces), ("edges", FlexibleRowCopy.newKindEdges)],
                  selection: model.edgePick == nil ? "faces" : "edges", id: "flexible-new-kind") { id in
            if id == "edges" { model.startEdgePick() } else { model.cancelEdgePick() }
        }
        .frame(minHeight: 36)
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["newKind": g.frame(in: .global)])
        }.allowsHitTesting(false))
    }
}

// MARK: - the pick card

struct FlexibleEdgePickCard: View {
    @ObservedObject var model: FlexibleStageModel
    @Binding var padTarget: String?
    static let weightKey = "edge-pick-weight"

    var body: some View {
        if let p = model.edgePick {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: DS.Space.s) {
                    Circle().fill(p.colour.rgba.color).frame(width: 12, height: 12)
                    Text(FlexibleRowCopy.newGroupTitle(model.squeezeGroups.count + 1))
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color).lineLimit(1)
                    Spacer(minLength: DS.Space.xs)
                    FlexInfoButton(title: FlexibleRowCopy.newKindEdges, text: FlexibleRowCopy.Info.edgePick, id: "flexible-edge-pick-info")
                }
                .frame(minHeight: 36)
                Text(FlexibleRowCopy.edgePickLine(picked: p.picks.count, loading: p.loading))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Color.textSecondary.color)
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .accessibilityIdentifier("flexible-edge-pick-line")
                FlexRow(FlexibleRowCopy.squeezeRow, info: FlexibleRowCopy.Info.squeeze, id: "flexible-edge-pick-squeeze") {
                    FlexNumberBox(key: Self.weightKey, title: FlexibleRowCopy.edgePickWeightAsk,
                                  spec: FlexibleNumberSpecs.weight(kg: p.weightKg ?? 0, unit: model.weightUnit),
                                  padTarget: $padTarget, units: FlexibleWeightUnit.allCases,
                                  onUnit: { model.setWeightUnit($0) }, onNote: { model.toast = $0 }) { v in
                        model.setEdgePickWeight(model.weightUnit.toKg(v))
                    }
                }
                ForEach(model.edgePickKeepsTheRest(), id: \.self) { line in
                    Text(line).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.accent.color)
                        .lineLimit(1).minimumScaleFactor(0.85)
                        .accessibilityIdentifier("flexible-edge-keeps-rest")
                }
                if let line = p.line { FlexWarningLine(text: line, id: "flexible-edge-pick-why") }
                if p.checking { FlexCaption(text: FlexibleRowCopy.edgePickChecking) }
                HStack(spacing: DS.Space.s) {
                    Button {
                        if p.weightKg == nil { padTarget = Self.weightKey }
                        Task { @MainActor in
                            if await model.finishEdgePick() == FlexibleRowCopy.edgePickWeightAsk { padTarget = Self.weightKey }
                        }
                    } label: {
                        Text(FlexibleRowCopy.edgePickDone(p.picks.count))
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(FlexibleStageStyle.onAccent)
                            .padding(.horizontal, 14).frame(minHeight: 44)
                            .background(Capsule().fill((p.picks.isEmpty || p.working ? DS.Color.strokeStrong : DS.Color.accent).color))
                    }
                    .buttonStyle(.plain).disabled(p.picks.isEmpty || p.working)
                    .accessibilityIdentifier("flexible-edge-pick-done")
                    Button { model.cancelEdgePick() } label: {
                        Text(FlexibleRowCopy.edgePickCancel).font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DS.Color.textSecondary.color).padding(.horizontal, 14).frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("flexible-edge-pick-cancel")
                    if p.working { ProgressView().controlSize(.small) }
                }
                ForEach(p.candidates) { c in FlexibleEdgeCandidateRow(model: model, pick: p, candidate: c) }
            }
        }
    }
}

/// One row of the list: "● 7  Corner · Face 1 + Face 2 + Face 3  ☐"; greyed with its one line why.
struct FlexibleEdgeCandidateRow: View {
    @ObservedObject var model: FlexibleStageModel
    let pick: FlexibleEdgePick
    let candidate: FlexibleEdgeCandidates.Candidate

    var body: some View {
        let n = candidate.number
        let picked = pick.picks.contains(n)
        let why = pick.greyed[n]
        let colour = picked ? pick.colour.rgba : (why == nil ? (pick.colours[n]?.rgba ?? DS.Color.strokeStrong) : DS.Color.textDisabled)
        Button { model.toggleEdgePick(n) } label: {
            HStack(spacing: DS.Space.s) {
                Text("\(n)").font(.system(size: 11, weight: .bold)).monospacedDigit()
                    .foregroundStyle(DS.Color.background.color)
                    .frame(minWidth: 22, minHeight: 22).background(Circle().fill(colour.color))
                VStack(alignment: .leading, spacing: 1) {
                    Text(FlexibleRowCopy.candidateRow(candidate, names: candidate.members.map { model.displayName($0) }))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle((why == nil ? DS.Color.textPrimary : DS.Color.textDisabled).color)
                        .lineLimit(1).minimumScaleFactor(0.85)
                    if let why {
                        Text(why).font(.system(size: 11, weight: .medium)).foregroundStyle(DS.Color.textTertiary.color)
                            .lineLimit(1).minimumScaleFactor(0.85)
                    }
                }
                Spacer(minLength: DS.Space.xs)
                if why == nil {
                    Image(systemName: picked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle((picked ? pick.colour.rgba : DS.Color.textTertiary).color)
                }
            }
            .padding(.horizontal, DS.Space.m)
            .frame(minHeight: FlexibleFaceList.rowHeight)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill((picked ? DS.Color.fillSelected : DS.Color.fillSubtle).color))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder((picked ? pick.colour.rgba : DS.Color.strokeSubtle).color, lineWidth: picked ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(why != nil)
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["edgeRow-\(n)": g.frame(in: .global)])
        }.allowsHitTesting(false))
        .accessibilityLabel(FlexibleRowCopy.candidateLabel(candidate) + (why.map { ", " + $0 } ?? (picked ? ", picked" : "")))
        .accessibilityIdentifier("flexible-edge-row-\(n)")
    }
}

// MARK: - an edges/corners group's tab

/// The group's presses: each one's name and trash, its one warning line, its flat prism's Deepest squish, Tilt and Twist (a
/// corner: Up/down, Left/right) boxes, [Back to halfway] when off it, and the faces that keep the rest. ★ R7-E1 (his 2026-10-18
/// words: "There shouldn't be a strip width."): no Strip width / Patch size row. One line per setting (≤ 44).
struct FlexibleEdgeGroupRows: View {
    @ObservedObject var model: FlexibleStageModel
    let group: FlexibleSqueezeGroup
    @Binding var padTarget: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            ForEach(group.presses, id: \.self) { id in
                if let p = model.press(id) { row(p) }
            }
        }
    }

    @ViewBuilder private func row(_ p: FlexiblePress) -> some View {
        let selected = model.selectedPress == p.id
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: p.kind == .corner ? "cube" : "line.diagonal")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(model.groupColour(group).color)
                Text(model.stripTitle(p.id))
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(DS.Color.textPrimary.color)
                    .lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: DS.Space.xs)
                Button { model.removePress(p.id) } label: {
                    Image(systemName: "trash").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.Color.textTertiary.color).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(p.strip?.label ?? "the press")")
                .accessibilityIdentifier("flexible-edge-press-remove-\(p.strip?.label ?? "")")
            }
            .frame(minHeight: FlexibleFaceList.rowHeight)
            .contentShape(Rectangle())
            .onTapGesture { model.selectedPress = p.id }
            // ★ R7-E1: ONE warning line, the first that applies — core refused it › a lattice stop (with its fix) › not sent yet
            if let why = model.pressRefusals[p.id] {
                FlexWarningLine(text: why, id: "flexible-edge-press-refused")
            } else if let stop = model.lastFlatStop, stop.press == p.id {
                HStack(spacing: DS.Space.s) {
                    FlexWarningLine(text: stop.line, id: "flexible-flat-stop-line")
                    if let mm = stop.setMM, mm >= FlexibleFlatPrism.minDepthMM {
                        Button {
                            Task { @MainActor in if let why = await model.setFlatCut(p.id, depthMM: mm, direction: p.direction, snap: p.snap) { model.toast = why } }
                        } label: {
                            Text(FlexibleRowCopy.flatSetMM(mm)).font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(FlexibleStageStyle.onAccent).padding(.horizontal, 12).frame(minHeight: 44)
                                .background(Capsule().fill(FlexibleStageStyle.accent))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("flexible-flat-set-mm")
                    }
                }
            } else {
                FlexCaption(text: FlexibleRowCopy.pressNotSent)
            }
            if let st = p.strip, let shown = FlexibleFlatPrismUI.shown(model: model, press: p.id) {
                flatRows(p, st, shown)
            }
            ForEach(model.keepsTheRest(press: p.id), id: \.self) { line in
                Text(line).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.textSecondary.color)
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .accessibilityIdentifier("flexible-edge-press-keeps-rest")
            }
        }
        .padding(.horizontal, DS.Space.m).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill((selected ? DS.Color.fillSelected : DS.Color.fillSubtle).color))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder((selected ? model.groupColour(group) : DS.Color.strokeSubtle).color, lineWidth: selected ? 1.5 : 1))
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["edgePress-\(p.strip?.label ?? p.id.uuidString)": g.frame(in: .global)])
        }.allowsHitTesting(false))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flexible-edge-press-\(p.strip?.label ?? "")")
    }

    /// ★ R7-E1: the flat prism's rows — the same numbers as the chip and the knob's boxes on the model (one store: the press).
    @ViewBuilder private func flatRows(_ p: FlexiblePress, _ st: FlexibleStrip, _ shown: FlexibleFlatPrismUI.Shown) -> some View {
        let corner = st.kind == .corner
        let range = model.press(p.id).map { _ in
            FlexibleFlatPrismAngles.depthRange(st, d: model.flatCut(p.id)?.direction ?? p.direction, limits: model.flatLimits(p.id, withLattice: true))
        }
        let f = FlexibleFlatPrismUI.frame(model, p.id)
        let name: (Int) -> String = { FlexibleFlatPrismUI.memberName(model, st, $0) }
        FlexRow(FlexibleRowCopy.flatDeepestRow, info: FlexibleRowCopy.Info.flatDepth, id: "flexible-row-deepest") {
            FlexNumberBox(key: "flat-depth-card-\(p.id.uuidString)", title: st.label + " \u{00B7} " + FlexibleRowCopy.flatDeepestRow,
                          spec: FlexNumberSpec(value: shown.depthMM, unit: "mm", step: 0.5,
                                               range: (range?.min ?? FlexibleFlatPrism.minDepthMM)...max(range?.min ?? 0.5, range?.max ?? 100), decimals: 1),
                          padTarget: $padTarget, onNote: { model.toast = $0 }, twin: "flat-depth-\(p.id.uuidString)") { v in
                Task { @MainActor in if let why = await model.setFlatCut(p.id, depthMM: v, direction: model.flatCut(p.id)?.direction ?? p.direction, snap: p.snap) { model.toast = why } }
            }
        }
        .background(publish("flatRow-deepest-\(st.label)"))
        FlexRow(corner ? FlexibleRowCopy.flatUpDownRow(into: f.map { name($0.tiltMember) } ?? "the top")
                       : FlexibleRowCopy.flatTiltRow(toward: name(0)),
                info: corner ? FlexibleRowCopy.Info.flatUpDown : FlexibleRowCopy.Info.flatTilt, id: "flexible-row-tilt") {
            angleBox(p, st, tilt: true, value: shown.tilt)
        }
        .background(publish("flatRow-tilt-\(st.label)"))
        FlexRow(corner ? FlexibleRowCopy.flatLeftRightRow(toward: f.flatMap { $0.twistMember }.map(name) ?? "a side")
                       : FlexibleRowCopy.flatTwistRow(end: f?.namedEnd ?? "one end"),
                info: corner ? FlexibleRowCopy.Info.flatLeftRight : FlexibleRowCopy.Info.flatTwist, id: "flexible-row-twist") {
            angleBox(p, st, tilt: false, value: shown.twist)
        }
        .background(publish("flatRow-twist-\(st.label)"))
        if let d0 = FlexibleFlatPrism.halfway(of: p), FlexiblePressAim.bits(model.flatCut(p.id)?.direction ?? p.direction) != FlexiblePressAim.bits(d0) {
            Button {
                Task { @MainActor in if let why = await model.flatBackToHalfway(p.id) { model.toast = why } }
            } label: {
                Text(FlexibleRowCopy.flatBackToHalfway).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary.color).padding(.horizontal, 12).frame(minHeight: 44)
                    .background(Capsule().fill(DS.Color.chipSolid.color))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("flexible-flat-back-to-halfway")
        }
    }

    /// Its frame reaches the page (the hosted tests read it): "flatRow-<row>-<label>".
    private func publish(_ key: String) -> some View {
        GeometryReader { g in Color.clear.preference(key: FlexibleKeepOutKey.self, value: [key: g.frame(in: .global)]) }.allowsHitTesting(false)
    }

    private func angleBox(_ p: FlexiblePress, _ st: FlexibleStrip, tilt: Bool, value: Double) -> some View {
        let key = (tilt ? "flat-tilt-" : "flat-twist-") + p.id.uuidString
        return FlexNumberBox(key: key + "-card", title: st.label + " \u{00B7} " + (tilt ? FlexibleRowCopy.flatTiltWord(corner: st.kind == .corner)
                                                                                         : FlexibleRowCopy.flatTwistWord(corner: st.kind == .corner)),
                             spec: FlexNumberSpec(value: (value * 10).rounded() / 10, unit: "\u{00B0}", step: 1, range: -89...89, decimals: 1),
                             padTarget: $padTarget, allowsNegative: true, twin: key) { v in
            Task { @MainActor in if let why = await model.setFlatAngle(p.id, degrees: v, tilt: tilt) { model.toast = why } }
        }
    }
}

// MARK: - on the model

/// ★ PICK MODE ON THE MODEL: every candidate through the page's projection — edges as 6 pt strokes, corners as 14 pt
/// dots, in their colours (picked: the group's, thicker, ✓) — and a numbered tag on each one facing the camera (a
/// button, ≥ 44 pt to hit; under the chrome, none). The strokes are cut out of the chrome like every line on the part.
struct FlexibleEdgePickOverlay: View {
    @ObservedObject var model: FlexibleStageModel
    @ObservedObject var proj: FlexibleProjectionBox
    var keepOut: [CGRect] = []
    var clip: [CGRect]? = nil

    /// What the overlay draws, as values (the evidence probe and the tests read the same list).
    struct Mark: Equatable {
        let number: Int
        let colour: RGBA
        let picked: Bool
        let greyed: Bool
        let front: Bool
        let projected: FlexibleEdgePickRules.Projected
        /// The tag's text and its hit rectangle (nil: no tag).
        let text: String
        let target: CGRect?
    }

    @MainActor
    static func marks(model: FlexibleStageModel, projection: CameraProjection?, keepOut: [CGRect] = []) -> [Mark] {
        guard let p = model.edgePick, !p.loading, let projection else { return [] }
        let shown = FlexibleEdgePickRules.project(p.candidates, loads: p.loads, projection: projection)
        let s = FlexibleEdgePickRules.tagTargetPt
        return shown.map { c in
            let picked = p.picks.contains(c.number)
            let greyed = p.greyed[c.number] != nil
            let colour = picked ? p.colour.rgba : greyed ? DS.Color.textDisabled : (p.colours[c.number]?.rgba ?? DS.Color.strokeStrong)
            var target: CGRect? = nil
            if let t = c.tag {
                let r = CGRect(x: t.x - s / 2, y: t.y - s / 2, width: s, height: s)
                if !keepOut.contains(where: { $0.intersects(r) }) { target = r }
            }
            return Mark(number: c.number, colour: colour, picked: picked, greyed: greyed, front: c.front, projected: c,
                        text: picked ? "✓\(c.number)" : "\(c.number)", target: target)
        }
    }

    var body: some View {
        let marks = Self.marks(model: model, projection: proj.projection, keepOut: keepOut)
        ZStack {
            Canvas { ctx, size in
                if let clip { FlexibleChromeClip.apply(&ctx, size: size, holes: clip) }
                for m in marks.sorted(by: { ($0.picked ? 1 : 0, $0.front ? 1 : 0) < ($1.picked ? 1 : 0, $1.front ? 1 : 0) }) {
                    let o = m.front ? 1 : FlexibleEdgePickRules.backFacingOpacity
                    let colour = m.colour.color.opacity(m.greyed ? 0.5 * o : o)
                    if m.projected.kind == .corner {
                        guard let q = m.projected.point else { continue }
                        let d = m.picked ? FlexibleEdgePickRules.pickedDotPt : FlexibleEdgePickRules.cornerDotPt
                        ctx.fill(Path(ellipseIn: CGRect(x: q.x - d / 2, y: q.y - d / 2, width: d, height: d)), with: .color(colour))
                    } else {
                        var path = Path()
                        for pl in m.projected.lines { path.addLines(pl) }
                        ctx.stroke(path, with: .color(colour),
                                   style: StrokeStyle(lineWidth: m.picked ? FlexibleEdgePickRules.pickedStrokePt : FlexibleEdgePickRules.edgeStrokePt,
                                                      lineCap: .round, lineJoin: .round))
                    }
                }
            }
            .allowsHitTesting(false)
            ForEach(marks.filter { $0.target != nil }, id: \.number) { m in
                Button { model.toggleEdgePick(m.number) } label: {
                    Text(m.text).font(.system(size: 12, weight: .bold)).monospacedDigit()
                        .foregroundStyle(DS.Color.background.color)
                        .padding(.horizontal, 6).frame(minWidth: 24, minHeight: 22)
                        .background(Capsule().fill(m.colour.color.opacity(m.greyed ? 0.6 : 1)))
                        .overlay(Capsule().strokeBorder(DS.Color.background.color.opacity(0.6), lineWidth: 1))
                        .frame(width: FlexibleEdgePickRules.tagTargetPt, height: FlexibleEdgePickRules.tagTargetPt)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .position(x: m.target!.midX, y: m.target!.midY)
                .accessibilityLabel("\(m.number)")
                .accessibilityIdentifier("flexible-edge-tag-\(m.number)")
            }
        }
    }
}
