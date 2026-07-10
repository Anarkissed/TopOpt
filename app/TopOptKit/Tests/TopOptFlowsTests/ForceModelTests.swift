// Headless macOS tests for the M7.6 force & gravity data model (ForceModel).
//
// The workspace's force/gravity experience (MOD-F1 D1–D6, docs/design/
// TopOpt_force_proto.html) is a SwiftUI/GPU surface that is maintainer device QA;
// its *logic* — gravity as a model-space unit vector, the settle rotation, the
// per-group Anchor|Load role, per-load direction + weight (stored kgf), the
// weight formatting/scrub, the D6 arrow convention, and Optimize enablement +
// summary — lives in ForceModel and is pinned here. Every assertion traces to a
// literal in the prototype (`S`, `fmtW`, `loadDir`, `setGravity`, the `opt`/`hint`
// sync block) so a reviewer can diff them.

import XCTest
import simd
@testable import TopOptFlows

final class ForceModelTests: XCTestCase {

    /// A selection with one single-face group per id; returns the model and the ids.
    /// `addGroup` starts a fresh active group before each pick so the faces land in
    /// separate groups (a bare `pickFaces` would add into the already-active group).
    private func groups(_ faces: [FaceID]) -> (SelectionModel, [UUID]) {
        var m = SelectionModel()
        for f in faces { m.addGroup(); m.pickFaces([f]) }
        return (m, m.groups.map { $0.id })
    }

    // MARK: gravity (D2)

    func testInitialPhaseIsGravitySetup() {
        let fm = ForceModel()
        XCTAssertEqual(fm.phase, .setup)
        XCTAssertFalse(fm.gravityIsSet)
        XCTAssertNil(fm.gravity)
        XCTAssertNil(fm.settleRotation)
    }

    func testSetGravityStoresModelSpaceUnitNormalAndEntersEdit() {
        var fm = ForceModel()
        // A face normal that is not axis-aligned and not unit length — must be
        // normalized and stored verbatim in model space (survives re-orientation).
        fm.setGravity(faceNormal: SIMD3<Float>(0, 3, 4), face: 7)
        XCTAssertTrue(fm.gravityIsSet)
        XCTAssertEqual(fm.gravityFace, 7)
        let g = try! XCTUnwrap(fm.gravity)
        XCTAssertEqual(simd_length(g), 1, accuracy: 1e-5)          // stored as a unit vector
        XCTAssertEqual(g.y, 0.6, accuracy: 1e-5)                   // 3/5
        XCTAssertEqual(g.z, 0.8, accuracy: 1e-5)                   // 4/5
        XCTAssertEqual(fm.phase, .edit)                           // proto: S.phase='edit'
    }

    func testSettleRotationAlignsGravityWithWorldDown() {
        // A tilted "down" face normal must rotate onto world −Y (proto Q.fromUnit(n,[0,-1,0])).
        var fm = ForceModel()
        fm.setGravity(faceNormal: SIMD3<Float>(0.3, 0.5, -0.2), face: 1)
        let rot = try! XCTUnwrap(fm.settleRotation)
        let down = rot.act(simd_normalize(SIMD3<Float>(0.3, 0.5, -0.2)))
        XCTAssertEqual(down.x, 0, accuracy: 1e-4)
        XCTAssertEqual(down.y, -1, accuracy: 1e-4)
        XCTAssertEqual(down.z, 0, accuracy: 1e-4)
    }

    func testSettleRotationHandlesAntiparallelNormal() {
        // Gravity normal already pointing at world +Y (opposite of −Y): must not NaN
        // and must still land on −Y.
        var fm = ForceModel()
        fm.setGravity(faceNormal: SIMD3<Float>(0, 1, 0), face: 2)
        let rot = try! XCTUnwrap(fm.settleRotation)
        let down = rot.act(SIMD3<Float>(0, 1, 0))
        XCTAssertFalse(down.x.isNaN || down.y.isNaN || down.z.isNaN)
        XCTAssertEqual(down.y, -1, accuracy: 1e-4)
    }

    func testChangeGravityReentersSetupButKeepsVector() {
        // The gravity chip's "Change" re-enters the prompt (phase→setup) without
        // clearing the already-chosen vector (proto gchange: phase='gravity' only).
        var fm = ForceModel()
        fm.setGravity(faceNormal: SIMD3<Float>(0, -1, 0), face: 3)
        fm.enterGravitySetup()
        XCTAssertEqual(fm.phase, .setup)
        XCTAssertTrue(fm.gravityIsSet)      // vector retained
        XCTAssertEqual(fm.gravityFace, 3)
    }

