// FlexibleStageViewTags — the Prisms view's mm tags and the Groups view's number discs, on screen (task
// 2026-09-29-flexible-screens, round 6, item 3; his img3: "When a face … is highlighted, we should
// automatically be able to see the amount of squish it has been set to").
//
// ★ THE TAGS (the Prisms view): each pressed face's deepest squish, "%.1f mm", READ-ONLY, at its prism's
// FLOOR (the depth chip's own anchor — FlexibleDepthPrism.handle), so the number sits where the prism ends.
// The selected face shows its draggable chip instead (FlexibleDepthChips); a tag's tap selects its face, and
// the chip replaces the tag. GREEDY against overlaps — the larger face (more columns) wins — and hidden under
// a keep-out (the panel, the legend, the player, the view buttons).
// ★ THE DISCS (the Groups view, past the eighth group): FlexibleGroupNumberDisc on each member's glass
// (FlexibleGroupWalls.discs), hidden under a keep-out, at 40 % on a member that faces away. Never a tap.
// ★ R6 REVIEW: THE DASHED OUTLINES — every shown member that faces away (its glass culled) as a bold dashed line in its
// colour ([Rests] from above, the Groups view's far members); and the layer names what it drew (FlexibleViewMarksKey).

import SwiftUI
import simd
import TopOptDesign
import TopOptKit

enum FlexibleStageViewTags {

    /// One read-only "%.1f mm" tag at a prism's floor.
    struct Tag: Equatable {
        let region: Int
        let text: String
        let point: CGPoint
        /// ★ S1b VERIFICATION (the main page; his img3's red line): the FACE this number belongs to, on screen — where
        /// its prism's axis meets the face (the prism's base centre). The tag's leader runs from the tag to it. nil on
        /// Settings, where the prism itself joins them through the X-ray.
        var face: CGPoint? = nil
        /// Where the leader's visible run stops: the face, or where a keep-out begins. nil: no leader.
        var leaderEnd: CGPoint? = nil
        /// The face turns away from the camera: its leader dashed and its dot hollow (the hidden-line convention).
        var away: Bool = false
        /// Under [Prisms], a face of the active Selections group: its prism brighter, its tag placed first.
        var bright: Bool = false
    }

    /// A tag's hit area (≥ 44 pt tall, as the chip's).
    static let size = CGSize(width: 84, height: 44)

    /// ★ S1b VERIFICATION: the MAIN page's tag AS DRAWN — a fixed capsule ("24.5 mm" in 12 pt semibold digits is ≈ 51 pt
    /// wide, in a 76 × 26 pt capsule), never a tap. The greedy pass reads it: Settings' 84 × 44 is a TAP target, and on the main
    /// page it dropped r5's face 3 against a neighbour whose capsule sat 18 pt clear.
    static let mainSize = CGSize(width: 76, height: 26)
    /// The gap a main-page tag keeps from another tag and from every keep-out.
    static let mainGap: CGFloat = 4
    /// A main-page tag's frame (as drawn) centred on `p`.
    static func mainFrame(_ p: CGPoint) -> CGRect {
        CGRect(x: p.x - mainSize.width / 2, y: p.y - mainSize.height / 2, width: mainSize.width, height: mainSize.height)
    }

    /// ★ S1b VERIFICATION: one main-page candidate — where its tag may sit, in order (its prism's FLOOR first, where the
    /// number belongs; then along the prism's axis toward its face; then on out past the face), and its face on screen.
    struct MainCandidate {
        let region: Int
        let columns: Int
        let bright: Bool
        let text: String
        let along: [CGPoint]
        /// `along[..<axisCount]` lie on the prism's axis; the rest beside its face, where the tag is taken only if its
        /// leader reaches the face.
        var axisCount: Int
        let face: CGPoint?
        let away: Bool
    }

