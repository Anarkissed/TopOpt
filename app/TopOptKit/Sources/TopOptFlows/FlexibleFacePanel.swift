// FlexibleFacePanel — the Flexible Settings panel, simple and visual (task
// 2026-09-29-flexible-screens, round 3, item 5; maintainer 2026-09-29).
//
// ★ HIS RULES. One line of text per setting (FlexibleRowCopy), details behind an (i) he
// won't tap (FlexibleInfo), only what is necessary, as visual as possible: the curves, the
// depth prism and the stamps are edited ON THE PART, so the panel only names and switches.
// No wizard. Tabs: Face | Stamps | More.
//
// ★ FACE: two part rows — the filament ("varioShore TPU · squish data") and the feel —
// then, for the face selected on the model:
//   1. its name, [Pressed | Rests]                      (a tap on the part only SELECTS)
//   2. its weight, from the main page's group (editing it writes back to the group)
//   3. Shape [Curves] [Stamp]                           (Stamp: batch D)
//   4. Deepest squish (the green chip drags it on the part)
//   5. Solid skin
// A face not set yet shows [Press it] [It rests here]; pressing a face with no main-page
// load asks "How much weight presses here?" on the number pad.
// ★ REMOVED (round 3): Both / Either / Centre (always both), the X / Y / 3D steps (the map
// always bends), the frame rotation, 1 / 2 beads (always 1), the density cross-section and
// its slider, and every long caption.
// ★ MORE: nozzle temperature, the lattice family, Auto's pick, physics (walls folded in) —
// read-mostly, every one with a working default, so nothing required hides there.
// ★ VERIFICATION OF ROUND 3: what he must know is ON the panel — the selected face's refusal
// or unreached columns (FlexWarningLine), Auto that cannot meet the curve or picked nothing,
// a missing filament list; Feel and Lattice are hidden for a calibrate-first filament (they
// change nothing there yet); chips take their own widths so no label reads "…".

import SwiftUI
import TopOptDesign
import TopOptKit

// MARK: - Face