    // MARK: group role (D3)

    func testFreshGroupIsPending() {
        let (_, ids) = groups([5])
        let fm = ForceModel()
        XCTAssertEqual(fm.kind(for: ids[0]), .pending)
        XCTAssertTrue(fm.kind(for: ids[0]).isPending)
    }

    func testMakeAnchorAndMakeLoad() {
        let (_, ids) = groups([5, 6])
        var fm = ForceModel()
        fm.makeAnchor(ids[0])
        fm.makeLoad(ids[1])
        XCTAssertEqual(fm.kind(for: ids[0]), .anchor)
        // A new load spawns along gravity with the default weight (proto mkLoad:
        // dir='gravity', group created with kg:2.5).
        XCTAssertEqual(fm.kind(for: ids[1]), .load(direction: .gravity, weightKg: ForceModel.defaultWeightKg))
        XCTAssertTrue(fm.kind(for: ids[1]).isLoad)
    }

    func testMakeLoadResetsDirectionButKeepsWeight() {
        let (_, ids) = groups([5])
        var fm = ForceModel()
        fm.makeLoad(ids[0])
        fm.setWeight(ids[0], kg: 12)
        fm.setDirection(ids[0], .push)
        fm.makeLoad(ids[0])                          // re-tapping Load resets dir to gravity
        XCTAssertEqual(fm.kind(for: ids[0]).loadDirection, .gravity)
        XCTAssertEqual(fm.kind(for: ids[0]).weightKg, 12)   // weight preserved
    }

    func testSetDirectionAndWeightOnlyAffectLoads() {
        let (_, ids) = groups([5])
        var fm = ForceModel()
        fm.makeAnchor(ids[0])
        fm.setDirection(ids[0], .push)               // no-op on an anchor
        fm.setWeight(ids[0], kg: 9)                   // no-op on an anchor
        XCTAssertEqual(fm.kind(for: ids[0]), .anchor)
    }

    func testWeightIsClamped() {
        let (_, ids) = groups([5])
        var fm = ForceModel()
        fm.makeLoad(ids[0])
        fm.setWeight(ids[0], kg: 9999)
        XCTAssertEqual(fm.kind(for: ids[0]).weightKg, ForceModel.maxWeightKg)
        fm.setWeight(ids[0], kg: -3)
        XCTAssertEqual(fm.kind(for: ids[0]).weightKg, ForceModel.minWeightKg)
    }

    func testSyncPrunesRemovedGroups() {
        var (m, ids) = groups([5, 6])
        var fm = ForceModel()
        fm.makeAnchor(ids[0])
        fm.makeLoad(ids[1])
        m.remove(ids[0])
        fm.sync(groups: m.groups)                    // the anchor group is gone
        XCTAssertEqual(fm.kind(for: ids[0]), .pending)   // pruned → back to default
        XCTAssertTrue(fm.kind(for: ids[1]).isLoad)       // survivor untouched
    }

    // MARK: weight formatting + scrub (D5)

    func testFormattedWeightKgAndLbs() {
        var fm = ForceModel()
        // < 10 → one decimal; ≥ 10 → rounded integer (proto fmtW).
        fm.unit = .kg
        XCTAssertEqual(fm.formattedWeight(kg: 2.5), "2.5 kg")
        XCTAssertEqual(fm.formattedWeight(kg: 12.4), "12 kg")
        fm.unit = .lbs
        XCTAssertEqual(fm.formattedWeight(kg: 1), "2.2 lbs")           // 1 kg → 2.20462 lb
        XCTAssertEqual(fm.formattedWeight(kg: 10), "22 lbs")          // 22.0462 → 22
    }

    func testScrubStepsInDisplayUnitAndClamps() {
        var fm = ForceModel()
        fm.unit = .kg
        // +40 points × 0.05 kg = +2.0 kg (proto stepKg = 0.05 in kg).
        XCTAssertEqual(fm.scrub(kg: 2.5, byPoints: 40), 4.5, accuracy: 1e-6)
        // clamps at the floor.
        XCTAssertEqual(fm.scrub(kg: 0.2, byPoints: -1000), ForceModel.minWeightKg, accuracy: 1e-9)
        // In lbs the step is 0.05 lb worth of kg, so the same drag moves less kg.
        fm.unit = .lbs
        let kgStep = 0.05 / ForceModel.kgToLb
        XCTAssertEqual(fm.scrub(kg: 2.5, byPoints: 10), 2.5 + 10 * kgStep, accuracy: 1e-6)
    }

