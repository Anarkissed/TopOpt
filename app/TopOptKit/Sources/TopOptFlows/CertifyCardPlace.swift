// CertifyCardPlace — ★ his notes 11-23 (notes25 B1, his Img 2): the certify wizard's pop-up ("LATTICE SETTINGS · 3 struts are
// still short …") sat right under the Structural | Setup | Lattice menu, touching it. His words: "It should never be even close
// to other assets. Place it at the very left side in the middle. Please also make it drag-able, so the user can place it
// anywhere on screen as long as it's not underneath/on top of any other asset on screen. It should also keep the arrow attached
// to the pop-up so no matter where you drag it, it is still attached and pointing to the right direction."
//
// So: at rest the card sits at the left edge, in the middle, a clear gap (`CertifyCardLayout.gap`) from every control the page
// publishes (ChromeKeepOutKey: the top-left block, the stage menu riding over Results, the view cube and its buttons, the view
// buttons, Bend/Break's panel, the stress key, Checks, the results list, Details, the corner's buttons, the print line). A
// finger drags it anywhere on the screen; let go over a control, it glides to the nearest spot clear of them all. The line
// leaves the card's nearest edge wherever it is (live while dragging, and gliding with it: OrganicCertifyLeaderShape). The spot
// he chose is remembered for the session (the Results screen comes and goes; the app's other dragged chips keep theirs for the
// session too: FaceChipState), and every control that opens or folds re-settles the card clear of it.
import SwiftUI
import TopOptDesign

/// The card's place, pure (CertifyCardPlaceTests).
public enum CertifyCardLayout {
    /// The clear gap kept from every control at rest (DS: the page's edge margin).
    public static let gap: CGFloat = DS.Space.xl4
    /// The gap kept from the screen's sides.
    public static let edge: CGFloat = PageChrome.edge

    /// His place: the very left side, in the middle.
    public static func home(size s: CGSize, viewport v: CGSize) -> CGPoint {
        clamped(CGPoint(x: edge, y: ((v.height - s.height) / 2).rounded()), size: s, viewport: v)
    }

    /// The card's top-left kept on the screen, `edge` in from each side.
    public static func clamped(_ o: CGPoint, size s: CGSize, viewport v: CGSize) -> CGPoint {
        let maxX = Swift.max(edge, v.width - edge - s.width), maxY = Swift.max(edge, v.height - edge - s.height)
        return CGPoint(x: Swift.min(Swift.max(o.x, edge), maxX), y: Swift.min(Swift.max(o.y, edge), maxY))
    }

    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX < b.maxX - 0.5 && b.minX < a.maxX - 0.5 && a.minY < b.maxY - 0.5 && b.minY < a.maxY - 0.5
    }

    /// Whether the card at `r` keeps the gap from every control.
    public static func isClear(_ r: CGRect, of assets: [CGRect]) -> Bool {
        !assets.contains { overlaps(r, $0.insetBy(dx: -gap, dy: -gap)) }
    }

    /// The nearest spot to `want` (a top-left) where the card keeps the gap from every control and the edge from the screen's
    /// sides. The nearest clear point lies on an edge of a control's gap box (or is `want` itself), so its x is `want`'s or a
    /// box's side and its y likewise: those candidates are all it tries. Nothing clear anywhere: `want`, on the screen.
    public static func settle(_ want: CGPoint, size s: CGSize, viewport v: CGSize, assets: [CGRect]) -> CGPoint {
        let p = clamped(want, size: s, viewport: v)
        func rect(_ o: CGPoint) -> CGRect { CGRect(origin: o, size: s) }
        if isClear(rect(p), of: assets) { return p }
        let loX = edge, hiX = Swift.max(edge, v.width - edge - s.width), loY = edge, hiY = Swift.max(edge, v.height - edge - s.height)
        var xs: [CGFloat] = [p.x, loX, hiX], ys: [CGFloat] = [p.y, loY, hiY]
        for a in assets {
            xs += [a.maxX + gap, a.minX - gap - s.width]
            ys += [a.maxY + gap, a.minY - gap - s.height]
        }
        xs = xs.filter { $0 >= loX - 0.01 && $0 <= hiX + 0.01 }
        ys = ys.filter { $0 >= loY - 0.01 && $0 <= hiY + 0.01 }
        var best: CGPoint?, bestD = CGFloat.infinity
        for x in xs {
            for y in ys {
                let d = hypot(x - p.x, y - p.y)
                guard d < bestD, isClear(rect(CGPoint(x: x, y: y)), of: assets) else { continue }
                best = CGPoint(x: x, y: y); bestD = d
            }
        }
        return best ?? p
    }

    /// The published frames the card keeps clear of: every control on the page, less the card's own frames, the rings on the
    /// part (they mark the part, they are not controls), the notification lane and the number pad (they keep clear of the card),
    /// nothing drawn (no size) and nothing page-sized (a backdrop, not a control).
    public static func assets(_ all: [String: CGRect], viewport v: CGSize) -> [CGRect] {
        let screen = CGRect(origin: .zero, size: v)
        let page = v.width * v.height
        return all.compactMap { k, r -> CGRect? in
            guard !ignored(k), r.width >= 1, r.height >= 1, page <= 0 || r.width * r.height < 0.5 * page,
                  page <= 0 || r.intersects(screen) else { return nil }
            return r.integral
        }
        .sorted { ($0.minY, $0.minX, $0.width, $0.height) < ($1.minY, $1.minX, $1.width, $1.height) }
    }
    static func ignored(_ k: String) -> Bool {
        k.hasPrefix("certify") || k.hasPrefix("resultsCheckMarker") || k.hasPrefix("lane-") || k.hasPrefix("numberPad")
            || k == "holdRing"
    }
    /// From the workspace's frames: only what rides over Results from outside it (the stage menu).
    static let pageKeys: Set<String> = ["capsule", "capsuleMenu"]
}

