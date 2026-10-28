// FlexibleDepthChips — the glass chip on the selected pressed face that drags its
// deepest squish out as a prism (task 2026-09-29-flexible-screens, round 3, item 1.1).
//
// ★ THE DRAG. The finger's MODEL-space ray (the page's projection composes the settle) meets
// the prism's `.slabDepth` handle (normal == load) — `ClearanceHandle.value`, the lattice
// stage's own ray math — and reads the SHOWN depth; ÷ k (frozen at drag start, on the model,
// so the dent, the prism and the chip all hold one scale while the finger moves) gives the
// true mm, then 0.5 mm / lattice-depth detents with a haptic tick, then the clamp. While
// dragging only the settings change (no re-design); release recomputes and saves.
// ★ LOOKING ALONG THE LOAD (a top face seen from above) the ray is parallel to the handle's
// axis and the ray math is ill-conditioned — then the drag is a screen scrub, 0.05 mm per
// point, seeded at drag start (every seed lives in @State: SwiftUI rebuilds a gesture on
// every body evaluation). ★ The scrub is always DOWN = DEEPER (verification of round 3):
// the load's projection there is ~0–4 pt per 10 mm, so its direction was the perspective's
// arbitrary radial one — dragging down made his top A SHALLOWER.
// ★ KEEP-OUT. A chip under the panel or the legend could not be reached; it hides there
// (LatticeBandChipLayout's rule) and the panel's row still sets the value — but NEVER mid-
// drag: removing the view cancelled the gesture without onEnded, which left k frozen and
// nothing recomputed or saved. A cancelled drag is finished by the @GestureState reset too.
// ★ ONE DRAG STAYS INSIDE THE PART: k × depth ≤ every column's lattice depth
// (FlexibleDepthPrism.dragLimit); after release k is re-chosen and the next drag goes on.

import SwiftUI
import simd
import TopOptDesign
import TopOptKit

enum FlexibleDepthChipLayout {
    /// Half the chip's hit target: how far off an edge or a keep-out it must sit.
    static let margin: CGFloat = 22

    static func visible(_ p: CGPoint, keepOut: [CGRect], viewport: CGSize) -> Bool {
        guard p.x.isFinite, p.y.isFinite,
              p.x >= margin, p.y >= margin, p.x <= viewport.width - margin, p.y <= viewport.height - margin
        else { return false }
        return !keepOut.contains { $0.insetBy(dx: -margin, dy: -margin).contains(p) }
    }

    /// Is the chip mounted? Always while it is being dragged (only a finite point is needed);
    /// otherwise only where it can be reached (`visible`).
    static func shows(_ p: CGPoint, dragging: Bool, keepOut: [CGRect], viewport: CGSize) -> Bool {
        guard p.x.isFinite, p.y.isFinite else { return false }
        return dragging || visible(p, keepOut: keepOut, viewport: viewport)
    }

    /// The scrub fallback: looking (nearly) along the load, or the load barely projects.
    static func needsScrub(rayAlongLoad: Double, projectedPointsPer10MM: CGFloat) -> Bool {
        rayAlongLoad > 0.97 || projectedPointsPer10MM < 8
    }

    /// The scrub's screen direction: DOWN is deeper, whatever the perspective does.
    static let scrubDirection = CGVector(dx: 0, dy: 1)

    /// The mm a scrub reads: the seed plus the finger's travel along `scrubDirection`.
    static func scrubMM(seedMM: Double, translation: CGSize) -> Double {
        seedMM + Double(translation.width * scrubDirection.dx + translation.height * scrubDirection.dy) * scrubMMPerPoint
    }

    /// mm per point of screen scrub.
    static let scrubMMPerPoint = 0.05
}

