// IPadNotes1109Tests — his iPad notes 11-09 (relayed by 362; his 2040 Extrusion Stand, install 8e1b257f), the pure parts:
//   (1)   a tap on a PIECE routes into the lattice list, non-destructively (LatticeLibraryTap.route(piece:));
//   (2.2) a zone (a lattice group with no faces) survives every empty-group sweep, and that is never saved;
//   (3.1) the Expand line's words;
//   (3.3) the number pad opens to its number's SIDE, the side with more room — never above or below it.
// The page parts on his stand: HisStandNotes1109HostedTests.
import XCTest
import CoreGraphics
import SwiftUI
@testable import TopOptFlows

final class IPadNotes1109Tests: XCTestCase {

    /// ★ (2.2) "He adds a zone, picks a group, then de-picks → the zone is GONE (Lattice zones 2 → 0)": every sweep of empty
    /// groups dropped the zones (a zone holds no faces). Kept ones stay through each; the zone's trash still removes it.
    func testAZoneSurvivesEverySweep() {
        var l = SelectionModel.latticeList(adopting: [])
        let a = l.addGroup()
        l.addFaces([1, 2], to: a)
        let z = l.addGroup()   // a zone: no faces, no regions
        l.setActive(a)
        var control = l
        control.clearActive()
        XCTAssertFalse(control.groups.contains { $0.id == z }, "control: an empty group nobody keeps is swept, as before")

        l.keepWhenEmpty([z])
        l.clearActive()
        XCTAssertTrue(l.groups.contains { $0.id == z }, "★ a de-pick (clearActive) keeps the zone")
        let b = l.addGroup()
        l.addFaces([3], to: b)
        XCTAssertTrue(l.groups.contains { $0.id == z }, "★ a face added to a group keeps it")
        l.addRegions([100], to: b)
        l.removeRegions([100])
        XCTAssertTrue(l.groups.contains { $0.id == z }, "★ regions added and dropped keep it")
        l.pickFaces([4])
        l.pickFaces([4])
        XCTAssertTrue(l.groups.contains { $0.id == z }, "★ a face picked in and out keeps it")
        l.remove(z)
        XCTAssertFalse(l.groups.contains { $0.id == z }, "the zone's trash still removes it")
        let e = l.addGroup()
        l.setActive(b)
        l.clearActive()
        XCTAssertFalse(l.groups.contains { $0.id == e }, "control: after it, an empty face group is still swept")
    }

