// FlexibleDepthChips — the green glass chip on the selected pressed face that drags its
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
    @State private var held: LatticeDepthDetent.Candidate?
    @State private var scrub: Scrub?
    /// True for exactly as long as the drag lives — reset by SwiftUI on end AND on cancel.
    @GestureState private var dragging = false

    struct Scrub { let seedMM: Double }

    var body: some View {
        ZStack {
            if let r = model.selectedRegion, let f = model.settings.face(r), f.isLoaded, let key = model.key(r),
               let st = model.stacks[key], let g = model.geometry[key], let proj = projection,
               let v = FlexibleDepthPrism.volume(region: r, stack: st, centres: g.centres, depthMM: f.deepestMM,
                                                 k: model.frozenExaggeration ?? k),
               let h = FlexibleDepthPrism.handle(v), let p = proj.project(h.anchor),
               FlexibleDepthChipLayout.shows(p, dragging: dragging || model.frozenExaggeration != nil,
                                             keepOut: keepOut, viewport: proj.viewportSize) {
                chip(f.deepestMM, arrow: arrowAngle(proj, h, at: p))
                    .position(p)
                    .gesture(drag(region: r, handle: h, stack: st, proj: proj, startMM: f.deepestMM)
                        .updating($dragging) { _, state, _ in state = true })
            }
        }
        // a drag that ENDED without onEnded (cancelled) is finished here
        .onChange(of: dragging) { d in if !d { finish() } }
        .onDisappear { finish() }
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

    private func chip(_ mm: Double, arrow: Angle) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.down").font(.system(size: 12, weight: .bold)).rotationEffect(arrow)
            Text(String(format: "%.1f mm", mm)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
        }
        .foregroundStyle(DS.Color.textPrimary.color)
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(Capsule().fill(.ultraThinMaterial))
        .background(Capsule().fill(FlexibleStageStyle.accent.opacity(0.28)))
        .overlay(Capsule().strokeBorder(FlexibleStageStyle.accent.opacity(0.8), lineWidth: 1.5))
        .contentShape(Capsule())
        .accessibilityIdentifier("flexible-depth-chip")
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
                let r = FlexibleDepthPrism.resolve(rawMM: raw, latticeMM: st.latticeMMMax,
                                                   limitMM: FlexibleDepthPrism.dragLimit(stack: st, k: kk), held: held)
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
