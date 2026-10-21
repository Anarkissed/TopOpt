// FlexibleR7U21CHandlesTests — round 7 · U21, batch C (the Lattice page's two handles), his Img6 of 2026-10-21:
//   "The expand and depth icons look too similar and are more often than not too close together.
//    * Please make it more obvious what each one does by having the icons be very different instead of the same but different
//      angles such as having expand be "+" and include it next to the input in the modal so that people will associate the too.
//    * Please also make sure that there is a large enough buffer between the two so that tapping one doesn't open the other."
// Written before the code; each RED control is asserted red inside its test.
//   HANDLE-ICONS     testTheTwoIconsAreDifferentGlyphsFromOneSource, testTheCaptionsCarryTheHandleIcons (+ hosted)
//   HANDLE-GAP       testImg6KnobLeftOfFloorKeepsTheUnitsApart, testSweepSixteenDirectionsBothScreens,
//                    testTheBoxMovesBeforeTheKnobFlips (+ hosted on his l-bracket)
//   EXPAND-DRAG-DIR  testAPushedDiscStillDragsOutward, testAShortProjectionPointingLeftDragsOutward
import XCTest
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleR7U21CHandlesTests: XCTestCase {
    typealias H = FlexibleLatticeHandles
    static let p13 = CGSize(width: 1032, height: 1376)
    static let p11 = CGSize(width: 834, height: 1194)

    // MARK: HANDLE-ICONS

    func testTheTwoIconsAreDifferentGlyphsFromOneSource() throws {
        XCTAssertEqual(H.depthSymbol, "arrow.up.and.down", "★ depth keeps its own up/down arrow")
        XCTAssertEqual(H.expandSymbol, "plus", "★ expand is \"+\" (his words)")
        XCTAssertFalse(H.rotatedTwins(H.depthSymbol, H.expandSymbol), "★ not the same glyph at another angle")
        // the discs read the one source: no literal symbol left in the layer
        let layer = try String(contentsOf: FlexibleRound7SelectionsHookTests.sources.appendingPathComponent("FlexibleOnModelLayer.swift"), encoding: .utf8)
        XCTAssertTrue(layer.contains("FlexibleHandleDisc(symbol: FlexibleLatticeHandles.depthSymbol"), "★ the depth disc reads depthSymbol")
        XCTAssertTrue(layer.contains("FlexibleHandleDisc(symbol: FlexibleLatticeHandles.expandSymbol"), "★ the expand disc reads expandSymbol")
        XCTAssertFalse(layer.contains("\"arrow.left.and.right\""), "★ the old expand arrow is gone")
        // ★ RED CONTROL: today's pair is the same arrow turned 90°
        XCTAssertTrue(H.rotatedTwins("arrow.up.and.down", "arrow.left.and.right"), "★ RED CONTROL: the old pair is caught as rotated twins")
    }

    func testTheCaptionsCarryTheHandleIcons() throws {
        let list = try String(contentsOf: FlexibleRound7SelectionsHookTests.sources.appendingPathComponent("FlexibleSelectionsList.swift"), encoding: .utf8)
        XCTAssertEqual(list.components(separatedBy: "FlexibleHandleCaption(kind: .depth).frame(width: FlexibleSelectionsList.boxWidth").count - 1, 1,
                       "★ the depth caption = icon + \"Depth mm\", over its 80 pt box")
        XCTAssertEqual(list.components(separatedBy: "FlexibleHandleCaption(kind: .expand).frame(width: FlexibleSelectionsList.boxWidth").count - 1, 1,
                       "★ the expand caption = + \"Expand mm\", over its 80 pt box")
        let handles = try String(contentsOf: FlexibleRound7SelectionsHookTests.sources.appendingPathComponent("FlexibleLatticeHandles.swift"), encoding: .utf8)
        XCTAssertTrue(handles.contains("kind == .depth ? FlexibleLatticeHandles.depthSymbol : FlexibleLatticeHandles.expandSymbol"),
                      "★ the captions read the discs' source")
        XCTAssertEqual(FlexibleSelectionsCopy.depthCaption, "Depth mm")
        XCTAssertEqual(FlexibleSelectionsCopy.expandCaption, "Expand mm")
        // ★ RED CONTROL: today's caption row is text only
        let today = "            Text(FlexibleSelectionsCopy.depthCaption).frame(width: FlexibleSelectionsList.boxWidth, alignment: .center)"
        XCTAssertFalse(today.contains("FlexibleHandleCaption"), "★ RED CONTROL: the text-only caption carries no icon")
    }

    // MARK: HANDLE-GAP

    /// His Img6 on the probe's worst view of his l-bracket (az 1.57 el 0.25): floor (467, 995), the true knob 43 pt LEFT of it,
    /// boxes 82 pt (9.0 mm) and 88 pt (−3.0 mm). Today the expand box (drawn right, on top) covered the depth disc.
    func testImg6KnobLeftOfFloorKeepsTheUnitsApart() throws {
        let floor = CGPoint(x: 467.1, y: 995.0), raw = CGPoint(x: 424.1, y: 995.0)
        let l = H.layout(floor: floor, rawKnob: raw, depthBox: 82, expandBox: 88, viewport: Self.p13)
        let e = try XCTUnwrap(l.expand)
        let g = try XCTUnwrap(l.gap)
        XCTAssertGreaterThanOrEqual(g, H.unitGap, "★ ≥ 24 pt between the two units")
        XCTAssertFalse(l.depth.boxOnLeft, "★ the depth box goes right, away from the expand handle")
        XCTAssertTrue(e.boxOnLeft, "★ the expand box goes left, away from the depth handle")
        XCTAssertFalse(l.flipped, "the knob stays on its own side")
        XCTAssertLessThan(e.disc.x, floor.x, "the expand disc still left of the floor")
        XCTAssertEqual(e.disc.y, floor.y, accuracy: 1e-6, "pushed along its own direction (horizontal here)")
        let discD = CGRect(x: floor.x - 22, y: floor.y - 22, width: 44, height: 44)
        XCTAssertFalse(e.rect.intersects(discD), "★ the depth disc is under no part of the expand unit")
        print("FLEX-U21C-1 Img6: expand disc \(e.disc) · gap \(g) pt · depth unit \(l.depth.rect) · expand unit \(e.rect)")
        // ★ RED CONTROL: today's rule (72 pt floor, both boxes right) — the units overlap
        let old = H.oldLayout(floor: floor, rawKnob: raw)
        let og = try XCTUnwrap(old.gap)
        XCTAssertLessThan(og, 0, "★ RED CONTROL: today's units overlap (\(og) pt)")
        XCTAssertTrue(try XCTUnwrap(old.expand).rect.intersects(discD), "★ RED CONTROL: today the expand box lies on the depth disc")
        H.controlOldLayout = true
        defer { H.controlOldLayout = false }
        XCTAssertEqual(H.layout(floor: floor, rawKnob: raw, depthBox: 82, expandBox: 88, viewport: Self.p13), old,
                       "★ RED CONTROL: the switch gives today's layout")
    }

    /// 16 directions × the true knob 0–200 pt from the floor × 13" and 11" portrait, the floor at five spots: ≥ 24 pt every
    /// time, both units on screen.
    func testSweepSixteenDirectionsBothScreens() throws {
        var n = 0, worst = CGFloat.infinity, flips = 0, oldBad = 0
        for size in [Self.p13, Self.p11] {
            let floors = [CGPoint(x: size.width / 2, y: size.height / 2), CGPoint(x: 260, y: 300), CGPoint(x: size.width - 260, y: 300),
                          CGPoint(x: 260, y: size.height - 300), CGPoint(x: size.width - 260, y: size.height - 300)]
            for f in floors {
                for i in 0..<16 {
                    let a = CGFloat(i) * .pi / 8
                    for r in stride(from: CGFloat(0), through: 200, by: 10) {
                        let raw = CGPoint(x: f.x + cos(a) * r, y: f.y + sin(a) * r)
                        for (db, eb) in [(CGFloat(82), CGFloat(88)), (96, 104)] {
                            let l = H.layout(floor: f, rawKnob: raw, depthBox: db, expandBox: eb, viewport: size)
                            let g = try XCTUnwrap(l.gap)
                            n += 1
                            worst = min(worst, g)
                            if l.flipped { flips += 1 }
                            XCTAssertGreaterThanOrEqual(g, H.unitGap, "★ \(size) floor \(f) dir \(i) r \(r): \(g) pt")
                            let screen = CGRect(origin: .zero, size: size)
                            let er = try XCTUnwrap(l.expand).rect
                            XCTAssertTrue(screen.contains(l.depth.rect) && screen.contains(er), "on screen: \(f) \(i) \(r)")
                            if let og = H.oldLayout(floor: f, rawKnob: raw).gap, og < H.unitGap { oldBad += 1 }
                        }
                    }
                }
            }
        }
        print("FLEX-U21C-2 sweep: \(n) layouts · worst gap \(worst) pt · knob flipped \(flips) · today's rule under 24 pt in \(oldBad)")
        XCTAssertEqual(flips, 0, "★ with room on screen the knob never flips")
        XCTAssertGreaterThan(oldBad, n / 4, "★ RED CONTROL: today's rule leaves the units under 24 pt apart in many of them")
    }

    /// Near the screen's right edge with the knob straight below: the boxes move left before the knob ever flips; only a knob
    /// pointing into the edge with no room left flips (the last resort).
    func testTheBoxMovesBeforeTheKnobFlips() throws {
        let v = Self.p13
        let f = CGPoint(x: v.width - 60, y: 600)
        let below = H.layout(floor: f, rawKnob: CGPoint(x: f.x, y: f.y + 20), depthBox: 82, expandBox: 88, viewport: v)
        XCTAssertTrue(below.depth.boxOnLeft && (below.expand?.boxOnLeft ?? false), "★ both boxes moved left (right ran off the screen)")
        XCTAssertFalse(below.flipped, "★ …and the knob stayed below the floor")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(below.gap), H.unitGap)
        let into = H.layout(floor: f, rawKnob: CGPoint(x: f.x + 20, y: f.y), depthBox: 82, expandBox: 88, viewport: v)
        XCTAssertTrue(into.flipped, "★ pointing into the edge with no room: the last resort flips it")
        XCTAssertLessThan(try XCTUnwrap(into.expand).disc.x, f.x)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(into.gap), H.unitGap)
        XCTAssertTrue(CGRect(origin: .zero, size: v).contains(try XCTUnwrap(into.expand).rect))
        // the open list is a keep-out for the expand unit
        let list = CGRect(x: 0, y: 500, width: 400, height: 300)
        let kept = H.layout(floor: CGPoint(x: 500, y: 650), rawKnob: CGPoint(x: 470, y: 650), depthBox: 82, expandBox: 88,
                            viewport: v, keepOut: [list])
        XCTAssertFalse(try XCTUnwrap(kept.expand).rect.intersects(list), "★ the expand unit stays off the open list")
        // group scope (no expand knob): right, or left at the right edge
        XCTAssertFalse(H.layout(floor: CGPoint(x: 500, y: 500), rawKnob: nil, depthBox: 82, expandBox: 88, viewport: v).depth.boxOnLeft)
        XCTAssertTrue(H.layout(floor: f, rawKnob: nil, depthBox: 82, expandBox: 88, viewport: v).depth.boxOnLeft)
        // ★ RED CONTROL: today the boxes always sit right — off the screen here
        let old = H.oldLayout(floor: f, rawKnob: CGPoint(x: f.x, y: f.y + 20))
        XCTAssertGreaterThan(old.depth.rect.maxX, v.width, "★ RED CONTROL: today's depth box runs off the screen")
    }

    // MARK: EXPAND-DRAG-DIR

    /// The disc drawn pushed out (72 pt) while the true knob is 20 pt from the floor and 10 mm further out projects at 39 pt
    /// (the probe's first view of his l-bracket): a +40 pt drag outward grows the expand.
    func testAPushedDiscStillDragsOutward() {
        let raw = CGPoint(x: 20, y: 0), drawn = CGPoint(x: 72, y: 0), out = CGPoint(x: 39, y: 0)
        let grown = H.dragExpand(seed: 0, translation: CGSize(width: 40, height: 0), knob: raw, outward: out)
        XCTAssertGreaterThan(grown, 0, "★ outward grows (\(grown) mm)")
        XCTAssertEqual(grown, 2, accuracy: 1e-9, "19 pt per 10 mm is short: #354's 0.05 mm per point, along the knob's direction")
        // the plan's own numbers (drawn 72, true 20, out 60): outward grows too
        XCTAssertGreaterThan(H.dragExpand(seed: 0, translation: CGSize(width: 40, height: 0), knob: raw, outward: CGPoint(x: 60, y: 0)), 0)
        // a long projection: the 10 mm sets mm per point
        XCTAssertEqual(H.dragExpand(seed: 0, translation: CGSize(width: 30, height: 0), knob: raw, outward: CGPoint(x: 80, y: 0)), 5, accuracy: 1e-9)
        // ★ RED CONTROL: today the drag read out − DRAWN disc: backwards
        H.controlOldDrag = true
        defer { H.controlOldDrag = false }
        let old = H.dragExpand(seed: 0, translation: CGSize(width: 40, height: 0), knob: drawn, outward: out)
        XCTAssertLessThan(old, 0, "★ RED CONTROL: today the same drag shrank it (\(old) mm)")
    }

    /// A knob pointing LEFT whose 10 mm projects short (15 pt): a −40 pt drag (outward, to the left) grows the expand.
    func testAShortProjectionPointingLeftDragsOutward() {
        let raw = CGPoint(x: -20, y: 0), drawn = CGPoint(x: -72, y: 0), out = CGPoint(x: -60, y: 0)
        let r = H.dragExpand(seed: 0, translation: CGSize(width: -40, height: 0), knob: raw, outward: CGPoint(x: -35, y: 0))
        XCTAssertEqual(r, 2, accuracy: 1e-9, "★ outward (left) grows")
        XCTAssertEqual(H.dragExpand(seed: 0, translation: CGSize(width: -40, height: 0), knob: raw, outward: out), 10, accuracy: 1e-9,
                       "the plan's numbers (true −20, out −60: 40 pt per 10 mm): 40 pt outward = 10 mm")
        XCTAssertEqual(H.dragExpand(seed: 0, translation: CGSize(width: 4, height: 0), knob: nil, outward: nil), 0, accuracy: 1e-9,
                       "no direction: #354's horizontal scrub and its snap to 0 (unchanged)")
        // ★ RED CONTROL: today (drawn −72, out −60: 12 pt, short ⇒ plain horizontal) the same drag shrank it
        H.controlOldDrag = true
        defer { H.controlOldDrag = false }
        XCTAssertLessThan(H.dragExpand(seed: 0, translation: CGSize(width: -40, height: 0), knob: drawn, outward: out), 0,
                          "★ RED CONTROL: today it shrank")
    }
}