/// ★ The card's live place: his spot for the session, the drag, and the controls it keeps clear of. Its OWN object (the drag
/// re-draws the card's layer only, never the Results screen's body).
@MainActor
public final class CertifyCardPlace: ObservableObject {
    public static let shared = CertifyCardPlace()

    /// His spot for the session: the card's top-left as a share of the room it moves in (0…1 each way); nil: home.
    @Published public private(set) var chosen: CGPoint?
    /// Where it rests now (top-left, global): his spot (or home), settled clear of every control.
    @Published public private(set) var rest: CGPoint = .zero
    /// While a finger drags it: the rest it started from, and the finger's travel.
    @Published public private(set) var dragFrom: CGPoint?
    @Published public private(set) var drag: CGSize = .zero
    @Published public private(set) var viewport: CGSize = .zero
    @Published public private(set) var size: CGSize = .zero
    private var resultsAssets: [CGRect] = []
    private var pageAssets: [CGRect] = []

    public var assets: [CGRect] { resultsAssets + pageAssets }

    /// The card's frame as drawn now (global): dragged, else at rest.
    public var frame: CGRect {
        let o = dragFrom.map { f in
            CertifyCardLayout.clamped(CGPoint(x: f.x + drag.width, y: f.y + drag.height), size: size, viewport: viewport)
        } ?? rest
        return CGRect(origin: o, size: size)
    }

    /// The spot he asked for (or home), before it is settled clear of the controls.
    var wanted: CGPoint {
        guard let c = chosen else { return CertifyCardLayout.home(size: size, viewport: viewport) }
        let e = CertifyCardLayout.edge
        let roomX = Swift.max(0, viewport.width - 2 * e - size.width), roomY = Swift.max(0, viewport.height - 2 * e - size.height)
        return CGPoint(x: e + c.x * roomX, y: e + c.y * roomY)
    }

    // MARK: what the page tells it
    //
    // Each arrives from a preference callback, inside the page's update: what it changes is applied on the next turn of the
    // main loop (a change published inside the update was dropped on the workspace — the card stayed where it first drew; the
    // house rule, ChromeGeometry.noteSelections).

    func noteResults(_ all: [String: CGRect]) { DispatchQueue.main.async { [weak self] in self?.applyResults(all) } }
    func notePage(_ all: [String: CGRect]) {
        let mine = all.filter { CertifyCardLayout.pageKeys.contains($0.key) }
        DispatchQueue.main.async { [weak self] in self?.applyPage(mine) }
    }
    func noteViewport(_ v: CGSize) { DispatchQueue.main.async { [weak self] in self?.applyViewport(v) } }
    func noteSize(_ s: CGSize) { DispatchQueue.main.async { [weak self] in self?.applySize(s) } }

    func applyResults(_ all: [String: CGRect]) {
        rawResults = all
        let a = CertifyCardLayout.assets(all, viewport: viewport)
        guard a != resultsAssets else { return }
        resultsAssets = a
        resettle()
    }
    func applyPage(_ mine: [String: CGRect]) {
        rawPage = mine
        let a = CertifyCardLayout.assets(mine, viewport: viewport)
        guard a != pageAssets else { return }
        pageAssets = a
        resettle()
    }
    func applyViewport(_ v: CGSize) {
        guard v != viewport, v.width > 0, v.height > 0 else { return }
        viewport = v
        resultsAssets = CertifyCardLayout.assets(rawResults, viewport: v)
        pageAssets = CertifyCardLayout.assets(rawPage, viewport: v)
        resettle(animated: false)
    }
    private(set) var rawResults: [String: CGRect] = [:]
    private(set) var rawPage: [String: CGRect] = [:]
    func applySize(_ s: CGSize) {
        guard s.width > 0, s.height > 0, abs(s.width - size.width) > 0.5 || abs(s.height - size.height) > 0.5 else { return }
        let first = size == .zero
        size = s
        resettle(animated: !first)
    }