struct FlexibleDepthChips: View {
    @ObservedObject var model: FlexibleStageModel
    let projection: CameraProjection?
    /// The page's exaggeration (FlexibleShownValues.exaggeration).
    let k: Double
    let keepOut: [CGRect]
    /// ★ ROUND 7 REVIEW (R, his answer of 2026-10-15: "With Bend on, the depth chip and depth labels MOVE with the bend"): the
    /// full-bend pose while Bend shows — the chip sits on its prism's floor at the full bend (nil: at rest).
    var pose: FlexibleBendPose? = nil
    /// ★ R7-E1: the page's keypad slot — a TAP on the chip opens the keypad (his rule: numbers are boxes); nil: drag only.
    var padTarget: Binding<String?>? = nil
    @State private var held: LatticeDepthDetent.Candidate?
    @State private var scrub: Scrub?
    /// True for exactly as long as the drag lives — reset by SwiftUI on end AND on cancel.
    @GestureState private var dragging = false

    struct Scrub { let seedMM: Double }

    var body: some View {
        ZStack {
            // ★ ROUND 7 (S, 4g): the face he works on in the OPEN tab only (his img4: Face 1's "3.0 mm" over Group 2's tab)
            if let r = FlexibleStageOverlays.workingRegion(model: model), let f = model.settings.face(r), f.isLoaded, let key = model.key(r),
               let st = model.stacks[key], let proj = projection,
               // ★ batch E review: no lattice under the face — nothing to drag into (the row says why)
               // ★ U21 batch E: and none with no lattice of its own (model.latticeMaxMM: 0)
               !FlexibleLatticeUnder.nothingToSquish(latticeMaxMM: model.latticeMaxMM(r) ?? FlexibleDepthPrism.latticeMax(st, pinched: model.pinchedColumns(r))),
               let h = Self.handle(model: model, k: k, pose: pose), let p = proj.project(h.anchor),
               FlexibleDepthChipLayout.shows(p, dragging: dragging || model.frozenExaggeration != nil,
                                             keepOut: keepOut, viewport: proj.viewportSize) {
              if !model.depthIsInput {
                // ★ MANUAL (M2, his picks of 2026-10-22: the depths become the app's PREDICTION): a read-only label on the prism's
                // floor — "≈ 3.2 mm" (or "No estimate yet"); no drag handle, no keypad
                chip(f.deepestMM, reached: nil, arrow: arrowAngle(proj, h, at: p), text: model.depthLabel(region: r, deepestMM: f.deepestMM))
                    .background(GeometryReader { g in
                        Color.clear.preference(key: FlexibleViewMarksKey.self, value: ["depthLabel-\(r)": g.frame(in: .global)])
                    }.allowsHitTesting(false))
                    .allowsHitTesting(false)
                    .position(p)
              } else {
                chip(f.deepestMM, reached: model.frozenExaggeration == nil ? model.reached(region: r) : nil, arrow: arrowAngle(proj, h, at: p))   // ★ U21 batch F: one number
                    // ★ ROUND 7 (S): what is drawn, by name (the hosted tests read it: no face's chip on an edges tab)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: FlexibleViewMarksKey.self, value: ["depthChip-\(r)": g.frame(in: .global)])
                    }.allowsHitTesting(false))
                    // ★ R7-E1: tap-to-type (the keypad; the value held to the lattice, as the row's box holds it)
                    .modifier(FlexPadCommit(key: "chip-deepest-\(r)", padTarget: padTarget ?? .constant(nil),
                                            config: .init(title: FlexibleRowCopy.deepestTitle, unit: "mm", allowsDecimal: true),
                                            seed: f.deepestMM) { v in
                        let lattice = FlexibleDepthPrism.latticeMax(st, pinched: model.pinchedColumns(r))
                        model.edit { s in
                            guard var g = s.face(r) else { return }
                            g.deepestMM = FlexibleDepthPrism.clamp(v, latticeMM: lattice)
                            s.setFace(g)
                        }
                    })
                    .onTapGesture { padTarget?.wrappedValue = "chip-deepest-\(r)" }
                    .position(p)
                    .gesture(drag(region: r, handle: h, stack: st, proj: proj, startMM: f.deepestMM)
                        .updating($dragging) { _, state, _ in state = true })
              }
            }
        }
        // a drag that ENDED without onEnded (cancelled) is finished here
        .onChange(of: dragging) { d in if !d { finish() } }
        .onDisappear { finish() }
    }

    /// The selected pressed face's prism handle (its anchor is where the chip sits): the one
    /// rule the chip and the stamp handle (which keeps clear of it) both read.
    @MainActor
    static func handle(model: FlexibleStageModel, k: Double) -> ClearanceHandle? { handle(model: model, k: k, pose: nil) }

    /// ★ ROUND 7 REVIEW (R): the handle on the prism at the full bend (`pose`; nil: at rest) — the chip and the drag read
    /// the same bent prism.
    @MainActor
    static func handle(model: FlexibleStageModel, k: Double, pose: FlexibleBendPose?) -> ClearanceHandle? {
        guard let r = FlexibleStageOverlays.workingRegion(model: model), let f = model.settings.face(r), f.isLoaded, let key = model.key(r),
              let st = model.stacks[key], let g = model.geometry[key],
              let v = FlexibleDepthPrism.volume(region: r, stack: st, centres: g.centres, depthMM: model.shownDepthMM(f),   // ★ M2
                                                k: model.frozenExaggeration ?? k, footprint: model.prismFootprint(r))
        else { return nil }
        // (the red control: F's chip, read from the prism at rest)
        let pose = FlexibleBendPose.controlInsideStays ? nil : pose
        return FlexibleDepthPrism.handle(pose.map { $0.pose(v) } ?? v)
    }

    /// Release: k thaws, the designs re-run, the file is written. Idempotent (onEnded and the
    /// gesture-state reset both call it).
    private func finish() {
        guard model.frozenExaggeration != nil else { return }
        model.frozenExaggeration = nil
        held = nil
        scrub = nil
        ClearanceHaptics.release()
        model.recomputeAll()
        model.save()
    }

    /// ★ ROUND 4 (D1, his explicit request, img 2): the lattice stage's depth knob — its
    /// face-prism purple glass (`latticeDepthKnob`'s frost of the density ramp's 0.6 stop) —
    /// with the true mm on it; brighter while dragged, as the knob is.
    /// ★ U21 batch F (DEPTH-LABEL, his Img9: "If it can't go to a depth, ensure that the depth it reverts to is labelled correctly
    /// in both areas"): when core builds short, "0.6 of 7.0 mm" in the warning tint — the card's numbers (one source,
    /// FlexibleStageModel.reached); his box keeps 7.
    private func chip(_ mm: Double, reached: FlexibleReached?, arrow: Angle, text shown: String? = nil) -> some View {
        let active = model.frozenExaggeration != nil
        let text = shown ?? Self.chipText(mm, reached: reached)   // ★ MANUAL (M2): `shown` — the estimate's label
        return HStack(spacing: 5) {
            Image(systemName: "arrow.down").font(.system(size: 12, weight: .bold)).rotationEffect(arrow)
            Text(text).font(.system(size: 13, weight: .semibold)).monospacedDigit()
        }
        .foregroundStyle(reached == nil ? Color.white : DS.Color.warning.color)
        .accessibilityLabel("Deepest squish \(text)")
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .liquidGlass(LiquidGlass.Tint.frost(FlexibleStageStyle.facePrismKnob, intensity: active ? 0.85 : 0.55),
                     in: Capsule(), specular: active ? 1.3 : 1)
        .contentShape(Capsule())
        .accessibilityIdentifier("flexible-depth-chip")
    }

    /// The chip's number: his depth, or core's "0.6 of 7.0 mm" when it builds short (no number while he drags: his own).
    static func chipText(_ mm: Double, reached: FlexibleReached?) -> String {
        reached.map { FlexibleRowCopy.reachedOf($0.reachedMM, $0.deepestMM) } ?? String(format: "%.1f mm", mm)
    }

    /// ★ U21 batch F (SQUISH-CHIP-COVER): the chip's size on screen for its text — 12 pt padding each side, the 12 pt arrow, a 5 pt
    /// gap, 13 pt semibold digits (≈ 7.6 pt each), 44 pt tall; never under the 93 pt his "7.0 mm" chip measured.
    static func size(text: String) -> CGSize { CGSize(width: max(93, 41 + CGFloat(text.count) * 7.6), height: 44) }
    /// The chip's frame around its anchor — what the bend tag and the stamp handle keep clear of.
    @MainActor
    static func frame(at p: CGPoint, model: FlexibleStageModel? = nil) -> CGRect {
        let text = model.flatMap { m in FlexibleStageOverlays.workingRegion(model: m).flatMap { r in
            m.settings.face(r).map { m.isManual ? m.depthLabel(region: r, deepestMM: $0.deepestMM)   // ★ MANUAL (M2)
                : chipText($0.deepestMM, reached: m.frozenExaggeration == nil ? m.reached(region: r) : nil) } } } ?? "00.0 mm"
        let sz = size(text: text)
        return CGRect(x: p.x - sz.width / 2, y: p.y - sz.height / 2, width: sz.width, height: sz.height)
    }

    /// The icon points along the projected load (down for a top face, sideways for a side) —
    /// and straight DOWN where the drag would be a scrub (looking along the load).
    private func arrowAngle(_ proj: CameraProjection, _ h: ClearanceHandle, at p: CGPoint) -> Angle {
        guard let a = proj.project(h.planeOrigin), let b = proj.project(h.planeOrigin + h.planeNormal * 10) else { return .zero }
        let along = proj.ray(throughViewPoint: p).map { Double(abs(simd_dot($0.dir, h.planeNormal))) } ?? 1
        if FlexibleDepthChipLayout.needsScrub(rayAlongLoad: along, projectedPointsPer10MM: hypot(b.x - a.x, b.y - a.y)) {
            return .zero
        }
        return .radians(atan2(-Double(b.x - a.x), Double(b.y - a.y)))
    }

    private func drag(region: Int, handle h: ClearanceHandle, stack st: FlexStackInfo, proj: CameraProjection,
                      startMM: Double) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(FlexibleStageSpace.name))
            .onChanged { g in
                if model.frozenExaggeration == nil {
                    // ★ k freezes for the whole drag (the dent, the prism and this chip)
                    model.frozenExaggeration = k
                    held = nil
                    ClearanceHaptics.grab()
                    let a = proj.project(h.planeOrigin), b = proj.project(h.planeOrigin + h.planeNormal * 10)
                    let along = proj.ray(throughViewPoint: g.startLocation).map { Double(abs(simd_dot($0.dir, h.planeNormal))) } ?? 1
                    let len = (a != nil && b != nil) ? hypot(b!.x - a!.x, b!.y - a!.y) : 0
                    scrub = FlexibleDepthChipLayout.needsScrub(rayAlongLoad: along, projectedPointsPer10MM: len)
                        ? Scrub(seedMM: startMM) : nil
                }
                let kk = model.frozenExaggeration ?? k
                let raw: Double
                if let s = scrub {
                    raw = FlexibleDepthChipLayout.scrubMM(seedMM: s.seedMM, translation: g.translation)
                } else if let ray = proj.ray(throughViewPoint: g.location),
                          let d = FlexibleDepthPrism.depth(handle: h, rayOrigin: ray.origin, rayDir: ray.dir, k: kk) {
                    raw = d
                } else { return }
                // ★ D2 REVIEW: a pinched face stops at the HALF its design uses
                let pinched = model.pinchedColumns(region)
                let r = FlexibleDepthPrism.resolve(rawMM: raw, latticeMM: FlexibleDepthPrism.latticeMax(st, pinched: pinched),
                                                   limitMM: FlexibleDepthPrism.dragLimit(stack: st, k: kk, pinched: pinched), held: held)
                if r.didSnap { ClearanceHaptics.detent() }
                held = r.held
                model.edit({ s in
                    guard var f = s.face(region), abs(f.deepestMM - r.mm) > 1e-9 else { return }
                    f.deepestMM = r.mm
                    s.setFace(f)
                }, recompute: false)
            }
            .onEnded { _ in finish() }
    }
}
