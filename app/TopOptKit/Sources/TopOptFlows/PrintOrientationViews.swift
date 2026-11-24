// PrintOrientationViews — ★ notes27 P6 (builder H; his print orientation 11-23, SPEC 2d's screens), drawn over Results.
//
//   asked     a centred pop-up: "Best orientation" + "Prints best as placed" + OK, or "A new orientation may be stronger" + its
//             reason (≤ 5 words, core's own) + OK / Not now; the estimate's numbers behind its (i) (his rule: a guess says so)
//   proposed  bottom right, in Export's place: Cancel + Manual orientation + Check strength (primary) — ★ notes28: Cancel left
//             of Manual orientation ("'Cancel' cuts below the 'Structural' menu row")
//   manual    ★ notes28 (his img 81, Bambu Studio's Lay on face): each hull face a flat translucent white patch inset from its
//             edges, each edge rest its own narrow bevel face; the one under his finger brighter, the picked one outlined; a
//             tap turns the part to it (Manual stays open); "would tip" is a centred pop-up
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
            if flow.phase == .manual, !flow.turning, let h = flow.hull, let pt = flow.patches, let p = projection {
                patches(h, pt, p)   // ★ notes28
            }
            if flow.phase == .asked, let a = flow.ask { PrintOrientationAsk(ask: a, ok: { flow.okay() }, notNow: { flow.notNow() }) }
            if flow.phase == .checking { PrintOrientationChecking(flow: flow) }
            if flow.phase == .compare, let r = flow.result {
                PrintOrientationBenefits(rows: r.rows, cancel: { flow.discard() }, keep: { flow.keep(host: host) })
            }
        }
    }

    // MARK: Manual orientation: ★ notes28 — Bambu Studio's patches (his img 81)

    /// One patch on screen: what it stands the part on, its shape, where a tap takes it (≥ 44 pt across), and whether it faces
    /// him (the picked one, turned away to the bed, is drawn as its outline only).
    struct Drawn: Identifiable {
        let target: PrintPatches.Target
        let path: Path
        let hit: Path
        let box: CGRect
        let front: Bool
        var id: PrintPatches.Target { target }
    }

    /// The patches turned toward him (faces first, then the edges' bevel faces over them), and the picked one wherever it is.
    /// A face is tapped anywhere on its own outline; an edge along a 44 pt band down its facet.
    static func layout(_ pt: PrintPatches, hull h: PrintHull, projection p: CameraProjection, rotation q: simd_quatf,
                       centre c: SIMD3<Float>, eye: SIMD3<Float>, picked: PrintPatches.Target?) -> [Drawn] {
        func f(_ m: SIMD3<Double>) -> SIMD3<Float> { SIMD3<Float>(Float(m.x), Float(m.y), Float(m.z)) }
        func world(_ m: SIMD3<Double>) -> SIMD3<Float> { c + q.act(f(m) - c) }
        func facing(_ n: SIMD3<Double>, _ at: SIMD3<Double>) -> Bool { simd_dot(q.act(f(n)), eye - world(at)) > 0 }
        func shape(_ pts3: [SIMD3<Double>]) -> Path? {
            let pts = pts3.compactMap { p.project(f($0)) }
            guard pts.count == pts3.count, pts.count >= 3 else { return nil }
            var path = Path()
            path.addLines(pts); path.closeSubpath()
            return path
        }
        func mid(_ o: [SIMD3<Double>]) -> SIMD3<Double> { o.reduce(SIMD3<Double>.zero, +) / Double(max(1, o.count)) }
        var out: [Drawn] = []
        for patch in pt.faces + pt.edges {
            let front = facing(patch.normal, mid(patch.outline))
            guard front || patch.target == picked, let path = shape(patch.outline) else { continue }
            var hit = path
            switch patch.target {
            case .face(let i):
                if h.faces.indices.contains(i), let whole = shape(h.faces[i].outline) { hit = whole }
            case .edge:
                // down the facet's middle, 44 pt across
                let o = patch.outline
                if o.count == 4, let a = p.project(f((o[0] + o[3]) / 2)), let b = p.project(f((o[1] + o[2]) / 2)) {
                    hit = Path { $0.move(to: a); $0.addLine(to: b) }.strokedPath(StrokeStyle(lineWidth: 44, lineCap: .round))
                }
            }
            out.append(Drawn(target: patch.target, path: path, hit: hit, box: path.boundingRect, front: front))
        }
        return out
    }

    /// The fill: translucent white; brighter under his finger; the picked one a little brighter, outlined.
    static func fill(lit: Bool, picked: Bool) -> Double { lit ? 0.55 : picked ? 0.34 : 0.2 }

    private func patches(_ h: PrintHull, _ pt: PrintPatches, _ p: CameraProjection) -> some View {
        let picked = pt.picked(flow.shown, hull: h)
        let l = Self.layout(pt, hull: h, projection: p, rotation: rotation, centre: centre, eye: eye, picked: picked)
        return ZStack {
            ForEach(l) { d in
                let isPicked = d.target == picked
                if d.front {
                    // a button (its press is the finger on it): the patch brighter while pressed or under the pointer
                    Button { pick(d.target, h) } label: { Color.clear }
                        .buttonStyle(PatchStyle(path: d.path, picked: isPicked, lit: flow.under == d.target,
                                                pressed: { flow.press($0 ? d.target : nil) }))
                        .contentShape(d.hit)
                        .onHover { flow.hover(d.target, $0) }
                        .accessibilityIdentifier(Self.key(d.target, "orient-plate-", "orient-edge-"))
                } else {
                    // the picked one, turned to the bed: its outline (what stands on the bed), never in the way of a tap
                    d.path.stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 2.5, dash: [6, 4]))
                        .allowsHitTesting(false)
                }
            }
            // their places (hosted tests): each patch's box (published before it is placed, so the frame is the box's own)
            ForEach(l) { d in
                Color.clear.frame(width: max(1, d.box.width), height: max(1, d.box.height))
                    .background(ResultsChrome.publish(Self.key(d.target, "orientPlate-", "orientEdge-")))
                    .position(x: d.box.midX, y: d.box.midY).allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }

    /// One patch: translucent white, brighter while his finger is on it (or the pointer over it), the picked one outlined.
    struct PatchStyle: ButtonStyle {
        let path: Path
        let picked: Bool
        let lit: Bool
        let pressed: (Bool) -> Void
        func makeBody(configuration: Configuration) -> some View {
            path.fill(Color.white.opacity(PrintOrientationLayer.fill(lit: lit || configuration.isPressed, picked: picked)))
                .overlay(path.stroke(Color.white.opacity(picked ? 1 : 0.4), lineWidth: picked ? 2.5 : 1))
                .onChange(of: configuration.isPressed) { pressed($0) }
        }
    }

    private func pick(_ t: PrintPatches.Target, _ h: PrintHull) {
        switch t {
        case .face(let i): if h.faces.indices.contains(i) { flow.pick(face: h.faces[i]) }
        case .edge(let i): if h.edges.indices.contains(i) { flow.pick(edge: h.edges[i]) }
        }
    }

    static func key(_ t: PrintPatches.Target, _ face: String, _ edge: String) -> String {
        switch t {
        case .face(let i): return face + "\(i)"
        case .edge(let i): return edge + "\(i)"
        }
    }
}

/// Bottom right, in Export's place: Cancel, "Manual orientation" and "Check strength" (Export is hidden: nothing unchecked is
/// exported). ★ notes28: Cancel here, left of Manual orientation (it cut under the Structural menu at the top left); in Manual,
/// what to tap (≤ 5 words) above the row.
struct PrintOrientationCorner: View {
    @ObservedObject var flow: PrintOrientationFlow
    let host: PrintOrientationHost
    let variant: () -> PrintCheckVariant

    var body: some View {
        DSCorner(key: "resultsCorner") {
            DSGlassButton(PrintOrientationWords.cancel, key: "orientCancel") { flow.cancel() }
                .accessibilityIdentifier("orient-cancel")
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
        } above: {
            if flow.phase == .manual {
                Text(flow.hull == nil ? PrintOrientationWords.findingFaces : PrintOrientationWords.manualCaption)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.textSecondary.color)
                    .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.xs)
                    .background(Capsule().fill(ResultsChrome.fill.color))
                    .background(ResultsChrome.publish("orientManualCaption"))
            }
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
