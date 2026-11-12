// FlexibleNewModelTests — "Upload new version" on a FLEXIBLE part, step A: the per-face setup on the new model's faces
// (FlexibleNewModel.carry / carryLattice; his picks 2026-11-12: a split pressed face → every piece pressed, same settings, same
// squeeze group; an edge or corner press re-found where its faces still meet; what finds no face kept and flagged). The match is
// a FaceMatch made by hand, so each case is exact; his pad A1_0003 is the control that nothing moves when no face moved.
import XCTest
@testable import TopOptFlows
@testable import TopOptKit

final class FlexibleNewModelTests: XCTestCase {

    func face(_ id: Int, kg: Double = 10, group: Int? = nil, role: String = "loaded") -> FlexibleFaceSettings {
        var f = FlexibleFaceSettings(faceRegionID: id, role: role, weightKg: kg, deepestMM: 4)
        f.squeezeGroup = group
        f.curveX = FlexCurve(x: [0, 0.4, 1], y: [0.2, 0.9, 0.2])
        return f
    }

    func match(_ m: [Int: [Int]]) -> FaceMatch {
        FaceMatch(map: Dictionary(uniqueKeysWithValues: m.map { (FaceID($0.key), $0.value.map { FaceID($0) }) }))
    }

    /// ★ HIS PICK 1: a pressed face the new model split — every piece pressed, the same settings, the same squeeze group.
    func testASplitPressedFaceIsPressedOnEveryPiece() {
        var s = FlexibleStageSettings()
        s.faces = [face(3, kg: 12, group: 2), face(5, group: 2)]
        let o = FlexibleNewModel.carry(s, match: match([3: [3, 40], 5: [5]]), faceRegions: nil)
        XCTAssertEqual(o.faces.map(\.faceRegionID), [3, 40, 5], "★ both pieces of face 3, in its place in the order")
        var piece = o.faces[1]
        piece.faceRegionID = 3
        XCTAssertEqual(piece, s.faces[0], "★ the piece has every setting of the face it came from")
        XCTAssertEqual(o.faces[1].squeezeGroup, 2, "★ in the same squeeze group")
        XCTAssertNil(o.newModel, "nothing waits for a face")
    }

    /// A moved face takes its new number; RED CONTROL: with no face moved, nothing changes.
    func testAMovedFaceTakesItsNewNumberAndNothingElseMoves() {
        var s = FlexibleStageSettings()
        s.faces = [face(3), face(5, role: "resting")]
        s.removedRegions = [7]
        let same = FlexibleNewModel.carry(s, match: match([3: [3], 5: [5], 7: [7]]), faceRegions: nil)
        XCTAssertEqual(same, s, "RED CONTROL: no face moved, nothing changes")
        let o = FlexibleNewModel.carry(s, match: match([3: [8], 5: [5], 7: [9]]), faceRegions: nil)
        XCTAssertEqual(o.faces.map(\.faceRegionID), [8, 5])
        XCTAssertEqual(o.removedRegions, [9], "a deleted face stays deleted on its new face")
    }

    /// ★ HIS PICK 3: a face that found none is KEPT, with its settings, and waits for him to pick its face.
    func testAFaceThatFoundNoneWaitsWithItsSettings() {
        var s = FlexibleStageSettings()
        s.faces = [face(3), face(5, kg: 7, group: 3)]
        let o = FlexibleNewModel.carry(s, match: match([3: [3]]), faceRegions: nil)
        XCTAssertEqual(o.faces.map(\.faceRegionID), [3])
        XCTAssertEqual(o.newModel?.lostFaces, [s.faces[1]], "★ kept, every setting with it")
        XCTAssertEqual(o.newModel?.lostCount, 1)
    }

    /// Two pressed faces the new model merged into one: the first takes it, the second waits (never two settings on one face).
    func testTwoMergedFacesTakeTheOneFaceOnce() {
        var s = FlexibleStageSettings()
        s.faces = [face(3, kg: 10), face(5, kg: 20)]
        let o = FlexibleNewModel.carry(s, match: match([3: [9], 5: [9]]), faceRegions: nil)
        XCTAssertEqual(o.faces.map(\.faceRegionID), [9])
        XCTAssertEqual(o.faces.first?.weightKg, 10, "the first face's settings")
        XCTAssertEqual(o.newModel?.lostFaces.map(\.faceRegionID), [5], "the other waits for a face")
    }

