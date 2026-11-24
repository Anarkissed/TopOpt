// Notes27FlowTests — ★ his iPad notes 2026-11-23 ~23:45 EST on release 17 (notes27, builder G "flow27"), model tests and pins:
//   G1 (his note 5) "The animation for regular lattices should *show* a regular lattice, and not an organic one. I picture
//      something like a bunch of hexagons getting put one after another."
//   G2 (his note 7) "tapping the orange marker should open up the notification again as well as an "x" next to it so that it
//      can be closed."
//   G3 (his 11-24 ~00:20) "add another button to the right of that called "Part" that leads to the list of the versions of the
//      part rather than all the way back to the project ... making it part of the same pill, but separated with a "|"."
// Hosted (his two iPad sizes): Notes27FlowHostedTests. The offscreen render (G1's frames, looked at) lands in
// <tmp>/topopt-evidence/notes27-flow (EvidenceOut; the path is printed).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import UniformTypeIdentifiers
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class Notes27FlowTests: XCTestCase {
    override func tearDown() {
        LatticeMacMake.shared.reset()
        LatticeFileSpot.shared.clear()
        AppPopups.shared.current = nil
        super.tearDown()
    }

    // MARK: G1 · the cell lattice's card shows hexagons

    /// ★ The press says the job's lattice kind, and each press sets it: Organic's (as today, no kind given) the vines, a cell
    /// lattice's the hexagons; a cell lattice's never carries over to the next Organic press.
    func testEachPressSaysItsLatticeKind() {
        let m = LatticeMacMake.shared
        m.begin(project: UUID(), path: nil, cancel: {})
        XCTAssertEqual(m.kind, .organic, "Organic's press: the vines")
        m.begin(project: UUID(), path: nil, fileOnly: true, kind: .cells, onMac: false, cancel: {})
        XCTAssertEqual(m.kind, .cells, "★ a cell lattice's press: the hexagons")
        XCTAssertEqual(m.stage, LatticeMacMakeCopy.makingFile, "the rest of the press as before")
        m.ended()
        XCTAssertEqual(m.kind, .cells, "a closing card never swaps its animation")
        m.begin(project: UUID(), path: nil, cancel: {})
        XCTAssertEqual(m.kind, .organic, "★ the next Organic press: the vines again")
    }

    /// ★ The pieces in place: the cell lattice's press (after Organic's branch has returned) says `.cells`; Organic's press says
    /// no kind (the vines); the card draws the animation of the press's kind, never the vines alone. RED CONTROL: release 17's
    /// card drew `LatticeMacMakeVines()` for every press.
    func testTheCellLatticesPressPicksTheHexagons() throws {
        let ws = try FlexibleSource.code("WorkspacePlaceholder.swift")
        let start = try XCTUnwrap(ws.range(of: "    private func startLatticeRun(_ request: RunRequest) {"))
        let end = try XCTUnwrap(ws.range(of: "    private func launchFileRun(", range: start.upperBound..<ws.endIndex))
        let body = String(ws[start.upperBound..<end.lowerBound])
        XCTAssertEqual(body.components(separatedBy: "LatticeMacMake.shared.begin(").count - 1, 2, "the two presses")
        XCTAssertEqual(body.components(separatedBy: "kind: .cells,").count - 1, 1, "★ one says the cells")
        let organic = try XCTUnwrap(body.range(of: "if LatticeLayoutPreview.organic(project.lattice) {"))
        let organicReturn = try XCTUnwrap(body.range(of: "\n            return\n        }\n", range: organic.upperBound..<body.endIndex))
        let cells = try XCTUnwrap(body.range(of: "kind: .cells,"))
        XCTAssertGreaterThan(cells.lowerBound, organicReturn.upperBound, "★ the cells' press is the one after Organic's branch")
        let organicPress = String(body[organic.upperBound..<organicReturn.lowerBound])
        XCTAssertFalse(organicPress.contains("kind:"), "Organic's press keeps the vines")
        let cellPress = String(body[organicReturn.upperBound...])
        XCTAssertTrue(cellPress.contains("LatticeMacMake.shared.begin(project: project.id, path: project.importedFile?.path, run: r, "
            + "fileOnly: true,\n" + String(repeating: " ", count: 36) + "kind: .cells,"), "★ the cell lattice's press")
        let mac = try FlexibleSource.code("LatticeMacMake.swift")
        XCTAssertTrue(mac.contains("LatticeMacMakeAnimation(kind: make.kind)"), "★ the card draws the press's kind")
        let card = try XCTUnwrap(mac.range(of: "struct LatticeMacMakeModal: View {"))
        let cardEnd = try XCTUnwrap(mac.range(of: "    private func timeLine(", range: card.upperBound..<mac.endIndex))
        XCTAssertFalse(mac[card.upperBound..<cardEnd.lowerBound].contains("LatticeMacMakeVines()"),
                       "★ RED CONTROL (release 17): the card drew the vines for every press")
        let anim = try XCTUnwrap(mac.range(of: "struct LatticeMacMakeAnimation: View {"))
        let animBody = String(mac[anim.upperBound...].prefix(900))
        XCTAssertTrue(animBody.contains("case .organic:\n                LatticeMacMakeVines()"), "Organic keeps the vines")
        XCTAssertTrue(animBody.contains("case .cells:\n                LatticeMacMakeCells()"), "★ the cells: the hexagons")
        // never frozen: the hexagons run on the animation clock, as the vines do
        let hex = try XCTUnwrap(mac.range(of: "struct LatticeMacMakeCells: View {"))
        XCTAssertTrue(mac[hex.upperBound...].prefix(400).contains("TimelineView(.animation) { ctx in"), "★ never frozen")
    }

    /// ★ "a bunch of hexagons getting put one after another": the honeycomb in the card's frame (the vines' 220 × 150) is 28
    /// flat-topped hexagons wholly inside it, never overlapping, each put BESIDE the one before (sharing a strut), the first on
    /// the floor (the bottom row), the last at the top.
    func testTheHoneycombIsHexagonsPutOneBesideTheLast() {
        let size = LatticeMacMakeAnimation.size
        XCTAssertEqual(size, CGSize(width: 220, height: 150), "★ the vines' size")
        let (r, c) = LatticeMacMakeCells.layout(size)
        XCTAssertEqual(c.count, LatticeMacMakeCells.columns * LatticeMacMakeCells.rows)
        XCTAssertEqual(c.count, 28)
        XCTAssertGreaterThan(r, 15, "cells big enough to read as a lattice")
        let s3 = CGFloat(3).squareRoot(), pad = LatticeMacMakeCells.line / 2
        for p in c {
            for i in 0..<6 {
                let a = Double(i) * .pi / 3
                let q = CGPoint(x: p.x + CGFloat(cos(a)) * r, y: p.y + CGFloat(sin(a)) * r)
                XCTAssertTrue(CGRect(origin: .zero, size: size).insetBy(dx: pad, dy: pad).contains(q), "★ inside the frame: \(q)")
            }
        }
        for i in c.indices {
            for j in c.indices where j > i {
                XCTAssertGreaterThan(hypot(c[i].x - c[j].x, c[i].y - c[j].y), s3 * r - 0.01, "never overlapping: \(i), \(j)")
            }
        }
        for i in c.indices.dropFirst() {
            XCTAssertEqual(hypot(c[i].x - c[i - 1].x, c[i].y - c[i - 1].y), s3 * r, accuracy: 0.01,
                           "★ cell \(i) is put beside cell \(i - 1) (they share a strut)")
        }
        let lowest = c.map(\.y).max() ?? 0, highest = c.map(\.y).min() ?? 0
        XCTAssertGreaterThanOrEqual(c[0].y, lowest - s3 * r / 2 - 0.01, "★ the first on the floor")
        XCTAssertLessThanOrEqual(c[c.count - 1].y, highest + s3 * r / 2 + 0.01, "the last at the top")
        // the portrait card is the same card: one size for both
        XCTAssertEqual(LatticeMacMakeCells.layout(size).centres, c)
    }

    /// ★ One after another, then again, never frozen: no cell at the cycle's start, more and more through the fill (one at a
    /// time), all 28 down at 80 %, the same a cycle later. RED CONTROL: a frozen clock would give the same count throughout.
    func testTheCellsArePutOneAfterAnotherAndItLoops() {
        let cy = LatticeMacMakeCells.cycle, base = 800_000_000.0 - 800_000_000.0.truncatingRemainder(dividingBy: cy)
        XCTAssertEqual(LatticeMacMakeCells.placed(at: base), 0, "a new cycle starts empty")
        var last = 0, seen = Set<Int>()
        for k in 0...82 {
            let t = base + cy * 0.82 * Double(k) / 82
            let n = LatticeMacMakeCells.placed(at: t)
            XCTAssertGreaterThanOrEqual(n, last, "never fewer while it fills")
            XCTAssertLessThanOrEqual(n - last, 1, "★ one after another, never a block at once")
            last = n; seen.insert(n)
        }
        XCTAssertEqual(last, 28, "★ all down as the fill ends")
        XCTAssertLessThan(LatticeMacMakeCells.placed(at: base + cy * 0.78), 28, "★ the last put just as the fill ends")
        XCTAssertGreaterThan(seen.count, 20, "★ it moves on through the fill")
        XCTAssertEqual(LatticeMacMakeCells.moment(base + cy * 0.99).fade, 0.05, accuracy: 0.01, "then it fades")
        for f in [0.1, 0.37, 0.62, 0.79] {
            XCTAssertEqual(LatticeMacMakeCells.placed(at: base + cy * f), LatticeMacMakeCells.placed(at: base + cy * (f + 3)),
                           "★ and fills again, the same")
        }
    }

    /// ★ THE OFFSCREEN RENDER (looked at): the hexagon animation drawn at six moments of one cycle, and the vines beside it, on
    /// the card's dark glass, at 2×. Measured: purple struts present, more of them as the fill goes on (it moves), the first
    /// cells at the bottom, gone at the cycle's end; and the vines' picture is not the hexagons'.
    func testTheHexagonAnimationRendered() throws {
        let size = LatticeMacMakeAnimation.size, cy = LatticeMacMakeCells.cycle
        let base = 800_000_000.0 - 800_000_000.0.truncatingRemainder(dividingBy: cy)
        let moments = [0.06, 0.2, 0.4, 0.6, 0.8, 0.95].map { base + cy * $0 }
        func frame(_ t: TimeInterval) -> some View {
            Canvas { g, s in LatticeMacMakeCells.draw(g, size: s, t: t) }.frame(width: size.width, height: size.height)
        }
        func lit(_ img: CGImage) -> (count: Int, bottom: Int, top: Int, purple: Int) {
            let rep = NSBitmapImageRep(cgImage: img)
            var n = 0, bottom = 0, top = 0, purple = 0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    // a strut or a node at full strength (the renderer blends in linear light: a settled strut sums ~1.5, the
                    // newest cell's faint fill ~0.9, a strut faded to a quarter ~0.85, the card's glass 0.3)
                    guard c.redComponent + c.greenComponent + c.blueComponent > 1.2 else { continue }
                    n += 1
                    if y > rep.pixelsHigh / 2 { bottom += 1 } else { top += 1 }
                    if c.blueComponent > c.redComponent + 0.15, c.blueComponent > c.greenComponent + 0.15 { purple += 1 }
                }
            }
            return (n, bottom, top, purple)
        }
        func render<V: View>(_ v: V) throws -> CGImage {
            let r = ImageRenderer(content: v.background(Color(.sRGB, red: 0.09, green: 0.09, blue: 0.12, opacity: 1))
                .environment(\.colorScheme, .dark))
            r.scale = 2
            return try XCTUnwrap(r.cgImage, "the render")
        }
        var counts: [(count: Int, bottom: Int, top: Int, purple: Int)] = []
        for t in moments { counts.append(lit(try render(frame(t)))) }
        print("NOTES27-G1 hexagon frames (lit px, bottom/top, purple): \(counts.map { "\($0.count) \($0.bottom)/\($0.top) \($0.purple)" })")
        XCTAssertGreaterThan(counts[0].count, 0, "the first cells are drawn")
        XCTAssertGreaterThan(counts[0].bottom, counts[0].top * 3, "★ the first cells on the floor")
        for i in 1..<5 { XCTAssertGreaterThan(counts[i].count, counts[i - 1].count, "★ more cells as the fill goes on (it moves)") }
        XCTAssertGreaterThan(counts[4].purple, counts[4].count / 2, "★ the lattice's purple")
        XCTAssertLessThan(counts[5].count, counts[4].count / 3, "and it fades at the cycle's end")

        // the sheet, looked at: the six moments, then the vines (Organic's) for comparison, each on the card's glass
        let sheet = VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) { ForEach(0..<3, id: \.self) { i in frame(moments[i]) } }
            HStack(spacing: 10) { ForEach(3..<6, id: \.self) { i in frame(moments[i]) } }
            HStack(spacing: 10) {
                LatticeMacMakeVines().frame(width: size.width, height: size.height)
                LatticeMacMakeAnimation(kind: .cells)
                LatticeMacMakeAnimation(kind: .organic)
            }
        }.padding(10)
        let img = try render(sheet)
        let vines = lit(try render(LatticeMacMakeVines().frame(width: size.width, height: size.height)))
        print("NOTES27-G1 vines (lit px, bottom/top, purple): \(vines.count) \(vines.bottom)/\(vines.top) \(vines.purple)")
        let dir = EvidenceOut.dir("notes27-flow")
        let url = dir.appendingPathComponent("G1_hexagons_six_moments_and_vines.png")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        print("NOTES27-G1 wrote \(url.path)")
    }

    // MARK: G2 · the marker reopens the pop-up; its x takes it away

    /// ★ The spot keeps the pop-up it came from: the ring's tap raises it again (and again), the marker staying; the x clears
    /// both. RED CONTROL: a spot marked with no pop-up (release 17's mark) raises nothing.
    func testTheSpotReopensItsPopUpAndTheXClearsIt() {
        let s = LatticeFileSpot.shared, v = UUID()
        var raised = 0
        s.mark(SIMD3(1, 2, 3), version: v, reopen: { raised += 1 })
        XCTAssertTrue(s.reopens)
        s.reopen(); s.reopen()
        XCTAssertEqual(raised, 2, "★ each tap raises the same pop-up")
        XCTAssertNotNil(s.spot, "★ the marker stays (its x takes it away)")
        s.clear()
        XCTAssertNil(s.spot, "★ the x: the marker gone")
        XCTAssertFalse(s.reopens)
        s.reopen()
        XCTAssertEqual(raised, 2, "nothing left to raise")
        s.mark(SIMD3(1, 2, 3), version: v)
        s.reopen()
        XCTAssertEqual(raised, 2, "RED CONTROL: a spot marked without its pop-up raises nothing")
    }

    /// ★ The x sits beside the ring with its own 44 pt target, never touching the ring's, wherever the spot is on the stage
    /// (flipped to the ring's left near the right edge, below near the top), and inside the stage.
    func testTheXSitsBesideTheRingClearOfIt() {
        let stage = CGSize(width: 1376, height: 1032), t = DSParts.target
        func box(_ p: CGPoint) -> CGRect { CGRect(x: p.x - t / 2, y: p.y - t / 2, width: t, height: t) }
        for p in [CGPoint(x: 688, y: 516), CGPoint(x: 1360, y: 516), CGPoint(x: 688, y: 10), CGPoint(x: 1360, y: 10),
                  CGPoint(x: 30, y: 1000), CGPoint(x: 24, y: 30)] {
            let o = LatticeFileSpotMarker.closeOffset(at: p, in: stage)
            let x = CGPoint(x: p.x + o.dx, y: p.y + o.dy)
            XCTAssertFalse(box(p).insetBy(dx: 0.5, dy: 0.5).intersects(box(x)), "★ clear of the ring at \(p)")
            XCTAssertLessThanOrEqual(hypot(o.dx, o.dy), 60, "★ beside it at \(p)")
            XCTAssertTrue(CGRect(origin: .zero, size: stage).contains(x), "on the stage at \(p): \(x)")
        }
        XCTAssertGreaterThan(LatticeFileSpotMarker.closeOffset(at: CGPoint(x: 688, y: 516), in: stage).dx, 0, "to the right")
        XCTAssertLessThan(LatticeFileSpotMarker.closeOffset(at: CGPoint(x: 1360, y: 516), in: stage).dx, 0, "flipped near the edge")
        XCTAssertGreaterThan(LatticeFileSpotMarker.closeOffset(at: CGPoint(x: 688, y: 10), in: stage).dy, 0, "below near the top")
    }

    /// ★ The pieces in place: "Show me" marks the spot with ITS pop-up (the same refusal, the same buttons: `latticeFilePopup`
    /// again); the marker's ring and x are buttons (release 17's marker let every tap through), each publishing its frame.
    func testTheMarkerIsWired() throws {
        let ws = try FlexibleSource.code("WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains("(LatticeFileRefusal.showMe, { showLatticeFileSpot(at, reopen: { latticeFilePopup(refusal, tryAgain: tryAgain) }) })"))
        XCTAssertTrue(ws.contains("func showLatticeFileSpot(_ at: SIMD3<Double>, reopen: (() -> Void)? = nil) {"))
        XCTAssertTrue(ws.contains("LatticeFileSpot.shared.mark(m, version: project.id, reopen: reopen)"))
        let rf = try FlexibleSource.code("LatticeFileRefusal.swift")
        let marker = try XCTUnwrap(rf.range(of: "struct LatticeFileSpotMarker: View {"))
        let body = String(rf[marker.upperBound...])
        XCTAssertTrue(body.contains("Button { spots.reopen() } label: {"), "★ the ring raises the pop-up")
        XCTAssertTrue(body.contains("Button { spots.clear() } label: {"), "★ the x takes the marker away")
        XCTAssertTrue(body.contains("publish(\"latticeFileSpot\")") && body.contains("publish(\"latticeFileSpotClose\")"))
        XCTAssertFalse(body.prefix(2600).contains(".allowsHitTesting(false)"), "★ RED CONTROL (release 17): taps went through it")
        XCTAssertTrue(rf.contains("TimelineView(.animation) { ctx in"), "the ring still breathes (never frozen)")
    }

    // MARK: G3 · ‹ the project | Part

    /// ★ (his 11-24 ~00:20) The pieces in place: every page that draws the top-left block gives it Part — the workspace's
    /// stages and Results (Back, landing on the part's versions), the Flexible page (its leave check first, then the same);
    /// the pill's "|" is the stage capsule's own divider; Back's target is unchanged.
    func testEveryTopLeftBlockHasPart() throws {
        let ws = try FlexibleSource.code("WorkspacePlaceholder.swift")
        XCTAssertEqual(ws.components(separatedBy: "TopLeftBlock(model:").count - 1, 2, "the workspace's two blocks")
        XCTAssertEqual(ws.components(separatedBy: "part: { model.backToPart() },").count - 1, 2, "★ both with Part")
        XCTAssertEqual(ws.components(separatedBy: "back: { model.backHome() },").count - 1, 2, "★ Back unchanged")
        let flex = try FlexibleSource.code("FlexibleStagePage.swift")
        XCTAssertTrue(flex.contains("process: project.process, back: { leave(then: onBack) },"), "the Flexible page's Back unchanged")
        XCTAssertTrue(flex.contains("{ leave(then: { back(); appModel.library.comeBackToPart(from: project.id) }) }"),
                      "★ the Flexible page's Part: its leave check, then Back landing on the part's versions")
        let block = try FlexibleSource.code("TopLeftBlock.swift")
        let capsule = try FlexibleSource.code("StageCapsule.swift")
        let rule = "Rectangle().fill(DS.Color.strokeStrong.color).frame(width: 1, height: 22)"
        XCTAssertTrue(capsule.contains(rule) && block.contains(rule), "★ the stage capsule's own \"|\"")
        XCTAssertTrue(block.contains("Button(action: part) {"))
        XCTAssertEqual(TopLeftBlock.partTitle, "Part", "★ his word")
        let app = try FlexibleSource.code("TopLeftPart.swift")
        XCTAssertTrue(app.contains("backHome()\n        if let folder { library.comeBackToPart(from: folder) }"),
                      "★ Part is Back (the version kept, the Library refreshed), landing on the part's page")
    }
}
#endif
