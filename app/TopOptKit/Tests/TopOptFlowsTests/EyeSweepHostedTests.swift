// EyeSweepHostedTests — ★ his iPad notes of 11-07 (3b; his answers via #362, 20:25Z): "Press an eye and drag: each row your
// finger passes FLIPS to the opposite of its own state (visible→hidden, hidden→visible). It works in BOTH directions, up or
// down. The list auto-scrolls while the finger is at its top or bottom edge, until release."
//
// On the fixture pad on Structural, Group 1 (the Lattice stage's own) holding n faces as Lattice, open. Lattice Setup's list
// has one sweep; every eye in it (the face rows', the group's line) is in it. A synthesised drag never reaches a gesture in
// an offscreen window (FlexibleR7U21CHandlesHostedTests' finding), so the test drives the very calls the eye's drag makes
// (begin, move, end), at the eyes' own frames, the page redrawing between moves.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit
import TopOptDesign

@MainActor
final class EyeSweepHostedTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            EyeSweep.recordLive = true
            LatticeSetupHandles.recordLive = true
            HardwareKeyboard.override = false
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            EyeSweep.live?.end()
            EyeSweep.live = nil
            EyeSweep.recordLive = false
            LatticeSetupHandles.recordLive = false
            LatticeSetupHandles.live = [:]
            LatticeSetupHandles.drawnPrisms = []
            LatticeSetupHandles.litThrough = []
            LatticeSetupHandles.livePick = nil
            LatticeSetupHandles.latticeTinted = []
            HardwareKeyboard.override = nil
        }
        try await super.tearDown()
    }

    /// The fixture pad on Structural; Group 1 holds `n` faces (the first from his Top) as Lattice, open.
    private func stage(_ size: CGSize = AppBuildHost.landscape13, faces n: Int) throws -> (AppBuildHost, ProjectModel, SelectionGroup) {
        LatticeSetupHandles.live = [:]
        let (h, p, _) = try ParityTopologyShots.pad(size, test: self)
        p.lattice.clearLatticeType()
        p.lattice.chooseLatticeType(.structural)
        try h.pickFromMenu("capsuleMenu", "Structural", what: "\(size): the stage menu")
        h.pump(1)
        let mesh = try XCTUnwrap(p.viewerMesh)
        let top = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" }, "his Top")
        let others = Set(mesh.faceIDs).subtracting(top.faces).sorted()
        for f in top.faces.prefix(1) + others.prefix(n - 1) {
            _ = p.latticeStageTap(face: f, loop: [f])
            if let g = p.latticeList.activeGroupID { p.lattice.groupRoles[g] = .include }
        }
        let g = try XCTUnwrap(p.latticeGroups.first, "Group 1")
        p.latticeList.setActive(g.id)
        h.pump(1)
        return (h, p, g)
    }

    private func faceEyes(_ p: ProjectModel, _ g: SelectionGroup) -> [(eye: String, ref: LatticeSelectableRef)] {
        p.latticeSelectableRefs(g).map { (eye: "latticeFaceEye-\($0.key)", ref: $0) }
    }

    private func centre(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

    /// The finger from where it is to `y`, in steps, the page redrawing between them.
    private func move(_ h: AppBuildHost, _ s: EyeSweep, from a: CGPoint, toY y: CGFloat, steps: Int = 8) {
        for i in 1...steps {
            s.move(to: CGPoint(x: a.x, y: a.y + (y - a.y) * CGFloat(i) / CGFloat(steps)))
            h.pump(0.05)
        }
        h.pump(0.3)
    }

    private func states(_ s: EyeSweep, _ eyes: [String]) -> [Bool?] { eyes.map { s.hidden($0) } }

    /// ★ 3b: press an eye and drag down — the pressed row flips at once, then each row the finger passes flips to the opposite
    /// of ITS OWN state (a hidden one shows); back up over a row, it is passed again and back as it was; release keeps them.
    func testDraggingDownTheEyesFlipsEachRowItPasses() throws {
        let (h, p, g) = try stage(faces: 4)
        let s = try XCTUnwrap(EyeSweep.live, "★ Lattice Setup's list has the sweep")
        let rows = Array(faceEyes(p, g).prefix(4))
        XCTAssertEqual(rows.count, 4, "premise: four face rows")
        let eyes = rows.map(\.eye)
        for e in eyes { XCTAssertNotNil(s.frame(e), "★ \(e) is in the sweep") }
        XCTAssertEqual(eyes, s.keys.filter { eyes.contains($0) }, "premise: the rows in the list's order")
        // a mixed column: the second row's prism hidden first, with its own tap (the tap stays the eye's)
        try h.tap(eyes[1], "the second row's eye")
        XCTAssertEqual(states(s, eyes), [false, true, false, false], "premise: one row hidden")

        let a = centre(try XCTUnwrap(s.frame(eyes[0])))
        s.begin(eyes[0], at: a)
        s.move(to: CGPoint(x: a.x, y: a.y + EyeSweep.minimumDistance))
        h.pump(0.3)
        XCTAssertEqual(states(s, eyes), [true, true, false, false], "★ the pressed row flips at once")
        move(h, s, from: a, toY: try XCTUnwrap(s.frame(eyes[3])).midY)
        XCTAssertEqual(states(s, eyes), [true, false, true, true], "★ each row passed flips to the opposite of its OWN state")
        XCTAssertFalse(LatticeSetupHandles.drawnPrisms.contains(rows[0].ref.key), "★ the first prism hidden")
        XCTAssertTrue(LatticeSetupHandles.drawnPrisms.contains(rows[1].ref.key), "★ the hidden second one shows")
        XCTAssertFalse(LatticeSetupHandles.drawnPrisms.contains(rows[3].ref.key), "★ the fourth hidden")
        move(h, s, from: CGPoint(x: a.x, y: try XCTUnwrap(s.frame(eyes[3])).midY), toY: try XCTUnwrap(s.frame(eyes[1])).midY)
        XCTAssertEqual(states(s, eyes), [true, false, false, false], "★ back up over the third and fourth: as they were")
        s.end()
        h.pump(0.5)
        XCTAssertFalse(s.isSweeping)
        XCTAssertEqual(states(s, eyes), [true, false, false, false], "★ release: the rows stay as the sweep left them")
        XCTAssertFalse(p.groupView.isHidden(g.id), "the group's own eye was not passed")
    }

    /// ★ 3b: "It works in BOTH directions": from the last row up, every row passed flips, the group's line included.
    func testDraggingUpFlipsTooTheGroupsLineIncluded() throws {
        let (h, p, g) = try stage(faces: 3)
        let s = try XCTUnwrap(EyeSweep.live, "★ Lattice Setup's list has the sweep")
        let eyes = faceEyes(p, g).map(\.eye)
        let line = "lattice-sel-eye-\(g.id.uuidString)"
        XCTAssertNotNil(s.frame(line), "★ the group's line's eye is in the column")
        let last = try XCTUnwrap(eyes.last)
        let a = centre(try XCTUnwrap(s.frame(last)))
        s.begin(last, at: a)
        move(h, s, from: a, toY: try XCTUnwrap(s.frame(eyes[0])).midY)
        XCTAssertEqual(states(s, eyes), eyes.map { _ in true }, "★ up from the last row: every face row passed is hidden")
        XCTAssertFalse(p.groupView.isHidden(g.id), "not yet up to the group's line")
        move(h, s, from: CGPoint(x: a.x, y: try XCTUnwrap(s.frame(eyes[0])).midY), toY: try XCTUnwrap(s.frame(line)).midY)
        XCTAssertTrue(p.groupView.isHidden(g.id), "★ on up over the group's line: its eye flips (the group hidden)")
        s.end()
        h.pump(0.5)
        XCTAssertTrue(p.groupView.isHidden(g.id), "release keeps it")
    }

    /// ★ 3b: "The list auto-scrolls while the finger is at its top or bottom edge, until release." In a window short enough
    /// that Group 1's rows overflow the list (the pad has seven faces: at 11″ and 13″ they all fit), the finger held at the
    /// list's foot brings the rows below the fold in, each flipping as it passes under the finger; released, the list stops.
    /// Then held at its top, the rows above come back in.
    func testTheListScrollsAtItsEdgesUntilRelease() throws {
        let (h, p, g) = try stage(CGSize(width: 1180, height: 640), faces: 18)
        let s = try XCTUnwrap(EyeSweep.live, "★ Lattice Setup's list has the sweep")
        let list = try XCTUnwrap(s.visible, "★ the sweep knows the list's scroll view")
        let eyes = faceEyes(p, g).map(\.eye).filter { s.frame($0) != nil }
        let below = eyes.filter { (s.frame($0)?.maxY ?? 0) > list.maxY + 1 }   // cut by the fold, or under it
        XCTAssertFalse(below.isEmpty, "premise: rows below the list's fold (\(eyes.count) rows, the list \(list))")
        let target = try XCTUnwrap(below.first)
        let was = try XCTUnwrap(s.hidden(target))
        let start = try XCTUnwrap(eyes.first { (s.frame($0)?.minY ?? -1) >= list.minY - 1 })
        let a = centre(try XCTUnwrap(s.frame(start)))
        s.begin(start, at: a)
        move(h, s, from: a, toY: list.maxY - 8)
        h.pump(3)   // held at the foot
        let now = try XCTUnwrap(s.frame(target))
        XCTAssertLessThanOrEqual(now.maxY, list.maxY + 1, "★ held at the foot, the list brought the row in (\(now) in \(list))")
        XCTAssertEqual(s.hidden(target), !was, "★ and it flipped as it passed under the finger")
        s.end()
        h.pump(0.3)
        let rest = eyes.compactMap { s.frame($0) }
        h.pump(1)
        XCTAssertEqual(eyes.compactMap { s.frame($0) }, rest, "★ released: the list stops")

        // the top edge: the rows scrolled away above come back in
        let above = eyes.filter { (s.frame($0)?.minY ?? .infinity) < list.minY - 1 }
        XCTAssertFalse(above.isEmpty, "premise: rows above the fold now")
        let up = try XCTUnwrap(above.last)
        let upWas = try XCTUnwrap(s.hidden(up))
        let low = try XCTUnwrap(eyes.last { (s.frame($0)?.maxY ?? .infinity) <= list.maxY + 1 })
        let b = centre(try XCTUnwrap(s.frame(low)))
        s.begin(low, at: b)
        move(h, s, from: b, toY: list.minY + 8)
        h.pump(3)
        let back = try XCTUnwrap(s.frame(up))
        XCTAssertGreaterThanOrEqual(back.minY, list.minY - 1, "★ held at the top, the rows above came back in (\(back))")
        XCTAssertEqual(s.hidden(up), !upWas, "★ flipping as they passed")
        s.end()
    }

    /// ★ 3b on the iPad: the drag that starts on an eye is the sweep's (above the list's scroll), and it makes these very calls;
    /// the eye's tap stays a button. Lattice Setup's list alone has the sweep (Topology's eyes stay taps).
    func testTheEyesDragIsTheSweeps() throws {
        let src = try FlexibleSource.code("EyeSweep.swift")
        XCTAssertTrue(src.contains(".highPriorityGesture("), "★ the eye's drag goes before the list's scroll")
        XCTAssertTrue(src.contains("if !sweep.isSweeping { sweep.begin(key, at: v.startLocation) }"), "★ begin")
        XCTAssertTrue(src.contains("sweep.move(to: v.location)"), "★ move")
        XCTAssertTrue(src.contains(".onEnded { _ in sweep.end() }"), "★ release")
        let parts = try FlexibleSource.code("DesignParts.swift")
        XCTAssertTrue(parts.contains(".eyeSweep(key, hidden: hidden, toggle: toggle)"), "★ every DSRowEye is in its list's sweep")
        let list = try FlexibleSource.code("SelectionsList.swift")
        XCTAssertTrue(list.contains(".environment(\\.eyeSweep, usesLatticeList ? sweep : nil)"), "★ Lattice Setup's list only")
        XCTAssertTrue(list.contains(".eyeSweep(\"\\(idPrefix)-sel-eye-\\(g.id.uuidString)\""), "★ the group's line's eye too")
    }
}
#endif