    /// ★ S1b VERIFICATION (the main page): the tags that show, of `cands`. The active group's first (under [Prisms]), then
    /// the larger face, then the lower region; each at the first place along its prism's axis whose capsule is on screen,
    /// clear of every keep-out and of the tags already placed (a floor under the Selections panel slides toward its face —
    /// on the verifier's 13" portrait two of A1_0003's five floors were under it). The leader keeps the tag tied to its
    /// face wherever it sits, so nothing points at the wrong face.
    static func placeMain(_ cands: [MainCandidate], keepOut: [CGRect], viewport: CGSize) -> [Tag] {
        let screen = CGRect(origin: .zero, size: viewport)
        let blockers = keepOut.map { $0.insetBy(dx: -mainGap, dy: -mainGap) }
        let order = cands.sorted { a, b in
            if a.bright != b.bright { return a.bright }
            if a.columns != b.columns { return a.columns > b.columns }
            return a.region < b.region
        }
        var out: [Tag] = []
        for c in order {
            for (i, p) in c.along.enumerated() {
                let fr = mainFrame(p)
                guard screen.contains(fr), !blockers.contains(where: { $0.intersects(fr) }),
                      !out.contains(where: { mainFrame($0.point).insetBy(dx: -mainGap, dy: -mainGap).intersects(fr) }) else { continue }
                let end = c.face.flatMap { leaderRun(from: p, to: $0, keepOut: keepOut, viewport: viewport) }
                // off the axis, only where the leader reaches the face's dot (else nothing ties it to its face)
                if i >= c.axisCount {
                    guard let e = end, let f = c.face, hypot(e.x - f.x, e.y - f.y) < 0.5 else { continue }
                }
                out.append(Tag(region: c.region, text: c.text, point: p, face: c.face, leaderEnd: end, away: c.away, bright: c.bright))
                break
            }
        }
        return out
    }

    /// The leader's visible run from a tag at `p` toward its face `f`: to the face, or to where it first enters a keep-out
    /// (it is never drawn over the chrome) or leaves the screen; nil when none of it shows outside the tag's capsule.
    static func leaderRun(from p: CGPoint, to f: CGPoint, keepOut: [CGRect], viewport: CGSize) -> CGPoint? {
        let screen = CGRect(origin: .zero, size: viewport)
        let n = max(1, Int((hypot(f.x - p.x, f.y - p.y) / 2).rounded(.up)))
        var last = p
        for i in 1...n {
            let q = i == n ? f : CGPoint(x: p.x + (f.x - p.x) * CGFloat(i) / CGFloat(n), y: p.y + (f.y - p.y) * CGFloat(i) / CGFloat(n))
            if !screen.contains(q) || keepOut.contains(where: { $0.contains(q) }) { break }
            last = q
        }
        return mainFrame(p).insetBy(dx: -1, dy: -1).contains(last) ? nil : last
    }

    /// The Prisms view's tags on screen: every pressed face but the selected one (its chip), greedy against
    /// overlaps (the larger face first), none under a keep-out or off screen.
    @MainActor
    static func tags(model m: FlexibleStageModel, k: Double, projection: CameraProjection?, keepOut: [CGRect]) -> [Tag] {
        guard m.views.contains(.prisms), let proj = projection, k > 0 else { return [] }
        let cands: [(columns: Int, tag: Tag)] = floors(model: m, k: k).compactMap { f in
            proj.project(f.anchor).map { (f.columns, Tag(region: f.region, text: f.text, point: $0)) }
        }
        return greedy(cands, keepOut: keepOut, viewport: proj.viewportSize)
    }

    /// The tags that show, of `cands`: greedy against overlaps (the larger face — more columns — first, then the lower
    /// region), none under a keep-out or off screen. Settings' tags (★ S1b VERIFICATION: the main page's read-only tags
    /// are placed by `placeMain` — measured as drawn, slid along the prism's axis, joined to the face by a leader).
    static func greedy(_ cands: [(columns: Int, tag: Tag)], keepOut: [CGRect], viewport: CGSize) -> [Tag] {
        var out: [Tag] = []
        for c in cands.sorted(by: { $0.columns != $1.columns ? $0.columns > $1.columns : $0.tag.region < $1.tag.region }) {
            let fr = frame(c.tag)
            guard FlexibleDepthChipLayout.visible(c.tag.point, keepOut: keepOut, viewport: viewport),
                  !keepOut.contains(where: { $0.intersects(fr) }),
                  !out.contains(where: { frame($0).intersects(fr) }) else { continue }
            out.append(c.tag)
        }
        return out
    }

