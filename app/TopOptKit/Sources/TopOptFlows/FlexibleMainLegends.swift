// FlexibleMainLegends — one legend per data view on the main Flexible page, and the reading a
// tap pins on the part (task 2026-09-29-flexible-screens, round 3 batch C: items 1.4 and 7;
// maintainer: "each data view has its own legend on the right edge … tapping a legend switches
// it to 'Tap the part to read' … legends never cover buttons").
//
// ★ THE LEGENDS: 'Squish · mm' (the dent's own DS ramp; "What you drew · mm" while the map is
// his drawing — batch C verification), 'Stress in the solid part · MPa' (Stress's rainbow;
// "Simulating…" while it solves, "Couldn't simulate" + Retry, or what to add first),
// 'Lattice · density' (the walls' pale → green). X-ray has none (his answer). Each is #354's
// LatticeLegendChrome — the same squircle, (i) and caret as the octet key — with ONE line, a
// ramp, its two ends.
//
// ★ TAP A LEGEND → it reads "TAP THE PART TO READ" (the main page's `latticeLegendMode =
// .colour(kind.id)`, so #354's own gates hold: a face tap is consumed, primitives hide, a
// double tap anywhere comes back out). A tap on the part pins the value — in the accent blue,
// in its own squircle (#354's LatticeLegendReading) — at that spot, and marks it on the ramp;
// the squish holds still while a legend reads. Tap the legend again (or double tap) to leave.
// The tap never moves the legends.
//
// ★ WHERE THEY GO (FlexibleMainLegendLayout, pure — FlexibleMainViewsTests measures it at
// iPad 13" and 11", both orientations): the trailing edge, from the vertical centre out,
// clear of the gizmo, the view toggles, the Settings / nav column, the bottom bar and the
// bottom-right chip column; a second column to their left when the edge is full; a legend that
// still finds no room is a small pill (tap it: it is placed first). The squish player is placed
// AFTER them and keeps clear of them (FlexibleMainPlayerSlot).

import SwiftUI
import simd
import TopOptDesign

public enum FlexibleMainLegendLayout {
    public static let width: CGFloat = 248
    public static let height: CGFloat = 124
    public static let pill = CGSize(width: 124, height: 34)
    /// Columns an open legend may take (the trailing edge, then one to its left).
    static let columns = 2
    static let pillColumns = 3
    static let step: CGFloat = 4

    public struct Placed: Equatable, Sendable {
        public let frame: CGRect
        public let expanded: Bool
    }

    /// The left panel strip (Selections, the stage buttons and the title above it).
    public static func leftStrip(viewport v: CGSize) -> CGRect {
        CGRect(x: 0, y: 0, width: PageChrome.edge + PageChrome.panelWidth, height: v.height)
    }

    /// The main page's buttons a legend must not cover.
    public static func keepOut(viewport v: CGSize, bottomClearance: CGFloat, chipColumnWidth: CGFloat) -> [CGRect] {
        var k: [CGRect] = [
            FlexibleLegendPlacement.gizmoFrame(viewport: v),
            FlexibleMainViewToggles.frame(viewport: v),
            // the forward nav + Settings column, left of the gizmo (top-right)
            CGRect(x: v.width - PageChrome.gizmoClearance - 240, y: 0, width: 240,
                   height: PageChrome.gizmoAlignedTop + 2 * (PageChrome.compactButton + PageChrome.gap)),
            // the bottom bar
            CGRect(x: 0, y: v.height - bottomClearance, width: v.width, height: bottomClearance),
            leftStrip(viewport: v),
        ]
        if chipColumnWidth > 0 {
            let h = FlexibleMainPlayerSlot.chipColumnHeight
            k.append(CGRect(x: v.width - PageChrome.edge - chipColumnWidth, y: v.height - bottomClearance - DS.Space.m - h,
                            width: chipColumnWidth, height: h))
        }
        return k
    }

