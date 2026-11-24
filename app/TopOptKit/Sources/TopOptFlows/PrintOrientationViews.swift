// PrintOrientationViews — ★ notes27 P6 (builder H; his print orientation 11-23, SPEC 2d's screens), drawn over Results.
//
//   asked     a centred pop-up: "Best orientation" + "Prints best as placed" + OK, or "A new orientation may be stronger" + its
//             reason (≤ 5 words, core's own) + OK / Not now; the estimate's numbers behind its (i) (his rule: a guess says so)
//   proposed  Cancel at the top left, under the Structural capsule (44 pt); bottom right, in Export's place: Check strength
//             (primary) + Manual orientation
//   manual    the part's hull faces as see-through plates and its hull edges as handles; a tap turns the part to it; "would tip"
//             is a centred pop-up
//   checking  the processing pop-up (the vines, or the hexagons), the Mac's step, the time and "About …", Cancel
//   compare   the benefits modal: As placed | New, six measured rows, Cancel / Keep orientation
// His rules: captions ≤ 5 words; errors as centred pop-ups; nothing at the bottom-centre; 44 pt targets.
import SwiftUI
import simd
import TopOptKit
import TopOptDesign

/// The turn the part is drawn with: the way it prints, or (the flow open) the way the flow shows; and whether it animates there.
/// Observes the flow, so the screen around it never has to.
struct PrintTurnedStage<Content: View>: View {
    @ObservedObject var flow: PrintOrientationFlow
    /// The flow is this screen's ("Print orientation" offered).
    let follows: Bool
    let up: SIMD3<Float>?
    @ViewBuilder let content: (_ settle: simd_quatf, _ animated: Bool) -> Content

    var body: some View {
        let u = (follows ? flow.shownUp() : nil) ?? up
        content(u.map(PrintDraw.settle(up:)) ?? simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)), follows && flow.animating)
    }
}

/// The corner: Results' own, or — the flow proposing a way — Check strength and Manual orientation in Export's place.
struct PrintOrientationCornerSwitch<Corner: View>: View {
    @ObservedObject var flow: PrintOrientationFlow
    let host: PrintOrientationHost?
    let variant: () -> PrintCheckVariant
    @ViewBuilder let corner: () -> Corner

    var body: some View {
        if let h = host, flow.ownsCorner {
            PrintOrientationCorner(flow: flow, host: h, variant: variant)
        } else {
            corner()
        }
    }
}

/// Everything the flow draws over Results, except the corner (`PrintOrientationCorner`).
struct PrintOrientationLayer: View {
    @ObservedObject var flow: PrintOrientationFlow
    let host: PrintOrientationHost
    /// The camera's projection (world → screen), the way the result prints, the mesh's centre and the camera's eye.
    let raw: CameraProjection?
    let up: SIMD3<Float>?
    let centre: SIMD3<Float>
    let eye: SIMD3<Float>

    /// The turn shown now, and model → screen through it.
    private var rotation: simd_quatf {
        (flow.shownUp() ?? up).map(PrintDraw.settle(up:)) ?? simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    }
    private var projection: CameraProjection? { raw.map { PrintDraw.modelProjection($0, centre: centre, rotation: rotation) } }

    var body: some View {
        ZStack {
            if flow.phase == .manual, let h = flow.hull, let p = projection { plates(h, p) }
            if flow.phase == .proposed || flow.phase == .manual { cancelButton }
            if flow.phase == .asked, let a = flow.ask { PrintOrientationAsk(ask: a, ok: { flow.okay() }, notNow: { flow.notNow() }) }
            if flow.phase == .checking { PrintOrientationChecking(flow: flow) }
            if flow.phase == .compare, let r = flow.result {
                PrintOrientationBenefits(rows: r.rows, cancel: { flow.discard() }, keep: { flow.keep(host: host) })
            }
        }
    }

