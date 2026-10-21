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
    public static let edgePick = "Only the edges and corners that can be pressed light up on the part, numbered, in colours that never repeat on touching ones. Tap one there; tap the same spot again to reach the next one. A tap where nothing lights up says why."
    /// ★ R7-E1: the flat prism's rows.
    public static let flatDepth = "How deep the flat prism presses in along its arrow at the edge (the corner). Deeper reaches wider on every face. It stops where the lattice ends and where a face would keep none of itself."
    public static let flatTilt = "Tips the arrow toward one face or the other. 0° is halfway between the faces; a drag snaps back to it within 3°."
    public static let flatTwist = "Turns the flat prism along the edge: one end presses deeper. It stops when the shallow end reaches 0 mm."
    public static let flatUpDown = "Tips the arrow more into the top face or more into the sides. 0° is halfway between the faces."
    public static let flatLeftRight = "Swings the arrow between the two side faces. 0° is halfway between the faces."
    /// ★ R7-E4: the flat press's Shape row, its stamp.
    public static let pressShape = "Curves: two curves inside the flat prism — across the edge (one side on each face) and along it. They start as the flat prism itself; drag a point toward the part for softer there. A curve never passes the flat face. [2D] and [3D] open the curves in a window over everything: 2D as two tables, one above the other; 3D on one table, turned with the cube — Front shows the across curve head-on, Top the along curve. OK keeps your changes, Cancel puts them back. Stamp: ONE stamp that sits on the edge (a corner: on its point); drag its handle along the edge. Core designs the lattice for the flat prism; your curves and stamp shape where Play pushes (core does not take them yet)."   // ★ C1: presses are sent
    public static let pressStamp = "What presses the edge. It sits on the edge and slides only along it; a corner's stays on its point, and only its size and turn change."
    public static let pressStampTurn = "Turns the stamp on the edge: 0° lays its long side along the edge; turning it away counts up."
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
                if let g = p.fixGroup { FlexibleEdgeFixGroupButton(model: model, group: g, kp: \.edgePick) }
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
            }
        }
    }
}

/// ★ R7-E1b: a blocked spot's fix — [Open Group N], the group that edge or corner is in.
struct FlexibleEdgeFixGroupButton: View {
    @ObservedObject var model: FlexibleStageModel
    let group: Int
    let kp: ReferenceWritableKeyPath<FlexibleStageModel, FlexibleEdgePick?>
    var body: some View {
        if let g = model.squeezeGroups.first(where: { $0.id == group }) {
            Button { model.openFixGroup(kp) } label: {
                Text(FlexibleRowCopy.openGroup(model.groupName(g))).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FlexibleStageStyle.onAccent).padding(.horizontal, 12).frame(minHeight: 44)
                    .background(Capsule().fill(FlexibleStageStyle.accent))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("flexible-edge-open-group")
        }
    }
}

// MARK: - an edges/corners group's tab

