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

/// ★ R6 REVIEW (stub): what the layer draws, by name (`tag-<region>`, `disc-<region>`, `hidden-<key>-<region>`), in the
/// stage's frame — the hosted tests read it.
struct FlexibleViewMarksKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

extension FlexibleStageViewTags {
    /// A shown member that faces AWAY, drawn dashed (stub).
    struct Hidden: Equatable {
        let key: String
        let region: Int
        let colour: RGBA
        let paths: [[CGPoint]]
    }
    @MainActor
    static func hidden(model m: FlexibleStageModel, projection: CameraProjection?) -> [Hidden] { [] }
}

/// The tags and discs, over the part (FlexibleStageOverlays mounts it; it follows the camera).
struct FlexibleStageViewTagsLayer: View {
    @ObservedObject var model: FlexibleStageModel
    let projection: CameraProjection?
    let k: Double
    let keepOut: [CGRect]

    static let discSize: CGFloat = 22

    var body: some View {
        ZStack {
            ForEach(FlexibleStageViewTags.tags(model: model, k: k, projection: projection, keepOut: keepOut), id: \.region) { t in
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
            ForEach(FlexibleStageViewTags.discs(model: model, projection: projection, keepOut: keepOut), id: \.disc.region) { d in
                FlexibleGroupNumberDisc(colour: d.disc.colour, number: d.disc.number, size: Self.discSize)
                    .opacity(d.facesAway ? 0.4 : 1)
                    .allowsHitTesting(false)
                    .position(d.point)
                    .accessibilityIdentifier("flexible-group-disc-\(d.disc.region)")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