    /// Top left, under the Structural capsule: Cancel (and, in Manual, what to tap — ≤ 5 words).
    private var cancelButton: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            PillButton(PrintOrientationWords.cancel, style: .secondary) { flow.cancel() }
                .fixedSize()
                .frame(minHeight: 44)
                .background(ResultsChrome.publish("orientCancel"))
                .accessibilityIdentifier("orient-cancel")
            if flow.phase == .manual {
                Text(flow.hull == nil ? "Finding its faces\u{2026}" : PrintOrientationWords.manualCaption)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.textSecondary.color)
                    .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.xs)
                    .background(Capsule().fill(ResultsChrome.fill.color))
                    .background(ResultsChrome.publish("orientManualCaption"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.leading, StageCapsuleLayout.capsuleLeft)
        .padding(.top, PageChrome.panelTop)
    }

    // MARK: Manual orientation: the plates and the edge handles

    struct Plate: Identifiable { let id: Int; let path: Path; let box: CGRect }
    struct Handle: Identifiable { let id: Int; let a: CGPoint; let b: CGPoint }

    /// The faces turned toward him, as see-through plates; the edges as handles. A face's plate is its outline on screen.
    static func layout(_ h: PrintHull, projection p: CameraProjection, rotation q: simd_quatf, centre c: SIMD3<Float>,
                       eye: SIMD3<Float>) -> (plates: [Plate], handles: [Handle]) {
        func world(_ m: SIMD3<Double>) -> SIMD3<Float> { c + q.act(SIMD3<Float>(Float(m.x), Float(m.y), Float(m.z)) - c) }
        func facing(_ n: SIMD3<Double>, _ at: SIMD3<Double>) -> Bool {
            simd_dot(q.act(SIMD3<Float>(Float(n.x), Float(n.y), Float(n.z))), eye - world(at)) > 0
        }
        var plates: [Plate] = []
        for (i, f) in h.faces.enumerated() where f.outline.count >= 3 {
            let mid = f.outline.reduce(SIMD3<Double>.zero, +) / Double(f.outline.count)
            guard facing(f.normal, mid) else { continue }
            let pts = f.outline.compactMap { p.project(SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z))) }
            guard pts.count == f.outline.count else { continue }
            var path = Path()
            path.addLines(pts); path.closeSubpath()
            plates.append(Plate(id: i, path: path, box: path.boundingRect))
        }
        var handles: [Handle] = []
        for (i, e) in h.edges.enumerated() {
            guard facing(e.n1, e.a) || facing(e.n2, e.a),
                  let a = p.project(SIMD3<Float>(Float(e.a.x), Float(e.a.y), Float(e.a.z))),
                  let b = p.project(SIMD3<Float>(Float(e.b.x), Float(e.b.y), Float(e.b.z))) else { continue }
            handles.append(Handle(id: i, a: a, b: b))
        }
        return (plates, handles)
    }

    private func plates(_ h: PrintHull, _ p: CameraProjection) -> some View {
        let l = Self.layout(h, projection: p, rotation: rotation, centre: centre, eye: eye)
        let accent = DS.Color.accent.color
        return ZStack {
            ForEach(l.plates) { pl in
                pl.path.fill(accent.opacity(0.16))
                    .overlay(pl.path.stroke(accent.opacity(0.7), lineWidth: 1.5))
                    .contentShape(pl.path)
                    .onTapGesture { flow.pick(face: h.faces[pl.id]) }
                    .accessibilityIdentifier("orient-plate-\(pl.id)")
            }
            .background(Color.clear)
            ForEach(l.handles) { hd in
                let seg = Path { $0.move(to: hd.a); $0.addLine(to: hd.b) }
                ZStack {
                    seg.stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    seg.stroke(accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                }
                .contentShape(seg.strokedPath(StrokeStyle(lineWidth: 44, lineCap: .round)))   // a 44 pt target along the edge
                .onTapGesture { flow.pick(edge: h.edges[hd.id]) }
                .accessibilityIdentifier("orient-edge-\(hd.id)")
            }
            // their places (hosted tests): the plates' and handles' boxes
            ForEach(l.plates) { pl in
                Color.clear.frame(width: max(1, pl.box.width), height: max(1, pl.box.height))
                    .position(x: pl.box.midX, y: pl.box.midY).allowsHitTesting(false)
                    .background(ResultsChrome.publish("orientPlate-\(pl.id)"))
            }
            ForEach(l.handles) { hd in
                Color.clear.frame(width: 44, height: 44)
                    .position(x: (hd.a.x + hd.b.x) / 2, y: (hd.a.y + hd.b.y) / 2).allowsHitTesting(false)
                    .background(ResultsChrome.publish("orientEdge-\(hd.id)"))
            }
        }
        .ignoresSafeArea()
    }
}

