// EyeSweep — ★ his iPad notes of 11-07 (3b; his answers via #362, 20:25Z): "Press an eye and drag: each row your finger passes
// FLIPS to the opposite of its own state (visible→hidden, hidden→visible). It works in BOTH directions, up or down. The list
// auto-scrolls while the finger is at its top or bottom edge, until release."
//
// One sweep per list (Lattice Setup's). Every eye in the list notes here its frame (global), its state and its toggle. A drag
// that starts on an eye begins a sweep: the pressed row flips at once, then every row whose middle lies between the pressed
// row's middle and the finger flips to the opposite of its own state. A row the finger goes back over is passed again, so it
// returns to its own state. While the finger is in the list's top or bottom band (or past it), having moved that way, the
// list steps a row at a time toward it and the rows that come under the finger flip as they pass. Release ends it. A tap
// stays the eye's own (one row).
import SwiftUI

@MainActor
public final class EyeSweep: ObservableObject {
    struct Eye {
        var frame: CGRect
        var hidden: Bool
        /// Inside the list's scroll view (a scroll target), not under it (Lattice Setup's zones).
        var inScroll: Bool
        var toggle: () -> Void
    }

    private(set) var eyes: [String: Eye] = [:]
    /// The list's scroll view, in the eyes' space (global).
    var visible: CGRect? = nil
    /// Brings `key`'s eye in at the scroll view's bottom (+1) or top (−1).
    var scrollTo: ((String, Int) -> Void)? = nil

    private(set) var start: String? = nil
    private var startMid: CGFloat? = nil
    private var pressY: CGFloat = 0
    private(set) var finger: CGPoint? = nil
    private(set) var flipped: Set<String> = []
    private var clock: Timer? = nil

    public init() {}

    /// The finger travels this far before an eye's drag is a sweep (under it, the eye's tap).
    nonisolated static let minimumDistance: CGFloat = 4
    /// The edge band: the finger this near the scroll view's top or bottom (or past it) scrolls the list.
    nonisolated static let band: CGFloat = 32
    /// One row per tick while the finger holds an edge.
    nonisolated static let tickSeconds: Double = 0.12
    nonisolated static func scrollID(_ key: String) -> String { "eyeSweep-" + key }

    /// Tests (the drag a synthesised event never reaches): the Lattice Setup list's sweep, as the list last built it.
    public static var recordLive = false
    public static weak var live: EyeSweep?

    // MARK: the eyes

    func note(_ key: String, frame: CGRect, hidden: Bool, inScroll: Bool, toggle: @escaping () -> Void) {
        eyes[key] = Eye(frame: frame, hidden: hidden, inScroll: inScroll, toggle: toggle)
        if key == start { startMid = frame.midY }
    }

    func drop(_ key: String) { eyes[key] = nil }

    public var isSweeping: Bool { start != nil }
    /// An eye's state as it last drew (nil: no such eye in the list).
    public func hidden(_ key: String) -> Bool? { eyes[key]?.hidden }
    public func frame(_ key: String) -> CGRect? { eyes[key]?.frame }
    public var keys: [String] { eyes.keys.sorted { (eyes[$0]?.frame.midY ?? 0) < (eyes[$1]?.frame.midY ?? 0) } }

    // MARK: the gesture's three calls

