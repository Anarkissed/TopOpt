// FlexiblePressReviewTests — the saved press, after the AP1 verification (task 2026-10-07, angled presses,
// batch AP1; final spec §4, §14, §15). Each test pins one of the verifier's findings that was confirmed:
//   * tilt then straighten leaves his setup — and the job written from it — exactly as it was (the face
//     goes back where it sat, not to the end of `faces`);
//   * a direction that is not finite or has no length is never stored (one NaN made every later save of
//     the project fail);
//   * the three rules no AP1 test turned red: a linked press sits in its hand's group; a press whose group
//     drops every member keeps its weight, unlinked; a face that is ALSO in a press keeps its link;
//   * a press links only to a main-page Load group that PRESSES one of its members (a group that only
//     pulls or shears them asks the pad, as a face does), and is unlinked when its group stops pressing;
//   * a frame is named by VALUE: a re-aim is two frames, and the frame its inputs were drawn in is saved;
//   * a linked weight is the same bits on every call (summed in his pick order, not a Set's);
//   * a trashed press leaves its members as he left them (the main page's re-sync never re-presses them);
//   * a member change and a re-aim go through the press's own two mutators, which keep the name core gives
//     it, the snap and the frame of record honest;
//   * a press action is its own undo step, and the press card follows the history.
// RED: the review's tests-first commit runs these against AP1 as it was, with the new API's rules as RED
// STUBS (a press frame named by its footprint only, its direction saved through Float, setMembers / aim
// that change the field only); the three pinned rules go red under the mutations recorded beside the
// evidence (ap1_review_red_runs.txt).
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexiblePressReviewTests: XCTestCase {
    typealias G = FlexibleAngledGoldens

    nonisolated static func bits(_ v: SIMD3<Double>) -> [UInt64] { [v.x.bitPattern, v.y.bitPattern, v.z.bitPattern] }

    /// His r5's Flexible setup saved by the app's own persist, then read back by a NEW AppModel's open
    /// over the same store (the app's restore). Also returns the saved file's `flexible` object.
    static func saveAndReopen(_ r: FlexibleHisProject.Restored) throws -> (FlexibleStageSettings, [String: Any]) {
        r.app.persistCurrentProject()
        XCTAssertNil(r.app.toast, "the save succeeded")
        let file = r.root.appendingPathComponent(r.project.id.uuidString).appendingPathComponent("project.json")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let saved = try XCTUnwrap((json["lattice"] as? [String: Any])?["flexible"] as? [String: Any])
        let core = FlexibleHisProject.repoRoot.appendingPathComponent("core")
        let app2 = AppModel(materialsPath: core.appendingPathComponent("src/materials/materials.json").path,
                            rulesPath: core.appendingPathComponent("src/settings/rules.json").path,
                            store: ProjectStore(rootDir: r.root))
        app2.loadMaterials()
        let recent = try XCTUnwrap(app2.recentProjects.first { $0.id == r.project.id })
        app2.open(recent)
        return (try XCTUnwrap(app2.project?.lattice.flexible), saved)
    }

    /// C1's pad with a main-page Load group over its x = 100 and y = 0 faces, 9 kg, under `gravity`.
    static func padWithAGroup(gravity: SIMD3<Double>) throws -> (ProjectModel, FlexibleStageModel, group: UUID, x: Int, y: Int) {
        let (pm, m, _, x, y) = try FlexiblePressSaveTests.pad()
        let g = pm.selection.addGroup()
        pm.selection.addFaces([FaceID(x), FaceID(y)], to: g)
        pm.force.makeLoad(g)
        pm.force.setWeight(g, kg: 9)
        pm.force.setGravity(direction: SIMD3<Float>(simd_normalize(gravity)))
        m.refreshMainPageLoads()
        return (pm, m, g, x, y)
    }

    /// Gravity that presses both pad faces at an angle, and gravity that points AWAY from both.
    static let pressing = SIMD3<Double>(-1, 1, -0.5)
    static let pulling = SIMD3<Double>(1, -1, 0)
    static let edge = simd_normalize(SIMD3<Double>(-1, 1, 0))

    // MARK: - tilt then straighten

    /// ★ His r5 as saved: top A (not the last face) tilted, then straightened. `faces` keeps its order, so
    /// his setup is EQUAL to the one before (the page's S9 compare reads "Exit"), the lattice's key is the
    /// same, and the first held send's run job is the AP0 golden, byte for byte. RED (AP1 as it was):
    /// straighten appended top A at the end — a different `faces`, a different key, a different job.
    func testTiltThenStraightenLeavesHisSetupAndJobAsTheyWere() async throws {
        let (r, m, first) = try await G.hisRound5Model(self)
        let before = m.settings
        let topA = FlexibleHisProject.topA
        let order = before.faces.map(\.faceRegionID)
        XCTAssertTrue(order.contains(topA) && order.last != topA, "premise: top A is a face, not the last: \(order)")
        let id = try XCTUnwrap(m.tilt(topA, direction: simd_normalize(SIMD3(0.2, 0, -1)), snap: nil))
        XCTAssertNil(m.settings.face(topA), "premise: tilted")
        XCTAssertTrue(m.straighten(id))
        await m.waitForIdle()
        print("FLEX-AP1 review tilt + straighten: faces \(order) → \(m.settings.faces.map(\.faceRegionID)) · equal \(m.settings == before)")
        XCTAssertEqual(m.settings.faces.map(\.faceRegionID), order, "★ top A is back where it sat")
        XCTAssertEqual(m.settings, before, "★ his setup as it was (the S9 compare reads Exit)")
        XCTAssertEqual(m.settings.designInputs.hashValue, before.designInputs.hashValue, "the lattice's key as it was")
        try G.assertGolden(try G.runJob(m, resting: Set(first.resting), roots: G.rootToken(r)), "his_r5_held_send_run_job.json")
    }

    // MARK: - a direction that cannot be saved

    /// ★ A direction that is not finite, or has (almost) no length, is never stored — not by addPress, not
    /// by a tilt, not by setPress — and his project still saves. RED (AP1 as it was): each was accepted,
    /// and the next save failed. Control: a NaN direction in the list does make the save fail.
    func testADirectionThatIsNotFiniteOrHasNoLengthIsNeverStored() throws {
        let r = try FlexiblePressFixtures.hisRound5(self)
        let m = FlexiblePressSaveTests.model(r.project)
        m.adoptMainPageLoads()
        let topA = FlexibleHisProject.topA, topB = FlexibleHisProject.topB
        XCTAssertEqual(m.settings.face(topA)?.isLoaded, true, "premise: top A is pressed")
        let before = m.settings
        let bad: [(String, SIMD3<Double>)] = [("zero", .zero), ("normalised zero (NaN)", simd_normalize(SIMD3<Double>.zero)),
                                              ("infinite", SIMD3(.infinity, 0, -1)), ("1e-12 long", SIMD3(1e-12, 0, 0))]
        for (name, d) in bad {
            XCTAssertNil(m.addPress(regions: [topB, 2], direction: d, snap: nil, kg: 5), "★ addPress refuses a \(name) direction")
            XCTAssertNil(m.tilt(topA, direction: d, snap: nil), "★ a tilt refuses a \(name) direction")
            var s = m.settings
            s.setPress(FlexiblePress(regions: [2, 4], direction: d, settings: FlexibleFaceSettings(faceRegionID: 2)))
            XCTAssertNil(s.presses, "★ setPress ignores a \(name) direction")
        }
        XCTAssertEqual(m.settings, before, "nothing was stored")
        r.app.persistCurrentProject()
        XCTAssertNil(r.app.toast, "★ his project still saves")
        // ★ RED CONTROL: a NaN direction in the list cannot be written
        var nan = before
        nan.setPresses([FlexiblePress(regions: [2, 4], direction: simd_normalize(SIMD3<Double>.zero),
                                      settings: FlexibleFaceSettings(faceRegionID: 2))])
        r.project.lattice.flexible = nan
        r.app.persistCurrentProject()
        print("FLEX-AP1 review NaN control: toast \(r.app.toast.map { "\($0)" } ?? "nil")")
        XCTAssertNotNil(r.app.toast, "control: a NaN direction makes the save fail")
        r.project.lattice.flexible = before
    }

    // MARK: - the three rules no AP1 test turned red

    /// ★ A press LINKED to a main-page Load group sits in the squeeze group of that group's pressed face
    /// (one force per hand): here group 2, while the press was made in group 1. A press of his own stays
    /// where it is. RED (mutation `unite`: uniteHands without its press block): the press stays in group 1.
    func testALinkedPressSitsInItsHandsGroup() throws {
        let g = UUID()
        let linked = UUID(uuidString: "AE000004-0000-4000-8000-000000000001")!
        let own = UUID(uuidString: "AE000004-0000-4000-8000-000000000002")!
        var s = FlexibleStageSettings(materialID: "varioshore_tpu")
        s.setFace(FlexibleFaceSettings(faceRegionID: 1, weightKg: 4, weightFrom: g, squeezeGroup: 2))   // the group's face, group 2
        s.setFace(FlexibleFaceSettings(faceRegionID: 5, weightKg: 6))                                    // his own face, group 1
        s.setPresses([
            FlexiblePress(id: linked, regions: [2, 3], direction: Self.edge, settings: FlexibleFaceSettings(faceRegionID: 2, weightKg: 4, weightFrom: g)),
            FlexiblePress(id: own, regions: [6, 7], direction: Self.edge, settings: FlexibleFaceSettings(faceRegionID: 6, weightKg: 6)),
        ])
        func entry(_ r: Int, _ role: FlexibleMainPageLoads.Role, _ share: Double) -> FlexibleMainPageLoads.Entry {
            .init(region: r, role: role, weightKg: role == .pressed ? 8 * share : 0, groupID: g, groupName: "Top",
                  groupKg: 8, share: share, pressFraction: role == .pressed ? 1 : 0, groupRegions: 3)
        }
        let loads = FlexibleMainPageLoads(entries: [1: entry(1, .pressed, 0.5), 2: entry(2, .pressed, 0.25), 3: entry(3, .ask, 0.25)])
        XCTAssertEqual(FlexibleSqueezeGroups.group(ofPress: linked, in: s)?.id, 1, "premise: made in group 1")
        FlexibleSqueezeGroups.uniteHands(&s, loads: loads)
        let faceGroup = FlexibleSqueezeGroups.group(of: 1, in: s)
        print("FLEX-AP1 review unite: the group's face in \(faceGroup?.id ?? -1) · the linked press in \(FlexibleSqueezeGroups.group(ofPress: linked, in: s)?.id ?? -1) · his own press in \(FlexibleSqueezeGroups.group(ofPress: own, in: s)?.id ?? -1)")
        XCTAssertEqual(faceGroup?.id, 2, "premise: the group's face sits in group 2")
        XCTAssertEqual(FlexibleSqueezeGroups.group(ofPress: linked, in: s)?.id, 2, "★ the linked press joined its hand's group")
        XCTAssertEqual(FlexibleSqueezeGroups.group(ofPress: own, in: s)?.id, 1, "his own press stays")
        let hands = FlexibleSqueezeGroups.hands(try XCTUnwrap(faceGroup), settings: s, loads: loads)
        XCTAssertEqual(hands.count, 1, "one hand: the group's face and the press")
        XCTAssertEqual(hands.first?.mainGroup, g)
        XCTAssertEqual(hands.first?.presses, [linked])
    }

    /// ★ A linked press whose main-page group no longer holds any of its members keeps its weight as his
    /// own and drops its link (the rule a face follows), so a later group edit no longer reaches it.
    /// RED (mutation `unlink`: adoptWeights without its unlink branch): the link stays.
    func testAPressWhoseGroupDropsEveryMemberKeepsItsWeightUnlinked() throws {
        let (pm, m, g, x, y) = try Self.padWithAGroup(gravity: Self.pressing)
        let id = try XCTUnwrap(m.addPress(regions: [x, y], direction: Self.edge, snap: "halfway"))
        XCTAssertEqual(m.press(id)?.settings.weightFrom, g, "premise: linked")
        let kg = try XCTUnwrap(m.press(id)?.settings.weightKg)
        XCTAssertEqual(kg, 9, accuracy: 1e-12, "premise: the group's whole weight")
        pm.selection.removeFaces([FaceID(x), FaceID(y)], from: g)
        m.adoptMainPageLoads()
        print("FLEX-AP1 review unlink: weightFrom \(m.press(id)?.settings.weightFrom.map { "\($0)" } ?? "nil") · \(m.press(id)?.settings.weightKg ?? -1) kg")
        XCTAssertNil(m.press(id)?.settings.weightFrom, "★ unlinked")
        XCTAssertEqual(m.press(id)?.settings.weightKg, kg, "★ its weight kept as his own")
        pm.force.setWeight(g, kg: 20)
        m.adoptMainPageLoads()
        XCTAssertEqual(m.press(id)?.settings.weightKg, kg, "a later edit of the group no longer reaches it")
    }

    /// ★ His r5: top A, pressed on its own and linked to his "Top" group, is ALSO in a press (a clash,
    /// spec §8 — AP4 offers the fixes). The re-sync keeps its face as it was (link and weight), and a Top
    /// edit still reaches it. The adopt's skip set is removedRegions ∪ (press members that are NOT faces).
    /// RED (mutation `adoptspec`: the spec's literal `∪ pressRegions`): top A is filtered out of the
    /// main page's read, so the re-sync unlinks it.
    func testAClashFaceKeepsItsLinkThroughTheReSync() throws {
        let r = try FlexiblePressFixtures.hisRound5(self)
        let m = FlexiblePressSaveTests.model(r.project)
        m.adoptMainPageLoads()
        let topA = FlexibleHisProject.topA
        let top = try XCTUnwrap(r.project.selection.groups.first { $0.name == "Top" }).id
        let a = try XCTUnwrap(m.settings.face(topA))
        XCTAssertEqual(a.weightFrom, top, "premise: top A is linked to Top")
        m.edit { s in
            s.setPress(FlexiblePress(regions: [topA, 3], direction: simd_normalize(SIMD3(-1, 0, -1)), snap: "halfway",
                                     settings: FlexibleFaceSettings(faceRegionID: topA, weightKg: 4)))
        }
        m.adoptMainPageLoads()
        print("FLEX-AP1 review clash: top A weightFrom \(m.settings.face(topA)?.weightFrom.map { "\($0)" } ?? "nil") (was \(top))")
        XCTAssertEqual(m.settings.face(topA), a, "★ the clashing face keeps its link and its weight")
        r.project.force.setWeight(top, kg: 12)
        m.adoptMainPageLoads()
        let e = try XCTUnwrap(m.mainPageLoads.entry(topA))
        XCTAssertEqual(m.settings.face(topA)?.weightFrom, top)
        XCTAssertEqual(m.settings.face(topA)?.weightKg ?? 0, e.weightKg, accuracy: 1e-12, "a Top edit still reaches it")
    }

    // MARK: - the weight rule: a group that only pulls

    /// ★ A main-page Load group that only PULLS or shears a press's members (every member's entry 'ask':
    /// gravity points away from both pad faces) is no force for it: the pad asks, as it does for a face.
    /// A press linked while the group pressed is its own hand the moment the group turns to pull, and the
    /// re-sync unlinks it, its weight kept. RED (AP1 as it was): linked at the pull's 9 kg; a Top hand.
    func testAGroupThatOnlyPullsItsMembersNeverLinksAPress() throws {
        let (pm, m, g, x, y) = try Self.padWithAGroup(gravity: Self.pulling)
        let ex = try XCTUnwrap(m.mainPageLoads.entry(x)), ey = try XCTUnwrap(m.mainPageLoads.entry(y))
        XCTAssertEqual([ex.role, ey.role], [.ask, .ask], "premise: the group pulls both faces (c \(ex.pressFraction), \(ey.pressFraction))")
        XCTAssertFalse(m.press(x), "premise: the face rule asks the pad for a face its group only pulls")
        print("FLEX-AP1 review pull: newPressWeight \(m.newPressWeight(regions: [x, y]))")
        XCTAssertEqual(m.newPressWeight(regions: [x, y]), .ask, "★ no link to a group that pulls")
        XCTAssertNil(m.addPress(regions: [x, y], direction: Self.edge, snap: "halfway"), "★ the pad must ask")
        XCTAssertNil(m.settings.presses)
        // linked while the group presses them …
        pm.force.setGravity(direction: SIMD3<Float>(simd_normalize(Self.pressing)))
        m.refreshMainPageLoads()
        let id = try XCTUnwrap(m.addPress(regions: [x, y], direction: Self.edge, snap: "halfway"))
        XCTAssertEqual(m.press(id)?.settings.weightFrom, g, "premise: linked while it presses")
        let kg = try XCTUnwrap(m.press(id)?.settings.weightKg)
        // … then the group turns to pull them
        pm.force.setGravity(direction: SIMD3<Float>(simd_normalize(Self.pulling)))
        m.refreshMainPageLoads()
        let sg = try XCTUnwrap(m.squeezeGroup(ofPress: id))
        let hand = FlexibleSqueezeGroups.hands(sg, settings: m.settings, loads: m.mainPageLoads, liveKg: m.liveMainKg)
            .first { $0.presses.contains(id) }
        XCTAssertNil(try XCTUnwrap(hand).mainGroup, "★ its own hand: the group no longer presses it")
        m.adoptMainPageLoads()
        XCTAssertNil(m.press(id)?.settings.weightFrom, "★ the re-sync unlinks it")
        XCTAssertEqual(m.press(id)?.settings.weightKg, kg, "its weight kept as his own")
    }

    // MARK: - frames by value

    /// Core's frames through the split pad's open scene; a press frame resolves (test double only) to the
    /// face frame named for its direction, and every press frame asked for is recorded.
    final class PressFramesByDirection: FlexibleFrameSource {
        let real: FlexibleSceneFrames
        let faces: [(FlexiblePressFrame, Int)]
        var asked: [FlexiblePressFrame] = []
        init(_ real: FlexibleSceneFrames, _ faces: [(FlexiblePressFrame, Int)]) { self.real = real; self.faces = faces }
        func resolve(_ ref: FlexibleFrameRef) throws -> FlexibleFrameRef {
            guard case .press(let p) = ref else { return ref }
            asked.append(p)
            guard let f = faces.first(where: { $0.0.regions == p.regions && FlexiblePressReviewTests.bits($0.0.direction) == FlexiblePressReviewTests.bits(p.direction) }) else {
                throw TopOptError(message: "no frame for \(p)")
            }
            return .face(f.1)
        }
        func stack(_ ref: FlexibleFrameRef) throws -> FlexStackInfo { try real.stack(resolve(ref)) }
        func fromUV(_ ref: FlexibleFrameRef, _ uv: [SIMD2<Double>]) throws -> [SIMD3<Double>] { try real.fromUV(resolve(ref), uv) }
        func toUVT(_ ref: FlexibleFrameRef, _ xyz: [SIMD3<Double>]) throws -> [SIMD3<Double>] { try real.toUVT(resolve(ref), xyz) }
    }

    /// ★ A re-aim is TWO frames: the press frame is its footprint and its direction, equal only bit for
    /// bit, so reframing from the old direction to the new asks the frame source for both — here a test
    /// double that answers with core's Top and Top B frames — and gives what core's own face frames give.
    /// The open scene still waits on AP9 for a press frame. RED (the review's tests-first stub: a press
    /// frame named by its footprint only, as by the press's id): old == new, nothing asked, the inputs
    /// returned unchanged.
    func testADirectionChangeIsTwoFrames() throws {
        let sp = try FlexiblePressReframeTests.split()
        let d1 = SIMD3<Double>(0, 0, -1)
        let d2 = simd_normalize(SIMD3<Double>(0.2, 0, -1))
        let old = FlexiblePressFrame(regions: [sp.top], direction: d1), new = FlexiblePressFrame(regions: [sp.top], direction: d2)
        XCTAssertNotEqual(old, new, "★ two directions, two frames")
        XCTAssertNotEqual(FlexibleFrameRef.press(old), .press(new))
        let ulp = FlexiblePressFrame(regions: [sp.top], direction: SIMD3(d1.x, d1.y, d1.z.nextUp))
        XCTAssertNotEqual(old, ulp, "★ one ulp is another frame")
        XCTAssertEqual(old, FlexiblePressFrame(regions: [sp.top], direction: d1), "the same footprint and bits: the same frame")
        XCTAssertEqual(Set([old, new, ulp, FlexiblePressFrame(regions: [sp.top], direction: d1)]).count, 3, "hashing agrees with ==")
        let source = PressFramesByDirection(sp.frames, [(old, sp.top), (new, sp.topB)])
        let f = try FlexiblePressReframeTests.topPress(sp)
        let viaPress = try FlexiblePressReframe.reframe(f, from: .press(old), to: .press(new), frames: source)
        let viaFaces = try FlexiblePressReframe.reframe(f, from: .face(sp.top), to: .face(sp.topB), frames: sp.frames)
        print("FLEX-AP1 review re-aim: frames asked \(source.asked.count) · \(source.asked.map { Self.bits($0.direction).map { String($0, radix: 16) } })")
        XCTAssertTrue(source.asked.contains(old) && source.asked.contains(new), "★ both frames asked for")
        XCTAssertEqual(viaPress, viaFaces, "★ core's answer for the two frames")
        XCTAssertNotEqual(viaPress.settings, f, "premise: the move changes the inputs")
        // the open scene: a press frame waits on core (AP9)
        XCTAssertThrowsError(try FlexiblePressReframe.reframe(f, from: .press(old), to: .press(new), frames: sp.frames)) {
            XCTAssertEqual($0 as? FlexiblePressReframe.Waiting, .pressFrame)
        }
        // the same frame: nothing asked, the inputs as they were
        let again = PressFramesByDirection(sp.frames, [(old, sp.top)])
        XCTAssertEqual(try FlexiblePressReframe.reframe(f, from: .press(old), to: .press(old), frames: again).settings, f)
        XCTAssertTrue(again.asked.isEmpty)
    }

    /// ★ The frame of record is SAVED by value: a press whose inputs were drawn in an earlier press frame
    /// (footprint + direction) and a tilt drawn in its face's frame round-trip through the app's own
    /// persist and a new AppModel's open, bit for bit; the file holds `{"face": 5}` and
    /// `{"press": {"direction": […], "regions": […]}}`. RED (the review's tests-first stub): the press
    /// frame's direction written through Float.
    func testTheFrameOfRecordRoundTripsThroughSaveAndLoad() throws {
        let r = try FlexiblePressFixtures.hisRound5(self)
        var s = try XCTUnwrap(r.project.lattice.flexible)
        let topA = FlexibleHisProject.topA
        let drawn = simd_normalize(SIMD3<Double>(0.123456789, -0.3, -1))
        let corner = FlexiblePress(id: UUID(uuidString: "AE000005-0000-4000-8000-000000000001")!, regions: [topA, 3, 2],
                                   direction: simd_normalize(SIMD3(-1, 1, -1)), snap: "halfway",
                                   settings: FlexibleFaceSettings(faceRegionID: topA, weightKg: 3),
                                   drawnIn: .press(FlexiblePressFrame(regions: [topA, 3], direction: drawn)))
        let face5 = try XCTUnwrap(s.face(5))
        let tilt = FlexiblePress(id: UUID(uuidString: "AE000005-0000-4000-8000-000000000002")!, regions: [5],
                                 direction: simd_normalize(SIMD3(0, 0.2, -1)), settings: face5, drawnIn: .face(5))
        s.removeFace(5)
        s.setPresses([corner, tilt])
        r.project.lattice.flexible = s
        let (back, saved) = try Self.saveAndReopen(r)
        let file = try XCTUnwrap(saved["presses"] as? [[String: Any]])
        let frames = file.compactMap { $0["drawnIn"] as? [String: Any] }
        print("FLEX-AP1 review frame of record in the file: \(frames)")
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual((frames.last?["face"] as? Int), 5, "a face frame is {\"face\": 5}")
        let pressFrame = try XCTUnwrap(frames.first?["press"] as? [String: Any], "a press frame is {\"press\": {…}}")
        XCTAssertEqual(pressFrame["regions"] as? [Int], [topA, 3])
        XCTAssertEqual((pressFrame["direction"] as? [Double])?.count, 3)
        XCTAssertEqual(back.presses, [corner, tilt], "every press, every field")
        guard case .press(let p)? = back.presses?.first?.drawnIn else { return XCTFail("the corner's frame of record is a press frame") }
        XCTAssertEqual(Self.bits(p.direction), Self.bits(drawn), "★ the frame of record's direction, bit for bit")
        XCTAssertEqual(p.regions, [topA, 3])
        XCTAssertEqual(back.presses?.last?.drawnIn, .face(5))
    }

    // MARK: - the linked weight's bits

    /// ★ A linked press's weight is the same BITS on every call and every re-sync: Σ share × the group's
    /// weight is summed in his pick order (de-duplicated), never in a Set's per-instance order. Shares
    /// 0.1 / 0.2 / 0.7 of 3 kg sum to two different doubles depending on the order (the control), so each
    /// of the six pick orders must give ITS order's sum every time, and 200 re-syncs of one corner press
    /// never rewrite it. RED (AP1 as it was, `for r in Set(regions)`): another order's sum.
    func testALinkedWeightIsTheSameBitsEveryCall() {
        let g = UUID()
        func entry(_ r: Int, _ share: Double) -> FlexibleMainPageLoads.Entry {
            .init(region: r, role: .pressed, weightKg: 3 * share, groupID: g, groupName: "Corner", groupKg: 3,
                  share: share, pressFraction: 1, groupRegions: 3)
        }
        let entries = [10: entry(10, 0.1), 11: entry(11, 0.2), 12: entry(12, 0.7)]
        let orders = [[10, 11, 12], [10, 12, 11], [11, 10, 12], [11, 12, 10], [12, 10, 11], [12, 11, 10]]
        var sums = Set<UInt64>()
        var wrong = 0
        for order in orders {
            let want = order.reduce(0.0) { $0 + entries[$1]!.share * entries[$1]!.groupKg }
            sums.insert(want.bitPattern)
            for _ in 0..<50 {
                let got = FlexiblePress.linkedKg(regions: order, group: g, loads: FlexibleMainPageLoads(entries: entries))
                if got?.bitPattern != want.bitPattern { wrong += 1 }
            }
            // de-duplicated: a repeated member counts once
            XCTAssertEqual(FlexiblePress.linkedKg(regions: order + [order[0]], group: g, loads: FlexibleMainPageLoads(entries: entries))?.bitPattern,
                           want.bitPattern)
        }
        print("FLEX-AP1 review linked bits: \(sums.count) distinct order sums · \(wrong) of \(orders.count * 50) calls off their order's sum")
        XCTAssertEqual(sums.count, 2, "control: these shares sum to two doubles by order")
        XCTAssertEqual(wrong, 0, "★ every call gives its pick order's sum")
        // the re-sync never rewrites an untouched corner press
        var s = FlexibleStageSettings(materialID: "varioshore_tpu")
        let order = [12, 10, 11]
        let kg = order.reduce(0.0) { $0 + entries[$1]!.share * entries[$1]!.groupKg }
        s.setPresses([FlexiblePress(regions: order, direction: simd_normalize(SIMD3(-1, -1, -1)),
                                    settings: FlexibleFaceSettings(faceRegionID: 12, weightKg: kg, weightFrom: g))])
        var rewrites = 0
        for _ in 0..<200 {
            var t = s
            FlexiblePress.adoptWeights(FlexibleMainPageLoads(entries: entries), into: &t)
            if t != s { rewrites += 1 }
        }
        print("FLEX-AP1 review re-sync rewrites: \(rewrites) of 200")
        XCTAssertEqual(rewrites, 0, "★ no re-sync rewrites an untouched press")
    }

    // MARK: - the trash

    /// ★ His r5: top A tilted (a press of its own, linked to Top), then trashed. Its member is remembered
    /// as deleted in the SAME edit (S6: "a face he deleted stays deleted"), so the next re-sync shows what
    /// the trash showed — top A not pressed — instead of re-pressing it at Top's weight with default curves
    /// in another undo step. Pressing it again brings it back as a new face. A member no main-page group
    /// holds is not recorded (the pad: the file as it was — FlexiblePressSaveTests). RED (AP1 as it was):
    /// the re-sync re-pressed top A.
    func testRemovingAPressLeavesItsMembersAsHeLeftThem() throws {
        let r = try FlexiblePressFixtures.hisRound5(self)
        let m = FlexiblePressSaveTests.model(r.project)
        m.adoptMainPageLoads()
        let topA = FlexibleHisProject.topA
        let top = try XCTUnwrap(r.project.selection.groups.first { $0.name == "Top" }).id
        XCTAssertFalse(m.mainPageLoads.canRemove(topA), "premise: Top presses top A")
        let id = try XCTUnwrap(m.tilt(topA, direction: simd_normalize(SIMD3(0.2, 0, -1)), snap: nil))
        m.removePress(id)
        let trashed = m.settings
        XCTAssertNil(trashed.face(topA))
        XCTAssertTrue(trashed.isRemoved(topA), "★ remembered as deleted, in the trash's own edit")
        m.adoptMainPageLoads()
        print("FLEX-AP1 review trash: after the re-sync top A \(m.settings.face(topA).map { "\($0.role) \($0.weightKg) kg" } ?? "not pressed")")
        XCTAssertNil(m.settings.face(topA), "★ the re-sync does not re-press it")
        XCTAssertEqual(m.settings, trashed, "★ the state the trash showed")
        XCTAssertTrue(m.press(topA), "pressing it again …")
        XCTAssertEqual(m.settings.face(topA)?.weightFrom, top, "… brings it back at Top's weight")
        XCTAssertFalse(m.settings.isRemoved(topA))
    }

    // MARK: - the two mutators

    /// ★ setMembers and aim are the only ways to change a press's footprint or direction: setMembers renames
    /// it (faceRegionID = regions[0]), keeps a snap only while its target holds (a member face still in it,
    /// or build Z; never the halfway, which moves with the members); both record the frame the inputs were
    /// drawn in when it was the press's own (`drawnIn` = the OLD press frame), keep a tilt's face frame,
    /// and aim refuses a direction that is not finite or has no length. RED (the review's tests-first
    /// stubs): only the field changed.
    func testAMemberChangeAndAReAimKeepTheFrameTheInputsWereDrawnIn() {
        let d = simd_normalize(SIMD3<Double>(-1, -1, -1))
        func press(_ regions: [Int], snap: String?, drawnIn: FlexibleFrameRef? = nil) -> FlexiblePress {
            FlexiblePress(regions: regions, direction: d, snap: snap, settings: FlexibleFaceSettings(faceRegionID: regions[0], weightKg: 5),
                          drawnIn: drawnIn)
        }
        var p = press([7, 3, 2], snap: "face:3")
        let old = p.frame
        XCTAssertEqual(p.inputsFrame, .press(old), "drawn in its own frame")
        XCTAssertTrue(p.setMembers([9, 2]))
        XCTAssertEqual(p.regions, [9, 2])
        XCTAssertEqual(p.settings.faceRegionID, 9, "★ core names it by regions[0]")
        XCTAssertNil(p.snap, "★ face 3 left: the snap holds no more")
        XCTAssertEqual(p.drawnIn, .press(old), "★ its inputs keep the frame they were drawn in")
        XCTAssertEqual(p.inputsFrame, .press(old))
        XCTAssertEqual(p.kind, .edge)
        XCTAssertFalse(p.setMembers([9, 2]), "the same members: nothing changes")
        XCTAssertFalse(p.setMembers([]), "no member: nothing changes")
        var keep = press([7, 3, 2], snap: "face:2")
        keep.setMembers([7, 2])
        XCTAssertEqual(keep.snap, "face:2", "a member face that stays keeps its snap")
        var half = press([7, 3, 2], snap: "halfway")
        half.setMembers([7, 3])
        XCTAssertNil(half.snap, "the halfway moves with the members")
        var build = press([7, 3, 2], snap: "build")
        build.setMembers([7, 3])
        XCTAssertEqual(build.snap, "build")
        var tilted = press([5], snap: nil, drawnIn: .face(5))
        tilted.setMembers([5, 6])
        XCTAssertEqual(tilted.drawnIn, .face(5), "a tilt's face frame is kept")

        var a = press([7, 3], snap: "halfway")
        let a0 = a.frame
        for bad in [SIMD3<Double>(.nan, 0, 0), .zero, SIMD3(0, .infinity, 0)] {
            XCTAssertFalse(a.aim(bad, snap: nil), "★ refused: \(bad)")
        }
        XCTAssertEqual(Self.bits(a.direction), Self.bits(d), "nothing changed")
        XCTAssertNil(a.drawnIn)
        XCTAssertEqual(a.snap, "halfway")
        XCTAssertTrue(a.aim(SIMD3(0, 0, -1), snap: "build"))
        XCTAssertEqual(Self.bits(a.direction), Self.bits(SIMD3(0, 0, -1)), "exactly the direction given")
        XCTAssertEqual(a.snap, "build")
        XCTAssertEqual(a.drawnIn, .press(a0), "★ the old direction's frame is the frame of record")
        XCTAssertTrue(a.aim(simd_normalize(SIMD3(0, 0.6, -0.8)), snap: nil))
        XCTAssertEqual(a.drawnIn, .press(a0), "a second re-aim keeps the frame they were drawn in")
        var same = press([7, 3], snap: nil)
        XCTAssertTrue(same.aim(d, snap: "halfway"))
        XCTAssertNil(same.drawnIn, "the same bits: the same frame, nothing recorded")
        tilted.aim(SIMD3(0, 0, -1), snap: nil)
        XCTAssertEqual(tilted.drawnIn, .face(5), "a tilt keeps its face frame through a re-aim")
    }

    // MARK: - undo

    /// ★ A press action is its OWN undo step (the edit before it is sealed first, as Reset all and every
    /// Surface action do), and the press card follows the page's undo / redo: a press the history took
    /// away is no longer selected. RED (AP1 as it was): one undo took the press of the top AND the tilt,
    /// and the card stayed open on a press that no longer existed.
    func testAPressActionIsItsOwnUndoStepAndTheCardFollowsTheHistory() throws {
        let (pm, m, top, _, _) = try FlexiblePressSaveTests.pad()
        pm.sealUndoStep()   // the setup is its own step
        XCTAssertTrue(m.press(top, kg: 12))
        let id = try XCTUnwrap(m.tilt(top, direction: simd_normalize(SIMD3(0.2, 0, -1)), snap: nil))
        m.selectedPress = id
        FlexibleStagePage.history(undo: true, project: pm, model: m)
        print("FLEX-AP1 review undo: top \(m.settings.face(top).map { "\($0.weightKg) kg" } ?? "not pressed") · presses \(m.settings.presses?.count ?? 0) · selected \(m.selectedPress.map { "\($0)" } ?? "nil")")
        XCTAssertNil(m.settings.presses, "the tilt undone …")
        XCTAssertEqual(m.settings.face(top)?.weightKg, 12, "★ … and only the tilt: the press of the top stays")
        XCTAssertNil(m.selectedPress, "★ no card open on a press the history took away")
        FlexibleStagePage.history(undo: false, project: pm, model: m)
        XCTAssertEqual(m.settings.presses?.map(\.id), [id], "redo brings the tilt back")
        XCTAssertNil(m.settings.face(top))
    }
}