/// The group's presses: each one's name and trash, its one warning line, its flat prism's Deepest squish, Tilt and Twist (a
/// corner: Up/down, Left/right) boxes, [Back to halfway] when off it, and the faces that keep the rest. ★ R7-E1 (his 2026-10-18
/// words: "There shouldn't be a strip width."): no Strip width / Patch size row. One line per setting (≤ 44).
struct FlexibleEdgeGroupRows: View {
    /// ★ U1, RED CONTROL only: Shape after the angles, on the working press only (R7-E4's card).
    nonisolated(unsafe) static var controlShapeAfterAngles = false
    @ObservedObject var model: FlexibleStageModel
    let group: FlexibleSqueezeGroup
    @Binding var padTarget: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            // ★ R7-E1b (his answer: "in a group, tapping an edge/corner adds it"): the lit ones on the part are what a tap adds
            if let a = model.edgeAdd, a.into == group.id {
                // ★ R7-E3 (his notes of 2026-10-19 ~14:40): nothing else lit until [+]; a tap on an edge or corner adds it either way
                let lit = model.edgeAddLit
                HStack(spacing: DS.Space.s) {
                    FlexCaption(text: !lit ? FlexibleRowCopy.edgeAddTapLine
                                : a.loading || a.checking ? FlexibleRowCopy.edgePickLine(picked: 0, loading: true) : FlexibleRowCopy.edgeAddLine)
                        .accessibilityIdentifier("flexible-edge-add-line")
                    Spacer(minLength: DS.Space.xs)
                    Button { model.toggleEdgeAdding() } label: {
                        Group {
                            if lit { Text(FlexibleRowCopy.edgeAddDone).font(.system(size: 13, weight: .semibold)) }
                            else { Image(systemName: "plus").font(.system(size: 15, weight: .bold)) }
                        }
                        .foregroundStyle(FlexibleStageStyle.onAccent).padding(.horizontal, 12).frame(minWidth: 44, minHeight: 44)
                        .background(Capsule().fill(FlexibleStageStyle.accent))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(lit ? FlexibleRowCopy.edgeAddDone : FlexibleRowCopy.edgeAddPlus)
                    .accessibilityIdentifier("flexible-edge-add-plus")
                }
                if let line = a.line { FlexWarningLine(text: line, id: "flexible-edge-add-why") }
                if let g = a.fixGroup { FlexibleEdgeFixGroupButton(model: model, group: g, kp: \.edgeAdd) }
            }
            ForEach(group.presses, id: \.self) { id in
                if let p = model.press(id) { row(p) }
            }
        }
    }

    @ViewBuilder private func row(_ p: FlexiblePress) -> some View {
        let selected = model.selectedPress == p.id
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: DS.Space.s) {
                let asking = model.pressRemoveAsk == p.id   // ★ U21: the trash's question is on this line
                Image(systemName: p.kind == .corner ? "cube" : "line.diagonal")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(model.groupColour(group).color)
                    .opacity(asking ? 0 : 1)
                Text(model.stripTitle(p.id))
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(DS.Color.textPrimary.color)
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .opacity(asking ? 0 : 1)
                Spacer(minLength: DS.Space.xs)
                // ★ U21 (DEL-CONFIRM, his Img13): the trash ASKS in place — [Keep] where it was, [Remove] to its left
                Button { model.askRemovePress(p.id) } label: {
                    Image(systemName: "trash").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.Color.textTertiary.color).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(FlexibleConfirmInPlace(asking: model.pressRemoveAsk == p.id,
                                                 question: FlexibleConfirmCopy.removeAsk(p.strip?.label ?? model.stripTitle(p.id)),
                                                 destructive: FlexibleConfirmCopy.remove, confirmKey: "pressRemoveConfirm",
                                                 keepKey: "pressRemoveKeep", questionID: "flexible-press-remove-ask",
                                                 confirm: { model.confirmRemovePress() }, cancel: { model.keepPress() }))
                .background(FlexibleConfirmInPlace.publish("pressRemove-\(p.strip?.label ?? "")"))
                .accessibilityLabel("Remove \(p.strip?.label ?? "the press")")
                .accessibilityIdentifier("flexible-edge-press-remove-\(p.strip?.label ?? "")")
            }
            .frame(minHeight: FlexibleFaceList.rowHeight)
            .contentShape(Rectangle())
            .onTapGesture { model.selectedPress = p.id }
            // ★ R7-E1: ONE warning line, the first that applies — core refused it › a lattice stop (with its fix) › not sent yet
            // ★ R7-E2 (found by looking — his twisted Edge 16: "Twist stops at 7° · lattice ends" hid "Twisted · squish shape up to
            // 16% off"): a lattice stop is said about his last change; the press's own line (not in the job and why · how far off a
            // twist is · core's side label) stays under it — two facts, a line each
            if let why = model.pressRefusals[p.id] {
                FlexWarningLine(text: why, id: "flexible-edge-press-refused")
            }
            // ★ R7-E1b: a group selection like the faces have — the press moves to another edges group (its one force)
            if selected { pressGroupChips(p) }
            if model.pressRefusals[p.id] == nil, let stop = model.lastFlatStop, stop.press == p.id {
                FlexStopLine(text: stop.line)   // ★ R7-E1b: RED, one line — the bound and its number
                HStack(spacing: DS.Space.s) {
                    if let ref = stop.prismRef, let mm = stop.prismMM {
                        Button {
                            if let why = model.deepenFacePrism(ref, mm: mm) { model.toast = why }
                        } label: {
                            Text(FlexibleRowCopy.deepenFacePrism(mm)).font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(FlexibleStageStyle.onAccent).padding(.horizontal, 12).frame(minHeight: 44)
                                .background(Capsule().fill(FlexibleStageStyle.accent))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("flexible-flat-deepen-prism")
                    }
                    if let mm = stop.setMM, mm >= FlexibleFlatPrism.minDepthMM {
                        Button {
                            // ★ R7-E1 REVIEW: N is core's number along the RELEASED arrow — the fix keeps that arrow
                            Task { @MainActor in if let why = await model.setFlatCut(p.id, depthMM: mm, direction: stop.direction ?? p.direction,
                                                                                    snap: stop.direction == nil ? p.snap : stop.snap) { model.toast = why } }
                        } label: {
                            Text(mm > (FlexibleFlatPrism.depth(of: p) ?? 0) + 1e-6 ? FlexibleRowCopy.flatDeepenTo(mm) : FlexibleRowCopy.flatSetMM(mm))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(FlexibleStageStyle.onAccent).padding(.horizontal, 12).frame(minHeight: 44)
                                .background(Capsule().fill(FlexibleStageStyle.accent))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("flexible-flat-set-mm")
                    }
                }
            }
            if model.pressRefusals[p.id] == nil, let w = model.pressWarning(p.id) {
                // ★ R7-E2: not in the job (its reason, 1–3 fixes) › twisted more than 2 % off › core's side label
                pressWarningRow(p, w)
            }
            if let st = p.strip, let shown = FlexibleFlatPrismUI.shown(model: model, press: p.id) {
                // ★ U1 (his notes of 2026-10-20, img_1020_8/9: "This is an edge selection. It should be the same table as any
                // face"): a face's order — Shape [Curves | Stamp] (and its stamp's rows), then Deepest squish — then the edge's
                // own Tilt / Twist and [Back to halfway]; Shape on EVERY press, as every face card has it (the curve's view
                // buttons stay on the press he works on). RED CONTROL `controlShapeAfterAngles`: R7-E4's order.
                let working = FlexibleFlatPrismUI.workingPress(model) == p.id
                if Self.controlShapeAfterAngles {
                    flatRows(p, st, shown)
                    if working { FlexiblePressShapeRows(model: model, press: p, strip: st, padTarget: $padTarget) }
                } else {
                    FlexiblePressShapeRows(model: model, press: p, strip: st, padTarget: $padTarget, viewButtons: working)
                    flatRows(p, st, shown)
                }
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

    /// ★ R7-E2: the press's one warning line beyond core's refusal and a lattice stop, and its 1–3 fixes (each one undo step).
    @ViewBuilder private func pressWarningRow(_ p: FlexiblePress, _ w: (line: String, fixes: [FlexiblePressFix], warn: Bool)) -> some View {
        let label = p.strip?.label ?? p.id.uuidString
        VStack(alignment: .leading, spacing: 4) {
            if !w.warn {
                FlexCaption(text: w.line).accessibilityIdentifier("flexible-edge-press-note")
            } else {
                FlexWarningLine(text: w.line, id: "flexible-edge-press-warning")
            }
            if !w.fixes.isEmpty {
                FlexiblePressFixButtons(model: model, fixes: w.fixes)
            }
        }
        // its frame and its words reach the page (the hosted tests read them, as the toast's)
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["pressLine-\(label)": g.frame(in: .global), "pressLine:\(label):" + w.line: .zero])
        }.allowsHitTesting(false))
    }

    /// ★ R7-E1: the flat prism's rows — the same numbers as the chip and the knob's boxes on the model (one store: the press).
    @ViewBuilder private func flatRows(_ p: FlexiblePress, _ st: FlexibleStrip, _ shown: FlexibleFlatPrismUI.Shown) -> some View {
        let corner = st.kind == .corner
        let range = model.press(p.id).map { _ in
            FlexibleFlatPrismAngles.depthRange(st, d: model.flatCut(p.id)?.direction ?? p.direction, limits: model.flatLimits(p.id, withLattice: false))   // ★ R7-E1b: past the lattice, the MODEL holds it (red, with core's number)
        }
        let f = FlexibleFlatPrismUI.frame(model, p.id)
        let name: (Int) -> String = { FlexibleFlatPrismUI.memberName(model, st, $0) }
        let steep = f?.thetaIsTwist ?? false   // ★ R7-E1b: Tilt = up/down, Twist = left/right
        FlexRow(FlexibleRowCopy.flatDeepestRow, info: FlexibleRowCopy.Info.flatDepth, id: "flexible-row-deepest") {
            FlexNumberBox(key: "flat-depth-card-\(p.id.uuidString)", title: st.label + " \u{00B7} " + FlexibleRowCopy.flatDeepestRow,
                          spec: FlexNumberSpec(value: shown.depthMM, unit: "mm", step: 0.5,
                                               range: (range?.min ?? FlexibleFlatPrism.minDepthMM)...max(range?.min ?? 0.5, range?.max ?? 100), decimals: 1),
                          padTarget: $padTarget, onNote: { model.toast = $0 }, twin: "flat-depth-\(p.id.uuidString)") { v in
                Task { @MainActor in if let why = await model.setFlatCut(p.id, depthMM: v, direction: model.flatCut(p.id)?.direction ?? p.direction, snap: p.snap) { model.toast = why } }
            }
        }
        .background(publish("flatRow-deepest-\(st.label)"))
        // ★ R7-E3 (carry-over (c), E1b's open question 2): the row that READS "Tilt" always comes first, then "Twist" — on a steep
        // edge the θ row reads "Twist", so it goes second (FlexibleFlatPrismUI.tiltFirst)
        let thetaFirst = FlexibleFlatPrismUI.thetaRowFirst(corner: corner, steep: steep)
        if thetaFirst { thetaRow(p, st, shown, corner: corner, f: f, name: name, steep: steep) }
        FlexRow(corner ? FlexibleRowCopy.flatLeftRightRow(toward: f.flatMap { $0.twistMember }.map(name) ?? "a side")
                       : FlexibleRowCopy.flatTwistRow(end: f?.namedEnd ?? "one end", steep: steep),
                info: corner ? FlexibleRowCopy.Info.flatLeftRight : FlexibleRowCopy.Info.flatTwist, id: "flexible-row-twist") {
            angleBox(p, st, tilt: false, value: shown.twist)
        }
        .background(publish("flatRow-twist-\(st.label)"))
        if !thetaFirst { thetaRow(p, st, shown, corner: corner, f: f, name: name, steep: steep) }
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

    /// ★ R7-E1b: the edges groups by name, the press's own lit — a tap moves it there (one undo step). Only with two or more.
    @ViewBuilder private func pressGroupChips(_ p: FlexiblePress) -> some View {
        let groups = model.squeezeGroups.filter { $0.kind == .edges }
        if groups.count > 1 {
            FlexRow(FlexibleRowCopy.groupRow, info: FlexibleRowCopy.Info.groupRow, id: "flexible-edge-press-group") {
                ScrollView(.horizontal, showsIndicators: false) {
                    FlexChips(options: groups.map { ("\($0.id)", model.groupName($0)) }, selection: "\(group.id)",
                              id: "flexible-edge-group", equalWidths: false) { v in if let g = Int(v) { model.movePress(p.id, to: g) } }
                        .fixedSize()
                }
            }
            .background(publish("edgeGroupChips-\(p.strip?.label ?? "")"))
        }
    }

    /// Its frame reaches the page (the hosted tests read it): "flatRow-<row>-<label>".
    private func publish(_ key: String) -> some View {
        GeometryReader { g in Color.clear.preference(key: FlexibleKeepOutKey.self, value: [key: g.frame(in: .global)]) }.allowsHitTesting(false)
    }

    @ViewBuilder private func thetaRow(_ p: FlexiblePress, _ st: FlexibleStrip, _ shown: FlexibleFlatPrismUI.Shown, corner: Bool,
                                       f: FlexibleFlatPrismAngles.Frame?, name: @escaping (Int) -> String, steep: Bool) -> some View {
        FlexRow(corner ? FlexibleRowCopy.flatUpDownRow(into: f.map { name($0.tiltMember) } ?? "the top")
                       : FlexibleRowCopy.flatTiltRow(toward: name(0), steep: steep),
                info: corner ? FlexibleRowCopy.Info.flatUpDown : FlexibleRowCopy.Info.flatTilt, id: "flexible-row-tilt") {
            angleBox(p, st, tilt: true, value: shown.tilt)
        }
        .background(publish("flatRow-tilt-\(st.label)"))
    }

    private func angleBox(_ p: FlexiblePress, _ st: FlexibleStrip, tilt: Bool, value: Double) -> some View {
        let key = (tilt ? "flat-tilt-" : "flat-twist-") + p.id.uuidString
        let steep = FlexibleFlatPrismUI.frame(model, p.id)?.thetaIsTwist ?? false
        return FlexNumberBox(key: key + "-card", title: st.label + " \u{00B7} " + FlexibleFlatPrismUI.boxLabel(tilt: tilt, corner: st.kind == .corner, steep: steep),
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
    /// ★ R7-E1b: the open edges group's lit ones (model.edgeAdd) — a tag ADDS it to the group; else [+ New]'s pick card.
    var add = false

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
    static func marks(model: FlexibleStageModel, projection: CameraProjection?, keepOut: [CGRect] = [], add: Bool = false) -> [Mark] {
        guard let p = add ? model.edgeAdd : model.edgePick, !p.loading, let projection else { return [] }
        // ★ R7-E3 (his notes of 2026-10-19 ~14:40): in a group, the other edges and corners are lit only while its [+] is on
        if add, !model.edgeAddLit { return [] }
        // ★ R7-E1b (his answer: no list; only the pressable light up): what cannot be pressed is not drawn
        let shown = FlexibleEdgePickRules.project(p.drawn, loads: p.loads, projection: projection)
        let s = FlexibleEdgePickRules.tagTargetPt
        // ★ R7-E3, found by looking (E3_02: two "12" tags — the one edge of the part a flat prism split in two pieces): ONE tag per
        // number (its first piece facing the camera); every piece's line is still drawn and a tap on either reaches it
        let owners = FlexibleEdgePickRules.tagOwners(shown) { p.candidate($0)?.shownNumber }
        let tagOwner = Dictionary(uniqueKeysWithValues: owners.map { ($0, $0) })
        return shown.map { c in
            let picked = p.picks.contains(c.number)
            let greyed = p.greyed[c.number] != nil
            let colour = picked ? p.colour.rgba : greyed ? DS.Color.textDisabled : (p.colours[c.number]?.rgba ?? DS.Color.strokeStrong)
            var target: CGRect? = nil
            if let t = c.tag, tagOwner[c.number] != nil || FlexibleEdgePickRules.controlTagEveryPiece {
                let r = CGRect(x: t.x - s / 2, y: t.y - s / 2, width: s, height: s)
                if !keepOut.contains(where: { $0.intersects(r) }) { target = r }
            }
            return Mark(number: c.number, colour: colour, picked: picked, greyed: greyed, front: c.front, projected: c,
                        text: picked ? "✓\(p.candidate(c.number)?.shownNumber ?? c.number)" : "\(p.candidate(c.number)?.shownNumber ?? c.number)",   // ★ R7-E3 (a)
                        target: target)
        }
    }

    var body: some View {
        let marks = Self.marks(model: model, projection: proj.projection, keepOut: keepOut, add: add)
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
                Button {
                    if add { Task { @MainActor in if let why = await model.addEdgeToGroup(m.number) { model.toast = why } } }
                    else { model.toggleEdgePick(m.number) }
                } label: {
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
                .accessibilityLabel(m.text)
                .accessibilityIdentifier("flexible-edge-tag-\(m.number)")
            }
        }
    }
}

/// ★ R7-E4 — a flat press's Shape row: [Curves | Stamp] and the curve's two views as icons ([Top], [45°] — never down the arrow); a
/// corner says once that its one curve moves all three sides; Stamp shows its stamp's one line, size and turn (it sits on the edge).
struct FlexiblePressShapeRows: View {
    @ObservedObject var model: FlexibleStageModel
    let press: FlexiblePress
    let strip: FlexibleStrip
    @Binding var padTarget: String?
    /// ★ U1: the curve's buttons — only on the press he works on (★ U2: [2D] / [3D], each opening the curve window).
    var viewButtons: Bool = true

    var body: some View {
        let stamp = press.settings.isStampShape
        FlexRow(FlexibleRowCopy.shape, info: FlexibleRowCopy.Info.pressShape, id: "flexible-row-press-shape") {
            HStack(spacing: 4) {
                FlexChips(options: FlexibleRowCopy.shapeOptions, selection: stamp ? "stamp" : "curves",
                          id: "flexible-press-shape", equalWidths: false) { v in model.setPressShape(press.id, v) }
                    .fixedSize()
                if !stamp, viewButtons {
                    if FlexiblePressCurveModal.controlOldViewButtons {   // (RED CONTROL: R7-E4's [↓] / [45°])
                        viewButton(.top, icon: "arrow.down", label: FlexibleRowCopy.pressViewTop)
                        viewButton(.deg45, icon: "rotate.3d", label: FlexibleRowCopy.pressView45)
                    } else {
                        // ★ U2 (his notes of 2026-10-20, item 5): only [2D] / [3D] — each opens the curves in a window over everything
                        modalButton(.flat2D, label: FlexibleRowCopy.pressCurves2D)
                        modalButton(.table3D, label: FlexibleRowCopy.pressCurves3D)
                    }
                }
            }
        }
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["pressShape-\(strip.label)": g.frame(in: .global)])
        }.allowsHitTesting(false))
        if !stamp, strip.kind == .corner {
            FlexCaption(text: FlexibleRowCopy.cornerOneCurve).accessibilityIdentifier("flexible-press-corner-one-curve")
        }
        if stamp, let p = press.settings.designStamp {
            FlexRow(FlexibleRowCopy.pressStamp(name: model.stampName(p), corner: strip.kind == .corner),
                    info: FlexibleRowCopy.Info.pressStamp, id: "flexible-row-press-stamp") {
                Menu {
                    ForEach(model.library?.stamps.filter { $0.shape != "whole_face" } ?? []) { s in
                        Button(s.name) {
                            model.updatePressStamp(press.id) { q in
                                let turn = FlexiblePressStamp.shownTurn(q)   // ★ R7-E5: the turn he reads is kept across a new stamp
                                q.source = .library(s.id); q.widthMM = s.naturalSizeMM.width; q.lengthMM = s.naturalSizeMM.length; q.rigid = s.press == "rigid"
                                q.rotationDeg = FlexiblePressStamp.storedTurn(shown: turn, q)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityIdentifier("flexible-press-stamp-menu")
            }
            FlexRow(FlexibleRowCopy.stampSizeRow, info: FlexibleRowCopy.Info.stampSize, id: "flexible-row-press-stamp-size") {
                FlexNumberBox(key: "press-stamp-size-\(press.id.uuidString)", title: FlexibleRowCopy.stampWidthTitle,
                              spec: FlexibleNumberSpecs.stampWidth(mm: p.widthMM, faceMM: FlexibleFlatPrism.length(strip) > 0 ? FlexibleFlatPrism.length(strip) : nil),
                              padTarget: $padTarget, onNote: { model.toast = $0 }) { v in
                    model.updatePressStamp(press.id) { FlexibleStampSize.setWidth(v, of: &$0) }
                }
            }
            FlexRow(FlexibleRowCopy.stampTurnRow, info: FlexibleRowCopy.Info.pressStampTurn, id: "flexible-row-press-stamp-turn") {
                FlexNumberBox(key: "press-stamp-turn-\(press.id.uuidString)", title: FlexibleRowCopy.stampTurnRow,
                              spec: FlexibleNumberSpecs.stampTurn(deg: FlexiblePressStamp.shownTurn(p)), padTarget: $padTarget) { v in
                    // ★ R7-E5: 0° = the long side along the edge (turning away counts up)
                    model.updatePressStamp(press.id) { $0.rotationDeg = FlexiblePressStamp.storedTurn(shown: v, $0) }
                }
            }
        }
    }

    private func modalButton(_ mode: FlexiblePressCurveDraft.Mode, label: String) -> some View {
        FlexibleCurveModalButton(mode: mode, id: "flexible-press-curves", label: label) { model.openCurveModal(press.id, mode) }
    }

    private func viewButton(_ v: FlexiblePressCurveBaselines.View, icon: String, label: String) -> some View {
        Button { model.showPressCurve(press.id, v) } label: {
            Group {
                if v == .deg45 { Text("45\u{00B0}").font(.system(size: 13, weight: .bold)) }
                else { Image(systemName: icon).font(.system(size: 14, weight: .semibold)) }
            }
            .foregroundStyle(DS.Color.textPrimary.color)
            .frame(width: 44, height: 44)
            .background(Circle().fill(DS.Color.fillSubtle.color))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["pressView-\(v.rawValue)": g.frame(in: .global)])
        }.allowsHitTesting(false))
        .accessibilityIdentifier("flexible-press-view-\(v.rawValue)")
    }
}