    /// The finger pressed `key`'s eye at `p` and moved: the sweep begins, and the pressed row flips.
    public func begin(_ key: String, at p: CGPoint) {
        end()
        start = key
        startMid = eyes[key]?.frame.midY
        pressY = p.y
        finger = p
        apply()
        let t = Timer(timeInterval: Self.tickSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        clock = t
    }

    public func move(to p: CGPoint) {
        guard start != nil else { return }
        finger = p
        apply()
    }

    /// Release: the rows stay as the sweep left them.
    public func end() {
        clock?.invalidate()
        clock = nil
        start = nil
        startMid = nil
        finger = nil
        flipped = []
    }

    // MARK: the sweep

    /// Each row between the pressed one and the finger flipped once; a row left behind is back to its own state.
    private func apply() {
        guard let start, let finger else { return }
        var mids = eyes.mapValues { $0.frame.midY }
        if mids[start] == nil, let startMid { mids[start] = startMid }
        let now = Self.covered(mids: mids, start: start, fingerY: finger.y)
        for k in flipped.subtracting(now) {
            eyes[k]?.toggle()
            flipped.remove(k)
        }
        for k in now.subtracting(flipped) {
            guard let e = eyes[k] else { continue }
            e.toggle()
            flipped.insert(k)
        }
    }

    /// The auto-scroll: the rows under a still finger flip as the list carries them past, and the list steps toward the edge
    /// the finger holds.
    func tick() {
        guard start != nil, let finger else { return }
        apply()
        guard let visible else { return }
        var dir = Self.scrollDirection(fingerY: finger.y, visible: visible)
        if dir < 0, finger.y >= pressY { dir = 0 }   // toward an edge only after moving that way (a press on the top row stays)
        if dir > 0, finger.y <= pressY { dir = 0 }
        guard dir != 0 else { return }
        let inScroll = eyes.filter(\.value.inScroll).mapValues(\.frame)
        guard let target = Self.nextTarget(frames: inScroll, visible: visible, direction: dir) else { return }
        scrollTo?(target, dir)
    }

    /// The pressed row and every row whose middle lies between its middle and the finger, up or down.
    nonisolated static func covered(mids: [String: CGFloat], start: String, fingerY: CGFloat) -> Set<String> {
        guard let s = mids[start] else { return [] }
        let lo = Swift.min(s, fingerY), hi = Swift.max(s, fingerY)
        var out: Set<String> = [start]
        for (k, m) in mids where m >= lo && m <= hi { out.insert(k) }
        return out
    }

    /// −1: the finger is in the top band or above it; +1: the bottom band or below; 0: between.
    nonisolated static func scrollDirection(fingerY: CGFloat, visible: CGRect, band: CGFloat = band) -> Int {
        if fingerY <= visible.minY + band { return -1 }
        if fingerY >= visible.maxY - band { return 1 }
        return 0
    }

    /// The next eye past the fold that way: the nearest below the bottom (+1) or above the top (−1); nil when none is left.
    nonisolated static func nextTarget(frames: [String: CGRect], visible: CGRect, direction: Int) -> String? {
        if direction > 0 {
            return frames.filter { $0.value.maxY > visible.maxY + 0.5 }.min { $0.value.minY < $1.value.minY }?.key
        }
        if direction < 0 {
            return frames.filter { $0.value.minY < visible.minY - 0.5 }.max { $0.value.maxY < $1.value.maxY }?.key
        }
        return nil
    }
}

// MARK: the list's sweep, to its eyes

private struct EyeSweepKey: EnvironmentKey { static let defaultValue: EyeSweep? = nil }
private struct EyeSweepInScrollKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// The list's sweep (nil: its eyes are taps only).
    var eyeSweep: EyeSweep? {
        get { self[EyeSweepKey.self] }
        set { self[EyeSweepKey.self] = newValue }
    }
    /// Inside the list's scroll view.
    var eyeSweepInScroll: Bool {
        get { self[EyeSweepInScrollKey.self] }
        set { self[EyeSweepInScrollKey.self] = newValue }
    }
}

extension View {
    /// ★ 3b: this eye takes part in its list's sweep, when the list has one: its frame, state and toggle noted; a drag that
    /// starts on it sweeps the column. Its tap stays its own.
    func eyeSweep(_ key: String, hidden: Bool, toggle: @escaping () -> Void) -> some View {
        modifier(EyeSweepEye(key: key, hidden: hidden, toggle: toggle))
    }
}

struct EyeSweepEye: ViewModifier {
    @Environment(\.eyeSweep) private var sweep
    @Environment(\.eyeSweepInScroll) private var inScroll
    let key: String
    let hidden: Bool
    let toggle: () -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if let sweep {
            content
                .id(EyeSweep.scrollID(key))
                .background(GeometryReader { g in
                    let f = g.frame(in: .global)
                    Color.clear
                        .onAppear { sweep.note(key, frame: f, hidden: hidden, inScroll: inScroll, toggle: toggle) }
                        .onChange(of: f) { sweep.note(key, frame: $0, hidden: hidden, inScroll: inScroll, toggle: toggle) }
                        .onChange(of: hidden) { sweep.note(key, frame: f, hidden: $0, inScroll: inScroll, toggle: toggle) }
                        .onDisappear { sweep.drop(key) }
                }.allowsHitTesting(false))
                // ★ the drag that starts on an eye is the sweep's, never the list's scroll (the eye's tap is the button's)
                .highPriorityGesture(
                    DragGesture(minimumDistance: EyeSweep.minimumDistance, coordinateSpace: .global)
                        .onChanged { v in
                            if !sweep.isSweeping { sweep.begin(key, at: v.startLocation) }
                            sweep.move(to: v.location)
                        }
                        .onEnded { _ in sweep.end() })
        } else {
            content
        }
    }
}