    // MARK: load direction + force (D4, D7)

    func testDirectionVectors() {
        let n = SIMD3<Float>(0, 0, 1)   // outward face normal
        XCTAssertEqual(ForceModel.directionVector(.gravity, groupNormal: n), SIMD3<Float>(0, -1, 0))
        XCTAssertEqual(ForceModel.directionVector(.push, groupNormal: n), SIMD3<Float>(0, 0, -1))  // into the face
        XCTAssertEqual(ForceModel.directionVector(.pull, groupNormal: n), SIMD3<Float>(0, 0, 1))   // away from the face
    }

    func testForceVectorInNewtons() {
        let (_, ids) = groups([5])
        var fm = ForceModel()
        fm.makeLoad(ids[0])
        fm.setWeight(ids[0], kg: 2)
        // gravity load, 2 kgf → 2 × 9.80665 N straight down.
        let f = try! XCTUnwrap(fm.loadForceVectorNewtons(ids[0], groupNormal: SIMD3<Float>(1, 0, 0)))
        XCTAssertEqual(f.x, 0, accuracy: 1e-4)
        XCTAssertEqual(f.y, -2 * Float(ForceModel.gravityAccel), accuracy: 1e-3)
        XCTAssertEqual(f.z, 0, accuracy: 1e-4)
        // an anchor has no load force.
        var fm2 = ForceModel(); let (_, a) = groups([1]); fm2.makeAnchor(a[0])
        XCTAssertNil(fm2.loadForceVectorNewtons(a[0], groupNormal: SIMD3<Float>(0, 1, 0)))
    }

    func testArrowConventionD6() {
        let n = SIMD3<Float>(0, 0, 1)
        // Pushing INTO the face (dir·n < 0) → tip drawn at the application point.
        XCTAssertTrue(ForceModel.arrowTipAtApplicationPoint(direction: SIMD3<Float>(0, 0, -1), faceNormal: n))
        // Pulling away (hanging) → tail at the application point.
        XCTAssertFalse(ForceModel.arrowTipAtApplicationPoint(direction: SIMD3<Float>(0, 0, 1), faceNormal: n))
    }

    // MARK: optimize enablement + summary (D-happy-path step 5)

    func testCannotOptimizeUntilGravityAnchorAndLoad() {
        var (m, ids) = groups([5, 6])
        var fm = ForceModel()
        // Still in gravity setup.
        XCTAssertFalse(fm.canOptimize(in: m.groups))
        XCTAssertEqual(fm.optimizeSummary(in: m.groups), "set gravity first")

        fm.setGravity(faceNormal: SIMD3<Float>(0, -1, 0), face: 99)
        // Two pending groups → blocked on the pending group.
        XCTAssertFalse(fm.canOptimize(in: m.groups))
        XCTAssertEqual(fm.optimizeSummary(in: m.groups), "finish the pending group")

        fm.makeAnchor(ids[0])
        // One anchor, no load yet (second group still pending → still blocked).
        XCTAssertFalse(fm.canOptimize(in: m.groups))

        fm.makeLoad(ids[1])
        XCTAssertTrue(fm.canOptimize(in: m.groups))
        XCTAssertEqual(fm.optimizeSummary(in: m.groups), "1 anchor · 1 load")
    }

    func testOptimizeSummaryNeedsMessages() {
        var (m, ids) = groups([5, 6])
        var fm = ForceModel()
        fm.setGravity(faceNormal: SIMD3<Float>(0, -1, 0), face: 9)
        fm.makeAnchor(ids[0]); fm.makeAnchor(ids[1])   // two anchors, no load
        XCTAssertEqual(fm.optimizeSummary(in: m.groups), "needs a load")
        XCTAssertFalse(fm.canOptimize(in: m.groups))

        var (m2, ids2) = groups([1, 2])
        var fm2 = ForceModel()
        fm2.setGravity(faceNormal: SIMD3<Float>(0, -1, 0), face: 9)
        fm2.makeLoad(ids2[0]); fm2.makeLoad(ids2[1])   // two loads, no anchor
        XCTAssertEqual(fm2.optimizeSummary(in: m2.groups), "needs an anchor")
    }

    func testPluralizedSummary() {
        var (m, ids) = groups([1, 2, 3])
        var fm = ForceModel()
        fm.setGravity(faceNormal: SIMD3<Float>(0, -1, 0), face: 9)
        fm.makeAnchor(ids[0]); fm.makeLoad(ids[1]); fm.makeLoad(ids[2])
        XCTAssertEqual(fm.optimizeSummary(in: m.groups), "1 anchor · 2 loads")
        XCTAssertTrue(fm.canOptimize(in: m.groups))
    }