    /// A tilted face press follows its face like a face: a split one is a press on each piece (the first keeps its id).
    func testATiltedPressFollowsItsFace() {
        var s = FlexibleStageSettings()
        let p = FlexiblePress(regions: [3], direction: SIMD3(0, 0, -1), settings: face(3), drawnIn: .face(3), faceIndex: 0)
        s.presses = [p]
        let o = FlexibleNewModel.carry(s, match: match([3: [3, 40]]), faceRegions: nil)
        XCTAssertEqual(o.presses?.map(\.regions), [[3], [40]])
        XCTAssertEqual(o.presses?.first?.id, p.id, "the first piece keeps the press's id")
        XCTAssertEqual(o.presses?.last?.settings.faceRegionID, 40)
        XCTAssertEqual(o.presses?.last?.drawnIn, .face(3), "drawn in its old face's frame until core re-expresses it")
        let lost = FlexibleNewModel.carry(s, match: match([:]), faceRegions: nil)
        XCTAssertNil(lost.presses)
        XCTAssertEqual(lost.newModel?.lostPresses.map(\.id), [p.id], "★ a press that found no face waits")
    }

    /// ★ HIS PICK 2 (step A's half): an edge press's member faces take their new numbers and it is listed to re-find when the
    /// scene opens; a member that found none → the press waits for a face.
    func testAnEdgePressIsMatchedAndListedToReFind() {
        var s = FlexibleStageSettings()
        let members = [FlexibleStrip.Member(face: 1, root: 1, origin: .zero, away: [SIMD3(1, 0, 0)], capMM: 5),
                       FlexibleStrip.Member(face: 2, root: -1, origin: .zero, away: [SIMD3(0, 1, 0)], capMM: 5)]
        let strip = FlexibleStrip(kind: .edge, label: "Edge 9", order: 1, members: members)
        let p = FlexiblePress(regions: [2_000_001, 2_000_002], direction: SIMD3(0, -0.7, -0.7), settings: face(2_000_001), strip: strip)
        s.presses = [p]
        let o = FlexibleNewModel.carry(s, match: match([1: [11], 2: [12]]), faceRegions: nil)
        XCTAssertEqual(o.presses?.first?.strip?.members.map(\.face), [11, 12], "★ its faces' new numbers")
        XCTAssertEqual(o.presses?.first?.strip?.members.map(\.root), [11, -1], "a root follows its face; −1 stays")
        XCTAssertEqual(o.presses?.first?.regions, p.regions, "its sectors are re-derived on the new model, their numbers kept")
        XCTAssertEqual(o.newModel?.refind, [p.id], "★ re-found when the scene opens")
        XCTAssertEqual(o.newModel?.lostCount, 0)
        let gone = FlexibleNewModel.carry(s, match: match([1: [11]]), faceRegions: nil)
        XCTAssertEqual(gone.newModel?.lostPresses.map(\.id), [p.id], "★ a member found no face: the press waits")
        XCTAssertEqual(gone.newModel?.refind, [])
    }

    /// His Surface sector stays itself while it still holds a face; one whose faces are all gone finds none.
    func testASurfaceSectorKeepsItsNumberWhileItHoldsAFace() {
        var regions = FaceRegionModel()
        let id = regions.union(faces: [1], named: "Top A")
        var s = FlexibleStageSettings()
        s.faces = [face(FlexibleRegions.sectorBase + id)]
        let kept = FlexibleNewModel.carry(s, match: match([1: [1]]), faceRegions: regions)
        XCTAssertEqual(kept.faces.map(\.faceRegionID), [FlexibleRegions.sectorBase + id])
        var emptied = regions
        emptied.remapFaces { _ in [] }
        let lost = FlexibleNewModel.carry(s, match: match([:]), faceRegions: emptied)
        XCTAssertEqual(lost.newModel?.lostFaces.count, 1, "a sector whose faces are all gone waits for a face")
    }

    /// The face-prisms (the Flexible lattice itself): a face's key follows its face; a split face's value goes to each piece;
    /// one that found none is gone; never back to Auto.
    func testTheFacePrismsFollowTheirFaces() {
        let g = UUID()
        var l = LatticeSettings()
        l.selectableRoles = ["f:\(g.uuidString):3": .include, "f:\(g.uuidString):5": .include, "p:\(UUID().uuidString)": .include]
        l.selectableDepthMM = ["f:\(g.uuidString):3": 12]
        l.paintedIncludeFaces = [3, 6]
        let o = FlexibleNewModel.carryLattice(l, match: match([3: [3, 40], 6: [6]]))
        XCTAssertEqual(o.selectableRoles["f:\(g.uuidString):3"], .include)
        XCTAssertEqual(o.selectableRoles["f:\(g.uuidString):40"], .include, "★ the split face's piece is latticed the same")
        XCTAssertEqual(o.selectableDepthMM["f:\(g.uuidString):40"], 12, "★ at the same depth")
        XCTAssertNil(o.selectableRoles["f:\(g.uuidString):5"], "a face that found none has no prism")
        XCTAssertEqual(o.selectableRoles.keys.filter { $0.hasPrefix("p:") }.count, 1, "a zone (a shape, not a face) stays")
        XCTAssertEqual(o.paintedIncludeFaces, [3, 40, 6])
    }

