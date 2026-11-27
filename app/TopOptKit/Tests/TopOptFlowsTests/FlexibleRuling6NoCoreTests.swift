// FlexibleRuling6NoCoreTests — round 7, the H39 hotfix (2026-10-17): the reviewer's ruling 6 of 2026-10-17 20:25 (approved
// by the maintainer): "M1: F10/F15/F16 — NO request of ANY kind (design, preview or run) goes to core from Flexible without a
// face-prism (test)." — "the same rule as Export (core's shared rule is 'no include = the whole part')". Written BEFORE the
// code (the red run: round7/batch_h39/h39_red_run.txt). On HIS pad as he saved it (A1_0003: nothing set to Lattice in
// Selections) through the main page's shared model, the app's way.
//
//   N1  with no face-prism NOTHING reaches the bridge: no scene is opened in core (so no stack, design, Auto, conflict,
//       stamp check, drawn map, preview mask or field, squish sim, frame or aim can be asked — each is a call ON a scene),
//       through every way the stage has to ask — the scene's open (again), a weight, a curve point, a recompute, Auto, the
//       main page's build and the model's, Ready's send and an Export step button. The stage is still ready and says the
//       one line; each face's card still offers [Lattice under it]. RED CONTROL `controlAskCoreWithoutPrism`: the stage
//       before ruling 6 — core's scene opened on the whole part and asked for stacks and designs (M1 verify, finding 10).
//   N2  a face-prism opens the door (his live lattice: one scene, stacks with lattice); taking the last one away shuts it
//       again — core's scene is let go and nothing more is asked (the worker refuses in his words).
//   N3  the door itself: a scene job with no face-prism is refused, counted, never opened.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleRuling6NoCoreTests: XCTestCase {
    typealias F = FlexibleR7M1Fixtures

    /// Every way the stage has to ask core, short of a face-prism: open again, a weight, a curve point, a recompute, Auto,
    /// the main page's build and the model's, Ready's send (the main stage's) and a step button's send.
    func knockEveryWay(_ s: FlexibleMainStage, _ m: FlexibleStageModel) async throws {
        let face = try XCTUnwrap(m.settings.loadedFaces.first?.faceRegionID, "premise: his pressed Top")
        m.openScene()
        m.setWeight(face, kg: 12)
        m.curveChanged(region: face)
        m.recomputeAll()
        m.scheduleAuto()
        s.buildIfReady()
        m.generateLattice()
        s.sendToCore()
        s.coreRun.send(m, fix: FlexibleCoreFix.send(resting: [], title: "Send Group 1 only", scope: "Group 1 only"))
        for _ in 0..<40 { try await Task.sleep(nanoseconds: 10_000_000) }
        await m.waitForIdle()
    }

    // MARK: - N1

    func testWithNoFacePrismNoRequestOfAnyKindReachesCore() async throws {
        let (_, s, m) = try await F.hisPad(self, live: false)
        let door = m.workerForTests.door
        XCTAssertFalse(m.facePrismsNow, "premise: his pad as saved sets no face-prism")
        XCTAssertFalse(m.settings.loadedFaces.isEmpty, "premise: his pressed faces (the main page's groups)")
        XCTAssertEqual(m.sceneState, .ready, "the stage is ready on the plain part")
        try await knockEveryWay(s, m)
        XCTAssertEqual(door.opened, 0, "★ no scene opened in core (core's rule would lattice the whole part)")
        XCTAssertEqual(door.asked, 0, "★ nothing asked on a scene: no stack, design, Auto, field, sim, frame")
        XCTAssertEqual(s.coreRun.runs, 0, "★ the run: core's runner never called")
        XCTAssertTrue(m.stacks.isEmpty && m.designs.isEmpty, "no stack, no design (nothing came from core)")
        XCTAssertNil(m.lattice, "no preview lattice")
        // what he sees is still the one line, and the per-face one-tap stays
        let rd = m.readiness
        XCTAssertEqual(rd.oneLine, FlexibleRowCopy.noFacePrism, "the Squish page's top line")
        XCTAssertTrue(rd.isReady, "nothing blocks: Exit still leaves (his answer: an empty setup may exit)")
        XCTAssertFalse(rd.designing, "★ never 'Still designing' — nothing is designed without a face-prism")
        XCTAssertNotNil(FlexibleLatticeUnder.first(rd), "each face's card still offers [Lattice under it]")
        XCTAssertFalse(s.viewsAvailable, "the lattice views stay unavailable (M1 verify)")
        XCTAssertEqual(s.status.line, FlexibleRowCopy.noFacePrism, "the big button's line: the reason")
        if case .notSent(let line, _) = s.coreRun.phase { XCTAssertEqual(line, FlexibleRowCopy.noFacePrism, "the card says why") }
        else { XCTFail("the card: not sent, with the reason (\(s.coreRun.phase))") }

        // ★ RED CONTROL: the stage before ruling 6 — core's scene opened on the whole part, stacks and designs asked
        let r2 = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let s2 = FlexibleMainStage()
        s2.reduceMotion = { true }
        let m2 = s2.model(for: r2.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        m2.controlAskCoreWithoutPrism = true
        addTeardownBlock { @MainActor in await m2.waitForIdle() }
        m2.openScene()
        try await FlexibleSquishFixture.settle(m2, "the control")
        try await FlexibleHisProject.waitFor(120, "the control's designs") { !m2.designs.isEmpty && !m2.designsInFlight }
        await m2.waitForIdle()
        let d2 = m2.workerForTests.door
        XCTAssertEqual(d2.opened, 1, "★ RED CONTROL: core's scene opened with no face-prism")
        XCTAssertGreaterThan(d2.asked, 0, "★ RED CONTROL: stacks and designs asked on it")
        XCTAssertFalse(m2.designs.isEmpty, "★ RED CONTROL: core's whole-part designs")
        print("FLEX-RULING6-N1 no face-prism: opened \(door.opened) asked \(door.asked) runs \(s.coreRun.runs) · line '\(rd.oneLine)' · control opened \(d2.opened) asked \(d2.asked) designs \(m2.designs.count)")
    }

    // MARK: - N2

    func testAFacePrismOpensTheDoorAndTakingTheLastOneAwayShutsItAgain() async throws {
        let (r, s, m) = try await F.hisPad(self, live: false)
        let p = r.project
        let door = m.workerForTests.door
        XCTAssertEqual(door.opened, 0, "premise: held — no face-prism")
        // his live lattice: Group C's Face 3 + Face 5 set to Lattice
        _ = try F.hisLiveLattice(p)
        XCTAssertTrue(m.facePrismsNow)
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his live lattice")
        XCTAssertEqual(door.opened, 1, "★ a face-prism: core's scene opens (once)")
        XCTAssertTrue(m.facePrismsSet)
        XCTAssertGreaterThan(door.asked, 0, "the stacks and designs are asked")
        XCTAssertTrue(m.loadedKeys.contains { (m.stacks[$0]?.latticedColumns ?? 0) > 0 }, "a stack with lattice under it")
        // the last face-prism taken away: lattice mode off on the main page (no include region left)
        p.lattice.enabled = false
        XCTAssertFalse(m.facePrismsNow, "premise: no face-prism now")
        m.openScene()
        await m.waitForIdle()
        let asked = door.asked
        try await knockEveryWay(s, m)
        XCTAssertEqual(door.opened, 1, "★ no new scene opened")
        XCTAssertEqual(door.asked, asked, "★ nothing more asked: core's old scene was let go")
        XCTAssertTrue(m.stacks.isEmpty && m.designs.isEmpty, "the old answers are gone with it")
        do {
            _ = try await m.workerForTests.withScene { _ in 0 }
            XCTFail("★ the worker holds no scene")
        } catch {
            XCTAssertEqual("\(error)", FlexibleRowCopy.noFacePrism, "★ …and says why in his words")
        }
        XCTAssertEqual(m.readiness.oneLine, FlexibleRowCopy.noFacePrism)
        print("FLEX-RULING6-N2 opened \(door.opened) asked \(door.asked) (unchanged after the last face-prism went)")
    }

    // MARK: - N4: a hold, then an open at once — the open's scene stays (found by the suite, a3784168)

    /// The suite's FlexibleFEFieldTests (a3784168): the stage held (no face-prism), the fixture set face-prisms and opened
    /// again in the same turn — the open reached the worker FIRST and the late hold dropped the new scene, so every stack was
    /// refused "Set a face to Lattice in Selections first". RED at a3784168 (the hold not awaited by the open).
    func testAHoldThenAnOpenAtOnceKeepsTheNewScene() async throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        XCTAssertTrue(m.heldWithoutFacePrism, "premise: held (its hold has not reached the worker yet)")
        _ = try F.hisLiveLattice(r.project)   // a face-prism in the same turn
        m.openScene()
        try await FlexibleHisProject.waitFor(90, "the scene and every stack (built or refused)") {
            m.sceneState == .ready && !m.heldWithoutFacePrism && m.loadedKeys.allSatisfy { m.stacks[$0] != nil || m.stackErrors[$0] != nil }
        }
        await m.waitForIdle()
        XCTAssertEqual(m.stackErrors.mapValues { $0 }.values.sorted(), [], "★ no stack refused by a late hold")
        XCTAssertTrue(m.loadedKeys.allSatisfy { m.stacks[$0] != nil }, "★ every stack built")
        let alive = (try? await m.workerForTests.withScene { _ in true }) ?? false
        XCTAssertTrue(alive, "★ the worker still holds the new scene")
        XCTAssertEqual(m.workerForTests.door.opened, 1)
    }

    // MARK: - N3

    func testTheDoorRefusesASceneJobWithNoFacePrism() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let m = FlexibleStageModel(project: r.project, materialsPath: FlexibleHisProject.materialsPath,
                                   stampsPath: FlexibleHisProject.stampsPath, persist: {})
        let job = try XCTUnwrap(try m.sceneJob(), "his pad's scene job")
        let door = FlexibleCoreDoor()
        XCTAssertThrowsError(try door.open(jobJSON: job.json, jobDir: job.dir, facePrism: false), "★ refused") { e in
            XCTAssertEqual(e as? FlexibleCoreDoor.Refusal, .noFacePrism)
            XCTAssertEqual("\(e)", FlexibleRowCopy.noFacePrism)
        }
        XCTAssertEqual(door.opened, 0, "★ nothing opened")
        XCTAssertEqual(door.refused, 1, "counted")
        XCTAssertFalse(m.mayAskCore(facePrism: false), "the stage's own rule: no face-prism, no core")
        XCTAssertTrue(m.mayAskCore(facePrism: true))
    }
}
