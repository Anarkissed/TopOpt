// FlexibleSqueezeGroupsTests — the squeeze groups as values (task 2026-09-29-flexible-screens,
// round 4 batch D2; his img 4: "there needs to be a setting that says Groups faces together …
// group all of them together, or group two sides together with another two sides as a
// different group"; his answer 1: ONE force per group).
//   * every pressed face starts in Group 1; a resting face is in none — RED: a rule over every
//     face lists the resting ones;
//   * move / new / remove renumber 1…N (group 1 stored as nil) — a face alone makes no new
//     group, the only group is never removed;
//   * the group's ONE line fits 44 characters with its faces and its force ("Squeeze 10 kg",
//     "Squeeze 7–10 kg" for faces of their own weights from before groups);
//   * group colours are DS tokens and never purple — RED: the instrument sees groupPalette[4];
//   * a pinch is a conflict INSIDE a group; across groups it is shared material — RED: the old
//     rule turned every conflict into a blocker;
//   * old projects decode (squeezeGroup optional) — RED: a required field would not;
//   * the sims: each group, then "All at once" (only with two or more groups);
//   * separate squeezes combine FIRMER-wins, −1 stays −1 — RED: min-combine softens a voxel.
import XCTest
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

final class FlexibleSqueezeGroupsTests: XCTestCase {

    /// Four pressed faces (top A, top B, 3, 5) and three resting ones, like his project.
    static func his() -> FlexibleStageSettings {
        var s = FlexibleStageSettings(materialID: "varioshore_tpu")
        for r in [FlexibleHisProject.topA, FlexibleHisProject.topB, 3, 5] { s.setFace(FlexibleFaceSettings(faceRegionID: r)) }
        for r in [0, 2, 4] { s.setFace(FlexibleFaceSettings(faceRegionID: r, role: "resting")) }
        return s
    }