    /// Each kind's frame: open where a column has room (from the vertical centre out), else a
    /// pill. `priority` is placed first (the drilled-in legend, or a pill he tapped open).
    /// ★ BATCH M (M4): the ONE card's size — every active scale stacked in one squircle (the octet's
    /// single key): the header, then one ~50 pt row per scale; folded, a column of bars.
    public static let rowHeight: CGFloat = 62
    /// ★ BATCH M VERIFICATION (the octet's minimised key, which he tuned: "attach the legend modal to the
    /// very far right side of the screen", "a bit of a gap between the different levels to be able to see
    /// the arrows separately"): folded, the bars are the octet's 18 × 150 pt, 30 pt apart, the card on
    /// the screen's very edge (`foldedEdge`) with the reading's arrow on its bar.
    public static let foldedBar = CGSize(width: 18, height: 150)
    public static let foldedSpacing: CGFloat = 30
    public static let foldedEdge: CGFloat = 0
    /// ★ S1b (round 6 item 3): a view's one-line row in the card (the Prisms row): the card's 12 pt row spacing and
    /// one 12 pt line, with room to spare.
    public static let viewRowHeight: CGFloat = 30
    /// The card with no scale, only view rows: the header (#354's chrome, 41 pt) and its content padding.
    public static let viewOnlyHeight: CGFloat = 66
    public static func cardSize(rows: Int, minimized: Bool, viewRows: Int = 0) -> CGSize {
        let n = CGFloat(Swift.max(1, rows))
        if minimized {
            // n bars, a 30 pt gap after each (the last before the chevron), the chevron, DS.Space.s padding
            return CGSize(width: n * (foldedBar.width + foldedSpacing) + 12 + 2 * DS.Space.s,
                          height: foldedBar.height + 2 * DS.Space.s)
        }
        // ★ S1b: [Prisms] adds its one line; with no scale the card is the header and that line
        let views = CGFloat(Swift.max(0, viewRows)) * viewRowHeight
        if rows <= 0, viewRows > 0 { return CGSize(width: width, height: viewOnlyHeight + views - DS.Space.m) }
        return CGSize(width: width, height: height + (n - 1) * rowHeight + views)
    }

    /// ★ BATCH M (M4): where the ONE card goes — the trailing edge from the vertical centre out, clear
    /// of every button (the same search as one legend), then a second column; nil when nothing fits.
    public static func placeCard(rows: Int, minimized: Bool, viewport v: CGSize, keepOut: [CGRect],
                                 edge: CGFloat = PageChrome.edge, viewRows: Int = 0) -> Placed? {
        let size = cardSize(rows: rows, minimized: minimized, viewRows: viewRows)
        let gap = FlexibleLegendPlacement.gap
        let blockers = keepOut.map { $0.insetBy(dx: -gap, dy: -gap) }
        for c in 0..<columns {
            let x = v.width - edge - size.width - CGFloat(c) * (width + gap)
            let centre = (v.height - size.height) / 2
            var d: CGFloat = 0
            while d < v.height {
                for y in d == 0 ? [centre] : [centre - d, centre + d] {
                    let r = CGRect(x: x, y: y, width: size.width, height: size.height)
                    if r.minX >= edge, r.minY >= edge, r.maxY <= v.height - edge, !blockers.contains(where: { $0.intersects(r) }) {
                        return Placed(frame: r, expanded: !minimized)
                    }
                }
                d += step
            }
        }
        return nil
    }

