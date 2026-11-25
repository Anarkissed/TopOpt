// CornerTapCloser — his iPad notes 2026-11-22, the corner drawers' second rule. Asked whether a tap on the Selections panel or a
// new menu closes an open drawer: "If you mean tapping on the Selections panel or opening up a new menu, then it ABSOLUTELY
// should".
//
// So a tap ANYWHERE on the page outside the open drawer (Settings or a ⌃'s) closes it — the Selections panel and its rows, the
// Topology panel, the top bar, the stage menu, the view cube, any other button or menu — and the tap still does its own job
// (a row tapped is picked; a menu tapped opens). Taps inside the open drawer, and on the corner's own Settings chip and ⌃
// (they open, shut and switch the drawers themselves), never close it by this rule.
//
// How: one touch watcher on the page's window that never takes a touch (it fails at once, cancels nothing, delays nothing,
// and recognises alongside every other recogniser), so no control loses its tap. On a finger's touch-down it closes the open
// drawer when the point lies outside the drawer's and the corner buttons' frames (the frames the page already publishes).
// The 3D view is left to its own tap (`closesCornerDrawers`): a drag there still turns the view and closes nothing. A touch in
// another presentation (a popover, a system menu, a sheet) is not the page's and is left alone.
import SwiftUI
#if canImport(MetalKit)
import MetalKit
#endif
#if os(iOS)
import UIKit
import UIKit.UIGestureRecognizerSubclass
#elseif os(macOS)
import AppKit
#endif

extension CornerDrawers {
    /// The published frames a tap leaves the open drawer alone in: the drawers and the corner's chip and ⌃ buttons.
    static let keepKeys: Set<String> = ["cornerPanel", "settingsPanel", "setupChip",
                                        "latticeSplitMore", "topologySplitMore", "resultsSplitMore",
                                        "versionMenuDrawer", "topLeftVersion"]   // ★ 11-23: the version chip and its drawer
    /// RED CONTROL (CornerDrawersOutsideTapHostedTests): a tap outside the drawer closes nothing (as before his answer).
    @MainActor static var controlNoOutsideTap = false

    func noteKeepFrames(_ all: [String: CGRect]) {
        keepFrames = all.compactMap { Self.keepKeys.contains($0.key) || $0.key.hasSuffix("SplitMoreDrawer") ? $0.value : nil }
    }

    /// A touch at `p` (global): outside the open drawer and the corner's buttons, the drawer closes.
    func touchedDown(at p: CGPoint) {
        guard open != nil, !Self.controlNoOutsideTap else { return }
        guard !keepFrames.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(p) }) else { return }
        close()
    }
}

extension View {
    /// ★ his 11-22: a tap anywhere on this page outside the open corner drawer closes it (CornerTapCloser).
    func cornerTapCloses(_ drawers: CornerDrawers) -> some View { modifier(CornerTapCloses(drawers: drawers)) }
    /// ★ his 11-22: a platform view that runs its own gesture (the view cube) may take a click before the window's watcher
    /// sees it (so on the Mac): a finger down on it closes the open drawer too, alongside its own drag and tap.
    func closesCornerDrawersOnTouch(_ drawers: CornerDrawers) -> some View {
        simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in
            if drawers.open != nil, !CornerDrawers.controlNoOutsideTap { drawers.close() }
        })
    }
}

struct CornerTapCloses: ViewModifier {
    let drawers: CornerDrawers
    func body(content: Content) -> some View {
        content
            .onPreferenceChange(ChromeKeepOutKey.self) { drawers.noteKeepFrames($0) }
            .background(CornerTapSpy(drawers: drawers).allowsHitTesting(false))
    }
}

enum CornerTapSpyRules {
    /// The view the last watched click landed on (the hosted tests' trace).
    @MainActor static var lastHit: String?
    #if os(iOS)
    typealias PlatformView = UIView
    #elseif os(macOS)
    typealias PlatformView = NSView
    #endif
    /// The page's 3D view (MetalMeshView's own, drawn by MeshRenderer — never the view cube's or a gizmo's): its taps close
    /// the drawer through `closesCornerDrawers`, and a drag there turns the view.
    @MainActor static func isMainViewer(_ v: PlatformView) -> Bool {
        #if canImport(MetalKit)
        var x: PlatformView? = v
        while let c = x {
            if let m = c as? MTKView, m.delegate is MeshRenderer { return true }
            x = c.superview
        }
        #endif
        return false
    }
}

