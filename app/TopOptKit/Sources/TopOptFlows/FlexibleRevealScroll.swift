// FlexibleRevealScroll — the Settings panel's scroll, RECODED (task 2026-09-29-flexible-screens,
// round 7 · T3; his rule: after 2–3 failed fixes, recode the section).
//
// ★ WHY: the panel asked a ScrollViewReader to `scrollTo(card, anchor: .bottom)`. On 11" landscape
// "as opened" the page's first pass gave the scroll 610 pt (the whole tab, nothing to scroll); the
// next pass (the top chrome measured) gave it 594 pt. The ask made in that pass never moved the
// scroll, and five later asks (a key on the card's top, the next main-queue turn, 0.15 s / 0.8 s
// later, a nominal first cap, a run-loop timer) did not either: the card's last 16 pt stayed below
// the fold until his next tap.
// ★ NOW: the scroll's position is EXPLICIT. The target (the selected card) reports its frame in the
// scroll's CONTENT space; the scroll reports what it shows (its visible rect, container and
// content sizes). A reveal is a pending ask, and it is settled against the scroll's measured
// geometry every time either side reports — so the 594 pt pass settles it, whenever it comes. The
// offset is computed (`FlexibleReveal.offset`): the least move that shows the whole card (a card
// already in view stays put; a card taller than the view shows its top). The ask is done once the
// card is in view (or the scroll can go no further), so his own scrolling is never pulled back.
// It is re-asked by the caller's `revealKey` (selection, tab, …), and by the card's or the
// scroll's height changing.
// iOS 18 / macOS 15 and later (the iPad app and the Mac test host today): `ScrollPosition` +
// `onScrollGeometryChange`. Earlier systems keep the old ScrollViewReader ask (the card's `.id`).

import SwiftUI

/// The pure reveal maths, and the names the target and the scroll share.
enum FlexibleReveal {
    /// The scroll content's coordinate space: the target's frame is read in it (it moves with the content).
    static let space = "flexible-reveal-content"

    /// The content-space y the scroll must show at its top so `target` is wholly in view, or nil
    /// when it already is (or the scroll can move no nearer). `visible` is what the scroll shows,
    /// in content space; `content` the content's height.
    static func offset(target: CGRect, visible: CGRect, content: CGFloat, slack: CGFloat = 0.5) -> CGFloat? {
        let view = visible.height
        guard view > 0, target.height > 0 else { return nil }
        var y = visible.minY
        if target.maxY > y + view + slack { y = target.maxY - view }   // below the fold: its last row up to the bottom
        if target.minY < y - slack { y = target.minY }                   // above (or taller than the view): its top
        y = min(max(0, y), max(0, content - view))
        return abs(y - visible.minY) > slack ? y : nil
    }
}

/// The frame the reveal target reports, in `FlexibleReveal.space`.
struct FlexibleRevealTargetKey: PreferenceKey {
    static var defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        if let n = nextValue() { value = n }
    }
}

extension View {
    /// Marks this view as what the enclosing `FlexibleRevealScroll` keeps in view (one at a time).
    func flexibleRevealTarget() -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: FlexibleRevealTargetKey.self, value: g.frame(in: .named(FlexibleReveal.space)))
        }.allowsHitTesting(false))
    }
}

/// A vertical scroll that brings its `flexibleRevealTarget()` wholly into view when `revealKey`
/// changes, when the target or the scroll changes height, and as it opens.
struct FlexibleRevealScroll<Content: View>: View {
    /// A change asks for a reveal.
    let revealKey: String
    /// Off: nothing is revealed (the panel folded, another tab).
    let enabled: Bool
    /// For systems before iOS 18 / macOS 15: the target's `.id`, asked of a ScrollViewReader.
    let legacyID: AnyHashable?
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            FlexibleRevealScrollModern(revealKey: revealKey, enabled: enabled, content: content)
        } else {
            FlexibleRevealScrollLegacy(revealKey: revealKey, enabled: enabled, legacyID: legacyID, content: content)
        }
    }
}

@available(iOS 18.0, macOS 15.0, *)
private struct FlexibleRevealScrollModern<Content: View>: View {
    let revealKey: String
    let enabled: Bool
    @ViewBuilder let content: () -> Content

    @State private var position = ScrollPosition(edge: .top)
    @State private var shown: Shown?
    @State private var target: CGRect?
    /// A reveal asked and not yet settled.
    @State private var pending = true

    /// What the scroll shows, in content space.
    struct Shown: Equatable {
        var visible: CGRect
        var content: CGFloat
        var offset: CGFloat
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            content()
                .coordinateSpace(name: FlexibleReveal.space)
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: Shown.self, of: { g in
            Shown(visible: g.visibleRect, content: g.contentSize.height, offset: g.contentOffset.y)
        }, action: { old, new in
            shown = new
            if abs(old.visible.height - new.visible.height) > 0.5 { pending = true }   // the scroll grew or shrank
            settle()
        })
        .onPreferenceChange(FlexibleRevealTargetKey.self) { t in
            if let t, abs((target?.height ?? -1) - t.height) > 0.5 { pending = true }   // the card grew or shrank
            target = t
            settle()
        }
        .onChange(of: revealKey) { _ in pending = true; settle() }
        .onChange(of: enabled) { on in if on { pending = true; settle() } }
        .onAppear { pending = true; settle() }
    }

    /// Settle a pending reveal against what is measured now (called whenever either side reports).
    /// The content's height is never taken as less than the card's bottom: the card reports its
    /// new frame before the scroll reports its new content, and a stale content height would read
    /// "as near as the scroll goes" and drop the ask. An ask made here is checked again on the next
    /// main-queue turn (at most `retries` times per ask) in case the scroll took it in a pass that
    /// reports nothing new.
    private func settle(retry: Int = 0) {
        guard pending, enabled, let s = shown, let t = target, s.visible.height > 0 else { return }
        guard let y = FlexibleReveal.offset(target: t, visible: s.visible, content: max(s.content, t.maxY)) else {
            pending = false   // in view (or as near as the scroll goes): his own scrolling is his
            return
        }
        // `scrollTo(y:)` is the content OFFSET; the visible rect may sit off it by the scroll's insets
        position.scrollTo(y: s.offset + (y - s.visible.minY))
        if retry < Self.retries { DispatchQueue.main.async { settle(retry: retry + 1) } }
    }
    static var retries: Int { 3 }
}

/// iOS 16–17 / macOS 13–14: round 4's ask, kept as it was (the card's `.id`, anchored at the bottom,
/// asked again when the card or the scroll changes height).
private struct FlexibleRevealScrollLegacy<Content: View>: View {
    let revealKey: String
    let enabled: Bool
    let legacyID: AnyHashable?
    @ViewBuilder let content: () -> Content
    @State private var scrollHeight = 0
    @State private var cardHeight = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                content()
                    .coordinateSpace(name: FlexibleReveal.space)
            }
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { scrollHeight = Int(g.size.height / 4) }
                    .onChange(of: g.size.height) { scrollHeight = Int($0 / 4) }
            }.allowsHitTesting(false))
            .onPreferenceChange(FlexibleRevealTargetKey.self) { cardHeight = Int(($0?.height ?? 0) / 4) }
            .onChange(of: "\(revealKey)|\(scrollHeight)|\(cardHeight)") { _ in reveal(proxy) }
            .onAppear { reveal(proxy) }
        }
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        guard enabled, let id = legacyID else { return }
        proxy.scrollTo(id, anchor: .bottom)
    }
}