    public static func place(_ kinds: [FlexibleReadKind], minimized: Set<FlexibleReadKind>, viewport v: CGSize,
                             keepOut: [CGRect], priority: FlexibleReadKind? = nil,
                             edge: CGFloat = PageChrome.edge) -> [FlexibleReadKind: Placed] {
        let gap = FlexibleLegendPlacement.gap
        let blockers = keepOut.map { $0.insetBy(dx: -gap, dy: -gap) }
        var taken: [CGRect] = []
        var out: [FlexibleReadKind: Placed] = [:]
        func clear(_ r: CGRect) -> Bool {
            guard r.minX >= edge, r.minY >= edge, r.maxY <= v.height - edge else { return false }
            if blockers.contains(where: { $0.intersects(r) }) { return false }
            return !taken.contains { $0.insetBy(dx: -gap, dy: -gap).intersects(r) }
        }
        func spot(_ size: CGSize, column i: Int) -> CGRect? {
            let x = v.width - edge - size.width - CGFloat(i) * (width + gap)
            let centre = (v.height - size.height) / 2
            var d: CGFloat = 0
            while d < v.height {
                for y in d == 0 ? [centre] : [centre - d, centre + d] {
                    let r = CGRect(x: x, y: y, width: size.width, height: size.height)
                    if clear(r) { return r }
                }
                d += step
            }
            return nil
        }
        var order = kinds
        if let p = priority, let i = order.firstIndex(of: p) { order.remove(at: i); order.insert(p, at: 0) }
        // ★ ONE STACK ON THE EDGE FIRST: every open legend as one block in the trailing column
        // (placed one by one from the middle, the first took the middle and left no room for
        // the third on 11" landscape); only if the block does not fit, one at a time
        let open = kinds.filter { !minimized.contains($0) }
        if open.count > 1,
           let block = spot(CGSize(width: width, height: CGFloat(open.count) * height + CGFloat(open.count - 1) * gap), column: 0) {
            for (i, k) in open.enumerated() {
                let r = CGRect(x: block.minX, y: block.minY + CGFloat(i) * (height + gap), width: width, height: height)
                out[k] = Placed(frame: r, expanded: true)
                taken.append(r)
            }
            order = order.filter { minimized.contains($0) }
        }
        for k in order {
            var placed: Placed?
            if !minimized.contains(k) {
                for c in 0..<columns { if let r = spot(CGSize(width: width, height: height), column: c) { placed = Placed(frame: r, expanded: true); break } }
            }
            if placed == nil {
                for c in 0..<pillColumns { if let r = spot(pill, column: c) { placed = Placed(frame: r, expanded: false); break } }
            }
            if let p = placed { out[k] = p; taken.append(p.frame) }
        }
        return out
    }
}

/// H6: the legends and the reading's callout, on the main Flexible page (inside the chrome
/// that hides under a full-screen page).
public struct FlexibleMainLegends: View {
    @ObservedObject var main: FlexibleMainStage
    @Binding var mode: LatticeLegendMode
    let projection: CameraProjection?
    let settle: simd_quatf
    let bottomClearance: CGFloat
    let chipColumnWidth: CGFloat

    public init(main: FlexibleMainStage, mode: Binding<LatticeLegendMode>, projection: CameraProjection?,
                settle: simd_quatf, bottomClearance: CGFloat, chipColumnWidth: CGFloat) {
        self.main = main
        self._mode = mode
        self.projection = projection
        self.settle = settle
        self.bottomClearance = bottomClearance
        self.chipColumnWidth = chipColumnWidth
    }

    private var drilled: FlexibleReadKind? { FlexibleReadKind(mode: mode) }
    /// ★ S1b: the card's header with no scale to read (only [Prisms]' row) — nothing to tap.
    static let prismsOnlyTab = "SQUISH PRISMS"

    public var body: some View {
        // the view a tap comes through, for the readings (no publish)
        let _ = main.noteView(projection: projection, settle: settle)
        let kinds = main.legendKinds
        ZStack {
            GeometryReader { g in
                // ★ BATCH M (M4, his img 4: "The legends should combine into a singular modal. Please
                // review the other lattice sections to understand"): ONE card, like the octet's key
                // ★ S1b: …and [Prisms]' row in it (the card comes for that row even with no scale)
                if let p = main.legendCard(viewport: g.size, bottomClearance: bottomClearance, chipColumnWidth: chipColumnWidth) {
                    card(kinds, p)
                        .frame(width: p.frame.width, height: p.frame.height, alignment: .top)
                        .position(x: p.frame.midX, y: p.frame.midY)
                }
            }
            // ★ S1b (round 6 item 3): the shown prisms' read-only mm tags, at their floors, clear of the card, the
            // buttons and the player
            if let m = main.model {
                FlexibleMainPrismTagsLayer(main: main, model: m, project: m.project, view: main.viewFrame,
                                           drilledIn: mode.drilledIn, bottomClearance: bottomClearance, chipColumnWidth: chipColumnWidth)
            }
            callout
        }
        // a legend that went away (its view turned off) cannot stay drilled in
        .onChange(of: kinds) { now in
            if let k = drilled, !now.contains(k) { mode = .groups }
        }
        // a reading that switched kind ("switching colours if needed"): the key follows
        .onChange(of: main.reading) { r in
            if let r, let k = drilled, k != r.kind { mode = r.kind.mode }
        }
        // out of the key (a double tap, the legend tapped again): the callout goes; while a
        // legend reads, the squish holds still (the reading stays on the surface it was read on)
        .onChange(of: mode) { m in
            let reading = FlexibleReadKind(mode: m) != nil
            if !reading { main.clearReading() }
            main.noteDrill(reading)
        }
        .onDisappear {
            if drilled != nil { mode = .groups }
            main.clearReading()
            main.noteDrill(false)
        }
    }

