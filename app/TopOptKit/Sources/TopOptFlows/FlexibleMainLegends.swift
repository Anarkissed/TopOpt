// FlexibleMainLegends — one legend per data view on the main Flexible page, and the reading a
// tap pins on the part (task 2026-09-29-flexible-screens, round 3 batch C: items 1.4 and 7;
// maintainer: "each data view has its own legend on the right edge … tapping a legend switches
// it to 'Tap the part to read' … legends never cover buttons").
//
// ★ THE LEGENDS: 'Squish · mm' (the dent's own DS ramp), 'Stress in the solid part · MPa'
// (Stress's rainbow; "Simulating…" while it solves), 'Lattice · density' (the walls' pale →
// green). X-ray has none (his answer). Each is #354's LatticeLegendChrome — the same squircle,
// (i) and caret as the octet key — with ONE line, a ramp, its two ends.
//
// ★ TAP A LEGEND → it reads "TAP THE PART TO READ" (the main page's `latticeLegendMode =
// .colour(kind.id)`, so #354's own gates hold: a face tap is consumed, primitives hide, a
// double tap anywhere comes back out). A tap on the part pins a callout at that spot — value
// and unit — and marks it on the ramp. Tap the legend again (or double tap) to leave.
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

    /// The main page's buttons a legend must not cover.
    public static func keepOut(viewport v: CGSize, bottomClearance: CGFloat, chipColumnWidth: CGFloat,
                               simulating: Bool) -> [CGRect] {
        var k: [CGRect] = [
            FlexibleLegendPlacement.gizmoFrame(viewport: v),
            FlexibleMainViewToggles.frame(viewport: v, simulating: simulating),
            // the forward nav + Settings column, left of the gizmo (top-right)
            CGRect(x: v.width - PageChrome.gizmoClearance - 240, y: 0, width: 240,
                   height: PageChrome.gizmoAlignedTop + 2 * (PageChrome.compactButton + PageChrome.gap)),
            // the bottom bar
            CGRect(x: 0, y: v.height - bottomClearance, width: v.width, height: bottomClearance),
            // the left panel strip (Selections, the stage buttons and the title above it)
            CGRect(x: 0, y: 0, width: PageChrome.edge + PageChrome.panelWidth, height: v.height),
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

    public var body: some View {
        // the view a tap comes through, for the readings (no publish)
        let _ = main.noteView(projection: projection, settle: settle)
        let kinds = main.legendKinds
        ZStack {
            GeometryReader { g in
                let placed = main.legendFrames(viewport: g.size, bottomClearance: bottomClearance, chipColumnWidth: chipColumnWidth)
                ForEach(kinds) { k in
                    if let p = placed[k] {
                        legend(k, p)
                            .frame(width: p.frame.width, height: p.frame.height, alignment: .top)
                            .position(x: p.frame.midX, y: p.frame.midY)
                    }
                }
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
        // out of the key (a double tap, the legend tapped again): the callout goes
        .onChange(of: mode) { m in
            if FlexibleReadKind(mode: m) == nil { main.clearReading() }
        }
        .onDisappear {
            if drilled != nil { mode = .groups }
            main.clearReading()
        }
    }

    // MARK: one legend

    @ViewBuilder private func legend(_ k: FlexibleReadKind, _ p: FlexibleMainLegendLayout.Placed) -> some View {
        if p.expanded {
            LatticeLegendChrome(tab: drilled == k ? "TAP THE PART TO READ" : "TAP TO READ", width: p.frame.width,
                                minimized: Binding(get: { main.minimized.contains(k) },
                                                   set: { if $0 { main.minimized.insert(k) } else { main.minimized.remove(k) } }),
                                info: k == .dent ? main.dentInfo : k.info) {
                content(k)
            }
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .strokeBorder(DS.Color.accent.color, lineWidth: drilled == k ? 1.5 : 0))
            .contentShape(Rectangle())
            .onTapGesture { toggle(k) }
            .latticeBandChipKeepOut()
            .accessibilityIdentifier("flexible-legend-\(k.rawValue)")
        } else {
            Button {
                main.minimized.remove(k)
                main.legendPriority = k
            } label: {
                HStack(spacing: DS.Space.xs) {
                    ramp(k).frame(width: 22, height: 8).clipShape(RoundedRectangle(cornerRadius: 2))
                    Text(k.short).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.Color.accent.color)
                }
                .frame(width: p.frame.width, height: p.frame.height)
                .background(Capsule().fill(DS.Surface.panel.color.opacity(0.94))
                    .overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
            }
            .buttonStyle(.plain)
            .latticeBandChipKeepOut()
            .accessibilityIdentifier("flexible-legend-pill-\(k.rawValue)")
        }
    }

    private func toggle(_ k: FlexibleReadKind) {
        if drilled == k {
            mode = .groups
        } else {
            main.clearReading()
            main.legendPriority = k
            mode = k.mode
        }
    }

    @ViewBuilder private func content(_ k: FlexibleReadKind) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: DS.Space.xs) {
                Text(k.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary.color)
                    .lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                if k == .dent {
                    Text("×\(main.dentExaggeration)")
                        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(DS.Color.textTertiary.color)
                }
            }
            if k == .stress, main.stressField == nil || main.stressPeak <= 0 {
                HStack(spacing: DS.Space.xs) {
                    if main.stressRunning { ProgressView().controlSize(.mini).tint(DS.Color.textPrimary.color) }
                    Text(main.stressRunning ? "Simulating…" : "No stress yet")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.Color.textSecondary.color)
                }
                .frame(height: 29, alignment: .leading)
            } else {
                ramp(k)
                    .frame(height: 10)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(marker(k))
                HStack {
                    Text(ends(k).lo)
                    Spacer(minLength: DS.Space.xs)
                    Text(ends(k).hi)
                }
                .font(.system(size: 11, weight: .medium)).monospacedDigit()
                .foregroundStyle(DS.Color.textSecondary.color)
                .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ramp(_ k: FlexibleReadKind) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { i in
                k.rampColour(Double(i) / 23).color
            }
        }
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
            return ("0", "\(LatticeStressTint.legendTicks(peakMPa: main.stressPeak).first ?? "—") MPa")
        case .lattice:
            guard let g = main.model?.lattice else { return ("", "") }
            let s = FlexibleProbe.latticeSpan(g.inputs)
            func end(_ rho: Double) -> String { String(format: "%.0f%% · %.1f mm", rho * 100, FlexibleProbe.cellMM(rho: rho, g.inputs)) }
            return (end(s.lowerBound), end(s.upperBound))
        }
    }

    // MARK: the callout

    /// ★ RE-PROJECTED EVERY RENDER (the octet's rule: "the arrow follows the position in 3D
    /// space"), in the MTKView's own space (it ignores the safe area).
    @ViewBuilder private var callout: some View {
        if drilled != nil, let r = main.reading, let s = main.screenPoint(r.anchor) {
            HStack(spacing: 5) {
                Image(systemName: "arrowtriangle.left.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Color.accent.color)
                Text(r.text)
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(DS.Color.textPrimary.color)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Capsule().fill(DS.Surface.panel.color.opacity(0.95))
                .overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
            .fixedSize()
            .offset(x: s.x + 8, y: s.y - 15)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityIdentifier("flexible-reading-callout")
        }
    }
}