    func testChangingGravityDisablesOptimize() {
        var (m, ids) = groups([1, 2])
        var fm = ForceModel()
        fm.setGravity(faceNormal: SIMD3<Float>(0, -1, 0), face: 9)
        fm.makeAnchor(ids[0]); fm.makeLoad(ids[1])
        XCTAssertTrue(fm.canOptimize(in: m.groups))
        fm.enterGravitySetup()                       // re-entering setup blocks optimize
        XCTAssertFalse(fm.canOptimize(in: m.groups))
        XCTAssertEqual(fm.optimizeSummary(in: m.groups), "set gravity first")
    }

    // MARK: total load + panel label

    func testTotalLoadKg() {
        var (m, ids) = groups([1, 2, 3])
        var fm = ForceModel()
        fm.makeAnchor(ids[0])
        fm.makeLoad(ids[1]); fm.setWeight(ids[1], kg: 2.5)
        fm.makeLoad(ids[2]); fm.setWeight(ids[2], kg: 4)
        XCTAssertEqual(fm.totalLoadKg(in: m.groups), 6.5, accuracy: 1e-9)
    }

    // MARK: gravity face normal (ViewerMesh helper feeding setGravity)

    func testFaceNormalAveragesTriangleNormalsPerFace() {
        // A quad on the y = 0 plane (outward normal −Y) as face 0, split into two
        // triangles wound so the cross product points at −Y; plus one triangle on
        // face 1 facing +X. faceNormal(0) must recover −Y.
        let verts: [Float] = [
            0, 0, 0,   1, 0, 0,   1, 0, 1,   0, 0, 1,   // 0..3  (bottom quad, y=0)
            0, 0, 0,   0, 1, 0,   0, 1, 1,               // 4..6  (a +? face)
        ]
        // Bottom quad wound so cross(p1−p0, p2−p0) points at −Y: (0,1,2) and (0,2,3).
        let indices: [Int32] = [0, 1, 2,  0, 2, 3,  4, 5, 6]
        let faceIDs: [Int32] = [0, 0, 1]
        let mesh = ViewerMesh(vertices: verts, indices: indices, faceIDs: faceIDs)
        let n = try! XCTUnwrap(mesh.faceNormal(0))
        XCTAssertEqual(n.x, 0, accuracy: 1e-5)
        XCTAssertEqual(n.y, -1, accuracy: 1e-5)
        XCTAssertEqual(n.z, 0, accuracy: 1e-5)
        XCTAssertNil(mesh.faceNormal(99), "absent face id → nil")
    }

    func testFaceNormalNilForFacelessMesh() {
        let mesh = ViewerMesh(vertices: [0, 0, 0, 1, 0, 0, 0, 1, 0],
                              indices: [0, 1, 2], faceIDs: [])
        XCTAssertNil(mesh.faceNormal(0))   // STL: no B-rep face ids
    }

    func testFaceCentroidAveragesFaceVertices() {
        // Face 0 = the unit square on y=0 (two triangles); its centroid is (0.5,0,0.5).
        let verts: [Float] = [0, 0, 0,  1, 0, 0,  1, 0, 1,  0, 0, 1]
        let indices: [Int32] = [0, 1, 2,  0, 2, 3]
        let mesh = ViewerMesh(vertices: verts, indices: indices, faceIDs: [0, 0])
        let c = try! XCTUnwrap(mesh.faceCentroid(0))
        XCTAssertEqual(c.x, 0.5, accuracy: 1e-5)
        XCTAssertEqual(c.y, 0, accuracy: 1e-5)
        XCTAssertEqual(c.z, 0.5, accuracy: 1e-5)
        XCTAssertNil(mesh.faceCentroid(9))
    }

    func testPanelKindLabel() {
        let (_, ids) = groups([1, 2, 3])
        var fm = ForceModel()
        fm.unit = .kg
        fm.makeAnchor(ids[0])
        fm.makeLoad(ids[1]); fm.setWeight(ids[1], kg: 2.5); fm.setDirection(ids[1], .push)
        XCTAssertEqual(fm.panelKindLabel(for: ids[0]), "Anchor")
        XCTAssertEqual(fm.panelKindLabel(for: ids[1]), "2.5 kg · push")
        XCTAssertEqual(fm.panelKindLabel(for: ids[2]), "Pending…")
    }
}