    func testEveryPressedFaceStartsInGroupOne() {
        let s = Self.his()
        let g = FlexibleSqueezeGroups.groups(s)
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g.first?.number, 1)
        XCTAssertEqual(g.first?.regions, [FlexibleHisProject.topA, FlexibleHisProject.topB, 3, 5], "the pressed faces only")
        XCTAssertNil(FlexibleSqueezeGroups.group(of: 0, in: s), "a resting face is in no group")
        // ★ RED CONTROL: a rule over EVERY face puts the resting faces in the group too
        XCTAssertEqual(s.faces.count, 7, "control: seven faces, three of them resting")
    }

    func testMoveNewAndRemoveRenumber() {
        var s = Self.his()
        XCTAssertEqual(FlexibleSqueezeGroups.newGroup(with: 3, in: &s), 2, "a new group, numbered after the last")
        XCTAssertEqual(FlexibleSqueezeGroups.groups(s).map(\.regions), [[FlexibleHisProject.topA, FlexibleHisProject.topB, 5], [3]])
        let two = try! XCTUnwrap(FlexibleSqueezeGroups.group(of: 3, in: s))
        FlexibleSqueezeGroups.move(5, to: two.id, in: &s)
        XCTAssertEqual(FlexibleSqueezeGroups.groups(s).map(\.regions), [[FlexibleHisProject.topA, FlexibleHisProject.topB], [3, 5]],
                       "his img 4: the sides in their own group")
        XCTAssertNil(s.face(FlexibleHisProject.topA)?.squeezeGroup, "group 1 is stored as nil")
        XCTAssertEqual(s.face(3)?.squeezeGroup, 2)
        // a face alone in its group makes no new group
        var alone = s
        FlexibleSqueezeGroups.move(FlexibleHisProject.topB, to: two.id, in: &alone)
        XCTAssertNil(FlexibleSqueezeGroups.newGroup(with: FlexibleHisProject.topA, in: &alone), "top A is alone: no new group")
        // removing group 1: its faces join the first other group, which becomes group 1
        FlexibleSqueezeGroups.remove(group: FlexibleSqueezeGroups.first, in: &s)
        let after = FlexibleSqueezeGroups.groups(s)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(Set(after[0].regions), Set([FlexibleHisProject.topA, FlexibleHisProject.topB, 3, 5]))
        XCTAssertTrue(s.loadedFaces.allSatisfy { $0.squeezeGroup == nil }, "renumbered: one group, stored as nil")
        // the only group is never removed
        FlexibleSqueezeGroups.remove(group: FlexibleSqueezeGroups.first, in: &s)
        XCTAssertEqual(FlexibleSqueezeGroups.groups(s).count, 1)
        // a resting face holds no group once normalised
        var r = Self.his()
        _ = FlexibleSqueezeGroups.newGroup(with: 5, in: &r)
        var f5 = try! XCTUnwrap(r.face(5)); f5.role = "resting"; r.setFace(f5)
        FlexibleSqueezeGroups.normalise(&r)
        XCTAssertNil(r.face(5)?.squeezeGroup)
        XCTAssertEqual(FlexibleSqueezeGroups.groups(r).count, 1, "the empty group is gone")
    }

    func testTheGroupLineIsOneLineWithItsFacesAndItsForce() {
        let names = ["Top A", "Top B", "Face 3", "Face 5"]
        XCTAssertEqual(FlexibleRowCopy.groupLine(number: 2, names: ["Face 3", "Face 5"], force: 10...10),
                       "Group 2 · Face 3 + Face 5 · Squeeze 10 kg")
        XCTAssertEqual(FlexibleRowCopy.groupLine(number: 1, names: names, force: 10...10),
                       "Group 1 · Top A + 3 more · Squeeze 10 kg")
        XCTAssertEqual(FlexibleRowCopy.squeeze(7...10), "Squeeze 7–10 kg", "faces of their own weights from before groups")
        XCTAssertEqual(FlexibleRowCopy.squeeze(2.5...2.5), "Squeeze 2.5 kg")
        let long = String(repeating: "Very long sector name ", count: 3)
        for n in 1...7 {
            let line = FlexibleRowCopy.groupLine(number: n, names: Array(repeating: long, count: n), force: 12.5...12.5)
            XCTAssertLessThanOrEqual(line.count, FlexibleRowCopy.maxChars, line)
            XCTAssertTrue(line.hasSuffix("Squeeze 12.5 kg"), "the force is never cut: \(line)")
            XCTAssertFalse(line.contains("\n"))
        }
        XCTAssertEqual(FlexibleRowCopy.simTitle(number: 2, names: ["Face 3", "Face 5"]), "Group 2 · Face 3 + Face 5")
        XCTAssertLessThanOrEqual(FlexibleRowCopy.groupsShare.count, FlexibleRowCopy.maxChars)
        XCTAssertLessThanOrEqual(FlexibleRowCopy.groupMisses(number: 2, asBuiltMM: 12.3, designedMM: 30.4).count, FlexibleRowCopy.maxChars)
        XCTAssertLessThanOrEqual(FlexibleRowCopy.pinched(with: long).count, FlexibleRowCopy.maxChars)
    }

    func testGroupColoursAreDSTokensAndNeverPurple() {
        XCTAssertEqual(FlexibleSqueezeGroups.colour(number: 1), DS.Color.accentGreen, "group 1 keeps the pressed faces' green")
        // ★ RE-PINNED (round 5, S1): he picks each group's colour; the DEFAULTS run green, orange, red,
        // blue — blue LAST, the dent heat is deep blue → cyan → white and a blue frame sank into it
        XCTAssertEqual(FlexibleSqueezeGroups.palette, [DS.Color.accentGreen, DS.Color.warning, DS.Color.danger, DS.Color.accent])
        for n in 1...12 {
            XCTAssertFalse(FlexibleShownValuesTests.isPurple(FlexibleSqueezeGroups.colour(number: n)), "group \(n) is never purple")
        }
        XCTAssertNotEqual(FlexibleSqueezeGroups.colour(number: 1), FlexibleSqueezeGroups.colour(number: 2))
        // ★ RED CONTROL: the instrument sees purple — groupPalette[4], the index a modulo 5 reaches
        XCTAssertTrue(FlexibleShownValuesTests.isPurple(DS.Color.groupPalette[4]), "control: groupPalette[4] is purple")
    }

    func testAPinchIsAConflictInsideAGroupAndAcrossGroupsItIsSharedMaterial() {
        var s = Self.his()
        let c = [FlexConflictInfo(faceA: 3, faceB: 5, overlapMM3: 203_125, axisAngleDeg: 0)]
        XCTAssertEqual(FlexibleSqueezeGroups.pinches(c, s).map { "\($0.a)|\($0.b)" }, ["3|5"], "one group: a pinch")
        XCTAssertTrue(FlexibleSqueezeGroups.acrossGroups(c, s).isEmpty)
        XCTAssertEqual(FlexibleSqueezeGroups.partners(FlexibleSqueezeGroups.pinches(c, s)), [3: [5], 5: [3]])
        _ = FlexibleSqueezeGroups.newGroup(with: 5, in: &s)
        XCTAssertTrue(FlexibleSqueezeGroups.pinches(c, s).isEmpty, "separate groups: no pinch")
        XCTAssertEqual(FlexibleSqueezeGroups.acrossGroups(c, s).map { "\($0.a)|\($0.b)" }, ["3|5"], "…the same material, the firmer wins")
        // a conflict naming a resting face is neither
        var rested = Self.his()
        var f5 = try! XCTUnwrap(rested.face(5)); f5.role = "resting"; rested.setFace(f5)
        XCTAssertTrue(FlexibleSqueezeGroups.pinches(c, rested).isEmpty)
        // ★ RED CONTROL: the OLD rule (round 3 batch B) made EVERY conflict a blocker
        let oldBlockers = c.map { "sharedStack|\(min($0.faceA, $0.faceB))|\(max($0.faceA, $0.faceB))" }
        XCTAssertEqual(oldBlockers, ["sharedStack|3|5"], "control: the old rule blocked his pinch")
    }

    @MainActor
    func testOldProjectsDecodeAndTheGroupRoundTrips() throws {
        // a face as saved before D2 (no squeezeGroup key)
        let old = #"{"faceRegionID":3,"role":"loaded","rotationDeg":0,"weightKg":10,"deepestMM":3,"mode":"both","curveX":{"x":[0,1],"y":[1,1]},"curveY":{"x":[0,1],"y":[1,1]},"curveCentreEdge":{"x":[0,1],"y":[0.3,1]},"skinOn":true}"#
        let f = try JSONDecoder().decode(FlexibleFaceSettings.self, from: Data(old.utf8))
        XCTAssertNil(f.squeezeGroup, "an old face is in group 1")
        var g = f; g.squeezeGroup = 2
        let back = try JSONDecoder().decode(FlexibleFaceSettings.self, from: JSONEncoder().encode(g))
        XCTAssertEqual(back.squeezeGroup, 2)
        // his real project decodes
        let r = try FlexibleHisProject.restore()
        defer { r.cleanup() }
        XCTAssertEqual(FlexibleSqueezeGroups.groups(try XCTUnwrap(r.project.lattice.flexible)).count, 1)
        // ★ RED CONTROL: a REQUIRED field would not decode the old face
        struct Required: Decodable { var faceRegionID: Int; var squeezeGroup: Int }
        XCTAssertThrowsError(try JSONDecoder().decode(Required.self, from: Data(old.utf8)), "control: a required group breaks old projects")
    }

    @MainActor
    func testTheSimsAreEachGroupThenAllAtOnce() {
        var s = Self.his()
        let area: (FlexFaceKey) -> Double = { k in [3: 2031.0, 5: 2031.0][k.region] ?? 5000 }
        func sims() -> [FlexibleSim] {
            FlexibleSqueezeGroups.sims(FlexibleSqueezeGroups.groups(s), key: { FlexFaceKey(region: $0, rotation: 0) },
                                       area: area, name: { [FlexibleHisProject.topA: "Top A", FlexibleHisProject.topB: "Top B"][$0] ?? "Face \($0)" })
        }
        let one = sims()
        XCTAssertEqual(one.map(\.id), ["group-1"], "one group: one sim, no 'Play all'")
        XCTAssertEqual(one[0].keys.map(\.region).prefix(2).sorted(), [FlexibleHisProject.topA, FlexibleHisProject.topB].sorted(),
                       "largest first")
        _ = FlexibleSqueezeGroups.newGroup(with: 3, in: &s)
        FlexibleSqueezeGroups.move(5, to: FlexibleSqueezeGroups.group(of: 3, in: s)!.id, in: &s)
        let two = sims()
        XCTAssertEqual(two.map(\.id), ["group-1", "group-2", "all"])
        // ★ RE-PINNED (round 5 batch G, his words: "a way to play the different sims"): D2's
        // "All at once" is dropped — "Play all" plays each group's own 3D sim in turn
        XCTAssertEqual(two.map(\.title), ["Group 1 · Top A + Top B", "Group 2 · Face 3 + Face 5", "Play all"])
        XCTAssertEqual(two.map(\.short), ["Group 1", "Group 2", "All"])
        XCTAssertEqual(two[1].keys.map(\.region), [3, 5])
        XCTAssertEqual(two[2].keys.count, 4)
        XCTAssertEqual(two[2].kind, .playAll)
    }

    func testSeparateSqueezesCombineFirmerWins() {
        func field(_ d: [Float], _ o: [Int]) -> FlexDensityField {
            FlexDensityField(nx: d.count, ny: 1, nz: 1, spacing: 1, origin: .zero, density: d, owner: o)
        }
        let a = field([-1, 0, 0.2, 0.3, 0.4], [-1, -1, 3, 3, 3])
        let b = field([-1, 0.1, 0, 0.5, 0.1], [-1, 5, -1, 5, 5])
        let (c, shared) = FlexibleGroupField.firmer([a, b])
        XCTAssertEqual(c.density, [-1, 0.1, 0.2, 0.5, 0.4], "the firmer wins; −1 stays not-lattice")
        XCTAssertEqual(c.owner, [-1, 5, 3, 5, 3], "the owner is the winner's")
        XCTAssertEqual(shared, 2, "two voxels both groups need")
        // ★ RED CONTROL: min-combine SOFTENS the voxel both need (0.3 < 0.5): a group would squish
        // further than it was designed for
        let minAt3 = min(a.density[3], b.density[3])
        XCTAssertLessThan(minAt3, c.density[3], "control: min-combine is softer")
    }
}
