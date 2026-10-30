// FlexibleRevealScrollTests — the Settings panel's scroll, recoded (task 2026-09-29-flexible-screens,
// round 7 · T3). The hosted page test (FlexibleSettingsPageHostedTests, 11" landscape "as opened")
// is the red on his project; these pin the mechanism on a rig that does what the page does — the
// scroll gets the whole tab on the first pass, then 16 pt less on the next (the top chrome measured):
//   * FlexibleRevealScroll shows the card whole (the old ScrollViewReader ask is recorded beside it;
//     the red is the hosted page test, where that ask never moved);
//   * a selection change brings a card above or below the fold wholly into view;
//   * a card already in view never moves the scroll; a card taller than the view shows its top;
//   * the pure maths (`FlexibleReveal.offset`).
#if canImport(AppKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows

private final class RigWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct RigFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

@MainActor
private final class RigState: ObservableObject {
    @Published var cap: CGFloat = 4000
    /// After the first pass: the cap the next pass brings (nil = none).
    var nextCap: CGFloat?
    @Published var selected = 7
    @Published var cardHeight: CGFloat = 246
    var rows = 8
    let useNew: Bool
    init(useNew: Bool) { self.useNew = useNew }
}

/// A Face tab in miniature: 48 pt rows, the selected one open as a card, in the panel's hug-then-scroll.
private struct Rig: View {
    @ObservedObject var s: RigState

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            FlexibleHugHeight {
                if s.useNew {
                    FlexibleRevealScroll(revealKey: "\(s.selected)", enabled: true, legacyID: "card-\(s.selected)") { rows }
                        .background(frame("scroll"))
                } else {
                    OldScroll(s: s, rows: rows).background(frame("scroll"))
                }
            }
            .frame(width: 372)
            .frame(maxHeight: s.cap, alignment: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .onAppear { if let c = s.nextCap { DispatchQueue.main.async { s.cap = c } } }   // the page's next pass
    }

    var rows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<s.rows, id: \.self) { i in
                if i == s.selected {
                    Color.blue.frame(height: s.cardHeight).flexibleRevealTarget().background(frame("card")).id("card-\(i)")
                } else {
                    Color.gray.frame(height: 48).id("row-\(i)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(frame("content"))
    }

    func frame(_ name: String) -> some View {
        GeometryReader { g in Color.clear.preference(key: RigFramesKey.self, value: [name: g.frame(in: .global)]) }
    }
}

/// Round 4 – T1's panel: a ScrollViewReader asked to scroll the card to its bottom, as the page
/// opens and when the scroll's height changes.
private struct OldScroll<Rows: View>: View {
    @ObservedObject var s: RigState
    let rows: Rows
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) { rows }
                .background(GeometryReader { g in
                    Color.clear.onAppear { height = g.size.height }.onChange(of: g.size.height) { height = $0 }
                })
                .onChange(of: "\(s.selected)|\(Int(height / 4))") { _ in proxy.scrollTo("card-\(s.selected)", anchor: .bottom) }
                .onAppear { proxy.scrollTo("card-\(s.selected)", anchor: .bottom) }
        }
    }
}

@MainActor
final class FlexibleRevealScrollTests: XCTestCase {

    final class Frames { var all: [String: CGRect] = [:] }

    func pump(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    private func host(_ s: RigState, size: CGSize) -> (NSWindow, Frames) {
        let frames = Frames()
        let hv = NSHostingView(rootView: Rig(s: s).onPreferenceChange(RigFramesKey.self) { frames.all = $0 })
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = RigWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = hv
        w.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        w.orderFrontRegardless()
        hv.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in w.orderOut(nil); w.contentView = nil }
        return (w, frames)
    }

    /// The card against what the scroll shows (1 pt slack, the hosted test's).
    private func cardIsOn(_ f: Frames) -> Bool {
        guard let v = f.all["scroll"], let c = f.all["card"] else { return false }
        return c.minY >= v.minY - 1 && c.maxY <= v.maxY + 1
    }

    /// How far the content is scrolled (its top above the scroll's top).
    private func offset(_ f: Frames) -> CGFloat {
        guard let v = f.all["scroll"], let c = f.all["content"] else { return .nan }
        return v.minY - c.minY
    }

    private func line(_ tag: String, _ f: Frames) -> String {
        let v = f.all["scroll"] ?? .zero, c = f.all["card"] ?? .zero
        return String(format: "%@: card %.0f–%.0f in the scroll %.0f–%.0f (%.0f pt) offset %.0f %@", tag, c.minY, c.maxY,
                      v.minY, v.maxY, v.height, offset(f), cardIsOn(f) ? "✓" : "✗ OFF")
    }

    // MARK: - the page's case: the scroll loses 16 pt on the next pass

