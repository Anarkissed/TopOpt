// FaceChipTests — the chip's join button and its placement (FaceChipLayout).
//
// Lifted from #362 (claude/flexible-screens) at b472880b, app/TopOptKit/Tests/TopOptFlowsTests/FlexibleFaceChipTests.swift,
// with FaceChip / FaceChipLayout (reviewer ruling 2026-10-24 07:30). The same assertions. Changed only where the source reached
// Flexible:
//   * the join's source pins read FaceChip.swift (was FlexibleFaceChip.swift) through this file's own path, and its fill is
//     JoinButton.fill (was FlexibleJoinButton.fill);
//   * the dragged spots are keyed by plain strings (the source derived them with FlexibleFaceScope.chipKey);
//   * testAutoPlacementOrderAndTheKeepOuts: `keepOuts` takes the page's chrome as `chrome:` — the source's assertions that it
//     holds FlexibleLegendPlacement.gizmoFrame, FlexibleMainViewToggles.frame and FlexibleChromeLayout.pair.lattice are
//     Flexible-only and dropped; "the chip never sits on a keep-out" is kept, over a stand-in chrome (a top-left capsule, a
//     right-hand gizmo, a bottom-right pair);
// Dropped (Flexible-only): testTheDragGestureWritesTheSpotLiveAndLetsGoClear's pins of FlexibleOnModelLayer.swift (its two
// `dragged` assertions are kept, below), and testTheInfoShowsOnlyHisFourRowsFromTheDrawersOwnNumbers (FlexibleFaceStats,
// FlexibleOnModelLayer).
import XCTest
import SwiftUI
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FaceChipTests: XCTestCase {

    static let pad13p = CGSize(width: 1032, height: 1376)
    static let pad11p = CGSize(width: 834, height: 1194)
    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/TopOptFlows")

    // MARK: (c) the join button

    /// The label is EXACTLY "Add to Group C as lattice" (the group's own name), a filled DS-accent button, white semibold,
    /// ≥ 44 tall, the button trait. RED CONTROL: the mockup's rejected `.rowA` (fill-subtle + a tint stroke) is not this style.
    func testTheJoinIsAFilledButtonWithItsExactLabel() throws {
        XCTAssertEqual(SelectionsCopy.joinLabel("Group C"), "Add to Group C as lattice")
        XCTAssertEqual(JoinButton.fill, DS.Color.accent, "★ the DS accent fill (#0A84FF)")
        XCTAssertGreaterThanOrEqual(JoinButton.height, 44, "★ ≥ 44 pt")
        let src = try String(contentsOf: Self.sources.appendingPathComponent("FaceChip.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains(".accessibilityAddTraits(.isButton)"), "★ the button trait")
        XCTAssertTrue(src.contains(".font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)"), "★ a white semibold label")
        XCTAssertTrue(src.contains(".fill(JoinButton.fill.color)"), "★ filled")
        // ★ RED CONTROL: the rejected row (his image 2) — fill-subtle with a 1.5 pt tint stroke, an outlined title row
        let rejected = (fill: DS.Color.fillSubtle, stroke: 1.5)
        XCTAssertNotEqual(JoinButton.fill, rejected.fill, "★ RED CONTROL: not the outlined `.rowA` he rejected")
    }

    // MARK: (a) the drag and the leader

    func testADraggedChipKeepsItsSpotForThatFaceAndTheLeaderReAims() {
        let st = FaceChipState()
        let key3 = "face-3"
        st.spots[key3] = CGPoint(x: 600, y: 900)
        let size = FaceChipLayout.size(.member)
        let r = FaceChipLayout.clamped(CGRect(origin: st.spots[key3]!, size: size), viewport: Self.pad13p)
        XCTAssertEqual(r.origin, CGPoint(x: 600, y: 900), "★ the spot is kept for that face")
        // an orbit moves the face's projected centre: the chip stays, the leader re-aims
        for target in [CGPoint(x: 300, y: 600), CGPoint(x: 500, y: 1200), CGPoint(x: 900, y: 920)] {
            let s = FaceChipLayout.leaderStart(chip: r, target: target)
            XCTAssertTrue(r.insetBy(dx: -0.5, dy: -0.5).contains(s), "the leader starts on the chip's edge")
            XCTAssertTrue(abs(s.x - r.minX) < 0.5 || abs(s.x - r.maxX) < 0.5 || abs(s.y - r.minY) < 0.5 || abs(s.y - r.maxY) < 0.5,
                          "★ on its nearest edge, toward \(target)")
        }
        // another face: its own spot (none yet)
        XCTAssertNil(st.spots["face-5"], "dropped for a different face")
        // clamped 16 pt inside; let go over a keep-out, it slides to the nearest clear spot
        let off = FaceChipLayout.clamped(CGRect(x: -200, y: 5000, width: size.width, height: size.height), viewport: Self.pad13p)
        XCTAssertEqual(off.minX, 16); XCTAssertEqual(off.maxY, Self.pad13p.height - 16)
        let keep = [CGRect(x: 400, y: 400, width: 300, height: 300)]
        let let_go = FaceChipLayout.released(CGRect(x: 420, y: 420, width: size.width, height: size.height), viewport: Self.pad13p, keepOut: keep)
        XCTAssertFalse(keep[0].insetBy(dx: -8, dy: -8).intersects(let_go), "★ nudged off the keep-out")
        XCTAssertLessThan(hypot(let_go.minX - 420, let_go.minY - 420), 400, "to the nearest clear spot")
        // ★ RED CONTROL: the automatic placement ignores the drag (every frame it puts the chip back)
        let autoSpot = FaceChipLayout.auto(size: size, anchor: CGPoint(x: 600, y: 700), viewport: Self.pad13p, keepOut: [])
        XCTAssertNotEqual(autoSpot.origin, r.origin, "★ RED CONTROL: auto alone would move his chip back")
    }

    /// A drag's spot: where the finger moved it, clamped 16 pt inside.
    func testADragMovesTheChipUnderTheFingerClampedInside() {
        let r = FaceChipLayout.dragged(anchor: CGPoint(x: 500, y: 600), translation: CGSize(width: -120, height: 160),
                                       size: CGSize(width: 404, height: 150), viewport: Self.pad13p)
        XCTAssertEqual(r.origin, CGPoint(x: 380, y: 760))
        XCTAssertEqual(FaceChipLayout.dragged(anchor: CGPoint(x: 500, y: 600), translation: CGSize(width: -900, height: 0),
                                              size: CGSize(width: 404, height: 150), viewport: Self.pad13p).minX, 16, "clamped inside")
    }

    /// A stand-in page chrome at viewport `v`: the capsule under the name row, the gizmo on the right, the corner pair.
    static func chrome(_ v: CGSize) -> [CGRect] {
        [CGRect(x: 0, y: 0, width: StageCapsuleLayout.capsuleLeft + StageCapsuleLayout.capsuleMaxWidth + PageChrome.gap,
                height: StageCapsuleLayout.capsuleTop + StageCapsuleLayout.capsuleHeight),
         CGRect(x: v.width - 24 - 120, y: 140, width: 120, height: 120),
         CGRect(x: v.width - 24 - 420, y: v.height - 24 - 64, width: 420, height: 64)]
    }

    func testAutoPlacementOrderAndTheKeepOuts() {
        let size = FaceChipLayout.size(.new(join: true))
        let v = Self.pad13p
        let a = CGPoint(x: 700, y: 800)
        let above = FaceChipLayout.auto(size: size, anchor: a, viewport: v, keepOut: [])
        XCTAssertEqual(above.maxY, a.y - 56, accuracy: 0.5, "★ above the face's centre, 56 pt gap")
        // above blocked → below
        let below = FaceChipLayout.auto(size: size, anchor: a, viewport: v, keepOut: [CGRect(x: 0, y: a.y - 400, width: v.width, height: 300)])
        XCTAssertEqual(below.minY, a.y + 56, accuracy: 0.5, "★ else below")
        // the page's keep-outs: its chrome, plus the list (and what else is measured)
        let sel = CGRect(x: 24, y: 400, width: 348, height: 360)
        let keep = FaceChipLayout.keepOuts(chrome: Self.chrome(v), selections: sel, legend: CGRect(x: 760, y: 292, width: 248, height: 124),
                                           panel: nil, player: nil)
        XCTAssertTrue(keep.contains(sel))
        XCTAssertTrue(Self.chrome(v).allSatisfy { keep.contains($0) }, "the page's own chrome")
        for anchor in [CGPoint(x: 200, y: 600), CGPoint(x: 900, y: 300), CGPoint(x: 516, y: 1300), CGPoint(x: 516, y: 688)] {
            for vp in [Self.pad13p, Self.pad11p] {
                let k = FaceChipLayout.keepOuts(chrome: Self.chrome(vp), selections: CGRect(x: 24, y: 300, width: 348, height: 420), legend: nil,
                                                panel: nil, player: nil)
                let r = FaceChipLayout.auto(size: size, anchor: anchor, viewport: vp, keepOut: k)
                XCTAssertFalse(k.contains { $0.intersects(r) }, "★ the chip never sits on a keep-out (\(anchor) on \(vp))")
                XCTAssertTrue(r.minX >= 15.5 && r.maxX <= vp.width - 15.5, "inside the screen")
            }
        }
    }
}