    /// A control opened, folded or moved: the card settles clear of it again (gliding), from his spot.
    private func resettle(animated: Bool = true) {
        guard viewport.width > 0, size.width > 0, dragFrom == nil else { return }
        let r = CertifyCardLayout.settle(wanted, size: size, viewport: viewport, assets: assets)
        guard abs(r.x - rest.x) > 0.5 || abs(r.y - rest.y) > 0.5 else { return }
        if animated, rest != .zero { withAnimation(DS.Motion.sheetIn) { rest = r } } else { rest = r }
    }

    // MARK: his finger

    public func dragChanged(_ t: CGSize) {
        if dragFrom == nil { dragFrom = rest }
        drag = t
    }

    /// Let go: the card stays where it is when that is clear, else glides to the nearest clear spot; that spot is his for the
    /// session.
    public func dragEnded(_ t: CGSize) {
        let from = dragFrom ?? rest
        let dropped = CertifyCardLayout.clamped(CGPoint(x: from.x + t.width, y: from.y + t.height), size: size, viewport: viewport)
        let settled = CertifyCardLayout.settle(dropped, size: size, viewport: viewport, assets: assets)
        let e = CertifyCardLayout.edge
        let roomX = viewport.width - 2 * e - size.width, roomY = viewport.height - 2 * e - size.height
        withAnimation(DS.Motion.sheetIn) {
            chosen = CGPoint(x: roomX > 0 ? (settled.x - e) / roomX : 0, y: roomY > 0 ? (settled.y - e) / roomY : 0)
            rest = settled
            dragFrom = nil
            drag = .zero
        }
    }

    /// Tests: back to a fresh session.
    func reset() {
        chosen = nil; rest = .zero; dragFrom = nil; drag = .zero; viewport = .zero; size = .zero
        resultsAssets = []; pageAssets = []; rawResults = [:]; rawPage = [:]
    }
}

/// The workspace's frames the card reads (the stage menu riding over Results is the workspace's, not the Results screen's).
/// A modifier with no stored value: the workspace's body value does not grow (WorkspaceBodySizeTests).
struct CertifyCardPageFrames: ViewModifier {
    func body(content: Content) -> some View {
        content.onPreferenceChange(ChromeKeepOutKey.self) { CertifyCardPlace.shared.notePage($0) }
    }
}
extension View {
    func certifyCardPageFrames() -> some View { modifier(CertifyCardPageFrames()) }
}

/// The card and its line, over the Results screen. The card's frame (global) is published as "certifyCard".
struct CertifyCardLayer: View {
    let card: OrganicCertifyCard
    /// Where the line points (the screen's points, as the 3D view projects them); nil: no line.
    let target: CGPoint?
    @ObservedObject var place: CertifyCardPlace

    /// The Results screen fills the screen (its layers ignore the safe area), so its own space is the screen's: the card is
    /// placed, and its line drawn, in the same points the page's frames are published in (the card's line always was).
    var body: some View {
        let f = place.frame
        ZStack(alignment: .topLeading) {
            if place.size.width > 0 { OrganicCertifyLeader(from: f, to: target) }
            OrganicCertifyCardView(card: card)
                .background(GeometryReader { c in
                    Color.clear.preference(key: CertifyCardMeasures.self, value: ["card": c.size])
                })
                .background(ResultsChrome.publish("certifyCard"))
                .gesture(DragGesture(minimumDistance: 8, coordinateSpace: .global)
                    .onChanged { place.dragChanged($0.translation) }
                    .onEnded { place.dragEnded($0.translation) })
                .opacity(place.size.width > 0 ? 1 : 0)
                .padding(.leading, Swift.max(0, f.minX)).padding(.top, Swift.max(0, f.minY))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GeometryReader { g in
            Color.clear.preference(key: CertifyCardMeasures.self, value: ["viewport": g.size])
        })
        .ignoresSafeArea()
        // the screen's size and the card's, as each layout leaves them (a preference follows every layout)
        .onPreferenceChange(CertifyCardMeasures.self) { m in
            if let v = m["viewport"] { place.noteViewport(v) }
            if let s = m["card"] { place.noteSize(s) }
        }
        .transformPreference(CertifyCardMeasures.self) { $0 = [:] }
    }
}

/// The layer's measures: the screen ("viewport") and the card ("card").
struct CertifyCardMeasures: PreferenceKey {
    static var defaultValue: [String: CGSize] = [:]
    static func reduce(value: inout [String: CGSize], nextValue: () -> [String: CGSize]) { value.merge(nextValue()) { $1 } }
}