    // MARK: ★ BATCH M (M4): the ONE card

    /// Every active scale in one squircle (#354's LatticeLegendChrome, the octet key's): the dent OR
    /// Stress row, then the walls' density; tap it → "TAP THE PART TO READ" (a tap on the part reads
    /// whichever is under the finger); the caret folds it to a column of bars (tap to open).
    @ViewBuilder private func card(_ kinds: [FlexibleReadKind], _ p: FlexibleMainLegendLayout.Placed) -> some View {
        if p.expanded {
            LatticeLegendChrome(tab: kinds.isEmpty ? Self.prismsOnlyTab : drilled != nil ? "TAP THE PART TO READ" : "TAP TO READ",
                                width: p.frame.width, minimized: $main.legendMinimized, info: main.cardInfo) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(kinds) { k in content(k) }
                    // ★ S1b (round 6 item 3): [Prisms]' one line — the Settings page's own row, at this page's k
                    if main.legendPrismsRow { FlexibleLegendViewRows.prisms(k: main.prismLegendK) }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .strokeBorder(DS.Color.accent.color, lineWidth: drilled != nil ? 1.5 : 0))
            .contentShape(Rectangle())
            .onTapGesture { mode = main.cardTapped(mode: mode) }
            .latticeBandChipKeepOut()
            .accessibilityIdentifier("flexible-legend-card")
        } else {
            Button { main.legendMinimized = false } label: {
                // ★ BATCH M VERIFICATION: the octet's minimised key — 18 × 150 pt bars, 30 pt apart, each
                // with its reading's arrow (LatticeLegendPanel.minimizedColumn)
                HStack(alignment: .center, spacing: FlexibleMainLegendLayout.foldedSpacing) {
                    ForEach(kinds) { k in
                        ramp(k, vertical: true)
                        .frame(width: FlexibleMainLegendLayout.foldedBar.width, height: FlexibleMainLegendLayout.foldedBar.height)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1))
                        .overlay(alignment: .top) { foldedArrow(k) }
                    }
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(DS.Color.accent.color)
                }
                .frame(width: p.frame.width, height: p.frame.height)
                .background(RoundedRectangle(cornerRadius: DS.Radius.panelSmall, style: .continuous)
                    .fill(DS.Surface.panel.color.opacity(0.94))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.panelSmall, style: .continuous)
                        .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
            }
            .buttonStyle(.plain)
            .latticeBandChipKeepOut()
            .accessibilityIdentifier("flexible-legend-card-folded")
        }
    }

    // MARK: one row of the card

    /// ★ BATCH M VERIFICATION: one row per scale, observing the squish loop too — under "Play all" the
    /// Stress row names the turn playing and shows ITS scale, and the dent's "×k" its field's fold cut,
    /// as the renderer swaps the turn in (the loop's `playingSimID`; a turn, never a frame).
    @ViewBuilder private func content(_ k: FlexibleReadKind) -> some View {
        FlexibleMainLegendRow(main: main, loop: main.loop, kind: k, drilled: drilled)
    }

    /// The reading's mark on a FOLDED bar (bottom → top), like the octet's minimised key.
    @ViewBuilder private func foldedArrow(_ k: FlexibleReadKind) -> some View {
        if let r = main.reading, r.kind == k, let f = r.fraction {
            let h = FlexibleMainLegendLayout.foldedBar.height, w = FlexibleMainLegendLayout.foldedBar.width
            HStack(spacing: 0) {
                Rectangle().fill(DS.Color.accent.color).frame(width: w, height: 2)
                Image(systemName: "arrowtriangle.left.fill").font(.system(size: 11)).foregroundStyle(DS.Color.accent.color)
            }
            .frame(width: w + 12, height: 12, alignment: .leading)
            .offset(x: 6, y: CGFloat(1 - min(1, max(0, f))) * h - 6)
            .allowsHitTesting(false)
        }
    }

    /// ★ BATCH M (M5): a SMOOTH bar (the ramp's own stops blended — 24 flat blocks read as bands
    /// beside a heat that no longer has any).
    private func ramp(_ k: FlexibleReadKind, vertical: Bool = false) -> some View {
        FlexibleMainLegendRow.ramp(k, vertical: vertical)
    }

    // MARK: the callout

    /// ★ RE-PROJECTED EVERY RENDER (the octet's rule: "the arrow follows the position in 3D
    /// space"), in the MTKView's own space (it ignores the safe area).
    @ViewBuilder private var callout: some View {
        if drilled != nil, let r = main.reading, let s = main.screenPoint(r.anchor) {
            FlexibleReadingTag(reading: r)
                .offset(x: s.x + 2, y: s.y - FlexibleReadingTag.halfHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityIdentifier("flexible-reading-callout")
        }
    }
}