    /// ★ (2.2) The kept set is the project's zones, handed over on every edit: it is never written to the project file, and
    /// two lists that differ only in it are equal.
    func testTheKeptSetIsNeverSaved() throws {
        var l = SelectionModel.latticeList(adopting: [])
        let z = l.addGroup()
        l.keepWhenEmpty([z])
        let data = try JSONEncoder().encode(l)
        let keys = Set(try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any]).keys)
        XCTAssertEqual(keys, ["groups", "activeGroupID", "nextColor", "numbered"], "★ the file's keys are what they were")
        let back = try JSONDecoder().decode(SelectionModel.self, from: data)
        XCTAssertEqual(back, l, "★ equal without the kept set")
    }

    /// ★ (1) A tapped piece: held (itself, a region it was cut from, or the whole face under it) → that group is picked and
    /// nothing moves; free → it grows the open group, or starts one. Never a steal.
    func testAPieceRoutesIntoTheLatticeListWithoutTakingAnything() {
        var s = SelectionModel.latticeList(adopting: [])
        let g = LatticeLibraryTap.route(piece: 101, lineage: [100], faces: [5], selection: &s)
        XCTAssertNotNil(g)
        XCTAssertEqual(s.groups.count, 1, "★ a free piece with nothing open starts a group")
        XCTAssertEqual(s.group(forRegion: 101)?.id, g)
        XCTAssertEqual(s.activeGroupID, g, "… and it is the open one (its role picker shows)")
        XCTAssertEqual(LatticeLibraryTap.route(piece: 102, lineage: [100], faces: [5], selection: &s), g, "★ the next free piece grows it")
        XCTAssertEqual(s.group(forRegion: 102)?.id, g)

        s.clearActive()
        let h = s.addGroup()
        s.addFaces([9], to: h)
        XCTAssertEqual(LatticeLibraryTap.route(piece: 101, lineage: [100], faces: [5], selection: &s), g, "★ a held piece picks its group")
        XCTAssertEqual(s.activeGroupID, g)
        XCTAssertEqual(s.groups.first { $0.id == h }?.faces, [9], "nothing moves")
        XCTAssertEqual(s.groups.first { $0.id == g }?.regionIDs, [101, 102], "nothing is added twice")

        var t = SelectionModel.latticeList(adopting: [])
        let p = t.addGroup()
        t.addRegions([100], to: p)
        t.clearActive()
        XCTAssertEqual(LatticeLibraryTap.route(piece: 101, lineage: [100], faces: [5], selection: &t), p,
                       "★ a piece of a region a group holds picks that group")
        XCTAssertNil(t.group(forRegion: 101), "… and is not added beside its parent")

        var u = SelectionModel.latticeList(adopting: [])
        let q = u.addGroup()
        u.addFaces([5], to: q)
        u.clearActive()
        XCTAssertEqual(LatticeLibraryTap.route(piece: 101, lineage: [], faces: [5], selection: &u), q,
                       "★ a piece of a face a group holds whole picks that group")
        XCTAssertNil(u.group(forRegion: 101))
    }

    /// ★ (3.3) "it moves to the side and ALWAYS shows whole, never cut at the bottom or top — everywhere it opens": the pad
    /// opens beside its number, on the side with more room (a side popover slides up or down to stay whole).
    func testThePadOpensBesideItsNumberOnTheSideWithRoom() {
        let w: CGFloat = 1376
        XCTAssertTrue(NumberPadPlacement.opensRight(anchor: CGRect(x: 200, y: 980, width: 74, height: 32), windowWidth: w),
                      "★ a number in the Selections panel: the pad on its right")
        XCTAssertFalse(NumberPadPlacement.opensRight(anchor: CGRect(x: 1260, y: 980, width: 74, height: 32), windowWidth: w),
                       "★ Settings › Protect skin (his shot): the pad on its left")
        for x in stride(from: CGFloat(0), through: 1300, by: 50) {
            for y in [CGFloat(0), 500, 1000] {
                let e = NumberPadPlacement.arrowEdge(anchor: CGRect(x: x, y: y, width: 74, height: 32), windowWidth: w)
                XCTAssertTrue(e == .leading || e == .trailing, "★ never above or below its number (\(x), \(y)): \(e)")
            }
        }
        #if os(macOS)
        XCTAssertEqual(NumberPadPlacement.arrowEdge(anchor: CGRect(x: 200, y: 0, width: 74, height: 32), windowWidth: w), .trailing,
                       "a Mac popover attaches at the number's own edge")
        #else
        XCTAssertEqual(NumberPadPlacement.arrowEdge(anchor: CGRect(x: 200, y: 0, width: 74, height: 32), windowWidth: w), .leading,
                       "the iPad's edge is the pad's arrow")
        #endif
    }

    /// ★ (3.2) The ± handle's place along the face moves exactly with the value — a millimetre of travel is a millimetre of
    /// Expand above 0 — and is one-to-one both ways; it stands 72 pt out on screen at 0, and below 0 it moves back toward
    /// the prism's end, never through it.
    func testTheExpandHandleMovesWithItsValue() {
        let b = LatticeSetupHandles.expandBaseMM(ptPerMM: 3)
        XCTAssertEqual(b * 3, LatticeSetupHandles.expandBasePT, accuracy: 1e-9, "72 pt out at 0")
        XCTAssertEqual(LatticeSetupHandles.expandBaseMM(ptPerMM: 100), 8, "never under 8 mm")
        var last = -Double.infinity
        for e in stride(from: LatticeSlabExpand.minMM, through: LatticeSlabExpand.maxMM, by: 0.5) {
            let s = LatticeSetupHandles.expandOffsetMM(e, baseMM: b)
            XCTAssertGreaterThanOrEqual(s, 0, "★ never through the prism's end (\(e) mm)")
            XCTAssertGreaterThan(s, last, "★ one way: more Expand, further out (\(e) mm)")
            XCTAssertEqual(LatticeSetupHandles.expandMM(offsetMM: s, baseMM: b), e, accuracy: 1e-9, "★ and back (\(e) mm)")
            last = s
        }
        XCTAssertEqual(LatticeSetupHandles.expandOffsetMM(12, baseMM: b) - LatticeSetupHandles.expandOffsetMM(2, baseMM: b), 10,
                       accuracy: 1e-9, "★ above 0, 10 mm of travel is 10 mm of Expand")
    }

    /// ★ (3.2) The finger's Expand: a finger over any point of the handle's path — along the face, and deeper by as much
    /// (the prism's far end goes deeper by the Expand) — reads that point's own Expand, either side of 0.
    func testAFingerOnTheHandlesPathReadsItsExpand() {
        let end = SIMD3<Float>(4, -2, 7), along = SIMD3<Float>(1, 0, 0), deep = SIMD3<Float>(0, 0, -1)
        let b = 18.0, now = 5.0
        for e in [-40.0, -12, -0.5, 0, 0.5, 3, 12, 40] {
            let at = end + deep * Float(e - now) + along * Float(LatticeSetupHandles.expandOffsetMM(e, baseMM: b))
            let got = LatticeSetupHandles.expandNearest(rayOrigin: at - SIMD3<Float>(0, 100, 0), rayDir: SIMD3<Float>(0, 1, 0),
                                                        end: end, along: along, deep: deep, now: now, baseMM: b)
            XCTAssertEqual(got ?? .nan, e, accuracy: 1e-3, "★ a finger on the handle at \(e) mm reads \(e) mm")
        }
    }

    /// ★ (2.1, ruling (a) 19:21Z) A Protect skin group's face says what it is — "Protect skin · 4 mm" — not "No lattice".
    func testAProtectSkinFaceSaysProtectSkin() {
        XCTAssertEqual(LatticeSetupCopy.faceValue(role: .exclude, groupHasRole: true, skin: true, mm: "4 mm"), "Protect skin \u{00B7} 4 mm")
        XCTAssertEqual(LatticeSetupCopy.faceValue(role: .exclude, groupHasRole: true, skin: false, mm: "4 mm"), "No lattice \u{00B7} 4 mm",
                       "control: a No lattice face as before")
        XCTAssertEqual(LatticeSetupCopy.faceValue(role: .include, groupHasRole: true, skin: true, mm: "4 mm"), "4 mm",
                       "a face set to Lattice in a Protect skin group: its depth")
        XCTAssertEqual(LatticeSetupCopy.faceValue(role: nil, groupHasRole: false, skin: false, mm: "4 mm"), "\u{2014}")
        XCTAssertEqual(LatticeSetupCopy.faceValue(role: nil, groupHasRole: true, skin: false, mm: "4 mm"), LatticeSetupCopy.off)
        XCTAssertEqual(LatticeSetupCopy.notLatticed(skin: true), "Protect skin", "its This face choice")
    }

    /// (3.1, 3.2) The Expand's words on the part's ± handle.
    func testTheExpandReadsWithItsSign() {
        XCTAssertEqual(LatticeSetupCopy.expandValue(0), "0 mm")
        XCTAssertTrue(LatticeSetupCopy.expandValue(2).hasPrefix("+"))
        XCTAssertTrue(LatticeSetupCopy.expandValue(-1.5).hasPrefix("\u{2212}"))
        XCTAssertTrue(LatticeSetupCopy.expandValue(-1.5).hasSuffix(" mm"))
    }
}