    /// Each pressed face's prism floor (model space) but the selected one's, with its text and its size —
    /// cached per model state (the projection moves every frame; the prisms do not).
    struct Floor { let region: Int; let columns: Int; let text: String; let anchor: SIMD3<Float> }
    @MainActor private static var floorCache: (key: String, floors: [Floor])?
    @MainActor
    static func floors(model m: FlexibleStageModel, k: Double) -> [Floor] {
        let key = "\(k)|\(m.selectedRegion ?? -1)|\(m.settings.hashValue)|\(m.stacks.count)|\(m.geometry.count)|\(m.stampGrids.count)"
        if let c = floorCache, c.key == key { return c.floors }
        var out: [Floor] = []
        for f in m.settings.loadedFaces where f.faceRegionID != m.selectedRegion {
            let r = f.faceRegionID
            guard let key = m.key(r), let st = m.stacks[key], let g = m.geometry[key],
                  let v = FlexibleDepthPrism.volume(region: r, stack: st, centres: g.centres, depthMM: f.deepestMM, k: k,
                                                    footprint: m.prismFootprint(r)),
                  let h = FlexibleDepthPrism.handle(v) else { continue }
            out.append(Floor(region: r, columns: st.columns.count, text: String(format: "%.1f mm", f.deepestMM), anchor: h.anchor))
        }
        floorCache = (key, out)
        return out
    }

    /// A tag's frame on screen (its hit area).
    static func frame(_ t: Tag) -> CGRect {
        CGRect(x: t.point.x - size.width / 2, y: t.point.y - size.height / 2, width: size.width, height: size.height)
    }

    /// A tag's tap: that face is selected (its draggable chip replaces the tag).
    @MainActor
    static func tap(_ t: Tag, model: FlexibleStageModel) { model.select(t.region) }

    /// One disc on screen.
    struct PlacedDisc: Equatable {
        let disc: FlexibleGroupWalls.Disc
        let point: CGPoint
        let facesAway: Bool
    }

    /// The Groups view's discs on screen (none under a keep-out).
    @MainActor
    static func discs(model m: FlexibleStageModel, projection: CameraProjection?, keepOut: [CGRect]) -> [PlacedDisc] {
        guard let proj = projection else { return [] }
        return FlexibleGroupWalls.discs(model: m, views: m.views, mesh: m.project.viewerMesh).compactMap { d in
            guard let p = proj.project(d.anchor), FlexibleDepthChipLayout.visible(p, keepOut: keepOut, viewport: proj.viewportSize)
            else { return nil }
            let away = proj.ray(throughViewPoint: p).map { simd_dot($0.dir, d.normal) > 0 } ?? false
            return PlacedDisc(disc: d, point: p, facesAway: away)
        }
    }
}

/// ★ R6 REVIEW: what the layer draws, by name (`tag-<region>`, `disc-<region>`, `hidden-<key>-<region>`), in the
/// stage's frame — the hosted tests read it.
struct FlexibleViewMarksKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

extension FlexibleStageViewTags {
    /// ★ R6 REVIEW: a shown member that faces AWAY — its glass is culled (colours never mix through the X-ray) — drawn
    /// as a bold dashed line in its group's colour round its own outline (the hidden-line convention): his [Rests] tab
    /// shows the bottom from every camera above it, and the Groups view every group's far members.
    struct Hidden: Equatable {
        let key: String
        let region: Int
        let colour: RGBA
        let paths: [[CGPoint]]
        var id: String { "hidden-\(key)-\(region)" }
        /// The paths' bounding box (the marks' frame).
        var bounds: CGRect {
            let ps = paths.flatMap { $0 }
            guard let x0 = ps.map(\.x).min(), let x1 = ps.map(\.x).max(), let y0 = ps.map(\.y).min(), let y1 = ps.map(\.y).max() else { return .null }
            return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }
    }
    /// The dashed line's stroke.
    static let hiddenLineWidth: CGFloat = 2.5
    static let hiddenDash: [CGFloat] = [7, 5]
    /// A member faces away when the view ray through its centroid meets its outward normal at more than this.
    static let awayDot: Float = 0.05