/// ★ BATCH M VERIFICATION: one row of the ONE card — its title (and the dent's "×k"), its ramp and ends,
/// or Stress's one line while it cannot draw. It observes the squish LOOP as well as the stage: under
/// "Play all" the renderer swaps a turn in (`playingSimID`), and the Stress row then names THAT group
/// and shows its own scale, the dent's "×k" its own fold cut.
struct FlexibleMainLegendRow: View {
    @ObservedObject var main: FlexibleMainStage
    @ObservedObject var loop: FlexibleSquishLoop
    let kind: FlexibleReadKind
    let drilled: FlexibleReadKind?

    var body: some View {
        let k = kind
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: DS.Space.xs) {
                Text(main.legendTitle(k))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary.color)
                    .lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                if k == .dent {
                    Text(main.dentFactorLabel)
                        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(DS.Color.textTertiary.color)
                }
            }
            if k == .stress, !main.stressDrawable {
                // ★ BATCH C VERIFICATION: the solve SAYS what it is doing — "Simulating…" (the
                // one place the wait is said), "Couldn't simulate" + Retry (core's words behind
                // the (i)), or what to add first ("Stress needs an anchor on Topology")
                let state = main.stressView   // ★ BATCH M (M3): the group's sim on the FE route
                HStack(spacing: DS.Space.xs) {
                    if state.isRunning { ProgressView().controlSize(.mini).tint(DS.Color.textPrimary.color) }
                    if case .failed = state {
                        Image(systemName: "exclamationmark.circle.fill").font(.system(size: 12, weight: .bold))
                            .foregroundStyle(DS.Color.warning.color)
                    }
                    Text(main.stressLine ?? FlexibleStressState.idle.line ?? "")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.Color.textSecondary.color)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .accessibilityIdentifier("flexible-stress-state")
                    Spacer(minLength: 0)
                    if state.retries {
                        Button("Retry") { main.retryStress() }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DS.Color.accent.color)
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("flexible-stress-retry")
                    }
                }
                .frame(height: 29, alignment: .leading)
            } else {
                let e = ends(k)
                Self.ramp(k)
                    .frame(height: 10)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(marker(k))
                HStack {
                    Text(e.lo)
                    Spacer(minLength: DS.Space.xs)
                    Text(e.hi)
                }
                .font(.system(size: 11, weight: .medium)).monospacedDigit()
                .foregroundStyle(DS.Color.textSecondary.color)
                .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// ★ BATCH M (M5): a SMOOTH bar (the ramp's own stops blended — 24 flat blocks read as bands
    /// beside a heat that no longer has any).
    static func ramp(_ k: FlexibleReadKind, vertical: Bool = false) -> some View {
        LinearGradient(colors: (0...16).map { k.rampColour(Double($0) / 16).color },
                       startPoint: vertical ? .bottom : .leading, endPoint: vertical ? .top : .trailing)
    }

    /// The pinned reading's place on the ramp.
    @ViewBuilder private func marker(_ k: FlexibleReadKind) -> some View {
        if let r = main.reading, r.kind == k, drilled == k, let f = r.fraction {
            GeometryReader { g in
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(DS.Color.accent.color)
                    .position(x: CGFloat(min(1, max(0, f))) * g.size.width, y: g.size.height + 6)
            }
            .allowsHitTesting(false)
        }
    }

    private func ends(_ k: FlexibleReadKind) -> (lo: String, hi: String) {
        switch k {
        case .dent:
            return ("0 mm", String(format: "%.1f mm", main.dentMaxMM))
        case .stress:
            return main.stressEnds
        case .lattice:
            // once per lattice generation (a full scan of the mask), never per body pass
            guard let e = main.latticeEnds() else { return ("", "") }
            return (e.lo, e.hi)
        }
    }
}

