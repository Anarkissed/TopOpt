// FlexibleR7RTests — round 7, "the review of M2 and F" (the owed two-angle review of batches M2 and F at a870cad4) and his
// three answers of 2026-10-15, written BEFORE the code (the stubs' red run: round7/review_fix/r7r_red_run.txt). Each test
// runs its RED control inside. His words (tasks.md):
//   answer 7, clarified: "the weight is an EQUAL SHARE PER LATTICE PART (two parts = 5 lb each of 10 lb, whatever their
//     size), only on the latticed parts."
//   answer 5: "If bend is on, all views move to the furthest bend. Always."
//   2026-10-15 (1) "With Bend on, the depth chip and depth labels MOVE with the bend (everything goes to the full-bend pose)."
//   2026-10-15 (2) "The main page forgets which group's heat was viewed between sessions and starts on the first group
//     again: yes, keep."
//   2026-10-15 (3) "After Reset all, the main page's status line also says 'Nothing to squish yet': yes."
//   answer 3: "Yes. Allow an *empty* setup after reset all."   answer 13: "Heat follows whatever group is selected …"
//   his rules: one line per setting (≤ 44 chars); 44 pt targets.
//   R1  A face's own weight is an equal share per lattice part, and the parts of one face are ONE hand (the review: M2's
//       carry copied Face 4's and Face 2's 10 lb onto each of their two parts — Group 2 pressed 40 lb, read "Squeeze 10 lb").
//       RED `FlexibleSectionShares.controlCopyWeight`.
//   R2  The Bend pose's key is the WHOLE bend (the review: F's strided sample gave every group the same key on his pad — the
//       leaked state behind the order-dependent Bend check, and the app kept the session's first pose). RED
//       `FlexibleBendPose.controlSampledKey`.
//   R3  With Bend on, a prism's floor, the depth chip and the floor tags move with the bend (his 2026-10-15 answer 1). RED
//       `FlexibleBendPose.controlInsideStays`.
//   R4  The main page starts on the first group every session (his 2026-10-15 answer 2 — kept, now pinned). RED
//       `FlexibleMainStage.controlPlayAllDefault`.
//   R5  After Reset all the main page says "Nothing to squish yet" (neutral, no Fix) and nothing is heated (his 2026-10-15
//       answer 3; the review's empty-Exit finding and the heat left lit). RED `FlexibleMainStage.controlEmptyMainFix`.
//   R6  "Delete Group N?" never outlives its group (the review: a new group reusing the id was asked about). RED
//       `FlexibleStageModel.controlAskOutlivesGroup`.
//   R7  On the main page, a tap on a face's solid middle picks its lattice parts' group. RED
//       `FlexibleMainStage.controlTapRootIgnored`.
//   R8  "Violet = lattice · tap to pick" only while something is violet. RED `FlexibleLegend.controlVioletRowAlways`.
//   R9  The rail counts faces, not lattice parts; the pinch line names the face, whole. RED
//       `FlexibleSettingsRailView.controlRailCountsParts`, `FlexibleFacePanel.controlPinchPartName`.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleR7RTests: XCTestCase {
    typealias F = FlexibleM2Fixtures

    override func tearDown() {
        FlexibleSectionShares.controlCopyWeight = false
        FlexibleBendPose.controlSampledKey = false
        FlexibleBendPose.controlInsideStays = false
        FlexibleMainStage.controlPlayAllDefault = false
        FlexibleMainStage.controlEmptyMainFix = false
        FlexibleStageModel.controlAskOutlivesGroup = false
        FlexibleMainStage.controlTapRootIgnored = false
        FlexibleLegend.controlVioletRowAlways = false
        FlexibleSettingsRailView.controlRailCountsParts = false
        FlexibleFacePanel.controlPinchPartName = false
        super.tearDown()
    }

    /// HIS pad as he saved it (A1_0003: Group 1 = the Top, Group 2 = Faces 4 and 2, Group 3 = Faces 3 and 5; the Top's
    /// 20 mm face-prism under the whole pad, so every face is whole), on the main stage's shared model, settled.
    func hisPad() async throws -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath,
                        persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "A1_0003")
        XCTAssertEqual(m.squeezeGroups.map(\.regions), [[1], [4, 2], [3, 5]], "premise: his three groups")
        return (r, s, m)
    }

    /// The loaded entries on face `face` (its lattice parts, or the face itself).
    func parts(_ m: FlexibleStageModel, face: Int) -> [FlexibleFaceSettings] {
        m.settings.loadedFaces.filter { m.regions.faces(of: $0.faceRegionID, mesh: m.project.viewerMesh) == [face] }
    }

    /// A point of face `face` that `want` accepts (the region the Squish page's tap there picks — nil: solid), the one
    /// nearest the face's middle (its area centroid), from a fine barycentric grid over its triangles.
    func point(_ m: FlexibleStageModel, face: Int, _ want: (Int?) -> Bool) throws -> SIMD3<Double> {
        let mesh = try XCTUnwrap(m.project.viewerMesh)
        let tris = FlexibleEdgeStrips.triangles(face: face, mesh: mesh)
        var centre = SIMD3<Double>(repeating: 0), area = 0.0
        for t in tris {
            let a = simd_length(simd_cross(t[1] - t[0], t[2] - t[0])) / 2
            centre += a * (t[0] + t[1] + t[2]) / 3; area += a
        }
        centre /= max(area, 1e-12)
        let n = 24
        var best: (d: Double, p: SIMD3<Double>)?
        for t in tris {
            for i in 0...n { for j in 0...(n - i) {
                let p = t[0] + (t[1] - t[0]) * (Double(i) + 0.3) / Double(n + 1) + (t[2] - t[0]) * (Double(j) + 0.3) / Double(n + 1)
                guard want(m.regions.pressable(at: p, face: face, mesh: mesh)) else { continue }
                let d = simd_length(p - centre)
                if best == nil || d < best!.d { best = (d, p) }
            } }
        }
        return try XCTUnwrap(best?.p, "a point on face \(face)")
    }

    /// The page's own overlay (cut to the 3D sim's grid while its field moves the part, as `rebuildOverlay` makes it).
    func pageOverlay(_ m: FlexibleStageModel) throws -> FlexibleOverlayMesh {
        let edge = FlexibleSettingsSquish.overlayEdge(model: m)
        return try XCTUnwrap(edge.map { FlexiblePageChannels.overlay(model: m, maxEdgeMM: $0) } ?? FlexiblePageChannels.overlay(model: m))
    }

    /// Group `regions`' bend as the page computes it (its face `face` selected in its open tab).
    func bend(_ m: FlexibleStageModel, group regions: [Int], face: Int, overlay: FlexibleOverlayMesh,
              views: FlexibleStageViews) throws -> (dents: [Float], k: Double) {
        let g = try XCTUnwrap(m.squeezeGroups.first { $0.regions == regions })
        m.rail = .group(g.id)
        m.select(face)
        m.tab = .face
        var cache: (key: String, dents: [Float])?
        let c = FlexibleStagePage.composeTints(model: m, overlay: overlay, views: views)
        let sq = FlexibleSettingsSquish.shown(model: m, overlay: overlay, channels: c, feCache: &cache)
        return (try XCTUnwrap(sq.dents, "premise: his drawing dents group \(regions)"), sq.exaggeration)
    }

    // MARK: - R1: an equal share per lattice part; one hand per face

    func testAFacesOwnWeightIsAnEqualSharePerLatticePartAndOneHand() async throws {
        let saved = try FlexiblePressFixtures.a1Project(3, self, facePrism: false).project.lattice.flexible
        var savedKg: [Int: Double] = [:]
        for f in saved?.loadedFaces ?? [] { savedKg[f.faceRegionID] = f.weightKg }
        XCTAssertEqual(savedKg[4] ?? 0, 4.5359237, accuracy: 1e-4, "premise: Face 4 at his 10 lb, its own")
        XCTAssertEqual(savedKg[2] ?? 0, 4.5359237, accuracy: 1e-4, "premise: Face 2 at his 10 lb, its own")
        XCTAssertNil(saved?.face(4)?.weightFrom)

        let (r, _, m) = try await F.pad(self, live: true)   // his live lattice: Group C's two 25 mm face-prisms
        for face in [4, 2] {
            let ps = parts(m, face: face)
            XCTAssertEqual(ps.count, 2, "premise: Face \(face) is cut into two lattice parts")
            XCTAssertTrue(ps.allSatisfy { FlexibleSectors.isFlexible($0.faceRegionID) && $0.weightFrom == nil }, "its own weight")
            let total = ps.map(\.weightKg).reduce(0, +)
            print(String(format: "FLEX-R7R-1 Face %d: parts %@ · total %.4f kg (saved %.4f)", face,
                         ps.map { String(format: "%d:%.4f", $0.faceRegionID, $0.weightKg) }.joined(separator: " "), total, savedKg[face] ?? 0))
            XCTAssertEqual(total, savedKg[face] ?? 0, accuracy: 1e-6, "★ Face \(face) still presses its own weight in all")
            for p in ps { XCTAssertEqual(p.weightKg, (savedKg[face] ?? 0) / 2, accuracy: 1e-6, "★ an equal share per part") }
        }
        let top = parts(m, face: 1)
        XCTAssertEqual(top.map(\.weightKg).reduce(0, +), savedKg[1] ?? 0, accuracy: 1e-6, "the Top (linked) as M2 split it")
        let g2 = try XCTUnwrap(m.squeezeGroups.first { $0.number == 2 })
        XCTAssertEqual(m.groupHands(g2).count, 2, "★ one hand per face (Face 4, Face 2) — never one per part")
        let force = try XCTUnwrap(m.groupForce(g2))
        XCTAssertEqual(force.lowerBound, force.upperBound, accuracy: 1e-9, "one force")
        XCTAssertEqual(force.upperBound, savedKg[4] ?? 0, accuracy: 1e-6, "★ the group's force row: his 10 lb")
        // the run job: in every send, each face's parts together press its saved weight
        let mesh = try XCTUnwrap(r.project.viewerMesh)
        for send in FlexibleAngledGoldens.sends(m) {
            let job = try m.runJobJSON(resting: Set(send.resting))
            let doc = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(job.utf8)) as? [String: Any])
            let loads = doc["loads"] as? [String: Any]
            let flex = try XCTUnwrap(loads?["flexible"] as? [String: Any] ?? doc["flexible"] as? [String: Any])
            var byFace: [Int: Double] = [:]
            for f in try XCTUnwrap(flex["faces"] as? [[String: Any]]) where (f["role"] as? String) == "loaded" {
                let id = try XCTUnwrap(f["face_region_id"] as? Int)
                for face in m.regions.faces(of: id, mesh: mesh) { byFace[face, default: 0] += f["weight_n"] as? Double ?? 0 }
            }
            for (face, n) in byFace {
                XCTAssertEqual(n, FlexibleUnits.newtons(kg: savedKg[face] ?? 0), accuracy: 1e-6,
                               "★ send resting \(send.resting.sorted()): Face \(face) presses its own weight (\(n) N)")
            }
        }
        // his group force box: each face takes it, shared by its parts
        m.setGroupForce(g2.id, kg: 3)
        for face in [4, 2] { for p in parts(m, face: face) { XCTAssertEqual(p.weightKg, 1.5, accuracy: 1e-9, "★ 3 kg on Face \(face): 1.5 per part") } }
        XCTAssertEqual(m.groupForce(try XCTUnwrap(m.squeezeGroups.first { $0.number == 2 }))?.upperBound ?? 0, 3, accuracy: 1e-9)
        // a move: the face's parts go together, at the new group's force shared
        let g3 = try XCTUnwrap(m.squeezeGroups.first { $0.number == 3 })
        let f3 = try XCTUnwrap(m.groupForce(g3)).upperBound
        let a4 = try XCTUnwrap(parts(m, face: 4).first).faceRegionID
        m.moveToGroup(a4, g3.id)
        let moved = parts(m, face: 4)
        XCTAssertEqual(Set(moved.compactMap { m.squeezeGroup(of: $0.faceRegionID)?.id }), [g3.id], "★ both parts of Face 4 moved")
        for p in moved { XCTAssertEqual(p.weightKg, f3 / 2, accuracy: 1e-9, "★ at Group 3's force, shared") }
        // one part taken out: the other carries the face's force
        m.removeFace(a4)
        let left = parts(m, face: 4)
        XCTAssertEqual(left.count, 1)
        XCTAssertEqual(left.first?.weightKg ?? 0, f3, accuracy: 1e-9, "★ the part left presses the face's whole force")
        // after Reset all: the first part at the keypad's weight, the second joins it — half each
        m.resetAll()
        try await F.reopen(m, "after Reset all")
        let pcs = F.pieces(m, face: 4).filter { $0.kind != .strip }.map(\.wireID)
        XCTAssertEqual(pcs.count, 2, "premise: Face 4's two parts")
        XCTAssertTrue(m.startFirstGroup(pcs[0], kg: 4), "Group 1 from Face 4's first part at 4 kg")
        XCTAssertTrue(m.press(pcs[1]), "its second part joins Group 1")
        for id in pcs { XCTAssertEqual(m.settings.face(id)?.weightKg ?? 0, 2, accuracy: 1e-9, "★ 4 kg over two parts") }
        XCTAssertEqual(m.groupForce(try XCTUnwrap(m.squeezeGroups.first))?.upperBound ?? 0, 4, accuracy: 1e-9, "★ the group: 4 kg")

        // ★ RED CONTROL: M2's carry — the face's weight copied onto each part, each part its own hand
        FlexibleSectionShares.controlCopyWeight = true
        let (_, _, c) = try await F.pad(self, live: true)
        let c4 = parts(c, face: 4)
        XCTAssertEqual(c4.map(\.weightKg).reduce(0, +), 2 * (savedKg[4] ?? 0), accuracy: 1e-6, "control: Face 4 presses twice its weight")
        XCTAssertEqual(c.groupHands(try XCTUnwrap(c.squeezeGroups.first { $0.number == 2 })).count, 4, "control: four hands")
    }

    // MARK: - R2: the Bend pose's key is the whole bend

    func testTheBendPoseKeyIsTheWholeBendSoEachGroupGetsItsOwnPose() async throws {
        let (_, _, m) = try await hisPad()
        let overlay = try pageOverlay(m)
        let views: FlexibleStageViews = [.bend, .heatOff]
        let two = try bend(m, group: [4, 2], face: 4, overlay: overlay, views: views)
        let one = try bend(m, group: [1], face: 1, overlay: overlay, views: views)
        XCTAssertNotEqual(two.dents, one.dents, "premise: two different bends")
        let peak = stride(from: 0, to: one.dents.count - 2, by: 3).map {
            simd_length(SIMD3<Float>(one.dents[$0], one.dents[$0 + 1], one.dents[$0 + 2]))
        }.max() ?? 0
        print(String(format: "FLEX-R7R-2 dents %d (step %d) · Group 1 bends %.3f mm × k %.2f · Group 2 k %.2f", one.dents.count,
                     max(1, one.dents.count / 256), Double(peak) * one.k, one.k, two.k))
        // F's own test asks Group 2's pose first; the hosted Bend check then asks Group 1's — the order that failed
        let p2 = try XCTUnwrap(FlexibleStagePage.bendPose(views: views, overlay: overlay, dents: two.dents, k: two.k))
        let p1 = try XCTUnwrap(FlexibleStagePage.bendPose(views: views, overlay: overlay, dents: one.dents, k: one.k))
        XCTAssertNotEqual(p1.key, p2.key, "★ each group's bend has its own key")
        let fresh = try XCTUnwrap(FlexibleBendPose(positions: overlay.mesh.flat.positions, dents: one.dents, k: one.k))
        let w = try XCTUnwrap(FlexibleStageOverlays.workingFace(model: m), "Face 1 is worked on")
        func moved(_ p: FlexibleBendPose) -> Double { Double(w.geometry.centres.map { simd_length(p.apply($0) - $0) }.max() ?? 0) }
        XCTAssertGreaterThan(moved(fresh), 0.01, "premise: Group 1's bend moves Face 1's middle")
        XCTAssertEqual(moved(p1), moved(fresh), accuracy: 1e-6, "★ Group 1's pose IS Group 1's bend, whatever was asked before")
        // the same bend again is the cached pose (one per bend)
        XCTAssertEqual(FlexibleStagePage.bendPose(views: views, overlay: overlay, dents: one.dents, k: one.k)?.key, p1.key)

        // ★ RED CONTROL: F's strided key — Group 1 asked after Group 2 gets Group 2's pose back
        FlexibleBendPose.controlSampledKey = true
        let c2 = try XCTUnwrap(FlexibleStagePage.bendPose(views: views, overlay: overlay, dents: two.dents, k: two.k))
        let c1 = try XCTUnwrap(FlexibleStagePage.bendPose(views: views, overlay: overlay, dents: one.dents, k: one.k))
        XCTAssertEqual(c1.key, c2.key, "control: one key for both groups (every sample a vertex's x, zero for his presses)")
        XCTAssertNotEqual(moved(c1), moved(fresh), "control: Face 1 drawn at Group 2's pose")
    }

    // MARK: - R3: with Bend on, the floors, the depth chip and the floor tags move with the bend

    func testWithBendOnTheDepthChipAndTheDepthLabelsMoveWithTheBend() async throws {
        // a 5 × 5 grid on z = 0, each vertex pushed down by x / 10 mm, k = 3 (F's own fixture)
        var pos: [Float] = [], d: [Float] = []
        for y in 0..<5 { for x in 0..<5 { pos += [Float(x), Float(y), 0]; d += [0, 0, -Float(x) / 10] } }
        let pose = try XCTUnwrap(FlexibleBendPose(positions: pos, dents: d, k: 3))
        let shell = FaceOffsetShell(base: [SIMD3(4, 2, 0), SIMD3(3, 2, 0), SIMD3(4, 3, 0)],
                                    offset: [SIMD3(4, 2, -40), SIMD3(3, 2, -40), SIMD3(4, 3, -40)], indices: [0, 1, 2], reachedDepthMM: 40)
        let item = ClearanceRenderItem(volume: .shell(faceID: 7, shell: shell), selected: true, tint: SIMD3(1, 0, 1), faceAlpha: 0.2)
        guard case .shell(let s) = pose.pose(item).volume.shape else { return XCTFail("a shell") }
        XCTAssertEqual(s.base[0].z, -1.2, accuracy: 1e-5, "the prism's face on the bent face (F)")
        XCTAssertEqual(s.offset[0].z, -41.2, accuracy: 1e-5, "★ its floor moves with its face (his 2026-10-15 answer 1)")
        XCTAssertEqual(s.offset[1].z, -40.9, accuracy: 1e-5, "★ each floor point with its own face point")

        // his pad: Group 2's Face 4 at the full bend — its depth chip and Face 2's floor tag follow the bend
        let (_, _, m) = try await hisPad()
        let overlay = try pageOverlay(m)
        m.views = [.bend, .prisms, .heatOff]
        let b = try bend(m, group: [4, 2], face: 4, overlay: overlay, views: m.views)
        let p = try XCTUnwrap(FlexibleStagePage.bendPose(views: m.views, overlay: overlay, dents: b.dents, k: b.k))
        let k = FlexibleStageVolumes.prismK(b.k)
        let rest = try XCTUnwrap(FlexibleDepthChips.handle(model: m, k: k, pose: nil), "Face 4's chip at rest")
        let bent = try XCTUnwrap(FlexibleDepthChips.handle(model: m, k: k, pose: p), "Face 4's chip at the full bend")
        let chipMove = Double(simd_length(bent.anchor - rest.anchor))
        let floorsRest = FlexibleStageViewTags.floors(model: m, k: k, pose: nil)
        let floorsBent = FlexibleStageViewTags.floors(model: m, k: k, pose: p)
        let tag2 = (floorsRest.first { $0.region == 2 }?.anchor, floorsBent.first { $0.region == 2 }?.anchor)
        let tagMove = tag2.0.flatMap { a in tag2.1.map { Double(simd_length($0 - a)) } } ?? -1
        print(String(format: "FLEX-R7R-3 Face 4's chip moves %.3f mm · Face 2's floor tag %.3f mm (k %.2f)", chipMove, tagMove, b.k))
        XCTAssertGreaterThan(chipMove, 0.5, "★ the depth chip moves with the bend")
        XCTAssertGreaterThan(tagMove, 0.5, "★ the floor tag moves with the bend")

        // ★ RED CONTROL: F's rule — the floor, the chip and the tags stay at rest
        FlexibleBendPose.controlInsideStays = true
        guard case .shell(let cs) = pose.pose(item).volume.shape else { return XCTFail("a shell") }
        XCTAssertEqual(cs.offset, shell.offset, "control: the floor stays")
        let cb = try XCTUnwrap(FlexibleDepthChips.handle(model: m, k: k, pose: p))
        XCTAssertEqual(Double(simd_length(cb.anchor - rest.anchor)), 0, accuracy: 1e-4, "control: the chip stays")
    }

    // MARK: - R4: the main page starts on the first group every session

    func testTheMainPageStartsOnTheFirstGroupEverySession() async throws {
        let (r, s, m) = try await hisPad()
        m.generateLattice()
        try await FlexibleHisProject.waitFor(240, "the lattice") { m.lattice != nil && !m.latticeBuilding }
        XCTAssertGreaterThan(s.sims.count, 1, "premise: his three groups to pick from")
        XCTAssertEqual(s.selectedSim, FlexibleSim.groupID(1), "★ the first group at open")
        let before = r.project.lattice.flexible
        s.noteMainTap(face: 4, point: SIMD3<Float>(try point(m, face: 4) { $0 != nil }))
        XCTAssertEqual(s.selectedSim, FlexibleSim.groupID(2), "a tap on Face 4: Group 2")
        XCTAssertEqual(r.project.lattice.flexible, before, "★ the pick is never saved")
        // the next session: a new stage over the same project
        let s2 = FlexibleMainStage()
        s2.reduceMotion = { true }
        let m2 = s2.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath,
                          persist: {})
        addTeardownBlock { @MainActor in await m2.waitForIdle() }
        m2.openScene()
        try await FlexibleSquishFixture.settle(m2, "the next session")
        m2.generateLattice()
        try await FlexibleHisProject.waitFor(240, "the next session's lattice") { m2.lattice != nil && !m2.latticeBuilding }
        XCTAssertNil(s2.tappedGroupNumber, "nothing tapped in the new session")
        XCTAssertEqual(s2.selectedSim, FlexibleSim.groupID(1), "★ the next session starts on the first group again")
        // ★ RED CONTROL: batch G's default — Play all
        FlexibleMainStage.controlPlayAllDefault = true
        XCTAssertNotEqual(FlexibleMainStage.heatSim(sims: s2.sims, tappedGroup: nil, all: false), FlexibleSim.groupID(1), "control: not the first group")
    }

    // MARK: - R5: after Reset all, the main page says "Nothing to squish yet"; nothing is heated

    func testAfterResetAllTheMainPageSaysNothingToSquishYetAndHeatsNothing() async throws {
        let (r, s, m) = try await F.pad(self, live: true)
        s.didExitSettings()
        s.apply(r.project, owned: true, pageUp: false)
        XCTAssertTrue(m.facePrismsSet, "premise: Group C's face-prisms")
        // his 3 s hold on both heat icons, then Reset all on the Squish page and its empty Exit
        s.heatHeld()
        var v = m.views; v.heatHeld(); m.views = v
        XCTAssertEqual(m.views.heatScope, .all, "premise: every group's heat on the Squish page")
        m.resetAll()
        try await F.reopen(m, "after Reset all")
        XCTAssertTrue(m.isEmptySetup, "premise: nothing set to squish")
        let rd = m.readiness
        XCTAssertEqual(FlexibleSettingsExit.decide(rd, modified: true, empty: true), .exit, "premise: the empty setup may leave (F)")
        s.didExitSettings()
        s.apply(r.project, owned: true, pageUp: false)
        let st = FlexibleMainStatus.of(model: m)
        XCTAssertEqual(st.line, FlexibleSettingsExit.emptyLine, "★ the main page's line: \"Nothing to squish yet\"")
        XCTAssertEqual(st.tone, .idle, "★ neutral (never the warning outline)")
        XCTAssertNil(st.fix, "★ no Fix")
        XCTAssertFalse(FlexibleMainStatusPill.disabled(st, visible: true), "a tap opens the Squish page (his tap; it never opens by itself)")
        XCTAssertEqual(st.tap, .openSettings)
        XCTAssertFalse(s.heatIconLit, "★ the main page's heat icon is not lit — nothing to heat")
        XCTAssertFalse(s.heatAllBadgeShown, "★ no \"every group\" mark with no group")
        XCTAssertNotEqual(m.views.heatScope, .all, "★ the Squish page's heat no longer says every group with no group left")
        // ★ RED CONTROL: today's main page — the readiness's Fix
        FlexibleMainStage.controlEmptyMainFix = true
        let c = FlexibleMainStatus.of(model: m)
        XCTAssertEqual(c.tone, .fix, "control: the Fix tone")
        XCTAssertNotEqual(c.line, FlexibleSettingsExit.emptyLine, "control: \(c.line)")
    }

    // MARK: - R6: "Delete Group N?" never outlives its group

    func testTheTrashQuestionNeverOutlivesItsGroup() async throws {
        let (_, _, m) = try await hisPad()
        let g3 = try XCTUnwrap(m.squeezeGroups.first { $0.number == 3 })
        m.askDeleteGroup(g3.id)
        XCTAssertEqual(m.groupDeleteAsk, g3.id, "premise: asked")
        for reg in g3.regions { m.removeFace(reg) }
        XCTAssertNil(m.squeezeGroups.first { $0.id == g3.id }, "premise: Group 3 left when its faces went")
        XCTAssertNil(m.groupDeleteAsk, "★ the group left — its question with it")
        let g2 = try XCTUnwrap(m.squeezeGroups.first { $0.number == 2 })
        let n = m.newGroup(with: try XCTUnwrap(g2.regions.last))
        XCTAssertEqual(n, 3, "premise: a new group numbered 3")
        XCTAssertNil(m.groupDeleteAsk, "★ the new group is not asked about")
        // another tab: the question goes
        let g1 = try XCTUnwrap(m.squeezeGroups.first)
        m.rail = .group(g2.id)
        m.askDeleteGroup(g2.id)
        m.rail = .group(g1.id)
        XCTAssertNil(m.groupDeleteAsk, "★ another tab opened — the question goes")

        // ★ RED CONTROL: F's question kept its id
        FlexibleStageModel.controlAskOutlivesGroup = true
        let (_, _, c) = try await hisPad()
        let c3 = try XCTUnwrap(c.squeezeGroups.first { $0.number == 3 })
        c.askDeleteGroup(c3.id)
        for reg in c3.regions { c.removeFace(reg) }
        let cn = c.newGroup(with: try XCTUnwrap(c.squeezeGroups.first { $0.number == 2 }?.regions.last))
        XCTAssertEqual(cn, 3)
        XCTAssertEqual(c.groupDeleteAsk, c3.id, "control: the stale question")
        XCTAssertNotNil(c.groupDeleteAsk.flatMap { c.railGroup($0) }, "control: …shown for the NEW group")
    }

    // MARK: - R7: a tap on a face's solid middle picks its lattice parts' group (the main page)

    func testATapOnAFacesSolidMiddlePicksItsLatticePartsGroup() async throws {
        let (_, s, m) = try await F.pad(self, live: true)
        let middle = try point(m, face: 4) { $0 == nil }
        let band = try point(m, face: 4) { $0 != nil }
        s.noteMainTap(face: 1, point: SIMD3<Float>(try point(m, face: 1) { $0 != nil }))
        XCTAssertEqual(s.tappedGroupNumber, 1, "premise: the Top's band — Group 1")
        s.noteMainTap(face: 4, point: SIMD3<Float>(middle))
        XCTAssertEqual(s.tappedGroupNumber, 2, "★ Face 4's solid middle: its lattice parts' group")
        s.noteMainTap(face: 1, point: SIMD3<Float>(try point(m, face: 1) { $0 != nil }))
        s.noteMainTap(face: 4, point: SIMD3<Float>(band))
        XCTAssertEqual(s.tappedGroupNumber, 2, "Face 4's band: Group 2 (as before)")
        // ★ RED CONTROL: F's tap — the solid middle keeps the last group
        FlexibleMainStage.controlTapRootIgnored = true
        s.noteMainTap(face: 1, point: SIMD3<Float>(try point(m, face: 1) { $0 != nil }))
        s.noteMainTap(face: 4, point: SIMD3<Float>(middle))
        XCTAssertEqual(s.tappedGroupNumber, 1, "control: the middle ignored")
    }

    // MARK: - R8: the violet row only while something is violet

    func testTheVioletRowOnlyWhileSomethingIsViolet() async throws {
        let (_, _, m) = try await F.pad(self, live: true)
        XCTAssertFalse(m.regions.flexible?.partialRoots.isEmpty ?? true, "premise: faces cut into lattice parts")
        XCTAssertFalse(FlexibleLegend.sectionRow(m), "★ every lattice part pressed or resting — nothing violet, no row")
        m.resetAll()
        try await F.reopen(m, "after Reset all")
        XCTAssertTrue(FlexibleLegend.sectionRow(m), "★ after Reset all the parts are violet — the row")
        // ★ RED CONTROL: M2's row — whenever a face is cut
        let (_, _, c) = try await F.pad(self, live: true)
        FlexibleLegend.controlVioletRowAlways = true
        XCTAssertTrue(FlexibleLegend.sectionRow(c), "control: the row with nothing violet")
    }

    // MARK: - R9: the rail counts faces; the pinch line names the face, whole

    func testTheRailCountsFacesAndThePinchLineNamesTheFaceWhole() async throws {
        let (_, _, m) = try await F.pad(self, live: true)
        let g2 = try XCTUnwrap(m.squeezeGroups.first { $0.number == 2 })
        XCTAssertEqual(g2.regions.count, 4, "premise: Faces 4 and 2, two parts each")
        let tab = try XCTUnwrap(FlexibleSettingsRailView.tabs(model: m).first { $0.tab == .group(g2.id) })
        XCTAssertEqual(tab.detail, "2 faces", "★ the rail counts faces")
        let part = try XCTUnwrap(parts(m, face: 4).first).faceRegionID
        let line = try XCTUnwrap(FlexibleFacePanel.pinchLine(model: m, region: part), "premise: Face 4's part is pinched with Face 2's")
        print("FLEX-R7R-9 rail '\(tab.detail ?? "")' · pinch line '\(line)' (\(line.count) chars)")
        XCTAssertLessThanOrEqual(line.count, 44, "★ one line, ≤ 44 chars")
        XCTAssertFalse(line.contains("…"), "★ whole: '\(line)'")
        XCTAssertTrue(line.contains("Face 2"), "★ it names the face")
        // ★ RED CONTROLS: M2's count and the part's name
        FlexibleSettingsRailView.controlRailCountsParts = true
        FlexibleFacePanel.controlPinchPartName = true
        XCTAssertEqual(FlexibleSettingsRailView.tabs(model: m).first { $0.tab == .group(g2.id) }?.detail, "4 faces", "control: parts counted")
        XCTAssertTrue(FlexibleFacePanel.pinchLine(model: m, region: part)?.contains("…") ?? false, "control: the part's name cut")
    }
}
