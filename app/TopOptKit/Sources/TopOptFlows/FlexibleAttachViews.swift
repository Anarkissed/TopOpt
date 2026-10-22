// FlexibleAttachViews — what the Attach tool draws (task 2026-09-29-flexible-screens, round 7 · U21 batch I, part I2; his answer
// of 2026-10-21 ~15:35 and his picks ~15:45 — see FlexibleAttach):
//   * FlexibleAttachRows — on chip M under the face line: [🔗 Attach] (a secondary capsule) with "Not attached" / "4 linked" /
//     "Nothing solid touches it", and — inset lattices only — the one-tap "🔗 Attach to the 4 walls around it" (never filled:
//     it never reads as done);
//   * FlexibleAttachStepCard — the card in place: "🔗 Attach · Face 6", the step line, the wall (or target) chips, the say line,
//     [‹ Back] and [Cancel] / [Done];
//   * FlexibleAttachWallsOverlay — the walls on the model, re-projected every render (tappable: accent fill and outline; not:
//     grey dashed; facing away: fainter), each with its 44 pt tag; step 2: the picked wall and its lit solid;
//   * FlexibleLinkRow — one link under its lattice in Selections, its trash asking IN PLACE ([Keep] on the trash's spot).
// Every string ≤ 44 characters (FlexibleSelectionsCopy.attachWorstCases).

import SwiftUI
import simd
import TopOptDesign

private func attachPublish(_ key: String) -> some View {
    GeometryReader { g in Color.clear.preference(key: FlexibleKeepOutKey.self, value: [key: g.frame(in: .global)]) }
        .allowsHitTesting(false)
}

/// A secondary capsule: SF Symbol + words, 36 tall in a 44 pt target.
private struct FlexibleAttachCapsule: View {
    let symbol: String
    let text: String
    var dim = false
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 12.5, weight: .bold)).foregroundStyle(DS.Color.accent.color)
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle((dim ? DS.Color.textTertiary : DS.Color.textPrimary).color)
                .lineLimit(1).fixedSize()
        }
        .padding(.horizontal, DS.Space.m).frame(height: 36)
        .background(Capsule().fill(DS.Color.fillSelected.color).overlay(Capsule().strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1)))
        .frame(height: 44).contentShape(Rectangle())
    }
}

/// Chip M's Attach rows (nothing when the face is not one unlocked Lattice face-prism, or a legend is drilled in).
struct FlexibleAttachRows: View {
    @ObservedObject var main: FlexibleMainStage
    @ObservedObject var project: ProjectModel
    let group: UUID
    let ref: LatticeSelectableRef

    var body: some View {
        switch main.attachRow(project, group: group, ref: ref) {
        case .none:
            EmptyView()
        case .curved:
            Text(FlexibleSelectionsCopy.curvedAttach).font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.Color.textSecondary.color).lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .accessibilityIdentifier("flexible-chip-attach-curved")
        case let .button(right, suggestion):
            HStack(spacing: DS.Space.s) {
                Button { main.startAttach(project, group: group, ref: ref) } label: {
                    FlexibleAttachCapsule(symbol: "link", text: FlexibleSelectionsCopy.attach)
                }
                .buttonStyle(.plain)
                .background(attachPublish("chipAttach"))
                .accessibilityLabel(FlexibleSelectionsCopy.attachVoice)
                .accessibilityIdentifier("flexible-chip-attach")
                Spacer(minLength: DS.Space.xs)
                Text(right).font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Color.textSecondary.color).lineLimit(1)
                    .accessibilityIdentifier("flexible-chip-attach-count")
            }
            .frame(minHeight: 44)
            if let s = suggestion {
                let around = main.attachWalls(project, key: ref.key)?.sides.filter { $0.status == .target && $0.target == "wall" }.count ?? s.count
                Button { main.applySuggestion(project, group: group, ref: ref) } label: {
                    FlexibleAttachCapsule(symbol: "link", text: FlexibleSelectionsCopy.suggest(s.count, other: s.count < around))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(attachPublish("chipAttachSuggest"))
                .accessibilityIdentifier("flexible-chip-attach-suggest")
            }
        }
    }
}

