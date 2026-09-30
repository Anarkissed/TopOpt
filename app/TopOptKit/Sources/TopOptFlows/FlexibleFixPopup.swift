// FlexibleFixPopup — the one thing to fix, said at once, fixed in one tap (task
// 2026-09-29-flexible-screens, round 3 batch B, item 9).
//
// ★ HIS RULE: "blockers surface at once as a pop-up that SELECTS the face and says exactly
// what to choose, with 1–3 fix buttons". The pop-up
//   * selects the face (the panel shows it) and pulses it on the part,
//   * turns the camera to look at it (the gizmo view nearest the face's outward normal —
//     never while he is mid-orbit: it turns once, when it opens),
//   * says ONE sentence (FlexibleIssue.oneLine),
//   * offers 1–3 big buttons (FlexibleFix): "[Face 2 rests] [Remove Face 2]", "[Type the
//     weight]" (the shared number pad), "[varioShore TPU]". (Round 3's "[Face 5 rests] [Face 3
//     rests]" for a shared stack went in round 4 D2: a pinch builds.)
// It opens on a NEW blocking issue HIS last action caused (FlexibleFixPrompt), when Exit is
// tapped while something blocks, or from the readiness line's [Fix] / the main page's pill.

import SwiftUI
import simd
import TopOptDesign

struct FlexibleFixPopup: View {
    @ObservedObject var model: FlexibleStageModel
    let issue: FlexibleIssue
    @Binding var padTarget: String?
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(alignment: .top, spacing: DS.Space.s) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(DS.Color.warning.color)
                Text(issue.oneLine)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary.color)
                    .lineLimit(2).minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("flexible-fix-line")
                Spacer(minLength: DS.Space.s)
                Button(action: onDone) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.Color.textTertiary.color)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("flexible-fix-close")
            }
            HStack(spacing: DS.Space.s) {
                ForEach(Array(issue.fixes.prefix(3).enumerated()), id: \.offset) { i, fix in
                    fixButton(fix, primary: i == 0)
                        // each button's frame reaches the page (a hosted test clicks it)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["fix-\(Self.id(fix))": g.frame(in: .global)])
                        }.allowsHitTesting(false))
                }
            }
        }
        .padding(DS.Space.ml)
        .frame(maxWidth: 460, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel).fill(DS.Surface.panel.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel).strokeBorder(DS.Color.warning.color.opacity(0.6), lineWidth: 1)))
        .dsShadow(DS.Shadow.panel)
        .accessibilityIdentifier("flexible-fix-popup")
    }

    @ViewBuilder private func fixButton(_ fix: FlexibleFix, primary: Bool) -> some View {
        let title = fix.title { model.displayName($0) }
        let label = Text(title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle((primary ? FlexibleStageStyle.onAccent : DS.Color.textPrimary.color))
            .lineLimit(1).minimumScaleFactor(0.8)
            .padding(.vertical, 12).padding(.horizontal, DS.Space.l)
            .frame(minWidth: 120)
            .background(Capsule().fill(primary ? FlexibleStageStyle.accent : DS.Color.chipSolid.color))
        switch fix {
        case .weight(let r):
            Button { padTarget = "fix-\(r)" } label: { label }
                .buttonStyle(.plain)
                .accessibilityIdentifier("flexible-fix-weight")
                .modifier(FlexPadCommit(key: "fix-\(r)", padTarget: $padTarget,
                                        config: .init(title: FlexibleRowCopy.askWeight, unit: "kg", allowsDecimal: true),
                                        seed: nil) { v in
                    if model.settings.face(r)?.isLoaded == true { model.setWeight(r, kg: v) } else { model.press(r, kg: v) }
                    onDone()
                })
        case .press(let r) where model.pressNeedsWeight(r):
            // no main-page weight and no squeeze force yet: pressing asks it (the pad), then presses
            Button { padTarget = "fix-\(r)" } label: { label }
                .buttonStyle(.plain)
                .accessibilityIdentifier("flexible-fix-press")
                .modifier(FlexPadCommit(key: "fix-\(r)", padTarget: $padTarget,
                                        config: .init(title: FlexibleRowCopy.askWeight, unit: "kg", allowsDecimal: true),
                                        seed: nil) { v in
                    model.press(r, kg: v)
                    onDone()
                })
        default:
            Button { Self.apply(fix, to: model); onDone() } label: { label }
                .buttonStyle(.plain)
                .accessibilityIdentifier("flexible-fix-\(Self.id(fix))")
        }
    }

    static func id(_ fix: FlexibleFix) -> String {
        switch fix {
        case .rest(let r): return "rest-\(r)"
        case .remove(let r): return "remove-\(r)"
        case .weight(let r): return "weight-\(r)"
        case .press(let r): return "press-\(r)"
        case .pickFilament(let id, _): return "filament-\(id)"
        case .joinGroups(let from, let into): return "join-\(from)-\(into)"
        case .keepApart: return "keep-apart"
        }
    }

    /// One tap: the fix, through the model's own actions (undoable, saved like every edit).
    @MainActor
    static func apply(_ fix: FlexibleFix, to model: FlexibleStageModel) {
        switch fix {
        case .rest(let r): model.rest(r)
        case .remove(let r): model.removeFace(r)
        case .press(let r): model.press(r)
        case .pickFilament(let id, _): model.pickMaterial(id)
        case .joinGroups(let from, let into): model.mergeGroup(from, into: into)
        case .keepApart: break   // the pop-up closes; the groups stay apart
        case .weight: break   // the pad commits
        }
    }

    /// The gizmo view that looks at a face whose load (into the part) is `load`, with the
    /// part drawn under `settle`: the region whose eye direction is nearest the face's
    /// outward normal in the world.
    static func cameraRegion(load: SIMD3<Double>, settle: simd_quatf) -> GizmoRegion? {
        let out = settle.act(SIMD3<Float>(-load))
        guard simd_length(out) > 1e-6 else { return nil }
        let n = simd_normalize(out)
        return OrientationGizmo.regions.max { simd_dot($0.direction, n) < simd_dot($1.direction, n) }
    }

    /// ★ TWO FACES (a shared stack — batch B review): the face-on view of ONE of them hid the
    /// other directly behind it, and turned its curve editor edge-on. So: between the two
    /// outward normals when they are apart (the region nearest their mean); for two facing
    /// AWAY from each other (3 and 5, the two ends of one stack) an OBLIQUE corner view from
    /// above that looks at `load`'s face, the other seen through the X-ray.
    static func cameraRegion(load: SIMD3<Double>, other: SIMD3<Double>, settle: simd_quatf) -> GizmoRegion? {
        let a = settle.act(SIMD3<Float>(-load)), b = settle.act(SIMD3<Float>(-other))
        guard simd_length(a) > 1e-6, simd_length(b) > 1e-6 else { return cameraRegion(load: load, settle: settle) }
        let na = simd_normalize(a), nb = simd_normalize(b)
        let mean = na + nb
        if simd_length(mean) > 0.5 {
            let m = simd_normalize(mean)
            return OrientationGizmo.regions.max { simd_dot($0.direction, m) < simd_dot($1.direction, m) }
        }
        let corners = OrientationGizmo.regions.filter { $0.kind == .corner && $0.direction.y > 0 }
        return corners.max { simd_dot($0.direction, na) < simd_dot($1.direction, na) }
    }
}
