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
    }

    /// A tag's hit area (≥ 44 pt tall, as the chip's).
    static let size = CGSize(width: 84, height: 44)

    /// The Prisms view's tags on screen: every pressed face but the selected one (its chip), greedy against
    /// overlaps (the larger face first), none under a keep-out or off screen.
    @MainActor
    static func tags(model m: FlexibleStageModel, k: Double, projection: CameraProjection?, keepOut: [CGRect]) -> [Tag] {
        guard m.views.contains(.prisms), let proj = projection, k > 0 else { return [] }
        let cands: [(columns: Int, tag: Tag)] = floors(model: m, k: k).compactMap { f in
            proj.project(f.anchor).map { (f.columns, Tag(region: f.region, text: f.text, point: $0)) }
        }
        var out: [Tag] = []
        for c in cands.sorted(by: { $0.columns != $1.columns ? $0.columns > $1.columns : $0.tag.region < $1.tag.region }) {
            let fr = frame(c.tag)
            guard FlexibleDepthChipLayout.visible(c.tag.point, keepOut: keepOut, viewport: proj.viewportSize),
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
