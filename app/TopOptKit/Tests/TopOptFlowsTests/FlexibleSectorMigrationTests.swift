// FlexibleSectorMigrationTests — round 7 batch M2 (step 2b), written BEFORE the code (the stubs' red run:
// round7/batch_m2/r7m2_red_run.txt). The reviewer's ruling 3: "If I2 already writes Surface sectors, move them to
// Flexible-only and say what moved." I2 (round 6) cut his edge strips with the Surface tool's own cut INTO the Surface
// stage's regions (`project.faceRegions`), so Topology, the lattice stage and the Stress solve carried them. A project saved
// that way (no Flexible store, a strip member with a Surface root) is moved ONCE: its strips become Flexible-only sectors
// (the same cuts, bit for bit), the Surface stage's regions are as before the cut, and the Report says what moved.
// The I2 state is made through I2's own route (FlexibleSectors.controlSurfaceRoute — the round-6 code path, kept as the red
// control), saved, and given to a second copy of his pad as a reload would.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleSectorMigrationTests: XCTestCase {
    typealias F = FlexibleM2Fixtures
    typealias G = FlexibleAngledGoldens

    override func tearDown() {
        FlexibleSectors.controlSurfaceRoute = false
        FlexibleSectorMigration.controlNoMigration = false
        super.tearDown()
    }

    struct Legacy {
        let regions: FaceRegionModel        // the Surface stage's regions I2 left
        let flexible: FlexibleStageSettings // the settings I2 saved
        let preCut: FaceRegionModel         // the Surface stage's regions before the cut
        let topology: Data, stage: Data, stress: String   // the other stages' requests before the cut
    }

    /// His pad (the Top at 20 mm), Edge 9 (the Top + Face 2) picked through I2's route, then saved: what I2 left.
    func makeLegacy() async throws -> Legacy {
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let m = try await G.openModel(self, r.project, "A1_0003")
        try await FlexibleSquishFixture.settle(m, "A1_0003")
        let preCut = r.project.faceRegions
        let before = try F.otherStages(r.app)
        FlexibleSectors.controlSurfaceRoute = true
        defer { FlexibleSectors.controlSurfaceRoute = false }
        let pick = try await F.pickMode(m)
        m.toggleEdgePick(try XCTUnwrap(F.edge(m, pick, faces: [1, 2]), "Edge 9: the Top + Face 2").number)
        let why = try await F.done(m)
        XCTAssertNil(why, "I2's [Done]")
        let flex = try XCTUnwrap(r.project.lattice.flexible)
        XCTAssertTrue(FlexibleSectorMigration.isLegacy(flex), "premise: I2's form (a strip with a Surface root, no Flexible store)")
        XCTAssertNotEqual(r.project.faceRegions, preCut, "premise: I2 cut the Surface stage's regions")
        return Legacy(regions: r.project.faceRegions, flexible: flex, preCut: preCut,
                      topology: before.topology, stage: before.stage, stress: before.stress)
    }

    /// A second copy of his pad given what I2 saved (as the store's reload gives it), undo seeded there.
    func reload(_ l: Legacy, edit: ((ProjectModel) -> Void)? = nil) throws -> FlexibleHisProject.Restored {
        let r = try FlexiblePressFixtures.a1Project(3, self)
        r.project.faceRegions = l.regions
        r.project.lattice.flexible = l.flexible
        r.project.seedUndoBaseline()
        edit?(r.project)
        return r
    }

    /// The stage opened the app's way (FlexibleMainStage's one model per project), settled.
    func open(_ r: FlexibleHisProject.Restored) async throws -> (FlexibleMainStage, FlexibleStageModel) {
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        try await Task.sleep(nanoseconds: 100_000_000)   // the move at open is made right after the stage binds (never in a view's init)
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "reloaded")
        return (s, m)
    }

    static func bits(_ cuts: [RegionCut]) -> [[UInt64]] {
        cuts.map { [$0.point.x, $0.point.y, $0.point.z, $0.normal.x, $0.normal.y, $0.normal.z].map(\.bitPattern) + [$0.strict ? 1 : 0] }
    }

    // MARK: - (1) the strips move to Flexible; the Surface stage is as before the cut

    func testI2StripsMoveToFlexibleAndSurfaceIsAsBeforeTheCut() async throws {
        let l = try await makeLegacy()
        let r = try reload(l)
        let leaked = try F.otherStages(r.app)
        XCTAssertNotEqual(leaked.topology, l.topology, "premise: I2's strips reach Topology's job")
        let (_, m) = try await open(r)
        let p = r.project
        XCTAssertEqual(p.faceRegions.regions, l.preCut.regions, "★ the Surface stage's regions as before the cut")
        XCTAssertFalse(p.canUndoNow, "★ the move is the loaded state (nothing was undoable)")
        let report = try XCTUnwrap(m.migrationReport, "★ the Report says what moved")
        let press = try XCTUnwrap(m.presses.first { $0.strip != nil })
        let old = try XCTUnwrap(l.flexible.presses?.first { $0.id == press.id }, "the same press")
        XCTAssertTrue(press.regions.allSatisfy(FlexibleRegions.isFlexible), "★ its strips are Flexible-only sectors \(press.regions)")
        for (k, id) in press.regions.enumerated() {
            let was = try XCTUnwrap(l.regions.region(old.regions[k] - FlexibleRegions.sectorBase), "the old Surface strip")
            XCTAssertEqual(Self.bits(m.regions.cuts(of: id)), Self.bits(was.cuts), "★ member \(k): the same cuts, bit for bit")
        }
        let removed = l.regions.regions.filter { r in !l.preCut.regions.contains { $0.id == r.id } }.map(\.id).sorted()
        XCTAssertEqual(report.removed.map(\.id).sorted(), removed, "★ the Report lists every Surface region removed")
        XCTAssertEqual(Set(report.made.map(\.id)), Set((m.regions.flexible?.pieces ?? []).map(\.wireID)), "★ and every Flexible piece made")
        print("FLEX-M2-MIG removed \(report.removed.map { "\($0.id) \($0.name)" }) · made \(report.made.map { "\($0.id) \($0.key)" }) · re-keyed \(report.rekeyed.map { "\($0.old)→\($0.new) \($0.owner)" })")
        let now = try F.otherStages(r.app)
        XCTAssertEqual(now.topology, l.topology, "★ Topology's job: its bytes before the cut")
        XCTAssertEqual(now.stage, l.stage, "★ the lattice stage's job: its bytes before the cut")
        XCTAssertEqual(now.stress, l.stress, "★ the Stress solve's regions: as before the cut")

        // ★ RED CONTROL: no migration — the strips stay on the Surface stage, Topology carries them
        FlexibleSectorMigration.controlNoMigration = true
        let rc = try reload(l)
        _ = try await open(rc)
        XCTAssertEqual(rc.project.faceRegions, l.regions, "control: the Surface stage keeps I2's cuts")
        XCTAssertNotEqual(try F.otherStages(rc.app).topology, l.topology, "control: Topology still carries them")
    }

    // MARK: - (2) with an earlier edit, the next Flexible edit moves them (one undo step)

    func testWithAnEarlierEditTheNextFlexibleEditMovesThem() async throws {
        let l = try await makeLegacy()
        let r = try reload(l) { p in
            let g = p.selection.groups[0]
            p.selection.rename(g.id, to: g.name + " ")   // a Topology-side edit: something is undoable
        }
        XCTAssertTrue(r.project.canUndoNow, "premise: an edit before the stage opened")
        let (_, m) = try await open(r)
        let p = r.project
        XCTAssertEqual(p.faceRegions, l.regions, "★ nothing moved yet (an undo must not lose his earlier edit)")
        XCTAssertTrue((m.presses.first { $0.strip != nil }?.regions ?? []).allSatisfy(FlexibleRegions.isFlexible),
                      "★ the stage already reads the Flexible form")
        let g = try XCTUnwrap(m.squeezeGroups.first { $0.kind == .edges })
        p.sealUndoStep()
        m.setGroupForce(g.id, kg: 7)
        XCTAssertEqual(p.faceRegions.regions, l.preCut.regions, "★ his next Flexible edit moved them, in the same change")
        XCTAssertFalse(FlexibleSectorMigration.isLegacy(try XCTUnwrap(p.lattice.flexible)), "★ the file holds the Flexible form")
        p.sealUndoStep()
        p.performUndo()
        XCTAssertEqual(p.faceRegions, l.regions, "★ one undo: I2's bytes back")
        XCTAssertTrue((m.presses.first { $0.strip != nil }?.regions ?? []).allSatisfy(FlexibleRegions.isFlexible),
                      "★ and they still read as Flexible")
    }

    // MARK: - (3) a chain he uses on another stage stays there

    func testAChainHeUsesOnSurfaceStaysThere() async throws {
        let l = try await makeLegacy()
        let strip = try XCTUnwrap(l.flexible.presses?.first?.regions.first, "a strip piece")
        let used = strip - FlexibleRegions.sectorBase
        let r = try reload(l) { p in
            let g = p.selection.groups[0]
            p.selection.addRegions([used], to: g.id)   // he put the Top's strip into a Selections group on the main page
            p.seedUndoBaseline()
        }
        let (_, m) = try await open(r)
        let report = try XCTUnwrap(m.migrationReport)
        XCTAssertNotNil(r.project.faceRegions.region(used), "★ the chain he uses on another stage stays on the Surface stage")
        XCTAssertFalse(report.kept.isEmpty, "★ the Report says it stayed, and why")
        print("FLEX-M2-MIG kept: \(report.kept.map { "\($0.root): \($0.line)" })")
        for k in report.kept { XCTAssertLessThanOrEqual(k.line.count, 44) }
        let mesh = try XCTUnwrap(r.project.viewerMesh)
        XCTAssertTrue(FlexibleEdgeStrips.sharedSurface(m.settings, regions: m.regions, mesh: mesh).isEmpty, "★ no two entries share surface")
    }
}
