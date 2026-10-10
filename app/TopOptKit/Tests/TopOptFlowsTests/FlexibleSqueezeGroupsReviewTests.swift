// FlexibleSqueezeGroupsReviewTests — the D2 verifier's correctness findings, on HIS project 0004
// (task 2026-09-29-flexible-screens, round 4 batch D2 review). Each test states the finding, the
// fix and its RED control (the D2 behaviour, computed beside it, must differ).
//   * removing a group gives its faces the OTHER group's one force — RED: D2's remove left
//     "Squeeze 6–10 kg" and the next press asked for the pad;
//   * the Settings page's undo re-reads the main page — RED: D2's handler left "10–12 kg";
//   * a pinched face's warning counts its HALVES' unreached columns — RED: core's whole column (832);
//   * a main-page Load group is ONE hand: its faces move together, so one group's force never
//     rewrites another's — RED: D2 moved top B alone and Group 1 read "Squeeze 4–10 kg";
//   * the main page resting a face clears its group; a re-press joins a group that exists —
//     RED: D2's adopt kept the stale id ("Group 2" nobody made);
//   * one face's throw keeps the other faces' two-segment designs — RED: D2's one catch lost all;
//   * the ~24 MB combined field is kept only when a test asks — RED: D2 kept it after every build;
//   * the static run-job encoder refuses a pinch itself — RED: D2's refused only in the model.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class FlexibleSqueezeGroupsReviewTests: XCTestCase {

    @MainActor
    private func his(_ before: (ProjectModel) -> Void = { _ in }) async throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore()
        addTeardownBlock { r.cleanup() }
        before(r.project)
        let m = try await FlexibleHisProject.openedModel(r.project, test: self)
        try await settle(m)
        return (r, m)
    }

    @MainActor
    private func settle(_ m: FlexibleStageModel) async throws {
        await m.waitForIdle()
        try await FlexibleHisProject.waitFor(90, "the designs") { !m.readiness.designing && !m.designsInFlight && !m.latticeBuilding }
        await m.waitForIdle()
    }

    @MainActor
    private func lines(_ m: FlexibleStageModel) -> [String] { m.squeezeGroups.map { m.groupLine($0) } }

    // MARK: removing a group — ONE force (V1)

    @MainActor
    func testRemovingAGroupGivesItsFacesTheOtherGroupsOneForce() async throws {
        let (_, m) = try await his()
        m.newGroup(with: 3)
        let two = try XCTUnwrap(m.squeezeGroup(of: 3))
        m.setGroupForce(two.id, kg: 6)
        XCTAssertEqual(m.settings.face(3)?.weightKg ?? 0, 6, accuracy: 1e-9, "premise: group 2 squeezes 6 kg")
        // ★ RED CONTROL: D2's remove (the renumber alone) — one group, two forces
        var d2 = m.settings
        FlexibleSqueezeGroups.remove(group: two.id, in: &d2)
        let d2Force = FlexibleSqueezeGroups.force(FlexibleSqueezeGroups.groups(d2)[0], settings: d2, loads: m.mainPageLoads,
                                                  liveKg: m.liveMainKg)
        XCTAssertEqual(d2Force, 6...10, "control: D2's remove left one group with two forces")
        m.removeGroup(two.id)
        print("FLEX-REVIEW remove: \(lines(m)) · face 3 \(m.settings.face(3)?.weightKg ?? -1) kg · first force \(String(describing: m.firstGroupForce))")
        XCTAssertEqual(m.squeezeGroups.count, 1)
        XCTAssertEqual(m.groupForce(m.squeezeGroups[0]), 10...10, "ONE force: group 1's 10 kg")
        XCTAssertEqual(m.settings.face(3)?.weightKg ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(m.firstGroupForce, 10, "a newly pressed face joins at 10 kg")
        XCTAssertFalse(m.pressNeedsWeight(2), "no number pad for the next press")
    }

    // MARK: the Settings page's undo (V6)

    @MainActor
    func testTheSettingsPageUndoRestoresTheGroupsForceLine() async throws {
        let (r, m) = try await his()
        let top = try XCTUnwrap(r.project.selection.groups.first { $0.name == "Top" })
        r.project.sealUndoStep()
        m.setGroupForce(FlexibleSqueezeGroups.first, kg: 12)
        XCTAssertEqual(m.groupForce(m.squeezeGroups[0]), 12...12)
        // ★ RED CONTROL: D2's handler (the project's undo, then the designs) on a copy of the
        // cache: its Top entry still says 12 kg though the project says 10
        let cached = m.mainPageLoads
        FlexibleStagePage.history(undo: true, project: r.project, model: m)
        await m.waitForIdle()
        XCTAssertEqual(r.project.force.kind(for: top.id).weightKg ?? 0, 10, accuracy: 1e-9, "premise: the undo restored Top")
        let staleLine = FlexibleRowCopy.squeeze(FlexibleSqueezeGroups.force(m.squeezeGroups[0], settings: m.settings, loads: cached))
        XCTAssertEqual(staleLine, "Squeeze 10–12 kg", "control: D2's cache read the undone 12 kg")
        let row = try XCTUnwrap(FlexibleSqueezeGroupRows.rows(model: m).first)
        print("FLEX-REVIEW undo: \(lines(m)) · header \(row.line) [\(row.value)] seed \(row.kg) · first force \(String(describing: m.firstGroupForce))")
        XCTAssertEqual(m.groupForce(m.squeezeGroups[0]), 10...10)
        XCTAssertEqual(row.value, "10 kg", "the pill says the restored force")
        XCTAssertEqual(row.kg, 10, "the pad seeds 10")
        XCTAssertEqual(m.firstGroupForce, 10)
        XCTAssertFalse(m.pressNeedsWeight(2))
        XCTAssertEqual(m.mainPageLoads.entry(FlexibleHisProject.topA)?.groupKg ?? 0, 10, accuracy: 1e-9, "the cache follows the project")
        // the redo stack survives the re-read (no edit, no undo step)
        XCTAssertTrue(r.project.canRedoNow, "the re-read sealed nothing")
        FlexibleStagePage.history(undo: false, project: r.project, model: m)
        await m.waitForIdle()
        XCTAssertEqual(m.groupForce(m.squeezeGroups[0]), 12...12, "redo: 12 kg again")
    }

    // MARK: a pinched face's warning (V5)

    @MainActor
    func testAPinchedFacesWarningCountsItsHalvesNotTheWholeColumn() async throws {
        let (_, m) = try await his()
        for r in [3, 5] {
            let k = FlexFaceKey(region: r, rotation: 0)
            let d = try XCTUnwrap(m.design(r)), sg = try XCTUnwrap(m.segments[k])
            let halves = sg.status.filter { $0 == "too_soft" || $0 == "too_firm" || $0 == "beyond_data" }.count
            let whole = d.tooFirm + d.tooSoft + d.beyondData
            let line = FlexibleFaceRows.warning(model: m, region: r)
            print("FLEX-REVIEW face \(r) warning: '\(line ?? "nil")' · halves \(halves) · core's whole column \(whole)")
            XCTAssertEqual(line, halves > 0 ? "Can't reach your curve on \(halves) columns" : nil)
            // ★ RED CONTROL: D2 counted core's whole-column design
            XCTAssertNotEqual(halves, whole, "control: the whole column's count differs")
            XCTAssertEqual(whole, 832, "control: D2 said 832 on face \(r)")
        }
        // a face with no pinch: core's own count, as before
        let topA = try XCTUnwrap(m.design(FlexibleHisProject.topA))
        let n = topA.tooFirm + topA.tooSoft + topA.beyondData
        XCTAssertEqual(FlexibleFaceRows.warning(model: m, region: FlexibleHisProject.topA),
                       FlexibleRowCopy.faceWarning(refusalCode: nil, refusalReason: nil, unreachedColumns: n,
                                                   side: m.stack(FlexibleHisProject.topA)?.side ?? false))
    }

    // MARK: one hand, one group (V2)

    @MainActor
    func testAMainPageHandMovesWholeSoOneGroupsForceLeavesTheOtherAlone() async throws {
        let (r, m) = try await his { p in
            if let top = p.selection.groups.first(where: { $0.name == "Top" }) { p.selection.addRegions([104], to: top.id) }
        }
        let top = try XCTUnwrap(r.project.selection.groups.first { $0.name == "Top" })
        XCTAssertEqual(m.settings.face(FlexibleHisProject.topA)?.weightFrom, top.id, "premise: top A is Top's")
        XCTAssertEqual(m.settings.face(FlexibleHisProject.topB)?.weightFrom, top.id, "premise: top B is Top's")
        XCTAssertEqual(Set(m.hand(of: FlexibleHisProject.topB)), [FlexibleHisProject.topA, FlexibleHisProject.topB])
        // ★ RED CONTROL: D2 moved top B alone — Top's hand in two groups
        var d2 = m.settings
        _ = FlexibleSqueezeGroups.newGroup(with: FlexibleHisProject.topB, in: &d2)
        XCTAssertNotEqual(FlexibleSqueezeGroups.group(of: FlexibleHisProject.topA, in: d2)?.id,
                          FlexibleSqueezeGroups.group(of: FlexibleHisProject.topB, in: d2)?.id, "control: D2 split Top's hand")
        m.newGroup(with: FlexibleHisProject.topB)
        XCTAssertEqual(m.squeezeGroup(of: FlexibleHisProject.topA)?.id, m.squeezeGroup(of: FlexibleHisProject.topB)?.id,
                       "top A moves with top B: one hand")
        XCTAssertEqual(Set(m.squeezeGroups[0].regions), [3, 5])
        let two = try XCTUnwrap(m.squeezeGroup(of: FlexibleHisProject.topB))
        m.setGroupForce(two.id, kg: 4)
        try await settle(m)
        print("FLEX-REVIEW hand: \(lines(m)) · Top \(r.project.force.kind(for: top.id).weightKg ?? -1) kg")
        XCTAssertEqual(r.project.force.kind(for: top.id).weightKg ?? 0, 4, accuracy: 1e-9, "Top took 4 kg")
        XCTAssertEqual(m.groupForce(try XCTUnwrap(m.squeezeGroup(of: 3))), 10...10, "Group 1 keeps its 10 kg")
        XCTAssertEqual(m.groupForce(two), 4...4)
        // a hand that is its whole group makes no new group ("+ New" is not offered)
        XCTAssertNil(m.newGroup(with: FlexibleHisProject.topA))
        XCTAssertFalse(FlexibleFaceGroupRow.options(model: m, region: FlexibleHisProject.topA).map(\.id).contains("new"))
        XCTAssertTrue(FlexibleFaceGroupRow.options(model: m, region: 3).map(\.id).contains("new"))
    }

    // MARK: the adopt keeps the groups whole (V4)

    func testTheMainPageRestingAFaceClearsItsGroupAndARepressJoinsOneThatExists() {
        let top = UUID(), anchor = UUID()
        func entry(_ r: Int, _ role: FlexibleMainPageLoads.Role, _ g: UUID) -> FlexibleMainPageLoads.Entry {
            FlexibleMainPageLoads.Entry(region: r, role: role, weightKg: role == .pressed ? 10 : 0, groupID: g, groupName: "G",
                                        groupKg: 10, share: 1, pressFraction: 1, groupRegions: 1)
        }
        var s = FlexibleStageSettings(materialID: "varioshore_tpu")
        var seven = FlexibleFaceSettings(faceRegionID: 7, weightFrom: anchor)
        seven.squeezeGroup = 3
        s.setFace(seven)
        s.setFace(FlexibleFaceSettings(faceRegionID: 8))
        FlexibleSqueezeGroups.normalise(&s)
        XCTAssertEqual(FlexibleSqueezeGroups.groups(s).count, 2, "premise: 7 in its own group (stored 2)")
        // the main page anchors 7: it rests…
        let rests = FlexibleMainPageLoads(entries: [7: entry(7, .rests, anchor)])
        var d2 = s
        _ = rests.adopt(into: &d2)
        _ = FlexibleStageModel.adopt(rests, into: &s)
        XCTAssertEqual(s.face(7)?.role, "resting")
        XCTAssertNil(s.face(7)?.squeezeGroup, "a resting face holds no group")
        // ★ RED CONTROL: D2's adopt kept the stale id; pressed again it made a "Group 2"
        XCTAssertEqual(d2.face(7)?.squeezeGroup, 2, "control: D2 kept the id")
        let presses = FlexibleMainPageLoads(entries: [7: entry(7, .pressed, top)])
        var d2b = d2
        _ = presses.adopt(into: &d2b)
        XCTAssertEqual(FlexibleSqueezeGroups.groups(d2b).count, 2, "control: D2's re-press made a group nobody made")
        _ = FlexibleStageModel.adopt(presses, into: &s)
        XCTAssertEqual(FlexibleSqueezeGroups.groups(s).count, 1, "pressed again, it joins group 1")
    }

    // MARK: one face's throw (the pinch segments)

    @MainActor
    func testOneFacesThrowKeepsTheOtherFacesHalves() async throws {
        let (_, m) = try await his()
        let law = try FlexiblePinch.Law.core(materialsPath: FlexibleHisProject.materialsPath, materialID: try XCTUnwrap(m.settings.materialID),
                                             tempC: try XCTUnwrap(m.designTempC), build: m.build)
        let k3 = FlexFaceKey(region: 3, rotation: 0), k5 = FlexFaceKey(region: 5, rotation: 0)
        let topAKey = FlexFaceKey(region: FlexibleHisProject.topA, rotation: 0)
        // face 5's design handed a stack with other columns: its design throws (columnsDoNotMatch)
        var stacks = m.stacks
        stacks[k5] = try XCTUnwrap(m.stacks[topAKey])
        let cuts = Dictionary(m.settings.loadedFaces.map { ($0.faceRegionID, m.regions.cuts(of: $0.faceRegionID)) }, uniquingKeysWith: { a, _ in a })
        let r = FlexibleStageModel.pinchSegments(settings: m.settings, conflicts: m.conflicts, designs: m.designs,
                                                 stacks: stacks, cuts: cuts, law: law)
        print("FLEX-REVIEW one throw: segments \(r.segments.keys.map(\.region).sorted()) · errors \(r.errors.mapValues { $0.prefix(40) })")
        XCTAssertNotNil(r.errors[k5], "face 5 threw")
        XCTAssertNotNil(r.segments[k3], "face 3 keeps its halves")
        XCTAssertNil(r.segments[k5])
        // ★ RED CONTROL: D2's one do/catch around the loop — the throw dropped every face
        var d2: [FlexFaceKey: FlexiblePinch.Segments] = [:]
        do {
            for (k, other) in [(k3, k5), (k5, k3)] {
                let st = try XCTUnwrap(stacks[k]), so = try XCTUnwrap(stacks[other])
                let pinched = FlexiblePinch.pinchedColumns(st, partners: [(so, cuts[other.region] ?? [])])
                d2[k] = try FlexiblePinch.design(try XCTUnwrap(m.designs[k]), stack: st, pinched: pinched, law: law)
            }
        } catch { d2 = [:] }
        XCTAssertTrue(d2.isEmpty, "control: D2 lost face 3's halves too")
        // the card says a face that fell back
        XCTAssertEqual(FlexibleRowCopy.pinchedOneProfile(with: "Face 3"), "Pinched with Face 3 · one profile for now")
    }

    // MARK: the combined field is not kept for nothing

    @MainActor
    func testTheCombinedFieldIsKeptOnlyWhenATestAsks() async throws {
        let (_, m) = try await his()
        m.generateLattice()
        try await FlexibleHisProject.waitFor(120, "the lattice") { (m.lattice != nil && !m.latticeIsStale) || m.latticeError != nil }
        await m.waitForIdle()
        XCTAssertNil(m.latticeError)
        XCTAssertNotNil(m.lattice)
        XCTAssertNil(m.lastCombinedField, "no ~24 MB field held after a build")
        // ★ RED CONTROL: asked for, it is there (D2 kept it always)
        m.keepCombinedField = true
        m.discardLattice()
        m.generateLattice()
        try await FlexibleHisProject.waitFor(120, "the lattice") { (m.lattice != nil && !m.latticeIsStale) || m.latticeError != nil }
        await m.waitForIdle()
        let f = try XCTUnwrap(m.lastCombinedField, "control: kept when a test asks")
        print("FLEX-REVIEW combined field: \(f.density.count) voxels · \(f.density.count * (MemoryLayout<Float>.size + MemoryLayout<Int>.size) / 1_000_000) MB held only on request")
    }

    // MARK: the static run job

    func testTheStaticRunJobRefusesAPinchItself() throws {
        var s = FlexibleStageSettings(materialID: "varioshore_tpu")
        s.setFace(FlexibleFaceSettings(faceRegionID: 3))
        s.setFace(FlexibleFaceSettings(faceRegionID: 5))
        var i = FlexibleJob.Inputs(modelPath: "/tmp/pad.step", resolution: 64, beadWidthMM: 0.45, faceCount: 6, settings: s)
        // ★ RED CONTROL: without the pinch named, the encoder sends it (D2 had no other check)
        XCTAssertNoThrow(try FlexibleJob.runJobJSON(i), "control: a job with no pinch named is written")
        i.pinches = [[3, 5]]
        XCTAssertThrowsError(try FlexibleJob.runJobJSON(i)) { XCTAssertEqual($0 as? FlexibleJob.EncodeError, .pinch) }
    }
}