/// ★ S1b (round 6 item 3 — his img3: "When a face … is highlighted, we should automatically be able to see the amount of
/// squish it has been set to"): the main page's READ-ONLY mm tags (FlexibleMainStage.prismTags) — one per prism H15
/// draws, at its floor, in the Settings page's tag style; never a tap (the mm is set in Settings). It observes the
/// project (the active Selections group) and the model (the views), and is handed the camera (`view`), so a group
/// picked, [Prisms] or a turn of the part re-places the tags at once. In the MTKView's own space (as the callout).
struct FlexibleMainPrismTagsLayer: View {
    @ObservedObject var main: FlexibleMainStage
    @ObservedObject var model: FlexibleStageModel
    @ObservedObject var project: ProjectModel
    let view: LatticeBandChipFrame?
    let drilledIn: Bool
    let bottomClearance: CGFloat
    let chipColumnWidth: CGFloat

    var body: some View {
        let tags = Self.tags(main: main, project: project, view: view, drilledIn: drilledIn,
                             bottomClearance: bottomClearance, chipColumnWidth: chipColumnWidth)
        ZStack(alignment: .topLeading) {
            ForEach(tags, id: \.region) { t in
                Text(t.text).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(DS.Color.textPrimary.color)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(DS.Surface.panel.color.opacity(0.85))
                        .overlay(Capsule().strokeBorder(FlexibleStageStyle.facePrismKnob.color, lineWidth: 1)))
                    .fixedSize()
                    .position(t.point)
                    .accessibilityLabel("Squish \(t.text)")
                    .accessibilityIdentifier("flexible-main-prism-tag-\(t.region)")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .preference(key: FlexibleViewMarksKey.self,
                    value: Dictionary(tags.map { ("tag-\($0.region)", FlexibleStageViewTags.frame($0)) }) { a, _ in a })
    }

    /// The tags on screen: H15's prisms', clear of every button, the legend card and the player.
    static func tags(main: FlexibleMainStage, project: ProjectModel, view: LatticeBandChipFrame?, drilledIn: Bool,
                     bottomClearance: CGFloat, chipColumnWidth: CGFloat) -> [FlexibleStageViewTags.Tag] {
        guard let view else { return [] }
        let v = view.viewportSize
        var keep = FlexibleMainLegendLayout.keepOut(viewport: v, bottomClearance: bottomClearance, chipColumnWidth: chipColumnWidth)
        if let card = main.legendCard(viewport: v, bottomClearance: bottomClearance, chipColumnWidth: chipColumnWidth) { keep.append(card.frame) }
        if let player = FlexibleMainPlayerSlot.frame(main: main, viewport: v, bottomClearance: bottomClearance,
                                                     chipColumnWidth: chipColumnWidth) { keep.append(player) }
        return main.prismTags(project, on: .lattice, drilledIn: drilledIn, viewport: v, keepOut: keep, projector: { view.project($0) })
    }
}

/// ★ A TAPPED VALUE, IN THE ACCENT BLUE, IN ITS OWN SQUIRCLE (#354's standing rule on
/// LatticeLegendReading: "same with every single tapped value" — batch C verification: the
/// Flexible readings were white text in a capsule). The arrow's tip sits on the tapped point;
/// the value is #354's own LatticeLegendReading. Both Flexible pages pin it at the tap.
struct FlexibleReadingTag: View {
    let reading: FlexibleReading
    /// Half the squircle's height (value + unit): the arrow, centred on it, sits on the point.
    static let halfHeight: CGFloat = 30

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrowtriangle.left.fill")
                .font(.system(size: 11))
                .foregroundStyle(DS.Color.accent.color)
            LatticeLegendReading(value: reading.value, unit: reading.unit)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Surface.panel.color.opacity(0.94)))
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(reading.text)
    }
}