    /// Every form a key names a face in takes its new number; a key naming no face is itself.
    func testKeysThatNameFaces() {
        let g = UUID().uuidString, press = UUID().uuidString
        let m = match([3: [30, 31], 12: [120], 4: [40], 1: [10], 7: [70], 9: [90]])
        XCTAssertEqual(FlexibleNewModel.remapKey("s:f12:f:\(g):3#1", m), "s:f120:f:\(g):30#1", "a section: its root and its prism")
        XCTAssertEqual(FlexibleNewModel.remapKey("rest:f12:2", m), "rest:f120:2")
        XCTAssertEqual(FlexibleNewModel.remapKey("side:f1.2", m), "side:f10.2")
        XCTAssertEqual(FlexibleNewModel.remapKey("skin:f7", m), "skin:f70")
        XCTAssertEqual(FlexibleNewModel.remapKey("hole:f9", m), "hole:f90")
        XCTAssertEqual(FlexibleNewModel.remapKey("face:4", m), "face:40", "a band chip's face")
        XCTAssertEqual(FlexibleNewModel.remapKey("cap:f:\(g):3", m), "cap:f:\(g):30")
        XCTAssertEqual(FlexibleNewModel.remapKey("p:\(press):1", m), "p:\(press):1", "a press's member index names no face")
        XCTAssertEqual(FlexibleNewModel.remapKey("r100", m), "r100", "his Surface sector keeps its own id")
        XCTAssertEqual(FlexibleNewModel.remapKey("floor", m), "floor")
        XCTAssertNil(FlexibleNewModel.remapKey("skin:f5", m), "a face that found none")
        XCTAssertEqual(FlexibleNewModel.remapKeyAll("f:\(g):3", m), ["f:\(g):30", "f:\(g):31"], "one key per piece")
    }

    /// RED CONTROL on his pad (A1_0003 as saved): every face matched to itself — nothing moves but the edge presses being listed
    /// to re-find; the file's other fields are byte-for-byte his.
    @MainActor
    func testHisPadWithNoFaceMovedKeepsEverything() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let lattice = r.project.lattice
        let s = try XCTUnwrap(lattice.flexible, "his pad is Flexible")
        let ids = Set(s.faces.map(\.faceRegionID) + (s.presses ?? []).flatMap { p in (p.strip?.members ?? []).flatMap { [$0.face, $0.root] } + p.regions }
                        + (s.removedRegions ?? [])).filter { $0 >= 0 && $0 < FlexibleRegions.sectorBase }
        let same = match(Dictionary(uniqueKeysWithValues: ids.map { ($0, [$0]) }))
        var o = FlexibleNewModel.carry(s, match: same, faceRegions: r.project.faceRegions)
        let strips = (s.presses ?? []).filter { $0.strip != nil }.map(\.id)
        XCTAssertEqual(o.newModel?.refind ?? [], strips, "the edge presses are listed to re-find")
        XCTAssertEqual(o.newModel?.lostCount ?? 0, 0, "nothing is lost")
        o.newModel = nil
        XCTAssertEqual(o, s, "★ RED CONTROL: with no face moved his setup is his")
        let l = FlexibleNewModel.carryLattice(lattice, match: same)
        XCTAssertEqual(l.selectableRoles, lattice.selectableRoles)
        XCTAssertEqual(l.selectableDepthMM, lattice.selectableDepthMM)
        print("FLEX-UPLOAD his pad: \(s.faces.count) faces, \((s.presses ?? []).count) presses (\(strips.count) edges/corners)")
    }

    /// A setup with nothing waiting writes no `newModel` key (every other project encodes byte-identical).
    func testNothingWaitingWritesNoKey() throws {
        var s = FlexibleStageSettings()
        s.faces = [face(3)]
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]   // (key order is unfixed otherwise: two encodes of one value differ)
        let data = try enc.encode(FlexibleNewModel.carry(s, match: match([3: [3]]), faceRegions: nil))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("newModel"))
        XCTAssertEqual(data, try enc.encode(s), "★ byte-identical")
    }
}