#if os(iOS)
struct CornerTapSpy: UIViewRepresentable {
    let drawers: CornerDrawers
    func makeUIView(context: Context) -> CornerTapSpyView {
        let v = CornerTapSpyView()
        v.isUserInteractionEnabled = false
        v.drawers = drawers
        return v
    }
    func updateUIView(_ v: CornerTapSpyView, context: Context) { v.drawers = drawers }
}

final class CornerTapSpyView: UIView {
    weak var drawers: CornerDrawers?
    private var watcher: CornerTouchWatcher?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let w = watcher { w.view?.removeGestureRecognizer(w); watcher = nil }
        guard let window else { return }
        let w = CornerTouchWatcher(target: nil, action: nil)
        w.onDown = { [weak self] t in self?.touched(t) }
        window.addGestureRecognizer(w)
        watcher = w
    }

    private func touched(_ t: UITouch) {
        guard let d = drawers, d.open != nil, let window, let hit = t.view else { return }
        // a popover, a system menu, a sheet: another presentation, not this page
        guard Self.top(hit, in: window) === Self.top(self, in: window) else { return }
        if CornerTapSpyRules.isMainViewer(hit) { return }
        d.touchedDown(at: t.location(in: window))
    }

    private static func top(_ v: UIView, in w: UIWindow) -> UIView? {
        var x = v
        while let s = x.superview, s !== w { x = s }
        return x.superview === w ? x : nil
    }
}

/// Watches a finger come down and fails at once: it never takes, cancels or delays a touch.
final class CornerTouchWatcher: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onDown: ((UITouch) -> Void)?
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let t = touches.first, (event.allTouches?.count ?? 1) == 1 { onDown?(t) }
        state = .failed
    }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    // never failed early by a control that grabs the touch at once (the view cube's drag), and never failing one
    override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }
    override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
}
#elseif os(macOS)
struct CornerTapSpy: NSViewRepresentable {
    let drawers: CornerDrawers
    func makeNSView(context: Context) -> CornerTapSpyView {
        let v = CornerTapSpyView()
        v.drawers = drawers
        return v
    }
    func updateNSView(_ v: CornerTapSpyView, context: Context) { v.drawers = drawers }
}

final class CornerTapSpyView: NSView {
    weak var drawers: CornerDrawers?
    private var watcher: CornerClickWatcher?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let w = watcher { w.view?.removeGestureRecognizer(w); watcher = nil }
        guard let root = window?.contentView else { return }
        let w = CornerClickWatcher(target: nil, action: nil)
        w.onDown = { [weak self] e in self?.clicked(e) }
        root.addGestureRecognizer(w)
        watcher = w
    }

    private func clicked(_ e: NSEvent) {
        guard let d = drawers, d.open != nil, let root = window?.contentView else { return }
        let hit = root.hitTest(root.superview?.convert(e.locationInWindow, from: nil) ?? e.locationInWindow)
        CornerTapSpyRules.lastHit = hit.map { String(describing: type(of: $0)) } ?? "nil"
        if let hit, CornerTapSpyRules.isMainViewer(hit) { return }
        let local = root.convert(e.locationInWindow, from: nil)
        d.touchedDown(at: root.isFlipped ? local : CGPoint(x: local.x, y: root.bounds.height - local.y))
    }
}

/// Watches a click come down and fails at once: it never takes or delays a click.
final class CornerClickWatcher: NSGestureRecognizer, NSGestureRecognizerDelegate {
    var onDown: ((NSEvent) -> Void)?
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        delaysPrimaryMouseButtonEvents = false
        delaysSecondaryMouseButtonEvents = false
        delegate = self
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    override func mouseDown(with event: NSEvent) {
        onDown?(event)
        state = .failed
    }
    func gestureRecognizer(_ g: NSGestureRecognizer, shouldRecognizeSimultaneouslyWith other: NSGestureRecognizer) -> Bool { true }
    // never failed early by a control that grabs the click at once (the view cube's drag), and never failing one
    override func canBePrevented(by other: NSGestureRecognizer) -> Bool { false }
    override func canPrevent(_ other: NSGestureRecognizer) -> Bool { false }
}
#endif
