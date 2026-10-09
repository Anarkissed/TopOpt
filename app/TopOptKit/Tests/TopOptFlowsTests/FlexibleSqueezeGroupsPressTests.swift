// FlexibleSqueezeGroupsPressTests — a press is in a squeeze group (task 2026-10-07, angled presses, batch AP1;
// final spec §4 "Squeeze groups", D-AP-2). A group may hold only presses and still be a tab; the job's
// one-group rule and core's hold count only groups with something SENT (none of a press until AP9); a
// press is renumbered, merged and forced with its group; with no presses every output is what it was.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleSqueezeGroupsPressTests: XCTestCase {
    typealias G = FlexibleAngledGoldens

    static let pressID = UUID(uuidString: "AE000002-0000-4000-8000-000000000001")!

    /// C1's pad settings (FlexibleStageTests: face 1 pressed in group 1, face 0 resting) with an edge
    /// press over faces 3 and 2 alone in group 2.
    static func padWithAPressInGroup2() -> FlexibleStageSettings {
        var s = FlexibleStageTests.settings()
        let f = FlexibleFaceSettings(faceRegionID: 3, weightKg: 8, squeezeGroup: 2)
        s.setPresses([FlexiblePress(id: pressID, regions: [3, 2], direction: simd_normalize(SIMD3(-1, -1, 0)),
                                    snap: "halfway", settings: f)])
        return s
    }

    /// ★ A group holding ONLY a press is a tab (listed, numbered), but not a job group: the job does not
    /// throw `.squeezeGroups` and its bytes are the AP0 golden's (the press is not in it); the model's
    /// own job, core's hold and the sims agree. RED: counting every group (the AP1 red commit's
    /// `groups(_:sent:)`) throws `.squeezeGroups`.
    func testAGroupWithOnlyPressesIsATabButNotAJobGroup() async throws {
        let s = Self.padWithAPressInGroup2()
        let gs = FlexibleSqueezeGroups.groups(s)
        XCTAssertEqual(gs.map(\.id), [1, 2], "two tabs")
        XCTAssertEqual(gs.map(\.number), [1, 2])
        XCTAssertEqual(gs[0].regions, [FlexibleJob.regionID(face: 1)])
        XCTAssertEqual(gs[0].presses, [])
        XCTAssertEqual(gs[1].regions, [], "group 2 holds no face …")
        XCTAssertEqual(gs[1].presses, [Self.pressID], "… only the press")
        XCTAssertEqual(FlexibleSqueezeGroups.group(ofPress: Self.pressID, in: s)?.number, 2)
        XCTAssertEqual(FlexibleSqueezeGroups.groups(s, sent: []).map(\.id), [1], "nothing of group 2 is sent")
        XCTAssertEqual(FlexibleSqueezeGroups.groups(s, sent: [Self.pressID]).map(\.id), [1, 2], "a SENT press would count (AP9)")
        // the pure encoder: no throw, and the golden's bytes
        let job = G.normalised(try FlexibleJob.runJobJSON(FlexibleStageTests.inputs(s)), [G.repo])
        try G.assertGolden(job, "c1_pad_pure_run_job.json")
        XCTAssertFalse(job.contains("press_direction") || job.contains("face_region_ids"), "no press key in the job")

        // the app's model over the pad: top pressed, bottom resting, an edge press alone in group 2
        let (m, _, _) = try await G.padModel(self)
        let mesh = try XCTUnwrap(m.project.viewerMesh)
        let x = FlexibleSquishFixture.face(mesh, axis: 0, value: 100), y = FlexibleSquishFixture.face(mesh, axis: 1, value: 0)
        let id = try XCTUnwrap(m.addPress(regions: [x, y], direction: simd_normalize(SIMD3(-1, 1, 0)), snap: "halfway", group: 2, kg: 6))
        try await FlexibleSquishFixture.settle(m, "the pad + a press")
        XCTAssertEqual(m.squeezeGroups.count, 2, "group 2 is a tab")
        XCTAssertEqual(m.squeezeGroup(ofPress: id)?.number, 2)
        XCTAssertEqual(m.sentSqueezeGroups.count, 1)
        XCTAssertNil(m.coreHoldKind, "★ core's hold is not raised by a press it cannot take yet")
        XCTAssertEqual(m.sims.count, 1, "one sim: the press plays nothing until core builds it")
        XCTAssertNil(m.groupMiss(1))
        try G.assertGolden(try G.runJob(m, roots: [G.repo]), "c1_pad_model_run_job.json")
    }

    /// With no presses every group output is what it was: on every AP0 project (his 0004 and r5 as saved,
    /// the A1 store's three Flexible projects) the groups equal the faces-only rule and the sent groups,
    /// and no group holds a press. (The goldens — FlexibleAngledGoldenTests — are re-run beside it.)
    func testProjectsWithoutPressesGroupIdentically() throws {
        func facesOnly(_ s: FlexibleStageSettings) -> [FlexibleSqueezeGroup] {
            var members: [Int: [Int]] = [:]
            for f in s.loadedFaces { members[FlexibleSqueezeGroups.id(f), default: []].append(f.faceRegionID) }
            return members.keys.sorted().enumerated().map { FlexibleSqueezeGroup(id: $1, number: $0 + 1, regions: members[$1] ?? []) }
        }
        var checked = 0
        for src in G.subtreeSources {
            let snap = try JSONDecoder().decode(ProjectSnapshot.self, from: Data(contentsOf: src.url))
            guard let s = snap.lattice?.flexible else { continue }
            let gs = FlexibleSqueezeGroups.groups(s)
            XCTAssertEqual(gs, facesOnly(s), "\(src.name): the faces' groups")
            XCTAssertEqual(FlexibleSqueezeGroups.groups(s, sent: []), gs, "\(src.name): every group is sent")
            XCTAssertTrue(gs.allSatisfy { $0.presses.isEmpty })
            var n = s
            FlexibleSqueezeGroups.normalise(&n)
            XCTAssertNil(n.presses, "\(src.name): normalise writes no list")
            print("FLEX-AP1 \(src.name): \(gs.count) group(s) \(gs.map { "\($0.number):\($0.regions)" })")
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 4)
    }

    /// Presses are renumbered with the faces, join the group a removed group merges into, keep a group
    /// alive when its last face leaves, and take their group's one force when they join it.
    func testPressesAreRenumberedMergedAndForcedWithTheirGroup() {
        var s = FlexibleStageTests.settings()   // face 1 in group 1
        var f3 = FlexibleFaceSettings(faceRegionID: 3, weightKg: 4, squeezeGroup: 5)
        s.setFace(f3)
        f3.faceRegionID = 2
        s.setPresses([FlexiblePress(id: Self.pressID, regions: [2, 4], direction: SIMD3(0, 0, -1), settings: f3)])
        FlexibleSqueezeGroups.normalise(&s)
        XCTAssertEqual(s.face(3)?.squeezeGroup, 2, "group 5 renumbered to 2")
        XCTAssertEqual(s.press(Self.pressID)?.settings.squeezeGroup, 2, "its press with it")
        // a new group from face 3: group 2 keeps its press, so it is not emptied by the move
        XCTAssertNotNil(FlexibleSqueezeGroups.newGroup(with: 3, in: &s), "★ the press keeps group 2 alive")
        XCTAssertEqual(FlexibleSqueezeGroups.groups(s).map(\.id), [1, 2, 3])
        XCTAssertEqual(FlexibleSqueezeGroups.group(ofPress: Self.pressID, in: s)?.id, 2)
        // removing group 2 merges its press into group 1
        FlexibleSqueezeGroups.remove(group: 2, into: 1, in: &s)
        XCTAssertNil(s.press(Self.pressID)?.settings.squeezeGroup, "the press joined group 1 (stored nil)")
        XCTAssertEqual(FlexibleSqueezeGroups.groups(s).map(\.id), [1, 2])
        // the one force: a press of his own is a hand; taking the group's force reaches it
        let g1 = FlexibleSqueezeGroups.groups(s)[0]
        XCTAssertEqual(g1.presses, [Self.pressID])
        let hands = FlexibleSqueezeGroups.hands(g1, settings: s, loads: FlexibleMainPageLoads())
        XCTAssertEqual(hands.map(\.kg), [30, 4], "face 1's 30 kg and the press's own 4 kg")
        XCTAssertEqual(FlexibleSqueezeGroups.force(g1, settings: s, loads: FlexibleMainPageLoads()), 4...30, "★ the press is in the group's force")
        FlexibleStageModel.takeForce(30...30, regions: [], presses: [Self.pressID], in: &s)
        XCTAssertEqual(s.press(Self.pressID)?.settings.weightKg, 30)
        XCTAssertEqual(FlexibleSqueezeGroups.force(g1, settings: s, loads: FlexibleMainPageLoads()), 30...30)
    }

    /// The model: the group's pill (setGroupForce) sets a press of his own; a press in a group shows in
    /// its force. RED: without presses among the hands the press would keep its old weight.
    func testTheGroupPillSetsAPressOfHisOwn() throws {
        let (_, m, top, x, y) = try FlexiblePressSaveTests.pad()
        XCTAssertTrue(m.press(top, kg: 12))
        let id = try XCTUnwrap(m.addPress(regions: [x, y], direction: simd_normalize(SIMD3(-1, 1, 0)), snap: "halfway"))
        XCTAssertEqual(m.press(id)?.settings.weightKg, 12, "it joined group 1 at its force")
        let g = try XCTUnwrap(m.squeezeGroup(ofPress: id))
        XCTAssertEqual(g.id, m.squeezeGroup(of: top)?.id)
        XCTAssertEqual(m.groupForce(g), 12...12)
        m.setGroupForce(g.id, kg: 15)
        XCTAssertEqual(m.settings.face(top)?.weightKg, 15)
        XCTAssertEqual(m.press(id)?.settings.weightKg, 15, "★ the pill reached the press")
        XCTAssertEqual(m.groupForce(try XCTUnwrap(m.squeezeGroup(ofPress: id))), 15...15)
    }
}