/// Bottom right, in Export's place: "Manual orientation" and "Check strength" (Export is hidden: nothing unchecked is exported).
struct PrintOrientationCorner: View {
    @ObservedObject var flow: PrintOrientationFlow
    let host: PrintOrientationHost
    let variant: () -> PrintCheckVariant

    var body: some View {
        DSCorner(key: "resultsCorner") {
            DSGlassButton(PrintOrientationWords.manual, systemImage: "hand.tap", selected: flow.phase == .manual, key: "orientManual") {
                flow.manual()
            }
            .accessibilityIdentifier("orient-manual")
        } run: {
            DSRunButton(PrintOrientationWords.check, subtitle: flow.shown?.recommended == false ? PrintOrientationWords.yourChoice : host.kind.about,
                        state: flow.shown == nil ? .disabled(PrintOrientationWords.manualCaption) : .ready, key: "orientCheck") {
                flow.check(host: host, variant: variant())
            }
            .accessibilityIdentifier("orient-check")
        } split: {
            EmptyView()
        }
    }
}

/// The centred pop-up: its title, its one caption (≤ 5 words), the estimate behind its (i), OK (and Not now).
struct PrintOrientationAsk: View {
    let ask: PrintOrientationFlow.Ask
    let ok: () -> Void
    let notNow: () -> Void

    var body: some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.28)).ignoresSafeArea()
            GlassPanel {
                VStack(spacing: DS.Space.m) {
                    Text(ask.title).dsStyle(DS.TypeScale.title).foregroundStyle(DS.Color.textPrimary.color)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("orient-ask-title")
                    HStack(spacing: DS.Space.s) {
                        Text(ask.caption).dsStyle(DS.TypeScale.body).foregroundStyle(DS.Color.textSecondary.color)
                            .accessibilityIdentifier("orient-ask-caption")
                        if !ask.info.isEmpty {
                            InfoTip(key: "orientAsk", text: ([PrintOrientationWords.estimate] + ask.info).joined(separator: "\n"),
                                    label: PrintOrientationWords.estimate)
                        }
                    }
                    HStack(spacing: DS.Space.m) {
                        if ask.change {
                            PillButton(PrintOrientationWords.notNow, style: .secondary, action: notNow).fixedSize()
                                .frame(minHeight: 44)
                                .background(ResultsChrome.publish("orientNotNow"))
                                .accessibilityIdentifier("orient-not-now")
                        }
                        PillButton(PrintOrientationWords.ok, style: .primary, action: ok).fixedSize()
                            .frame(minWidth: 88, minHeight: 44)
                            .background(ResultsChrome.publish("orientOK"))
                            .accessibilityIdentifier("orient-ok")
                    }
                    .padding(.top, DS.Space.xs)
                }
                .padding(DS.Space.xl2)
                .frame(maxWidth: 440)
            }
            .fixedSize()
            .background(ResultsChrome.publish("orientAsk"))
        }
        .transition(.opacity)
        .zIndex(80)
    }
}

/// The processing pop-up: the vines (an Organic lattice) or the hexagons, the Mac's step, the time and "About …", Cancel.
struct PrintOrientationChecking: View {
    @ObservedObject var flow: PrintOrientationFlow