struct FlexibleFacePanel: View {
    @ObservedObject var model: FlexibleStageModel
    @Binding var padTarget: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            filamentRow
            if model.material?.noPrediction == nil {
                FlexRow(FlexibleRowCopy.feel, info: FlexibleRowCopy.Info.feel, id: "flexible-row-feel") {
                    FlexChips(options: FlexibleRowCopy.feelOptions, selection: model.settings.feel,
                              id: "flexible-feel", equalWidths: false) { v in model.edit { $0.feel = v } }
                        .fixedSize()
                }
            }
            Divider().overlay(DS.Color.strokeSubtle.color).padding(.vertical, DS.Space.xs)
            faceRows
        }
        .onAppear {
            if model.selectedRegion == nil { model.selectedRegion = model.settings.loadedFaces.first?.faceRegionID }
        }
    }

    // MARK: part rows

    private var filamentRow: some View {
        let m = model.material
        let missing = model.catalogueError != nil
        return FlexRow(missing ? FlexibleRowCopy.catalogueMissing
                               : FlexibleRowCopy.filament(name: m?.displayName, hasData: m != nil && m?.noPrediction == nil),
                       info: FlexibleRowCopy.Info.filament, id: "flexible-row-filament", warning: missing) {
            Menu {
                ForEach(model.catalogue) { c in
                    Button { model.pickMaterial(c.id) } label: {
                        Text(FlexibleRowCopy.filament(name: c.displayName, hasData: c.noPrediction == nil))
                    }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary.color)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(DS.Color.fillSubtle.color))
            }
            .accessibilityIdentifier("flexible-filament-menu")
        } extra: {
            if let np = m?.noPrediction { FlexInfoText(np.reason) }
            if let e = model.catalogueError { FlexInfoText(e, warning: true) }
        }
    }

    // MARK: face rows

    private func name(_ r: Int) -> String {
        let sector = model.regions.sector(r)
        return FlexibleRowCopy.faceName(sector: sector?.name, face: sector == nil ? r : model.regions.faces(of: r, mesh: model.project.viewerMesh).first ?? r)
    }

    @ViewBuilder private var faceRows: some View {
        if let r = model.selectedRegion {
            if let f = model.settings.face(r) {
                markedRows(r, f)
            } else {
                unmarkedRow(r)
            }
        } else {
            FlexRow(FlexibleRowCopy.noFace, info: FlexibleRowCopy.Info.noFace, id: "flexible-row-noface")
        }
    }

    @ViewBuilder private func markedRows(_ r: Int, _ f: FlexibleFaceSettings) -> some View {
        FlexRow(name(r), info: FlexibleRowCopy.Info.face, id: "flexible-row-face") {
            FlexChips(options: FlexibleRowCopy.roleOptions, selection: f.role, id: "flexible-role", equalWidths: false) { v in
                if v == "loaded" { pressOrAsk(r) } else { model.rest(r) }
            }
            .fixedSize()
            // ★ NO TRASH FOR A FACE A MAIN-PAGE GROUP HOLDS: the next re-sync would bring it
            // back (the group is the one truth) — [Rests] is the Flexible page's way out
            if model.mainPageLoads.canRemove(r) {
                Button { model.removeFace(r) } label: {
                    Image(systemName: "trash").font(.system(size: 13)).foregroundStyle(DS.Color.textTertiary.color)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("flexible-face-remove")
            }
        }
        .background(askAnchor(r))
        // [Rests] chosen here on a face the main page presses: one line, never hidden
        if !f.isLoaded, let e = model.mainPageLoads.entry(r), e.role == .pressed {
            Text(FlexibleRowCopy.pressedOnMainPage(group: e.groupName))
                .font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Color.textSecondary.color)
                .lineLimit(1)
                .accessibilityIdentifier("flexible-row-pressed-on-main")
        }
        if let c = model.conflicts.first(where: { $0.faceA == r || $0.faceB == r }) {
            FlexWarningLine(text: FlexibleRowCopy.sharesStack(with: name(c.faceA == r ? c.faceB : c.faceA)),
                            id: "flexible-row-conflict")
        }
        if f.isLoaded, let w = warning(r) { FlexWarningLine(text: w) }
        if f.isLoaded {
            let e = model.mainPageLoads.entry(r)
            let fromGroup = f.weightFrom != nil && e?.groupID == f.weightFrom
            FlexRow(FlexibleRowCopy.weight(face: f, entry: e), info: FlexibleRowCopy.Info.weight, id: "flexible-row-weight") {
                FlexEditPill(key: "weight-\(r)", title: FlexibleRowCopy.weightTitle, unit: "kg", value: f.weightKg,
                             padTarget: $padTarget) { model.setWeight(r, kg: $0) }
            }
            if fromGroup, let old = model.relinkedWeights[r], let e {
                Text(FlexibleRowCopy.relinked(oldKg: old, group: e.groupName))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Color.textSecondary.color)
                    .lineLimit(1)
                    .accessibilityIdentifier("flexible-row-relinked")
            }
            FlexRow(FlexibleRowCopy.shape, info: FlexibleRowCopy.Info.shape, id: "flexible-row-shape") {
                // ★ BATCH D: the Stamp shape (squish by stamp: flat curves + design_stamp, the
                // stamp's weight as the face's, the prism on its footprint) lands here. Until
                // then it is shown, and disabled — the curves are this build's shape.
                FlexChips(options: FlexibleRowCopy.shapeOptions, selection: f.shape ?? "curves",
                          id: "flexible-shape", disabled: ["stamp"], equalWidths: false) { v in
                    guard v == "curves" else { return }
                    model.edit { s in guard var g = s.face(r) else { return }; g.shape = nil; s.setFace(g) }
                }
                .fixedSize()
            }
            FlexRow(FlexibleRowCopy.deepest(f.deepestMM), info: FlexibleRowCopy.Info.deepest, id: "flexible-row-deepest") {
                FlexEditPill(key: "deepest-\(r)", title: FlexibleRowCopy.deepestTitle, unit: "mm", value: f.deepestMM,
                             padTarget: $padTarget) { v in
                    let lattice = model.stack(r)?.latticeMMMax ?? v
                    model.edit { s in
                        guard var g = s.face(r) else { return }
                        g.deepestMM = FlexibleDepthPrism.clamp(v, latticeMM: lattice)
                        s.setFace(g)
                    }
                }
            } extra: {
                if let d = model.design(r) {
                    if let why = d.refusal { FlexInfoText(model.text(why.reason), warning: true) }
                    else { FlexibleFaceResult(design: d, model: model) }
                }
                if let st = model.stack(r) {
                    FlexInfoText(String(format: "%.0f × %.0f mm · %d columns, %.1f mm apart · lattice %.1f–%.1f mm deep",
                                        st.uExtentMM, st.vExtentMM, st.columns.count, st.pitchMM, st.latticeMMMin, st.latticeMMMax))
                    if st.side { FlexInfoText("Side face · gyroid only · estimated", warning: true) }
                }
            }
        }
        FlexRow(FlexibleRowCopy.skin, info: FlexibleRowCopy.Info.skin, id: "flexible-row-skin") {
            GlassToggle(isOn: f.skinOn) { model.edit { s in guard var g = s.face(r) else { return }; g.skinOn.toggle(); s.setFace(g) } }
                .accessibilityIdentifier("flexible-skin")
        }
    }

    /// The selected face's one warning line (FlexibleRowCopy.faceWarning), or nil.
    private func warning(_ r: Int) -> String? {
        let d = model.design(r)
        return FlexibleRowCopy.faceWarning(refusalCode: d?.refusal?.code, refusalReason: d?.refusal.map { model.text($0.reason) },
                                           unreachedColumns: d.map { $0.tooFirm + $0.tooSoft + $0.beyondData } ?? 0,
                                           side: model.stack(r)?.side ?? false)
    }

    @ViewBuilder private func unmarkedRow(_ r: Int) -> some View {
        FlexRow(name(r), info: FlexibleRowCopy.Info.face, id: "flexible-row-face") {
            Button { pressOrAsk(r) } label: { chipLabel("Press it") }
                .buttonStyle(.plain).accessibilityIdentifier("flexible-press")
            Button { model.rest(r) } label: { chipLabel("It rests here") }
                .buttonStyle(.plain).accessibilityIdentifier("flexible-rest")
        }
        .background(askAnchor(r))
    }

    private func chipLabel(_ t: String) -> some View {
        Text(t).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Capsule().fill(DS.Color.fillSelected.color))
    }

    /// Press with the main page's weight, or ask for one ("How much weight presses here?").
    private func pressOrAsk(_ r: Int) {
        if !model.press(r) { padTarget = "press-\(r)" }
    }

    /// The anchor the "How much weight presses here?" pad pops from. ★ THE FACE IS PRESSED
    /// WHEN THE PAD CLOSES, not per keystroke: pressing on the first digit swapped this row for
    /// the marked rows, which tore the pad's anchor down mid-number ("25" became 2 kg).
    private func askAnchor(_ r: Int) -> some View {
        Color.clear
            .modifier(FlexPadCommit(key: "press-\(r)", padTarget: $padTarget,
                                    config: .init(title: FlexibleRowCopy.askWeight, unit: "kg", allowsDecimal: true),
                                    seed: nil) { v in model.press(r, kg: v) })
            .allowsHitTesting(false)
    }
}

