// FlexiblePressSaveTests — the saved press (task 2026-10-07, angled presses, batch AP1; final spec §4, §14,
// §15). The ruling's test "an angled press round-trips through save and load" is here, through the real
// ProjectStore and AppModel.open; so are the nil rule (no presses ⇒ the file as it was), the lattice key
// (a press core cannot build never stales the lattice), the main page's re-sync (a press member is never
// re-pressed as a face; a linked press follows its group), the weight rule (never an invented weight),
// tilt / straighten (one struct, intact) and Reset all.
//
// Each test names its RED control: the AP1 "tests first" commit carries the spec's red variant of every
// rule (direction through Float, [] for nil, no strip, no skip, no re-sync, `?? 10`, tilt dropping the
// link, Reset keeping the selection), and its red run is recorded beside the evidence (ap1_red_runs.txt).
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexiblePressSaveTests: XCTestCase {
    typealias G = FlexibleAngledGoldens

    static func bits(_ v: SIMD3<Double>) -> [UInt64] { [v.x.bitPattern, v.y.bitPattern, v.z.bitPattern] }

    /// A stage model over `pm` (no scene: the saved state needs none).
    static func model(_ pm: ProjectModel) -> FlexibleStageModel {
        FlexibleStageModel(project: pm, materialsPath: FlexibleHisProject.materialsPath,
                           stampsPath: FlexibleHisProject.stampsPath, persist: {})
    }

    /// C1's pad, its settings already in the migrated form (so an edit writes nothing else).
    static func pad() throws -> (ProjectModel, FlexibleStageModel, top: Int, xSide: Int, ySide: Int) {
        let pm = try FlexiblePressFixtures.padProject()
        pm.lattice.flexible = FlexibleSettingsMigration.migrated(try XCTUnwrap(pm.lattice.flexible))
        let mesh = try XCTUnwrap(pm.viewerMesh)
        let top = FlexibleHisProject.topFace(mesh)
        let x = FlexibleSquishFixture.face(mesh, axis: 0, value: 100), y = FlexibleSquishFixture.face(mesh, axis: 1, value: 0)
        XCTAssertTrue(top >= 0 && x >= 0 && y >= 0 && Set([top, x, y]).count == 3, "premise: the pad's top, x = 100 and y = 0 faces")
        return (pm, model(pm), top, x, y)
    }

    /// The `lattice` subtree as ProjectStore writes it (JSONEncoder, sorted keys).
    static func subtree(_ pm: ProjectModel) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return String(decoding: try enc.encode(pm.lattice), as: UTF8.self)
    }

    // MARK: - the ruling's test

    /// ★ THE RULING: "an angled press round-trips through save and load". His r5 as saved, with an EDGE
    /// press (Top A + face 3, at the halfway, in group 2) and a FREE TILT of face 5 along
    /// normalize(0.123456789, −0.3, −1) — saved by the app's own persist into a ProjectStore, then read by
    /// a NEW AppModel's open (the app's restore). Every field comes back; every direction component is
    /// bit-equal. RED: a direction stored through Float is not bit-equal (the AP1 red commit stores it so).
    func testAnAngledPressRoundTripsThroughSaveAndLoad() throws {
        let r = try FlexiblePressFixtures.hisRound5(self)
        let pm = r.project
        var s = try XCTUnwrap(pm.lattice.flexible)
        XCTAssertNil(s.presses, "premise: his r5 saved no presses")
        let halfway = simd_normalize(SIMD3<Double>(-1, 0, -1))
        let edgeSettings = FlexibleFaceSettings(faceRegionID: FlexibleHisProject.topA, weightKg: 4.25, deepestMM: 2.5,
                                                curveX: FlexCurve(x: [0, 0.37, 1], y: [0.2, 0.9, 0.4]),
                                                curveY: FlexCurve(x: [0, 0.61, 1], y: [0.5, 0.15, 0.8]), squeezeGroup: 2)
        let edge = FlexiblePress(id: UUID(uuidString: "AE000001-0000-4000-8000-000000000001")!,
                                 regions: [FlexibleHisProject.topA, 3], direction: halfway, snap: "halfway", settings: edgeSettings)
        let free = simd_normalize(SIMD3<Double>(0.123456789, -0.3, -1))
        let face5 = try XCTUnwrap(s.face(5), "premise: face 5 is pressed in r5")
        let tilt = FlexiblePress(id: UUID(uuidString: "AE000001-0000-4000-8000-000000000002")!,
                                 regions: [5], direction: free, snap: nil, settings: face5, drawnIn: 5)
        s.removeFace(5)
        s.setPresses([edge, tilt])
        pm.lattice.flexible = s
        r.app.persistCurrentProject()
        XCTAssertNil(r.app.toast, "the save succeeded")

        // the file holds them
        let file = r.root.appendingPathComponent(pm.id.uuidString).appendingPathComponent("project.json")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let saved = try XCTUnwrap(((json["lattice"] as? [String: Any])?["flexible"] as? [String: Any])?["presses"] as? [[String: Any]])
        XCTAssertEqual(saved.count, 2, "two presses in the file")
        XCTAssertEqual(saved.compactMap { $0["snap"] as? String }, ["halfway"], "the free tilt's nil snap is omitted")
        XCTAssertEqual(saved.compactMap { $0["drawnIn"] as? Int }, [5], "the edge's nil drawnIn is omitted")

        // a NEW app over the same store: the app's own restore
        let core = FlexibleHisProject.repoRoot.appendingPathComponent("core")
        let app2 = AppModel(materialsPath: core.appendingPathComponent("src/materials/materials.json").path,
                            rulesPath: core.appendingPathComponent("src/settings/rules.json").path,
                            store: ProjectStore(rootDir: r.root))
        app2.loadMaterials()
        let recent = try XCTUnwrap(app2.recentProjects.first { $0.id == pm.id })
        app2.open(recent)
        let back = try XCTUnwrap(app2.project?.lattice.flexible)
        XCTAssertEqual(back.presses, [edge, tilt], "every press, every field (Equatable)")
        XCTAssertEqual(back, s, "the whole Flexible setup")
        // every component's bits against the Double he aimed (not the struct's copy: a struct that rounded it
        // would compare equal to itself)
        for (got, (want, aimed)) in zip(back.presses ?? [], zip([edge, tilt], [halfway, free])) {
            print("FLEX-AP1 round trip \(want.kind): aimed \(aimed) bits \(Self.bits(aimed).map { String($0, radix: 16) }) → \(Self.bits(got.direction).map { String($0, radix: 16) }) · snap \(got.snap ?? "nil") · drawnIn \(got.drawnIn.map(String.init) ?? "nil")")
            XCTAssertEqual(Self.bits(got.direction), Self.bits(aimed), "★ \(want.kind): the direction he aimed, bit for bit")
            XCTAssertEqual(got.snap, want.snap)
            XCTAssertEqual(got.drawnIn, want.drawnIn)
            XCTAssertEqual(got.settings, want.settings)
        }
        XCTAssertEqual(back.presses?.first?.kind, .edge)
        XCTAssertEqual(back.presses?.last?.kind, .tilted)
        XCTAssertEqual(back.presses?.last?.settings.weightKg, face5.weightKg, "the tilt kept face 5's weight")
        // the stage model reads it through the migration unchanged
        let m = Self.model(try XCTUnwrap(app2.project))
        XCTAssertEqual(m.settings.presses, [edge, tilt])

        // ★ RED CONTROL: a direction that went through Float is NOT the same bits — a Float field would fail above
        let viaFloat = SIMD3<Double>(SIMD3<Float>(free))
        XCTAssertNotEqual(Self.bits(viaFloat), Self.bits(free), "control: the bit check sees a Float round trip")
    }

    // MARK: - the nil rule

    /// 0004, 0004_r5, 102117B9 and the A1 store's three Flexible projects decode with NO presses, and their
    /// lattice subtrees re-encode as the AP0 goldens (the base S1 will re-record). RED (in-test): an empty
    /// list where nil was changes every Flexible block.
    func testOldProjectsDecodeWithNoPresses() throws {
        var flexible = 0
        for src in G.subtreeSources {
            let snap = try JSONDecoder().decode(ProjectSnapshot.self, from: Data(contentsOf: src.url))
            XCTAssertNil(snap.lattice?.flexible?.presses, "\(src.name): no presses")
            let now = try G.latticeSubtree(src.url)
            XCTAssertFalse(now.contains("\"presses\""), "\(src.name): nothing written for them")
            let golden = try G.read(src.name)
            XCTAssertEqual(try G.flexibleBlock(now), try G.flexibleBlock(golden), "\(src.name): the flexible block")
            XCTAssertEqual(try G.canonicalSubtree(now), try G.canonicalSubtree(golden), "\(src.name): the whole subtree, canonical")
            guard snap.lattice?.flexible != nil else { continue }
            flexible += 1
            // ★ RED CONTROL: [] where nil was is a different file
            let empty = try G.latticeSubtree(src.url) { $0.flexible?.presses = [] }
            XCTAssertNotEqual(try G.flexibleBlock(empty), try G.flexibleBlock(golden), "control: \(src.name) with presses = []")
        }
        print("FLEX-AP1 old projects: \(G.subtreeSources.count) decoded, \(flexible) with a Flexible block, none with presses")
        XCTAssertGreaterThanOrEqual(flexible, 4, "premise: the Flexible projects are in the set")
    }

    /// A press added then removed leaves the file as it was: the last removal writes nil. RED: a removal
    /// that leaves [] changes the subtree (the AP1 red commit's removal does).
    func testRemovingTheLastPressWritesNil() throws {
        let (pm, m, _, x, y) = try Self.pad()
        let before = try Self.subtree(pm)
        XCTAssertFalse(before.contains("presses"), "premise: no presses")
        let id = try XCTUnwrap(m.addPress(regions: [x, y], direction: simd_normalize(SIMD3(-1, 1, 0)), snap: "halfway", kg: 6))
        XCTAssertEqual(m.settings.presses?.count, 1)
        XCTAssertTrue(try Self.subtree(pm).contains("\"presses\""))
        m.removePress(id)
        XCTAssertNil(m.settings.presses, "the last press leaves nil")
        XCTAssertNil(pm.lattice.flexible?.presses)
        XCTAssertEqual(try Self.subtree(pm), before, "the file as it was")
        // ★ RED CONTROL: [] in place of nil is not the file it was
        var s = try XCTUnwrap(pm.lattice.flexible)
        s.presses = []
        pm.lattice.flexible = s
        XCTAssertNotEqual(try Self.subtree(pm), before, "control: an empty list changes the subtree")
    }

    // MARK: - the lattice's key

    /// A press core cannot build never makes the lattice stale (designInputs strips the list until AP9),
    /// and the job stays the golden's. RED: the full settings' hash moved (a key on it would read stale) —
    /// the AP1 red commit keys on it.
    func testAPendingPressNeverMakesTheLatticeStale() async throws {
        let (m, _, _) = try await G.padModel(self)
        _ = try await FlexibleSquishFixture.build(m, "the pad")
        let lattice = try XCTUnwrap(m.lattice)
        XCTAssertFalse(m.latticeIsStale, "premise: the lattice is current")
        let fullBefore = m.settings.hashValue
        let mesh = try XCTUnwrap(m.project.viewerMesh)
        let x = FlexibleSquishFixture.face(mesh, axis: 0, value: 100), y = FlexibleSquishFixture.face(mesh, axis: 1, value: 0)
        let id = try XCTUnwrap(m.addPress(regions: [x, y], direction: simd_normalize(SIMD3(-1, 1, 0)), snap: "halfway"),
                               "group 1 has a force (the top's 30 kg)")
        await m.waitForIdle()
        XCTAssertEqual(m.press(id)?.settings.weightKg, 30, "it took group 1's one force")
        print("FLEX-AP1 pending press: stale \(m.latticeIsStale) · key \(lattice.settingsKey) · designInputs \(m.settings.designInputs.hashValue) · full \(fullBefore) → \(m.settings.hashValue)")
        XCTAssertFalse(m.latticeIsStale, "★ a press core can't build never stales the lattice")
        XCTAssertFalse(m.settingsOutranPipeline)
        XCTAssertEqual(m.settings.designInputs.hashValue, lattice.settingsKey)
        XCTAssertNil(m.settings.designInputs.presses)
        try G.assertGolden(try G.runJob(m, roots: [G.repo]), "c1_pad_model_run_job.json")
        // ★ RED CONTROL: the full settings moved — a key on them would read stale
        XCTAssertNotEqual(m.settings.hashValue, fullBefore, "control: the press is in the settings")
        XCTAssertNotEqual(m.settings.hashValue, lattice.settingsKey, "control: the full hash is not the lattice's key")
    }

    // MARK: - the main page's re-sync

    /// His r5: top A (linked to his "Top" Load group) tilted. The main page's re-sync (a scene open, a
    /// write-back) never presses it again as a face, and a group weight edit still reaches the press —
    /// Σ share × the group's weight, through its link. RED 1 (the AP1 red commit, no skip): top A is
    /// pressed twice, as a face and in the press. RED 2: with the link cleared the edit never reaches it.
    func testTheMainPageReSyncSkipsAPressMemberAndKeepsItsWeightLinked() throws {
        let r = try FlexiblePressFixtures.hisRound5(self)
        let m = Self.model(r.project)
        m.adoptMainPageLoads()
        let topA = FlexibleHisProject.topA, topB = FlexibleHisProject.topB
        let top = try XCTUnwrap(r.project.selection.groups.first { $0.name == "Top" }).id
        let a = try XCTUnwrap(m.settings.face(topA))
        XCTAssertEqual(a.weightFrom, top, "premise: top A takes Top's weight")
        let id = try XCTUnwrap(m.tilt(topA, direction: simd_normalize(SIMD3(0.2, 0, -1)), snap: nil))
        XCTAssertEqual(m.press(id)?.settings, a, "the struct moved intact, its link kept")
        m.adoptMainPageLoads()
        XCTAssertNil(m.settings.face(topA), "★ RED 1: the re-sync must not press top A again as a face")
        XCTAssertEqual(m.settings.pressRegions, [topA])
        XCTAssertEqual(m.press(id)?.settings.weightFrom, top, "still linked")
        // the press is in Top's HAND in its squeeze group (one force per hand)
        let g = try XCTUnwrap(m.squeezeGroup(ofPress: id))
        XCTAssertEqual(g.id, m.squeezeGroup(of: topB)?.id, "the same group as top B, the hand's other face")
        let hands = FlexibleSqueezeGroups.hands(g, settings: m.settings, loads: m.mainPageLoads, liveKg: m.liveMainKg)
        XCTAssertEqual(hands.first { $0.mainGroup == top }?.presses, [id], "Top's hand presses the press")
        XCTAssertEqual(m.groupForce(g), 10...10, "his group 1's one force (Top 10 kg, face 5 10 kg)")

        // a group weight edit on the main page reaches the press, by area, before any cos
        r.project.force.setWeight(top, kg: 12)
        m.adoptMainPageLoads()
        let ea = try XCTUnwrap(m.mainPageLoads.entry(topA)), eb = try XCTUnwrap(m.mainPageLoads.entry(topB))
        print("FLEX-AP1 re-sync: Top 12 kg · top A share \(ea.share) → press \(m.press(id)?.settings.weightKg ?? -1) kg · top B \(m.settings.face(topB)?.weightKg ?? -1) kg")
        XCTAssertEqual(m.press(id)?.settings.weightKg ?? 0, 12 * ea.share, accuracy: 1e-12, "★ RED 2's subject: the edit reaches the press")
        XCTAssertEqual(m.settings.face(topB)?.weightKg ?? 0, eb.weightKg, accuracy: 1e-12)
        // … and so does the squeeze group's ONE force (it writes the main-page group)
        m.setGroupForce(g.id, kg: 14)
        XCTAssertEqual(m.groupForce(try XCTUnwrap(m.squeezeGroup(ofPress: id))), 14...14)
        XCTAssertEqual(r.project.force.kind(for: top).weightKg ?? 0, 14, accuracy: 1e-12)
        XCTAssertEqual(m.press(id)?.settings.weightKg ?? 0, 14 * ea.share, accuracy: 1e-12)

        // ★ RED CONTROL 2: with the link cleared, the same kind of edit never reaches it
        m.edit { s in if var p = s.press(id) { p.settings.weightFrom = nil; s.setPress(p) } }
        r.project.force.setWeight(top, kg: 20)
        m.adoptMainPageLoads()
        XCTAssertEqual(m.press(id)?.settings.weightKg ?? 0, 14 * ea.share, accuracy: 1e-12, "control: unlinked, it keeps its own weight")
    }

    // MARK: - the weight rule

    /// A new press never invents a weight: with no main-page Load group and no group force the pad asks
    /// (nil, nothing saved); the pad's answer; then group 1's one force; then the members' Load group,
    /// linked, at Σ share × its weight BEFORE the cos (the main page presses those faces obliquely).
    /// RED: a `firstGroupForce ?? 10` rule presses at 10 kg (the AP1 red commit's).
    func testAPressNeverInventsAWeight() throws {
        let (pm, m, top, x, y) = try Self.pad()
        let d = simd_normalize(SIMD3<Double>(-1, 1, 0))
        XCTAssertTrue(m.pressNeedsWeight(regions: [x, y]))
        XCTAssertEqual(m.newPressWeight(regions: [x, y]), .ask)
        XCTAssertNil(m.addPress(regions: [x, y], direction: d, snap: "halfway"), "★ no weight anywhere: the pad must ask")
        XCTAssertNil(m.settings.presses, "★ nothing was pressed at an invented weight")
        // the pad's answer
        let own = try XCTUnwrap(m.addPress(regions: [x, y], direction: d, snap: "halfway", kg: 7))
        XCTAssertEqual(m.press(own)?.settings.weightKg, 7)
        XCTAssertNil(m.press(own)?.settings.weightFrom)
        m.removePress(own)
        // (2) group 1's one force
        XCTAssertTrue(m.press(top, kg: 12))
        XCTAssertEqual(m.newPressWeight(regions: [x, y]), .force(12))
        let joined = try XCTUnwrap(m.addPress(regions: [x, y], direction: d, snap: "halfway", kg: 99))
        XCTAssertEqual(m.press(joined)?.settings.weightKg, 12, "the group's one force, never the pad's number")
        m.removePress(joined)
        // (1) the members' main-page Load group, linked — pressing them at an angle on the main page
        let g = pm.selection.addGroup()
        pm.selection.addFaces([FaceID(x), FaceID(y)], to: g)
        pm.force.makeLoad(g)
        pm.force.setWeight(g, kg: 9)
        pm.force.setGravity(direction: SIMD3<Float>(simd_normalize(SIMD3<Double>(-1, 1, -0.5))))
        m.refreshMainPageLoads()
        let ex = try XCTUnwrap(m.mainPageLoads.entry(x)), ey = try XCTUnwrap(m.mainPageLoads.entry(y))
        XCTAssertTrue(ex.oblique && ey.oblique, "premise: the main page presses both faces at an angle")
        let linked = try XCTUnwrap(m.addPress(regions: [x, y], direction: d, snap: "halfway"))
        let p = try XCTUnwrap(m.press(linked))
        print("FLEX-AP1 weight rule: faces \(ex.weightKg) + \(ey.weightKg) kg at the main page's angle (c \(ex.pressFraction)) · the press \(p.settings.weightKg) kg linked \(p.settings.weightFrom == g)")
        XCTAssertEqual(p.settings.weightFrom, g, "linked to the members' Load group")
        XCTAssertEqual(p.settings.weightKg, ex.share * 9 + ey.share * 9, accuracy: 1e-12, "Σ share × its weight")
        XCTAssertEqual(p.settings.weightKg, 9, accuracy: 1e-12, "both members: the group's whole weight")
        XCTAssertNotEqual(p.settings.weightKg, ex.weightKg + ey.weightKg, accuracy: 1e-6, "before the cos — not the faces' oblique share")
        // ★ RED CONTROL (in-test): the faces' own main-page weights are the cos-scaled ones
        XCTAssertLessThan(ex.weightKg + ey.weightKg, 9 - 1, "control: the main page's at-an-angle weight is smaller")
    }

    // MARK: - tilt and straighten

    /// His r5's top A (linked to Top, a stamp, group 1): a tilt moves its struct INTACT into a press drawn
    /// in its own frame; straighten moves it back, and the face comes back the same. RED: a tilt that
    /// drops the link (the AP1 red commit's).
    func testTiltAndStraightenMoveOneStructIntact() throws {
        let r = try FlexiblePressFixtures.hisRound5(self)
        let m = Self.model(r.project)
        m.adoptMainPageLoads()
        let topA = FlexibleHisProject.topA
        let before = try XCTUnwrap(m.settings.face(topA))
        XCTAssertNotNil(before.weightFrom, "premise: linked")
        XCTAssertNotNil(before.designStamp, "premise: top A has a stamp")
        let groups = m.squeezeGroups.map(\.id)
        XCTAssertEqual(m.settings.face(0)?.isLoaded, false, "premise: face 0 rests")
        XCTAssertNil(m.tilt(0, direction: SIMD3(0, 0, -1), snap: nil), "a resting face is not tilted")
        let id = try XCTUnwrap(m.tilt(topA, direction: simd_normalize(SIMD3(0.3, 0, -1)), snap: nil))
        let p = try XCTUnwrap(m.press(id))
        XCTAssertEqual(p.settings, before, "★ the struct, intact: weight, link, curves, stamp, group")
        XCTAssertEqual(p.drawnIn, topA, "drawn in its face's frame")
        XCTAssertEqual(p.regions, [topA])
        XCTAssertEqual(p.kind, .tilted)
        XCTAssertNil(m.settings.face(topA), "it left the faces (its design leaves the page)")
        XCTAssertFalse(m.loadedKeys.contains { $0.region == topA })
        XCTAssertEqual(m.squeezeGroups.map(\.id), groups, "its group is the same group")
        XCTAssertNil(m.tilt(topA, direction: SIMD3(0, 0, -1), snap: nil), "a face already in a press is not tilted again")
        XCTAssertTrue(m.straighten(id))
        XCTAssertNil(m.settings.presses, "the last press gone: nil")
        XCTAssertEqual(m.settings.face(topA), before, "★ the face is back, the same struct")
        XCTAssertEqual(m.selectedRegion, topA)
        XCTAssertFalse(m.straighten(id), "nothing to straighten twice")
    }

    // MARK: - Reset all

    /// Reset all leaves no press and no selected press (freshSettings builds none). RED: a reset that keeps
    /// the selection (the AP1 red commit's).
    func testResetAllClearsPresses() throws {
        let (_, m, _, x, y) = try Self.pad()
        let id = try XCTUnwrap(m.addPress(regions: [x, y], direction: simd_normalize(SIMD3(-1, 1, 0)), snap: "halfway", kg: 5))
        m.selectedPress = id
        XCTAssertNotNil(m.settings.presses)
        XCTAssertNil(m.freshSettings().presses, "a brand-new setup has none")
        m.resetAll()
        XCTAssertNil(m.settings.presses)
        XCTAssertNil(m.selectedPress, "★ no press card left open on nothing")
    }
}