/// ★ R7-E2's warning-row fixes ([Shallower] [Face 3 rests] [Remove Edge 16]), each one undo step. ★ U21 FIX ROUND 1 (the check:
/// [Remove Edge 16] here deleted on one tap): Remove asks in place like every delete (FlexibleFixAsk; his Img13 note, ruling
/// E(2)); the others apply on one tap.
struct FlexiblePressFixButtons: View {
    @ObservedObject var model: FlexibleStageModel
    let fixes: [FlexiblePressFix]
    static let scope = "pressFix"

    var body: some View {
        HStack(spacing: DS.Space.s) {
            ForEach(Array(fixes.prefix(3).enumerated()), id: \.offset) { i, f in
                let back = FlexibleFixAsk.stepsBack(model: model, scope: Self.scope, id: f.id)
                Button { model.tapPressFix(f, scope: Self.scope) } label: {
                    Text(f.title).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(i == 0 ? FlexibleStageStyle.onAccent : DS.Color.textPrimary.color)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .padding(.horizontal, 12).frame(minHeight: 44)
                        .background(Capsule().fill(i == 0 ? FlexibleStageStyle.accent : DS.Color.chipSolid.color))
                        .overlay(FlexibleCornerPairStyle.secondaryEdge(i == 0))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("flexible-press-fix-\(f.id)")
                .modifier(FlexibleFixAsk.confirm(model: model, scope: Self.scope, id: f.id, first: i == 0) { model.applyPressFixNow(f) })
                .opacity(back ? 0 : 1).allowsHitTesting(!back)
                .background(FlexibleConfirmInPlace.publish("press-\(f.id)"))
            }
        }
        .onDisappear { FlexibleFixAsk.drop(model: model, scope: Self.scope) }
    }
}