    var body: some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.35)).ignoresSafeArea()
            GlassPanel {
                VStack(spacing: DS.Space.m) {
                    LatticeMacMakeAnimation(kind: flow.kind.animation)
                    Text(PrintOrientationWords.checkingTitle).dsStyle(DS.TypeScale.title)
                        .foregroundStyle(DS.Color.textPrimary.color)
                        .accessibilityIdentifier("orient-checking-title")
                    Text(flow.stage).dsStyle(DS.TypeScale.body).foregroundStyle(DS.Color.textSecondary.color)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("orient-checking-stage")
                    LatticeMacMakeBar().frame(width: 220, height: 4).accessibilityHidden(true)
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(LatticeMacMakeCopy.clock(flow.started.map { ctx.date.timeIntervalSince($0) } ?? 0) + " \u{00B7} " + flow.kind.about)
                            .dsStyle(DS.TypeScale.body).monospacedDigit().foregroundStyle(DS.Color.textSecondary.color)
                            .accessibilityIdentifier("orient-checking-time")
                    }
                    PillButton(PrintOrientationWords.cancel, style: .secondary) { flow.stopCheck() }
                        .fixedSize().frame(minHeight: 44)
                        .background(ResultsChrome.publish("orientCheckingCancel"))
                        .accessibilityIdentifier("orient-checking-cancel")
                }
                .padding(DS.Space.xl2)
                .frame(maxWidth: 480)
            }
            .fixedSize()
            .background(ResultsChrome.publish("orientChecking"))
        }
        .transition(.opacity)
        .zIndex(90)
    }
}

/// The benefits modal: As placed | New, every row measured; a row coloured only when it is worse past the gate or better.
struct PrintOrientationBenefits: View {
    let rows: [PrintBenefitRow]
    let cancel: () -> Void
    let keep: () -> Void

    static func colour(_ t: PrintBenefitRow.Tone) -> Color {
        switch t {
        case .plain: return DS.Color.textPrimary.color
        case .better: return DS.Color.accent.color
        case .worse: return DS.Color.danger.color
        }
    }

    var body: some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.35)).ignoresSafeArea()
            GlassPanel {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    Text(PrintOrientationWords.compareTitle).dsStyle(DS.TypeScale.title).foregroundStyle(DS.Color.textPrimary.color)
                    Grid(alignment: .leading, horizontalSpacing: DS.Space.l, verticalSpacing: DS.Space.s) {
                        GridRow {
                            Text("")
                            Text(PrintOrientationWords.asPlacedColumn).font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(DS.Color.textSecondary.color)
                            Text(PrintOrientationWords.newColumn).font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(DS.Color.textSecondary.color)
                        }
                        ForEach(rows) { r in
                            GridRow {
                                Text(r.label).font(.system(size: 14)).foregroundStyle(DS.Color.textSecondary.color)
                                    .fixedSize()
                                Text(r.old).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                                    .foregroundStyle(DS.Color.textPrimary.color).fixedSize()
                                Text(r.new).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                                    .foregroundStyle(Self.colour(r.tone)).fixedSize()
                                    .background(ResultsChrome.publish("orientBenefit-" + r.label))
                                    .accessibilityIdentifier("orient-benefit-\(r.label)")
                            }
                        }
                    }
                    HStack(spacing: DS.Space.m) {
                        Spacer(minLength: 0)
                        PillButton(PrintOrientationWords.cancel, style: .secondary, action: cancel).fixedSize()
                            .frame(minHeight: 44)
                            .background(ResultsChrome.publish("orientBenefitsCancel"))
                            .accessibilityIdentifier("orient-benefits-cancel")
                        PillButton(PrintOrientationWords.keep, style: .primary, action: keep).fixedSize()
                            .frame(minHeight: 44)
                            .background(ResultsChrome.publish("orientKeep"))
                            .accessibilityIdentifier("orient-keep")
                    }
                    .padding(.top, DS.Space.xs)
                }
                .padding(DS.Space.xl2)
            }
            .fixedSize()
            .background(ResultsChrome.publish("orientBenefits"))
        }
        .transition(.opacity)
        .zIndex(90)
    }
}