// MARK: - More

struct FlexibleMorePanel: View {
    @ObservedObject var model: FlexibleStageModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            let calibrateFirst = model.material?.noPrediction != nil
            if let m = model.material, m.noPrediction == nil {
                // a temperature core has a note on (not in order, estimated…) is said by the
                // row's colour; the (i) carries the note itself
                let note = model.settings.nozzleTempC.map { model.temperatureNote($0) } ?? ""
                FlexRow(FlexibleRowCopy.temperature, info: FlexibleRowCopy.Info.temperature, id: "flexible-row-temp",
                        warning: !note.isEmpty) {
                    FlexChips(options: FlexibleRowCopy.temperatureOptions(m.testedTempsC),
                              selection: model.settings.nozzleTempC.map { String(Int($0)) } ?? "auto", id: "flexible-temp",
                              equalWidths: false) { v in
                        model.edit { $0.nozzleTempC = v == "auto" ? nil : Double(v) }
                    }
                    .fixedSize()
                } extra: {
                    if let t = model.settings.nozzleTempC, !note.isEmpty {
                        FlexInfoText("\(Int(t)) °C: \(note)", warning: true)
                    }
                }
            } else {
                FlexRow(FlexibleRowCopy.temperatureNoData, info: FlexibleRowCopy.Info.temperature, id: "flexible-row-temp")
            }
            if !calibrateFirst {
                FlexRow(FlexibleRowCopy.topology, info: FlexibleRowCopy.Info.topology, id: "flexible-row-topology") {
                    FlexChips(options: FlexibleRowCopy.topologyOptions, selection: model.settings.topology,
                              id: "flexible-topology", equalWidths: false) { v in model.edit { $0.topology = v } }
                        .fixedSize()
                }
            }
            let auto = autoLine
            FlexRow(auto.text, info: FlexibleRowCopy.Info.auto, id: "flexible-row-auto", warning: auto.warning) {
                EmptyView()
            } extra: {
                FlexibleAutoPane(model: model)
            }
            FlexRow(FlexibleRowCopy.physics, info: FlexibleRowCopy.Info.physics, id: "flexible-row-physics") {
                EmptyView()
            } extra: {
                FlexiblePhysicsPane(model: model)
            }
        }
    }

    private var autoLine: (text: String, warning: Bool) {
        let r = model.recommendation
        return FlexibleRowCopy.autoLine(noData: model.material?.noPrediction != nil,
                                        pressedFaces: model.settings.loadedFaces.count,
                                        chosen: r?.chosen, reachable: r?.reachable,
                                        error: model.recommendationError != nil,
                                        topology: r?.topology ?? "", tempC: r?.tempC)
    }
}

