// FlexibleLatticeOnlyGateTests — round 7, batch R7-D2, the lattice-only role (H35) and the reviewer's condition (d), written
// BEFORE the code (red run: round7/batch_d2/d2_red_run.txt).
//
// Condition (d), binding (2026-10-14 19:45): "H35 OK as a new optional field nil off Flexible. Add a decode test: an old
// project without the field opens; goldens and hashes unchanged" AND "a lattice-only group shown as Pending on Topology is
// OK ONLY IF it changes nothing about a Topology run: must not block Run, not loaded/anchored/protected, the solve
// byte-identical with and without it — prove with ONE test; if it does change a Topology run, STOP and tell the reviewer."
//
// ★ THE ANSWER, MEASURED (before any D2 code; round7/batch_d2/conditionD/): it DOES change a Topology run, either way —
//   * without H35 the role is pruned, the group is Pending, and Topology's Optimize is BLOCKED ("finish the pending group");
//   * with H35 Run is not blocked and nothing is loaded / anchored / protected, but Topology's job gains the face's include
//     slab in its lattice block (AppModel.makeRunRequest carries latticeRunSpec(emission: latticeJobRegions()) whenever
//     lattice.enabled — as every face-prism of a Flexible project already rides it).
// So H35 is HELD (STOPPED, posted to the reviewer 2026-10-18T02-40-59.241Z-362-7436ed). The test below pins today's facts
// (H35 absent): a lattice-role group with no anchor / load / protect BLOCKS Topology's Run — the reason the role cannot ship
// without H35 — and the job is unchanged by it. When the reviewer rules, this test is re-pinned to the ruling.
import XCTest
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleLatticeOnlyGateTests: XCTestCase {

    func topologyJob(_ app: AppModel) throws -> String {
        let req = try XCTUnwrap(app.makeRunRequest(), "the Topology run request")
        let d = try RemoteRun.buildJobJSON(req)
        let pretty = try JSONSerialization.data(withJSONObject: try JSONSerialization.jsonObject(with: d), options: [.prettyPrinted, .sortedKeys])
        return String(decoding: pretty, as: UTF8.self)
    }

    /// (d) part 1: an old project.json without the key decodes (nil), and an untouched project re-encodes byte-identical.
    func testAnOldProjectWithoutTheKeyDecodesAndReEncodesByteIdentical() throws {
        let src = FlexiblePressFixtures.a1Dir(3).appendingPathComponent("project.json")
        let data = try Data(contentsOf: src)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("latticeOnlyGroups"), "premise: an old project, no key")
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        XCTAssertNotNil(r.project.lattice.flexible, "his Flexible pad opened")
        XCTAssertNil(r.project.lattice.flexible?.latticeOnlyGroups, "★ decodes with the field nil")
        // a Flexible settings value round-trips with no key while nil
        let s = try XCTUnwrap(r.project.lattice.flexible)
        let enc = try JSONEncoder().encode(s)
        XCTAssertFalse(String(decoding: enc, as: UTF8.self).contains("latticeOnlyGroups"), "★ nil is never encoded")
        XCTAssertEqual(try JSONDecoder().decode(FlexibleStageSettings.self, from: enc), s)
        // the field set: it encodes, and decodes back
        var t = s
        t.latticeOnlyGroups = [UUID(uuidString: "A1000001-AAAA-4000-8000-000000000009")!]
        let enc2 = try JSONEncoder().encode(t)
        XCTAssertTrue(String(decoding: enc2, as: UTF8.self).contains("latticeOnlyGroups"))
        XCTAssertEqual(try JSONDecoder().decode(FlexibleStageSettings.self, from: enc2).latticeOnlyGroups, t.latticeOnlyGroups)
        // display / main-page data: never the lattice's key
        XCTAssertNil(t.designInputs.latticeOnlyGroups, "★ not a design input (the face-prisms reach the lattice through the scene)")
    }

    /// Reset all (R7-S) keeps the set: it is main-page data, not the Squish page's.
    func testResetAllKeepsTheSet() async throws {
        let (r, _, m) = try await FlexibleR7M1Fixtures.hisPad(self, live: true)
        let id = UUID(uuidString: "A1000001-AAAA-4000-8000-000000000009")!
        r.project.lattice.flexible?.latticeOnlyGroups = [id]
        m.resetAll()
        XCTAssertEqual(r.project.lattice.flexible?.latticeOnlyGroups, [id], "★ Reset all keeps the main page's lattice-only set")
    }

    /// ★ (d) part 2 — THE STOP's evidence, pinned as it stands (H35 not landed): a group with only a lattice role (no anchor,
    /// no load, no Protect) — what chip N's [Lattice] would make — BLOCKS Topology's Optimize, and leaves Topology's job bytes
    /// unchanged. RED CONTROL (the other route): the same face as a Protect + Lattice group (today's recipe) changes the job.
    func testConditionDALatticeOnlyGroupAndATopologyRun() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        _ = try FlexibleR7M1Fixtures.hisLiveLattice(p)
        func canRun() -> Bool {
            p.force.canOptimize(in: p.selection.groups, minimizePlastic: p.minimizePlastic, latticeRoleGroups: Set(p.latticeEligibleRoles().keys))
        }
        XCTAssertTrue(canRun(), "premise: his pad's Topology Run is allowed")
        let before = try topologyJob(r.app)
        let gid = p.selection.addGroup()
        p.selection.addFaces([4], to: gid)
        p.force.sync(groups: p.selection.groups)
        p.lattice.groupRoles[gid] = .include
        p.lattice.groupDepthMM[gid] = 25
        p.lattice.selectableRoles[LatticeSelectableRef.face(group: gid, face: 4).key] = .include
        XCTAssertTrue(p.force.kind(for: gid).isPending, "not loaded, not anchored")
        XCTAssertFalse(p.force.isProtected(gid), "not protected")
        XCTAssertFalse(canRun(), "★ FACT (H35 held): a lattice-role-only group is Pending and BLOCKS Topology's Run")
        XCTAssertEqual(try topologyJob(r.app), before, "★ FACT: its role is pruned, so the job is unchanged")
        // the reviewer's assertion, as it would be with H35 landed, cannot hold: see conditionD/d2_conditionD_probe_raw.txt
        // (Run not blocked, but the job gains Face 4's include slab, 3 479 → 4 374 bytes)
        // ★ RED CONTROL: the same face behind Protect (today's recipe) — Run allowed, the job moves (a face-prism + a protection)
        p.force.setProtected(gid, true)
        XCTAssertTrue(canRun())
        XCTAssertNotEqual(try topologyJob(r.app), before, "★ RED CONTROL: an eligible face-prism rides Topology's lattice block")
    }
}