    /// The content: 7 rows of 48 + a 246 pt card + 7 gaps of 4 = 610 pt, the card last (his 11"
    /// landscape Face tab, "as opened"). First pass: no cap, the scroll hugs 610; next pass 594.
    func testTheCardIsWholeAfterTheScrollShrinksOnTheNextPass() {
        var report: [String] = []
        for useNew in [false, true] {
            let s = RigState(useNew: useNew)
            s.nextCap = 594
            let (w, f) = host(s, size: CGSize(width: 600, height: 834))
            pump(1.2)
            report.append(line(useNew ? "FlexibleRevealScroll" : "control (old ask)", f))
            XCTAssertEqual(f.all["scroll"]?.height ?? 0, 594, accuracy: 0.5, "the next pass's scroll")
            XCTAssertEqual(f.all["content"]?.height ?? 0, 610, accuracy: 0.5, "the content")
            if useNew {
                XCTAssertTrue(cardIsOn(f), "the card must be whole in the scroll as opened — \(line("new", f))")
                XCTAssertEqual(offset(f), 16, accuracy: 1, "the least move: the card's last 16 pt up")
            }
            // (the old ask is only recorded: on this rig it moves; on his page at 11" landscape it did not —
            // FlexibleSettingsPageHostedTests is that red)
            w.orderOut(nil); w.contentView = nil
        }
        print("FLEX-REVEAL shrink\n  " + report.joined(separator: "\n  "))
    }

    // MARK: - a selection change, no jump, a tall card, at the page's sizes

    /// At each size's scroll (11" landscape 594, 11" portrait and 13" portrait their tall scrolls with
    /// a longer tab): as opened, then a selection above the fold, below it, and one already in view.
    func testASelectionChangeBringsTheCardWhollyIntoViewAndAVisibleOneDoesNotMove() {
        // (tag, rows, the next pass's cap): the long tabs make the 11"/13" portrait scrolls scroll too
        let cases: [(String, Int, CGFloat)] = [("11l", 8, 594), ("11p", 20, 860), ("13p", 26, 1040)]
        var report: [String] = []
        for (tag, rows, cap) in cases {
            let s = RigState(useNew: true)
            s.rows = rows
            s.selected = rows - 1
            s.nextCap = cap
            let (w, f) = host(s, size: CGSize(width: 600, height: cap + 240))
            pump(1.2)
            report.append(line("\(tag) as opened (last row)", f))
            XCTAssertTrue(cardIsOn(f), "\(tag) as opened: \(line(tag, f))")
            // a selection ABOVE the fold (the first row): the card's top comes down to the scroll's top
            s.selected = 0
            pump(0.8)
            report.append(line("\(tag) first row", f))
            XCTAssertTrue(cardIsOn(f), "\(tag) first row: \(line(tag, f))")
            // and back to the last row, BELOW the fold
            s.selected = rows - 1
            pump(0.8)
            report.append(line("\(tag) last row again", f))
            XCTAssertTrue(cardIsOn(f), "\(tag) last row again: \(line(tag, f))")
            // a row already in view (the one above the card): the scroll stays where it is
            let before = offset(f)
            s.selected = rows - 2
            pump(0.8)
            report.append(line("\(tag) the row above (in view)", f))
            XCTAssertTrue(cardIsOn(f), "\(tag) the row above: \(line(tag, f))")
            XCTAssertEqual(offset(f), before, accuracy: 1, "\(tag): a card already in view never moves the scroll")
            // the card grows (a stamp's rows) past the fold: brought back whole
            s.cardHeight = 330
            pump(0.8)
            report.append(line("\(tag) the card grows to 330", f))
            XCTAssertTrue(cardIsOn(f), "\(tag) the card grew: \(line(tag, f))")
            w.orderOut(nil); w.contentView = nil
        }
        print("FLEX-REVEAL selection\n  " + report.joined(separator: "\n  "))
    }

    /// A card taller than the scroll shows its TOP (its first rows), never its bottom.
    func testACardTallerThanTheScrollShowsItsTop() {
        let s = RigState(useNew: true)
        s.cardHeight = 700
        s.selected = 7
        s.nextCap = 594
        let (_, f) = host(s, size: CGSize(width: 600, height: 834))
        pump(1.2)
        let v = f.all["scroll"] ?? .zero, c = f.all["card"] ?? .zero
        print("FLEX-REVEAL tall " + line("700 pt card", f))
        XCTAssertEqual(c.minY, v.minY, accuracy: 1, "the tall card's top at the scroll's top")
    }

    // MARK: - the maths

    func testTheOffsetIsTheLeastMove() {
        let view = CGRect(x: 0, y: 0, width: 372, height: 594)
        // below the fold by 16: up 16
        XCTAssertEqual(FlexibleReveal.offset(target: CGRect(x: 0, y: 364, width: 372, height: 246), visible: view, content: 610) ?? -1, 16, accuracy: 0.01)
        // in view: nil (no jump)
        XCTAssertNil(FlexibleReveal.offset(target: CGRect(x: 0, y: 100, width: 372, height: 246), visible: view, content: 610))
        // above the fold: its top
        XCTAssertEqual(FlexibleReveal.offset(target: CGRect(x: 0, y: 40, width: 372, height: 100),
                                             visible: view.offsetBy(dx: 0, dy: 200), content: 2000) ?? -1, 40, accuracy: 0.01)
        // taller than the view: its top
        XCTAssertEqual(FlexibleReveal.offset(target: CGRect(x: 0, y: 300, width: 372, height: 800), visible: view, content: 2000) ?? -1, 300, accuracy: 0.01)
        // never past the content's end: as near as the scroll goes, then nil (the ask is settled)
        XCTAssertEqual(FlexibleReveal.offset(target: CGRect(x: 0, y: 500, width: 372, height: 200), visible: view, content: 660) ?? -1, 66, accuracy: 0.01)
        XCTAssertNil(FlexibleReveal.offset(target: CGRect(x: 0, y: 500, width: 372, height: 200), visible: view.offsetBy(dx: 0, dy: 66), content: 660))
    }
}
#endif