    /// Every shown member that faces away from the camera, its outline loops projected (a loop with a point
    /// behind the camera is left out).
    @MainActor
    static func hidden(model m: FlexibleStageModel, projection: CameraProjection?) -> [Hidden] {
        guard let proj = projection else { return [] }
        return FlexibleGroupWalls.outlines(model: m, views: m.views, mesh: m.project.viewerMesh).compactMap { o in
            guard let p = proj.project(o.point), let ray = proj.ray(throughViewPoint: p), simd_dot(ray.dir, o.normal) > awayDot
            else { return nil }
            let paths = o.loops.compactMap { loop -> [CGPoint]? in
                let ps = loop.compactMap { proj.project($0) }
                return ps.count == loop.count && ps.count >= 3 ? ps : nil
            }
            return paths.isEmpty ? nil : Hidden(key: o.key, region: o.region, colour: o.colour, paths: paths)
        }
    }
}

/// The tags and discs, over the part (FlexibleStageOverlays mounts it; it follows the camera).
struct FlexibleStageViewTagsLayer: View {
    @ObservedObject var model: FlexibleStageModel
    let projection: CameraProjection?
    let k: Double
    let keepOut: [CGRect]

    static let discSize: CGFloat = 22

    var body: some View {
        let tags = FlexibleStageViewTags.tags(model: model, k: k, projection: projection, keepOut: keepOut)
        let discs = FlexibleStageViewTags.discs(model: model, projection: projection, keepOut: keepOut)
        let hidden = FlexibleStageViewTags.hidden(model: model, projection: projection)
        ZStack {
            // ★ R6 REVIEW: the shown members that face away, dashed in their colour (under the tags and discs)
            ForEach(hidden, id: \.id) { h in
                Path { p in
                    for loop in h.paths {
                        p.move(to: loop[0])
                        for q in loop.dropFirst() { p.addLine(to: q) }
                        p.closeSubpath()
                    }
                }
                .stroke(h.colour.color, style: StrokeStyle(lineWidth: FlexibleStageViewTags.hiddenLineWidth, lineCap: .round,
                                                           lineJoin: .round, dash: FlexibleStageViewTags.hiddenDash))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            ForEach(tags, id: \.region) { t in
                Button { FlexibleStageViewTags.tap(t, model: model) } label: {
                    Text(t.text).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(DS.Color.textPrimary.color)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(DS.Surface.panel.color.opacity(0.85))
                            .overlay(Capsule().strokeBorder(FlexibleStageStyle.facePrismKnob.color, lineWidth: 1)))
                        .frame(width: FlexibleStageViewTags.size.width, height: FlexibleStageViewTags.size.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Squish \(t.text)")
                .accessibilityIdentifier("flexible-prism-tag-\(t.region)")
                .position(t.point)
            }
            ForEach(discs, id: \.disc.region) { d in
                FlexibleGroupNumberDisc(colour: d.disc.colour, number: d.disc.number, size: Self.discSize)
                    .opacity(d.facesAway ? 0.4 : 1)
                    .allowsHitTesting(false)
                    .position(d.point)
                    .accessibilityIdentifier("flexible-group-disc-\(d.disc.region)")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // ★ R6 REVIEW: what this layer drew, by name, in the stage's frame (the hosted tests read it)
        .preference(key: FlexibleViewMarksKey.self, value: Self.marks(tags: tags, discs: discs, hidden: hidden))
    }

    static func marks(tags: [FlexibleStageViewTags.Tag], discs: [FlexibleStageViewTags.PlacedDisc],
                      hidden: [FlexibleStageViewTags.Hidden]) -> [String: CGRect] {
        var m: [String: CGRect] = [:]
        for t in tags { m["tag-\(t.region)"] = FlexibleStageViewTags.frame(t) }
        for d in discs { m["disc-\(d.disc.region)"] = CGRect(x: d.point.x - discSize / 2, y: d.point.y - discSize / 2, width: discSize, height: discSize) }
        for h in hidden { m[h.id] = h.bounds }
        return m
    }
}
