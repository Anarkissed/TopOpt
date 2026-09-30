// FlexibleLegendPlacement — where a legend and the squish player go, computed against the
// page's keep-outs (task 2026-09-29-flexible-screens, round 3 batch B, item 7; maintainer:
// "legends never cover buttons").
//
// ★ THE RULE, AS FRAMES (pure, so FlexibleLegendPlacementTests measures it at iPad 13" and
// 11", both orientations):
//   * a LEGEND sits on the trailing edge, vertically centred (like the octet's
//     latticeDensityLegend) — never in a bottom corner, where it covered Generate (img 7);
//     if a keep-out crosses it there, it slides up (then down) until it clears;
//   * the PLAYER sits bottom-centre above the bottom bar, centred in the widest free span of
//     its row (the Settings panel takes the bottom-left), and rises until it clears every
//     keep-out; it narrows (never below `playerMinWidth`) before it gives up a row.
// The Settings page has no bottom-right buttons at all (the Generate pill is gone).

import CoreGraphics

public enum FlexibleLegendPlacement {
    /// The player's preferred size (the Results capsule: 34 pt button, labels, a slider).
    public static let playerSize = CGSize(width: 340, height: 46)
    public static let playerMinWidth: CGFloat = 240
    /// The gap kept around every keep-out.
    public static let gap: CGFloat = PageChrome.gap
    /// The step a blocked frame moves by while it looks for a clear place.
    static let step: CGFloat = 4

    /// A legend of `size`, trailing and vertically centred in `viewport`, `edge` from the
    /// trailing edge; moved (up first) off any keep-out. nil when there is no room at all.
    public static func legend(size: CGSize, viewport: CGSize, edge: CGFloat = PageChrome.edge,
                              keepOut: [CGRect] = []) -> CGRect? {
        let x = viewport.width - edge - size.width
        let centreY = (viewport.height - size.height) / 2
        let blockers = keepOut.map { $0.insetBy(dx: -gap, dy: -gap) }
        func clear(_ y: CGFloat) -> CGRect? {
            let r = CGRect(x: x, y: y, width: size.width, height: size.height)
            guard r.minY >= edge, r.maxY <= viewport.height - edge else { return nil }
            return blockers.contains { $0.intersects(r) } ? nil : r
        }
        if let r = clear(centreY) { return r }
        var d: CGFloat = step
        while d < viewport.height {
            if let r = clear(centreY - d) { return r }
            if let r = clear(centreY + d) { return r }
            d += step
        }
        return nil
    }

    // MARK: the Settings page's top line and the fix pop-up (batch B review)

    /// The top line's height (the readiness pill).
    public static let noticeHeight: CGFloat = 40
    /// Narrower than this, the top line takes its own row under the Exit row.
    public static let noticeMinWidth: CGFloat = 460
    /// The fix pop-up's widest.
    public static let popUpMaxWidth: CGFloat = 460

    /// The gizmo's frame (FlexibleViewColumn: top-right, `gizmoInset` from both edges).
    public static func gizmoFrame(viewport: CGSize) -> CGRect {
        CGRect(x: viewport.width - PageChrome.gizmoInset - PageChrome.gizmoSize, y: PageChrome.gizmoInset,
               width: PageChrome.gizmoSize, height: PageChrome.gizmoSize)
    }

    /// ★ THE TOP LINE NEVER COVERS A BUTTON (batch B review, item 7: at 11" portrait the line,
    /// centred with 180 pt each side, lay over Redo and part of Undo — and swallowed their taps —
    /// and put [Fix] half under the gizmo, which orbits on its whole square). The band right of
    /// the Exit row and left of the gizmo's clearance; narrower than `noticeMinWidth`, its own
    /// row under the Exit row, from the edge to the gizmo's clearance.
    public static func noticeBand(viewport: CGSize, exitRow: CGRect, edge: CGFloat = PageChrome.edge) -> CGRect {
        let right = viewport.width - PageChrome.gizmoClearance
        let left = exitRow.maxX + gap
        if right - left >= noticeMinWidth {
            return CGRect(x: left, y: exitRow.midY - noticeHeight / 2, width: right - left, height: noticeHeight)
        }
        return CGRect(x: edge, y: exitRow.maxY + gap, width: max(0, right - edge), height: noticeHeight)
    }

    /// The fix pop-up's frame (its height is its content's): under the top line (and the
    /// toast line when one shows), centred in the span left of the gizmo's clearance.
    public static func popUp(viewport: CGSize, notice: CGRect, below extra: CGFloat = 0,
                             edge: CGFloat = PageChrome.edge) -> CGRect {
        let right = viewport.width - PageChrome.gizmoClearance
        let w = max(0, min(popUpMaxWidth, right - edge))
        return CGRect(x: edge + (right - edge - w) / 2, y: notice.maxY + gap + extra, width: w, height: 0)
    }

    /// The player: bottom-centre, `bottomClearance` above the bottom edge (the bottom bar and
    /// its inset), in the widest free span of its row. nil when nothing fits.
    public static func player(viewport: CGSize, bottomClearance: CGFloat, edge: CGFloat = PageChrome.edge,
                              keepOut: [CGRect] = [], size: CGSize = playerSize) -> CGRect? {
        let blockers = keepOut.map { $0.insetBy(dx: -gap, dy: -gap) }
        var y = viewport.height - bottomClearance - gap - size.height
        while y >= edge {
            let row = CGRect(x: 0, y: y, width: viewport.width, height: size.height)
            // the free spans of this row between the side edges
            var spans: [(CGFloat, CGFloat)] = [(edge, viewport.width - edge)]
            for b in blockers where b.intersects(row) {
                spans = spans.flatMap { s -> [(CGFloat, CGFloat)] in
                    if b.maxX <= s.0 || b.minX >= s.1 { return [s] }
                    var out: [(CGFloat, CGFloat)] = []
                    if b.minX > s.0 { out.append((s.0, b.minX)) }
                    if b.maxX < s.1 { out.append((b.maxX, s.1)) }
                    return out
                }
            }
            if let best = spans.max(by: { ($0.1 - $0.0) < ($1.1 - $1.0) }), best.1 - best.0 >= playerMinWidth {
                let w = min(size.width, best.1 - best.0)
                // centred on the page when the span allows it, else in the span
                var x = (viewport.width - w) / 2
                if x < best.0 || x + w > best.1 { x = (best.0 + best.1 - w) / 2 }
                return CGRect(x: x, y: y, width: w, height: size.height)
            }
            y -= step
        }
        return nil
    }
}
