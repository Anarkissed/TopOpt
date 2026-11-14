// FlexibleC2W2Tests — C2 WIRING W2 (B9, 2026-11-09), the reviewer's ruling 5 (a) of 11-08: "core squeeze group = one app HAND
// with 2+ entries (force_n = hand weight, entries no weight_n); a hand of one = today's bytes; a pinch inside one Load group =
// core's pinch; hands are separate load cases (core combination)." #361's C2 core (API 5-8) designs several squeeze groups and a
// pinch, so the app SENDS them instead of refusing (`.squeezeGroups` / `.pinch`) and holding the pill on "Preview · core runs one
// group at a time". `FlexibleJob.sendsC2W2` off is the app before C2 (FlexibleAngledGoldens.preC2). Each RED CONTROL runs inside
// its test.
import XCTest
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleC2W2Tests: XCTestCase {
    typealias W1 = FlexibleC2WiringTests

    override func tearDown() {
        FlexibleJob.sendsC2W1 = true
        FlexibleJob.sendsC2W2 = true
        super.tearDown()
    }

    /// Faces 1 and 2 pressed in squeeze group 1, face 3 pressed in group 2 (the pad's faces; 10, 10 and 5 kg).
    static func twoGroups() -> FlexibleStageSettings {
        var s = FlexibleStageSettings(materialID: "varioshore_tpu", nozzleTempC: 220, topology: "auto", feel: "damped", beadsPerWall: 1)
        for (f, kg) in [(1, 10.0), (2, 10.0), (3, 5.0)] {
            s.setFace(FlexibleFaceSettings(faceRegionID: FlexibleJob.regionID(face: f), weightKg: kg, deepestMM: 3, mode: "both",
                                           curveX: FlexCurve(x: [0, 1], y: [1, 1]), curveY: FlexCurve(x: [0, 1], y: [1, 1])))
        }
        var g2 = s.face(FlexibleJob.regionID(face: 3))!
        g2.squeezeGroup = 2
        s.setFace(g2)
        s.setFace(FlexibleFaceSettings(faceRegionID: FlexibleJob.regionID(face: 0), role: "resting"))
        return s
    }

    /// ★ A hand of two or more entries is ONE core squeeze group: `faces` = its entries, `force_n` = the hand's weight (the sum
    /// of the weights its entries stated), and its entries state no weight_n; a hand of one keeps today's bytes. Two app groups are sent (each hand its own load case), never
    /// refused; core's own parser takes the job. RED CONTROLS: the switch off refuses the two groups (the app before C2); a grouped
    /// entry that keeps its weight_n is refused by core's parser — core reads the group.
    func testAHandOfTwoIsOneCoreSqueezeGroupAndTwoGroupsAreSent() throws {
        let s = Self.twoGroups()
        XCTAssertEqual(FlexibleSqueezeGroups.groups(s).count, 2)
        var i = FlexibleStageTests.inputs(s)
        let r1 = FlexibleJob.regionID(face: 1), r2 = FlexibleJob.regionID(face: 2), r3 = FlexibleJob.regionID(face: 3)
        let handN = FlexibleUnits.newtons(kg: 10) + FlexibleUnits.newtons(kg: 10)
        i.hands = [[r1, r2], [r3]]
        let on = try FlexibleJob.runJobJSON(i)
        let groups = try XCTUnwrap(try W1.block(on)["squeeze_groups"] as? [[String: Any]], "★ the hand of two is sent")
        XCTAssertEqual(groups.count, 1, "★ a hand of one is not listed")
        XCTAssertEqual(groups[0]["faces"] as? [Int], [r1, r2])
        XCTAssertEqual(try XCTUnwrap(groups[0]["force_n"] as? Double), handN, accuracy: 1e-9, "★ force_n = the hand's weight")
        XCTAssertEqual(handN, FlexibleUnits.newtons(kg: 20), accuracy: 1e-9)
        let faces = try W1.faces(on)
        func entry(_ r: Int) -> [String: Any]? { faces.first { $0["face_region_id"] as? Int == r } }
        XCTAssertNil(entry(r1)?["weight_n"], "★ a grouped entry states no weight")
        XCTAssertNil(entry(r2)?["weight_n"])
        XCTAssertEqual(try XCTUnwrap(entry(r3)?["weight_n"] as? Double), FlexibleUnits.newtons(kg: 5), accuracy: 1e-9,
                       "★ a hand of one: today's bytes")
        XCTAssertNoThrow(try FlexibleCore.parseJobBlock(on), "★ core's own parser takes two groups and the squeeze group")
        // the job = the pre-C2 job + exactly squeeze_groups and the two weights taken out (with no_include_region from W1)
        let off = try FlexibleAngledGoldens.preC2 { () throws -> String in
            var one = i
            one.settings.faces = one.settings.faces.map { var f = $0; f.squeezeGroup = nil; return f }
            return try FlexibleJob.runJobJSON(one)
        }
        var b = try W1.block(on)
        b.removeValue(forKey: "squeeze_groups")
        b.removeValue(forKey: "no_include_region")
        var offB = try W1.block(off)
        offB["faces"] = (offB["faces"] as? [[String: Any]])?.map { e -> [String: Any] in
            var e = e
            if let r = e["face_region_id"] as? Int, r == r1 || r == r2 { e["weight_n"] = nil }
            return e
        }
        XCTAssertTrue(NSDictionary(dictionary: b).isEqual(to: offB), "★ every other byte unchanged")
        // ★ RED CONTROL 1: the app before C2 refuses the two groups
        XCTAssertThrowsError(try FlexibleAngledGoldens.preC2 { try FlexibleJob.runJobJSON(i) }) {
            XCTAssertEqual($0 as? FlexibleJob.EncodeError, .squeezeGroups)
        }
        // ★ RED CONTROL 2: a grouped entry keeping its weight is refused by core — core reads the group
        var o = try W1.object(on)
        var ob = try W1.block(on)
        ob["faces"] = faces.map { e -> [String: Any] in
            var e = e
            if e["face_region_id"] as? Int == r1 { e["weight_n"] = 98.0 }
            return e
        }
        o["flexible"] = ob
        XCTAssertThrowsError(try FlexibleCore.parseJobBlock(try W1.encode(o)), "★ RED CONTROL: core refuses a weight inside a group")
        print("FLEX-C2W2 squeeze_groups: hand [\(r1), \(r2)] \(handN) N sent, hand of one kept; two groups sent; RED off refuses, RED weight refused")
    }

    /// ★ A hand's entries that are not LOADED entries of the job (a face resting in it, a press left out) are dropped; a hand left
    /// with one entry is no group and that entry keeps its weight. Hands never share an entry.
    func testAHandOnlyListsTheJobsLoadedEntries() throws {
        var s = Self.twoGroups()
        var rest = s.face(FlexibleJob.regionID(face: 2))!
        rest.role = "resting"
        s.setFace(rest)
        var i = FlexibleStageTests.inputs(s)
        let r1 = FlexibleJob.regionID(face: 1), r2 = FlexibleJob.regionID(face: 2), r3 = FlexibleJob.regionID(face: 3)
        i.hands = [[r1, r2]]
        let on = try FlexibleJob.runJobJSON(i)
        XCTAssertNil(try W1.block(on)["squeeze_groups"], "★ [1, resting 2] is a hand of one")
        XCTAssertNotNil(try W1.faces(on).first { $0["face_region_id"] as? Int == r1 }?["weight_n"], "★ it keeps its weight")
        XCTAssertNoThrow(try FlexibleCore.parseJobBlock(on))
        // ★ RED CONTROL: with face 2 pressed again the same hand makes a group
        var j = FlexibleStageTests.inputs(Self.twoGroups())
        j.hands = i.hands
        XCTAssertEqual((try W1.block(try FlexibleJob.runJobJSON(j))["squeeze_groups"] as? [[String: Any]])?.count, 1)
        // ★ hands never share an entry: [1, 2] takes 1 and 2, so [2, 3] is left a hand of one and face 3 keeps its weight
        j.hands = [[r1, r2], [r2, r3]]
        let shared = try FlexibleJob.runJobJSON(j)
        let gs = try XCTUnwrap(try W1.block(shared)["squeeze_groups"] as? [[String: Any]])
        XCTAssertEqual(gs.map { $0["faces"] as? [Int] }, [[r1, r2]], "★ one group: 2 is never listed twice")
        XCTAssertNotNil(try W1.faces(shared).first { $0["face_region_id"] as? Int == r3 }?["weight_n"], "★ face 3 keeps its weight")
        XCTAssertNoThrow(try FlexibleCore.parseJobBlock(shared))
    }

    /// ★ THE JOB'S FORCE IS CONSERVED: grouping moves weight from entries into force_n, never adds any — the job's total (each
    /// ungrouped entry's weight_n + each group's force_n) is the app before C2's (every entry's weight_n), with one hand, two
    /// hands, and a hand with one entry resting (that entry's share drops out, as before C2). ★ CONTROL: a 1 kg change on one
    /// entry is seen in the total.
    func testTheJobsForceIsConservedByTheGroups() throws {
        let r1 = FlexibleJob.regionID(face: 1), r2 = FlexibleJob.regionID(face: 2), r3 = FlexibleJob.regionID(face: 3)
        func total(_ json: String) throws -> Double {
            let b = try W1.block(json)
            let entries = (b["faces"] as? [[String: Any]] ?? []).compactMap { $0["weight_n"] as? Double }.reduce(0, +)
            let groups = (b["squeeze_groups"] as? [[String: Any]] ?? []).compactMap { $0["force_n"] as? Double }.reduce(0, +)
            return entries + groups
        }
        for (label, hands, restR2) in [("one hand", [[r1, r2, r3]], false), ("two hands", [[r1, r2], [r3]], false),
                                       ("one hand, face 2 resting", [[r1, r2, r3]], true)] {
            var s = Self.twoGroups()
            if restR2 { var f = s.face(r2)!; f.role = "resting"; s.setFace(f) }
            var i = FlexibleStageTests.inputs(s)
            i.hands = hands
            let on = try FlexibleJob.runJobJSON(i)
            XCTAssertNotNil(try W1.block(on)["squeeze_groups"], "\(label): premise — a group is sent")
            let before = try FlexibleAngledGoldens.preC2 { () throws -> String in
                var one = i
                one.settings.faces = one.settings.faces.map { var f = $0; f.squeezeGroup = nil; return f }
                return try FlexibleJob.runJobJSON(one)
            }
            XCTAssertEqual(try total(on), try total(before), accuracy: 1e-9, "★ \(label): the job's force is the app before C2's")
            XCTAssertNoThrow(try FlexibleCore.parseJobBlock(on), label)
            print("FLEX-C2W2 force \(label): \(try total(on)) N sent = \(try total(before)) N before C2")
        }
        // ★ CONTROL: face 3 one kg heavier — the same hands send one kg more
        var s = Self.twoGroups()
        var f3 = s.face(r3)!
        f3.weightKg += 1
        s.setFace(f3)
        var i = FlexibleStageTests.inputs(s)
        i.hands = [[r1, r2, r3]]
        var base = FlexibleStageTests.inputs(Self.twoGroups())
        base.hands = i.hands
        XCTAssertEqual(try total(try FlexibleJob.runJobJSON(i)) - total(try FlexibleJob.runJobJSON(base)), FlexibleUnits.newtons(kg: 1),
                       accuracy: 1e-9, "control: a 1 kg change is seen")
    }

    /// ★ The pill holds nothing core designs now: two groups, a pinch. A calibrate-first filament still holds (core refuses it
    /// from the same catalogue entry). An edges group the job cannot carry (edgesBeside: a press gate keeps it out) still says
    /// so — ruling 4, "never silently drop a group" — with W2's own words; a pressed face with no lattice says core's refusal.
    /// RED CONTROL: the app before C2 held each.
    func testTheHoldKeepsOnlyTheCalibrateFirstFilament() {
        XCTAssertNil(FlexibleCoreHold.kind(calibrateFirst: false, groups: 2, pinches: 1))
        XCTAssertEqual(FlexibleCoreHold.kind(calibrateFirst: false, groups: 2, pinches: 1, edgesBeside: true), .edgesBeside,
                       "★ an edges group not in the export is said, never dropped")
        XCTAssertEqual(FlexibleCoreHold.kind(calibrateFirst: false, groups: 2, pinches: 1, edgesBeside: true, noLatticeUnder: true),
                       .noLatticeUnder, "★ core's refusal first: no lattice under a pressed face")
        XCTAssertEqual(FlexibleCoreHold.kind(calibrateFirst: true, groups: 2, pinches: 1), .shapeOnly)
        FlexibleJob.sendsC2W2 = false
        XCTAssertEqual(FlexibleCoreHold.kind(calibrateFirst: false, groups: 2, pinches: 0), .squeezeGroups, "★ RED CONTROL")
        XCTAssertEqual(FlexibleCoreHold.kind(calibrateFirst: false, groups: 1, pinches: 1), .pinch, "★ RED CONTROL")
    }
}