// MARK: - the edit pill

/// A pencil pill that opens the shared number pad (every numeric input opens a keypad).
struct FlexEditPill: View {
    let key: String
    let title: String
    let unit: String
    let value: Double
    @Binding var padTarget: String?
    let onValue: (Double) -> Void

    var body: some View {
        Button { padTarget = key } label: {
            Image(systemName: "pencil")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Color.textPrimary.color)
                .frame(width: 44, height: 32)
                .background(Capsule().fill(DS.Surface.valuePill.color))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("flexible-number-\(key)")
        .modifier(FlexPadCommit(key: key, padTarget: $padTarget,
                                config: .init(title: title, unit: unit, allowsDecimal: true), seed: value, commit: onValue))
    }
}

// MARK: - the number pad, committed ONCE when it closes

/// What the number pad typed, held until it CLOSES. The shared pad emits a value on every
/// keystroke; applied live, typing "12" wrote 1 kg then 12 kg to the main-page group — two
/// writes and two sealed undo steps — and a first digit that marked a face tore its pad down.
/// Pure, so the rule is testable (FlexibleMainPageLoadsTests).
struct FlexPadBuffer: Equatable {
    private(set) var pending: Double?
    mutating func typed(_ v: Double?) { pending = v }
    /// The value to commit as the pad closes (a positive number, else nothing); empties the buffer.
    mutating func closed() -> Double? {
        defer { pending = nil }
        guard let v = pending, v.isFinite, v > 0 else { return nil }
        return v
    }
}

/// The shared number pad on a Flexible control, committing `FlexPadBuffer`'s value once, as
/// the pad closes (the popover's own dismissal, or `padTarget` moving elsewhere).
struct FlexPadCommit: ViewModifier {
    let key: String
    @Binding var padTarget: String?
    let config: NumberPad.Config
    let seed: Double?
    let commit: (Double) -> Void
    @State private var buffer = FlexPadBuffer()

    func body(content: Content) -> some View {
        content
            .numberPad(Binding(get: { padTarget == key }, set: { if !$0, padTarget == key { padTarget = nil } }),
                       config: config, seed: seed) { buffer.typed($0) }
            .onChange(of: padTarget == key) { open in
                if !open, let v = buffer.closed() { commit(v) }
            }
    }
}