/// The step card (the chip's content while Attach is on).
struct FlexibleAttachStepCard: View {
    @ObservedObject var main: FlexibleMainStage
    @ObservedObject var project: ProjectModel

    static func chipID(_ name: String) -> String { name.lowercased().replacingOccurrences(of: " ", with: "") }

    var body: some View {
        let st = main.attach
        let walls = main.attachWalls(project, key: st.lattice)
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "link").font(.system(size: 14, weight: .bold)).foregroundStyle(DS.Color.accent.color)
                Text(FlexibleSelectionsCopy.attachTitle(st.faceName)).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary.color).lineLimit(1)
                    .accessibilityIdentifier("flexible-attach-title")
                Spacer(minLength: 0)
                Button { main.attachChip(.cancel, project: project) } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(DS.Color.textSecondary.color)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, -6).padding(.trailing, -8)
                .accessibilityLabel(st.linkedHere > 0 ? FlexibleSelectionsCopy.done : FlexibleSelectionsCopy.cancel)
                .accessibilityIdentifier("flexible-attach-close")
            }
            .frame(minHeight: 44)
            Text(FlexibleAttach.stepLine(st, walls: walls)).font(.system(size: 14, weight: .medium))
                .foregroundStyle(DS.Color.textPrimary.color).lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .accessibilityIdentifier("flexible-attach-step")
            chips(st, walls)
            if let say = st.say {
                Text(say).font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Color.textSecondary.color).lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .accessibilityIdentifier("flexible-attach-say")
            }
            HStack(spacing: DS.Space.s) {
                if st.wall != nil {
                    Button { main.attachChip(.back, project: project) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                            Text(FlexibleSelectionsCopy.back).font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(DS.Color.textPrimary.color)
                        .padding(.horizontal, DS.Space.s).frame(height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("flexible-attach-back")
                }
                Spacer(minLength: 0)
                Button { main.attachChip(.cancel, project: project) } label: {
                    Text(st.linkedHere > 0 ? FlexibleSelectionsCopy.done : FlexibleSelectionsCopy.cancel)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                        .padding(.horizontal, DS.Space.m).frame(height: 36)
                        .background(Capsule().fill(DS.Color.fillSelected.color))
                        .frame(height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(attachPublish("attachEnd"))
                .accessibilityIdentifier("flexible-attach-cancel")
            }
        }
        .background(attachPublish("attachCard"))
    }

    private struct Chip: Identifiable { let id: String; let label: String; let lit: Bool; let tap: FlexibleAttachTap }

    @ViewBuilder private func chips(_ st: FlexibleAttachState, _ walls: FlexibleLatticeWalls.Result?) -> some View {
        let list: [Chip] = {
            if let k = st.wall, let w = walls?.wall(k) {
                return w.target.map { [Chip(id: "target-" + $0, label: FlexibleLatticeWalls.targetName($0), lit: true, tap: .target($0))] } ?? []
            }
            return (walls?.walls ?? []).map { Chip(id: Self.chipID($0.name), label: $0.name, lit: $0.tappable, tap: .wall($0.key)) }
        }()
        let first = Array(list.prefix(4)), rest = Array(list.dropFirst(4))
        VStack(alignment: .leading, spacing: DS.Space.s) {
            row(first)
            if !rest.isEmpty {
                if rest.count <= 4 { row(rest) } else { ScrollView(.horizontal, showsIndicators: false) { row(rest) } }
            }
        }
    }

    private func row(_ cs: [Chip]) -> some View {
        HStack(spacing: 6) {
            ForEach(cs) { c in
                Button { main.attachChip(c.tap, project: project) } label: {
                    Text(c.label).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle((c.lit ? DS.Color.textPrimary : DS.Color.textTertiary).color).lineLimit(1).fixedSize()
                        .padding(.horizontal, DS.Space.m).frame(height: 36)
                        .background(Capsule().fill(c.lit ? DS.Color.accent.opacity(0.22).color : DS.Color.fillSubtle.color)
                            .overlay(Capsule().strokeBorder((c.lit ? DS.Color.accent : DS.Color.strokePanel).color,
                                                            style: StrokeStyle(lineWidth: c.lit ? 1.5 : 1, dash: c.lit ? [] : [3, 3]))))
                        .frame(height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(attachPublish("attachChip-\(c.id)"))
                .accessibilityIdentifier("flexible-attach-chip-\(c.id)")
            }
        }
    }
}

/// The walls on the model (hit-transparent except its tags), re-projected every render.
struct FlexibleAttachWallsOverlay: View {
    @ObservedObject var main: FlexibleMainStage
    @ObservedObject var project: ProjectModel
    let frame: LatticeBandChipFrame
    let origin: CGPoint
    let viewport: CGSize
    let under: CGRect?
    let keepOut: [CGRect]

    struct Tag: Identifiable { let id: String; let key: String; let label: String; let point: CGPoint; let tap: FlexibleAttachTap; let linked: Bool; let lit: Bool }

    private func local(_ q: SIMD3<Double>) -> CGPoint? {
        frame.project(SIMD3<Float>(q)).map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) }
    }

    /// Facing away from the camera (its outward normal along the view).
    private func away(_ w: FlexibleLatticeWalls.Wall) -> Bool {
        guard let c = w.centre, let d = frame.viewDirection(at: SIMD3<Float>(c)) else { return false }
        return simd_dot(SIMD3<Double>(d), w.m) > 0.2
    }

    var body: some View {
        let st = main.attach
        let walls = main.attachWalls(project, key: st.lattice)
        let all = walls?.walls ?? []
        let picked = st.wall.flatMap { walls?.wall($0) }
        let fresh = main.model.map { $0.lattice != nil && !$0.latticeIsStale } ?? false
        let tags = placeTags(st, all: all, picked: picked)
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                if let u = under {
                    var p = Path(CGRect(origin: .zero, size: size)); p.addRect(u)
                    ctx.clip(to: p, style: FillStyle(eoFill: true))
                }
                func path(_ q: [SIMD3<Double>]) -> Path? {
                    let pts = q.compactMap(local)
                    guard pts.count == q.count, pts.count >= 3 else { return nil }
                    var p = Path(); p.move(to: pts[0]); for x in pts.dropFirst() { p.addLine(to: x) }; p.closeSubpath()
                    return p
                }
                let accent = DS.Color.accent.color
                if let w = picked {
                    // step 2: the lattice as a ghost (drawn here even with a built lattice: the pass's ghost does not show over
                    // the opaque model), the picked wall bright, its lit solid on top
                    if FlexibleAttach.overlayDrawsGhost(fresh: fresh) {
                        for x in all { for q in x.quads { if let p = path(q) {
                            ctx.fill(p, with: .color(Color.white.opacity(0.12)))
                            ctx.stroke(p, with: .color(Color.white.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        } } }
                    }
                    for q in w.quads {
                        guard let p = path(q) else { continue }
                        ctx.fill(p, with: .color(accent.opacity(0.30)))
                        ctx.stroke(p, with: .color(accent), lineWidth: 2.5)
                    }
                } else {
                    for w in all {
                        let faint = away(w)
                        let flash = st.flash == w.key
                        for q in (w.quads.isEmpty ? w.frame : w.quads) {
                            guard let p = path(q) else { continue }
                            if w.tappable && !w.quads.isEmpty {
                                ctx.fill(p, with: .color(accent.opacity((flash ? 0.5 : 0.22) * (faint ? 0.45 : 1))))
                                ctx.stroke(p, with: .color(accent.opacity(faint ? 0.45 : 1)),
                                           style: StrokeStyle(lineWidth: 2, dash: faint ? [5, 4] : []))
                            } else {
                                ctx.stroke(p, with: .color(Color.gray.opacity(faint ? 0.45 : 0.9)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            }
                        }
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            ForEach(tags) { t in
                Button { main.attachChip(t.tap, project: project) } label: {
                    HStack(spacing: 3) {
                        if t.linked { Image(systemName: "link").font(.system(size: 10.5, weight: .bold)) }
                        Text(t.label).font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
                    }
                    .foregroundStyle((t.lit ? Color.white : DS.Color.textSecondary.color))
                    .padding(.horizontal, 9).frame(height: 24)
                    .background(Capsule().fill(t.lit ? DS.Color.accent.color : DS.Surface.valuePill.color))
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(attachPublish("attachTag-\(t.id)"))
                .position(t.point)
                .accessibilityIdentifier(t.id.hasPrefix("target-") ? "flexible-attach-\(t.id)" : "flexible-attach-wall-\(t.id)")
            }
        }
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
    }

    /// Each tag at the first clear spot — its wall's centre, then its edges' midpoints — keeping the spot it had while clear.
    private func placeTags(_ st: FlexibleAttachState, all: [FlexibleLatticeWalls.Wall], picked: FlexibleLatticeWalls.Wall?) -> [Tag] {
        let ui = main.faceUI
        let linked = Set(main.liveLinks(project, key: st.lattice).map(\.wall))
        var items: [(id: String, key: String, label: String, tap: FlexibleAttachTap, quads: [[SIMD3<Double>]], lit: Bool, linked: Bool)] = []
        if let w = picked {
            if let t = w.target, !t.hasPrefix("skin") {
                items.append(("target-" + t, w.key, FlexibleLatticeWalls.targetName(t), .target(t), w.quads, true, false))
            }
        } else {
            for w in all where !w.quads.isEmpty {
                items.append((FlexibleAttachStepCard.chipID(w.name), w.key, w.name, .wall(w.key), w.quads, w.tappable, linked.contains(w.key)))
            }
        }
        var taken: [CGRect] = []
        var out: [Tag] = []
        for it in items {
            if FlexibleAttach.controlTagsPlacedOnce, let p = ui.attachTagFrozen[it.id] {
                out.append(Tag(id: it.id, key: it.key, label: it.label, point: p, tap: it.tap, linked: it.linked, lit: it.lit)); continue
            }
            var cands: [SIMD3<Double>] = []
            var sum = SIMD3<Double>.zero, a = 0.0
            for q in it.quads { let ar = simd_length(simd_cross(q[1] - q[0], q[3] - q[0])); sum += (q[0] + q[1] + q[2] + q[3]) / 4 * ar; a += ar }
            if a > 0 { cands.append(sum / a) }
            if let big = it.quads.max(by: { simd_length(simd_cross($0[1] - $0[0], $0[3] - $0[0])) < simd_length(simd_cross($1[1] - $1[0], $1[3] - $1[0])) }) {
                let c = (big[0] + big[1] + big[2] + big[3]) / 4
                for i in 0..<4 { cands.append(c + ((big[i] + big[(i + 1) % 4]) / 2 - c) * 0.6) }
            }
            let w = CGFloat(it.label.count) * 7.6 + 18 + (it.linked ? 14 : 0)
            func rect(_ p: CGPoint) -> CGRect { CGRect(x: p.x - max(44, w) / 2, y: p.y - 22, width: max(44, w), height: 44) }
            func clear(_ p: CGPoint) -> Bool {
                let r = rect(p)
                return r.minX >= 4 && r.minY >= 4 && r.maxX <= viewport.width - 4 && r.maxY <= viewport.height - 4
                    && !keepOut.contains(where: { $0.intersects(r.insetBy(dx: 10, dy: 10)) })
                    && !taken.contains(where: { $0.insetBy(dx: -2, dy: -2).intersects(r) || hypot($0.midX - p.x, $0.midY - p.y) < 24 })
                    && !(under?.intersects(r) ?? false)
            }
            let pts = cands.map(local)
            var order = Array(pts.indices)
            if let keep = ui.attachTagPick[it.id], keep < pts.count { order.removeAll { $0 == keep }; order.insert(keep, at: 0) }
            for i in order {
                guard let p = pts[i], clear(p) else { continue }
                ui.attachTagPick[it.id] = i
                taken.append(rect(p))
                if ui.attachTagFrozen[it.id] == nil { ui.attachTagFrozen[it.id] = p }
                out.append(Tag(id: it.id, key: it.key, label: it.label, point: p, tap: it.tap, linked: it.linked, lit: it.lit))
                break
            }
        }
        return out
    }
}

/// One link under its lattice's face line in Selections (42 pt in): its glyph, "Side 2 → wall" (grey with its reason when
/// stale), and the trash that asks IN PLACE. A tap on the row picks its face (the step card flashes its wall); it never edits.
struct FlexibleLinkRow: View {
    @ObservedObject var main: FlexibleMainStage
    @ObservedObject var project: ProjectModel
    @ObservedObject var ui: FlexibleFaceChipState
    let link: FlexibleLatticeLink
    let state: FlexibleAttach.LinkState
    let group: UUID
    let ref: LatticeSelectableRef
    let cardsChanged: () -> Void

    static let indent: CGFloat = 42

    var body: some View {
        let asking = ui.linkRemoveAsk == link.id
        let stale = state != .live
        let wall = main.wallName(project, lattice: link.lattice, wall: link.wall)
        let id = link.id.uuidString
        HStack(spacing: 6) {
            Image(systemName: "link").font(.system(size: 13, weight: .semibold))
                .foregroundStyle((stale ? DS.Color.textTertiary : DS.Color.accent).color)
                .opacity(asking ? 0 : 1)
            Text(FlexibleAttach.rowText(link, wallName: wall, state: state)).font(.system(size: 13, weight: .medium))
                .foregroundStyle((stale ? DS.Color.textTertiary : DS.Color.textPrimary).color).lineLimit(1).fixedSize()
                .opacity(asking ? 0 : 1)
                .accessibilityIdentifier("flexible-sel-link-text-\(id)")
            Spacer(minLength: 0)
            Button {
                ui.closeTransient()
                ui.linkRemoveAsk = link.id
            } label: {
                Image(systemName: "trash").font(.system(size: 14, weight: .medium)).foregroundStyle(DS.Color.textSecondary.color)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(attachPublish("selLinkTrash-\(id)"))
            .modifier(FlexibleConfirmInPlace(asking: asking, question: FlexibleSelectionsCopy.removeLinkAsk,
                                             destructive: FlexibleSelectionsCopy.removeLink, confirmKey: "linkRemove-\(id)",
                                             keepKey: "linkKeep-\(id)", confirm: {
                ui.linkRemoveAsk = nil
                FlexibleFaceCommits.removeLink(id: link.id, project: project)
                cardsChanged()
            }, cancel: { ui.linkRemoveAsk = nil }))
            .accessibilityLabel(FlexibleSelectionsCopy.removeLinkVoice(wall, FlexibleLatticeWalls.targetName(link.target)))
            .accessibilityIdentifier("flexible-sel-link-trash-\(id)")
        }
        .padding(.leading, Self.indent).padding(.trailing, FlexibleSelectionsList.rowTrailing)
        .frame(height: FlexibleSelectionsList.lineHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            main.pickFace(ref, group: group, project: project)
            main.flashWall(link.wall)
        }
        .background(attachPublish("selLink-\(id)"))
        .accessibilityIdentifier("flexible-sel-link-\(id)")
    }
}

/// ★ I2: the compact card's [🔗] (a 44 pt icon on the title line, its live-link count beside the glyph) — the mini in portrait,
/// where the card with its Attach row has no clear spot. The one-tap suggestion is not shown there (it needs its own row).
struct FlexibleAttachIconButton: View {
    @ObservedObject var main: FlexibleMainStage
    @ObservedObject var project: ProjectModel
    let group: UUID
    let ref: LatticeSelectableRef

    var body: some View {
        if case .button = main.attachRow(project, group: group, ref: ref) {
            let n = main.liveLinks(project, key: ref.key).count
            Button { main.startAttach(project, group: group, ref: ref) } label: {
                HStack(spacing: 2) {
                    Image(systemName: "link").font(.system(size: 14, weight: .bold)).foregroundStyle(DS.Color.accent.color)
                    if n > 0 { Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(DS.Color.textSecondary.color) }
                }
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(attachPublish("chipAttach"))
            .accessibilityLabel(FlexibleSelectionsCopy.attachVoice)
            .accessibilityIdentifier("flexible-chip-attach")
        }
    }
}
