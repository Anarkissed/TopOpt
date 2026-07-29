// ManualPrimitiveTests — the group-editing bars at the model layer (handoff
// group-editing). Covers manual-primitive add / move / delete, the auto-primitive
// deletion escape hatch (BAR B3), undo/redo through the EXISTING UndoHistory (B5),
// the group-lock + name-only-rename invariants (B6), the magnetic-detent math, and
// the deletion/manual sidecar round-trip (B3 persistence). Pure, headless — the /app/
// verification standard; the SwiftUI gesture + Metal draw are the device-QA'd layers.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class ManualPrimitiveTests: XCTestCase {

    /// A bore+plane mesh carrying `faceGeometry`: a full-wrap through-HOLE (face 1, a
    /// concave cylinder) capped by a plane (face 3). The wall triangles wind INWARD
    /// (normals toward the axis), as a real STL import winds a hole, so the bore passes
    /// `FaceTopology.isFastenerBore` (handoff 2026-07-29); a peg-wound / arc-split bore
    /// would be — correctly — rejected as not a fastener bore.
    private func borePlusPlaneMesh() -> ViewerMesh {
        let n = 8
        var verts: [Float] = []
        let r: Float = 2.5
        for k in 0..<n { let a = Float(k) * (2 * .pi / Float(n)); verts += [r*cos(a), r*sin(a), 0] }
        for k in 0..<n { let a = Float(k) * (2 * .pi / Float(n)); verts += [r*cos(a), r*sin(a), 10] }
        verts += [0, 0, 10]
        let topCentre: Int32 = 16
        var indices: [Int32] = []
        var faceIDs: [Int32] = []
        func B(_ k: Int) -> Int32 { Int32(k % n) }
        func T(_ k: Int) -> Int32 { Int32(n + (k % n)) }
        for k in 0..<n {
            indices += [B(k), T(k + 1), B(k + 1), B(k), T(k), T(k + 1)]   // inward-normal (hole)
            faceIDs += [1, 1]                                            // one full-wrap barrel
        }
        for k in 0..<n { indices += [topCentre, T(k), T(k + 1)]; faceIDs += [3] }
        let cyl = StepFaceGeometry(kind: .cylinder, cylinderRadiusMM: 2.5,
                                   axisPoint: SIMD3(0, 0, 0), axisDir: SIMD3(0, 0, 1))
        let plane = StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1),
                                     planeOrigin: SIMD3(0, 0, 10))
        let geo: [StepFaceGeometry] = [StepFaceGeometry(kind: .other), cyl,
                                       StepFaceGeometry(kind: .other), plane]
        return ViewerMesh(vertices: verts, indices: indices, faceIDs: faceIDs, faceGeometry: geo)
    }

    /// A project with the bore+plane mesh, an anchor group on the bore (face 1) and a
    /// bare group on the plane (face 3). Returns the project + the two group ids.
    private func project() -> (ProjectModel, boreID: UUID, planeID: UUID) {
        let p = ProjectModel(id: UUID(), name: "P", material: "PLA", process: .fdm,
                             importedFile: nil, importedMesh: nil)
        p.viewerMesh = borePlusPlaneMesh()
        var sel = SelectionModel()
        sel.addGroup(); sel.pickFaces([1])
        sel.addGroup(); sel.pickFaces([3])
        p.selection = sel
        let ids = sel.groups.map { $0.id }
        p.force.makeAnchor(ids[0])
        p.seedUndoBaseline()
        return (p, ids[0], ids[1])
    }

    // MARK: - ADD: a manual primitive becomes a run clearance

    func testAddManualBoltEmitsAManualClearanceSpec() {
        let (p, _, planeID) = project()
        let before = p.clearanceSpecs().count
        p.addManualPrimitive(.bolt, to: planeID)
        let specs = p.clearanceSpecs()
        XCTAssertEqual(specs.count, before + 1, "the manual bolt adds exactly one clearance")
        let manual = specs.first { $0.manual != nil }
        XCTAssertNotNil(manual, "the added spec carries inline manual geometry")
        XCTAssertEqual(manual?.kind, .bolt)
        XCTAssertEqual(manual?.faceID, -1, "a manual spec uses the -1 face sentinel")
        XCTAssertTrue((manual?.manual?.radiusMM ?? 0) > 0, "the placed bolt has a real radius")
    }

    func testAddManualFaceEmitsASlabSpec() {
        let (p, boreID, _) = project()
        p.addManualPrimitive(.face, to: boreID)
        let manual = p.clearanceSpecs().first { $0.manual != nil && $0.kind == .face }
        XCTAssertNotNil(manual, "a manual plane emits a face (slab) clearance")
    }

    // MARK: - DELETE an AUTO primitive (BAR B3) — the over-find escape hatch

    func testDeleteAutoClearanceDropsItFromTheRun() {
        let (p, boreID, _) = project()
        XCTAssertEqual(p.clearanceSpecs().count, 1, "the anchored bore auto-clears")
        p.deleteAutoClearance(face: 1)          // the "−" on the auto bore's row
        XCTAssertTrue(p.clearanceSpecs().isEmpty, "a deleted auto clearance leaves the run")
        XCTAssertTrue(p.force.isClearanceFaceSuppressed(1))
        // The face STAYS in the group (it may still anchor) — only its clearance is gone.
        XCTAssertTrue(p.selection.groups.first { $0.id == boreID }!.faces.contains(1),
                      "delete suppresses the CLEARANCE, it does not remove the anchor face")
    }

    func testDeletionSurvivesAReDeriveAndAResolutionChange() {
        // B3: the decision persists in the model (ForceModel), so re-deriving specs
        // — which is exactly what a re-detect / resolution change does — never
        // resurrects it. clearanceSpecs is resolution-independent by construction.
        let (p, _, _) = project()
        p.deleteAutoClearance(face: 1)
        for _ in 0..<3 { XCTAssertTrue(p.clearanceSpecs().isEmpty, "stays deleted across re-derive") }
    }

    func testRestoreAutoClearanceUndeletesIt() {
        let (p, _, _) = project()
        p.deleteAutoClearance(face: 1)
        p.restoreAutoClearance(face: 1)
        XCTAssertEqual(p.clearanceSpecs().count, 1, "restoring the auto clearance brings it back")
    }

    // MARK: - UNDO / REDO through the EXISTING UndoHistory (BAR B5)

    func testUndoRedoCoversAdd() {
        let (p, _, planeID) = project()
        p.addManualPrimitive(.bolt, to: planeID)
        XCTAssertEqual(p.force.manualPrimitives(for: planeID).count, 1)

        p.performUndo()
        XCTAssertTrue(p.force.manualPrimitives(for: planeID).isEmpty, "undo removes the added primitive")
        p.performRedo()
        XCTAssertEqual(p.force.manualPrimitives(for: planeID).count, 1, "redo restores it")
    }

    func testUndoRedoCoversMove() {
        let (p, _, planeID) = project()
        let id = p.addManualPrimitive(.bolt, to: planeID)!
        // Commit the ADD as its own step, then move it well away from any detent target.
        p.performUndo(); p.performRedo()
        let original = p.force.manualPrimitives(for: planeID).first { $0.id == id }!.center
        p.moveManualPrimitive(id: id, in: planeID, to: SIMD3(100, 100, 100))
        let moved = p.force.manualPrimitives(for: planeID).first { $0.id == id }!.center
        XCTAssertNotEqual(moved, original, "the move changed the centre")

        p.performUndo()
        XCTAssertEqual(p.force.manualPrimitives(for: planeID).first { $0.id == id }!.center, original,
                       "undo reverts the move")
        p.performRedo()
        XCTAssertEqual(p.force.manualPrimitives(for: planeID).first { $0.id == id }!.center, moved,
                       "redo re-applies the move")
    }

    func testUndoRedoCoversDelete() {
        let (p, _, planeID) = project()
        let id = p.addManualPrimitive(.bolt, to: planeID)!
        p.performUndo(); p.performRedo()             // settle the add as a step
        p.removeManualPrimitive(id: id, from: planeID)
        XCTAssertTrue(p.force.manualPrimitives(for: planeID).isEmpty)

        p.performUndo()
        XCTAssertEqual(p.force.manualPrimitives(for: planeID).count, 1, "undo restores the deleted primitive")
        p.performRedo()
        XCTAssertTrue(p.force.manualPrimitives(for: planeID).isEmpty, "redo re-deletes it")
    }

    func testUndoCoversAutoDeletion() {
        let (p, _, _) = project()
        p.deleteAutoClearance(face: 1)
        XCTAssertTrue(p.clearanceSpecs().isEmpty)
        p.performUndo()
        XCTAssertEqual(p.clearanceSpecs().count, 1, "undo un-deletes an auto primitive too")
    }

    // MARK: - GROUP LOCK + name-only rename invariants (BAR B6)

    func testTappingGroupLocksInWithoutRenaming() {
        let (p, boreID, planeID) = project()
        let name = p.selection.groups.first { $0.id == boreID }!.name
        p.selection.setActive(boreID)                // "tap the group body"
        XCTAssertEqual(p.selection.activeGroupID, boreID, "tapping the group LOCKS INTO it")
        XCTAssertEqual(p.selection.groups.first { $0.id == boreID }!.name, name,
                       "tapping the group body does NOT rename (B6)")
        // Locking a different group moves the lock; nothing renames.
        p.selection.setActive(planeID)
        XCTAssertEqual(p.selection.activeGroupID, planeID)
    }

    func testRenameChangesOnlyTheName() {
        let (p, boreID, _) = project()
        p.selection.setActive(boreID)
        p.selection.rename(boreID, to: "Bolt holes")   // "tap the NAME"
        XCTAssertEqual(p.selection.groups.first { $0.id == boreID }!.name, "Bolt holes")
        XCTAssertEqual(p.selection.activeGroupID, boreID, "renaming keeps the group locked")
    }

    func testLeavingClearsTheActiveGroup() {
        let (p, boreID, _) = project()
        p.selection.setActive(boreID)
        p.selection.clearActive()                      // "tap elsewhere / into the ether"
        XCTAssertNil(p.selection.activeGroupID, "leaving unlocks the group")
    }

    // MARK: - magnetic detents (pure math)

    func testDetentSnapsAxisToWorldZAndCentreToBoreAxis() {
        // A bolt placed slightly askew + off the bore axis snaps back: axis → world Z,
        // centre → onto the bore axis point (reported so the UI can say WHY).
        let bore = PrimitiveSnapTarget(kind: .primitiveAxis, point: SIMD3(0, 0, 0),
                                       direction: SIMD3(0, 0, 1), label: "bore axis")
        var targets = ManualPrimitiveDetent.worldAxisTargets()
        targets.append(bore)
        let result = ManualPrimitiveDetent.apply(
            freeCenter: SIMD3(0.5, 0.5, 4),              // within 3 mm of the axis line
            axis: SIMD3(0.05, 0.0, 0.99),                // ~3° off Z
            targets: targets)
        XCTAssertTrue(result.didSnap, "a near-aligned placement snaps")
        XCTAssertLessThan(simd_distance(simd_normalize(result.axis), SIMD3(0, 0, 1)), 1e-5,
                          "the axis snaps to world Z")
        // Centre drops onto the bore axis line (x=y=0), keeping its z.
        XCTAssertEqual(result.center.x, 0, accuracy: 1e-4)
        XCTAssertEqual(result.center.y, 0, accuracy: 1e-4)
        XCTAssertTrue(result.labels.contains("bore axis"), "the UI is told it snapped to the bore axis")
    }

    func testDetentLeavesAFarPlacementFree() {
        let result = ManualPrimitiveDetent.apply(
            freeCenter: SIMD3(50, 50, 50),
            axis: SIMD3(1, 1, 0),                        // 45° off every world axis
            targets: ManualPrimitiveDetent.worldAxisTargets())
        XCTAssertFalse(result.didSnap, "a far, skew placement moves freely (no forced snap)")
        XCTAssertEqual(result.center, SIMD3(50, 50, 50))
    }

    // MARK: - sidecar round-trip (BAR B3 persistence across re-import)

    func testSidecarRoundTripsSuppressionsAndManualPrimitives() throws {
        let dir = NSTemporaryDirectory() + "clr-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let model = dir + "/part.stl"
        FileManager.default.createFile(atPath: model, contents: Data("solid".utf8))
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let g = UUID()
        let mp = ManualPrimitive.defaultBolt(at: SIMD3(1, 2, 3), radiusMM: 2, halfLengthMM: 5)
        let sidecar = ClearanceSidecar(
            suppressedAutoFaces: [1, 4, 9],
            manual: [.init(group: g, primitives: [mp])])
        XCTAssertTrue(sidecar.write(forModelPath: model))

        let read = try XCTUnwrap(ClearanceSidecar.read(forModelPath: model))
        XCTAssertEqual(read.suppressedAutoFaces, [1, 4, 9], "deletions survive the sidecar (B3)")
        XCTAssertEqual(read.manual.first?.group, g)
        XCTAssertEqual(read.manual.first?.primitives.first?.id, mp.id)
        XCTAssertEqual(read.manual.first?.primitives.first?.radiusMM, 2)
    }

    func testEmptySidecarIsDeletedNotWritten() throws {
        let dir = NSTemporaryDirectory() + "clr-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let model = dir + "/part.stl"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // Pre-seed a stale sidecar, then write an empty one → it should be removed.
        _ = ClearanceSidecar(suppressedAutoFaces: [5]).write(forModelPath: model)
        XCTAssertNotNil(ClearanceSidecar.read(forModelPath: model))
        _ = ClearanceSidecar().write(forModelPath: model)
        XCTAssertNil(ClearanceSidecar.read(forModelPath: model), "an empty state deletes the sidecar")
    }

    /// The "auto-apply on import" effect: loading the sidecar's deletions into the
    /// force model drops those clearances — a phantom bore stays deleted after a
    /// re-import of the same file, without the finder resurrecting it.
    func testLoadingSuppressionsReappliesDeletions() {
        let (p, _, _) = project()
        XCTAssertEqual(p.clearanceSpecs().count, 1)
        p.force.loadSuppressedClearanceFaces([1])       // what applyClearanceSidecar does
        XCTAssertTrue(p.clearanceSpecs().isEmpty, "a re-imported deletion stays deleted (B3)")
    }

    // MARK: - DEFECT 1: the panel and the viewport chip read ONE value

    /// The regression guard for DEFECT 1. A manual CYLINDER's margin/axial as the
    /// 3D-viewport chip resolves it (`clearanceMetric`) MUST equal what the Selections
    /// panel resolves (the identical call) AND the number the rendered volume is built
    /// from. The bug: the viewport chip derived Auto from a B-rep face lookup a MANUAL
    /// primitive has NO entry in (→ nil → 0 mm) while the panel used the primitive's own
    /// radius (→ 9.14 mm). This test fails the instant the two paths can диverge again —
    /// e.g. if `clearanceMetric` stops handling the negative (manual) faceID.
    func testManualBoltMetricIsOneValueAcrossSurfaces() {
        let (p, _, planeID) = project()
        let id = p.addManualPrimitive(.bolt, to: planeID)!
        let key = ProjectModel.manualFaceKey(id)
        let mp = p.force.manualPrimitives(for: planeID).first { $0.id == id }!

        let margin = try! XCTUnwrap(p.clearanceMetric(groupID: planeID, faceID: key, role: .margin))
        let axial = try! XCTUnwrap(p.clearanceMetric(groupID: planeID, faceID: key, role: .axial))
        XCTAssertNil(margin.override); XCTAssertNil(axial.override)
        XCTAssertEqual(margin.resolved, mp.radiusMM, accuracy: 1e-9, "Auto margin = bore radius")
        XCTAssertEqual(axial.resolved, 2 * mp.radiusMM, accuracy: 1e-9, "Auto axial = 2·radius")
        XCTAssertGreaterThan(margin.resolved, 0, "the manual bolt's margin is NOT 0 (the DEFECT 1 symptom)")

        // The rendered VOLUME is built from the SAME number: cylinder radius = boreR + margin,
        // axial span end = halfLength + axial. Picture == chip == run.
        let vol = try! XCTUnwrap(p.clearanceVolumes().first { $0.volume.faceID == key }).volume
        guard case let .cylinder(_, _, radiusMM, _, tHi) = vol.shape else { return XCTFail("bolt → cylinder") }
        XCTAssertEqual(Double(radiusMM) - mp.radiusMM, margin.resolved, accuracy: 1e-3,
                       "the picture is drawn with the value the chips show (margin)")
        XCTAssertEqual(Double(tHi) - mp.halfLengthMM, axial.resolved, accuracy: 1e-3,
                       "the picture is drawn with the value the chips show (axial)")
    }

    /// The manual PLANE case (which the on-device report said AGREED) still agrees: its
    /// Auto is the 3 mm constant, needing no radius lookup — so both surfaces read 3 mm.
    func testManualPlaneMetricIsOneValue() {
        let (p, boreID, _) = project()
        let id = p.addManualPrimitive(.face, to: boreID)!
        let key = ProjectModel.manualFaceKey(id)
        let depth = try! XCTUnwrap(p.clearanceMetric(groupID: boreID, faceID: key, role: .slabDepth))
        XCTAssertEqual(depth.resolved, ClearanceSuggestion.faceSlabDepthMM)
    }

    /// G2 — the SAME single source serves an AUTO-found bore (the other origin). Its
    /// margin resolves to the exact bore radius and matches the rendered volume.
    func testAutoBoreMetricMatchesRenderedVolume() {
        let (p, boreID, _) = project()            // face 1 is a cylinder r=2.5, anchored → auto-clears
        let m = try! XCTUnwrap(p.clearanceMetric(groupID: boreID, faceID: 1, role: .margin))
        XCTAssertEqual(m.resolved, 2.5, accuracy: 1e-6, "auto Auto margin = bore radius")
        let vol = try! XCTUnwrap(p.clearanceVolumes().first { $0.volume.faceID == 1 }).volume
        guard case let .cylinder(_, _, radiusMM, _, _) = vol.shape else { return XCTFail("bore → cylinder") }
        XCTAssertEqual(Double(radiusMM) - 2.5, m.resolved, accuracy: 1e-3)
    }

    /// The other half of DEFECT 1's viewport breakage: a viewport-handle DRAG write must
    /// land on the MANUAL primitive's OWN override — not a phantom group/bore slot the run
    /// ignores. `writeClearanceMetric` dispatches by the sign of faceID; the written value
    /// reaches both the metric and the serialized run spec (B2 discipline).
    func testWriteClearanceMetricReachesManualPrimitiveAndRun() {
        let (p, _, planeID) = project()
        let id = p.addManualPrimitive(.bolt, to: planeID)!
        let key = ProjectModel.manualFaceKey(id)
        p.writeClearanceMetric(groupID: planeID, faceID: key, role: .margin, mm: 7.0)
        XCTAssertEqual(p.clearanceMetric(groupID: planeID, faceID: key, role: .margin)?.override, 7.0)
        XCTAssertEqual(p.force.manualPrimitives(for: planeID).first { $0.id == id }?.override.concentricMarginMM, 7.0)
        let spec = try! XCTUnwrap(p.clearanceSpecs().first { $0.manual != nil })
        XCTAssertEqual(spec.concentricMarginMM, 7.0, accuracy: 1e-9, "the drag write reaches the run")
    }

    // MARK: - DEFECT 2: transform-gizmo model ops (rotate / copy / convert / move→job)

    /// ROTATE turns the primitive's axis and keeps its centre, through the SAME undo
    /// history (G3). Snap off so the assertion is exact.
    func testRotateManualPrimitiveTurnsAxisKeepsCentreUndoable() {
        let (p, _, planeID) = project()
        let id = p.addManualPrimitive(.bolt, to: planeID)!
        p.performUndo(); p.performRedo()                 // settle the ADD as its own step
        let before = p.force.manualPrimitives(for: planeID).first { $0.id == id }!
        p.rotateManualPrimitive(id: id, in: planeID, to: SIMD3(1, 0, 0), snap: false)
        let after = p.force.manualPrimitives(for: planeID).first { $0.id == id }!
        XCTAssertEqual(after.center, before.center, "rotation is in place — centre unchanged")
        XCTAssertEqual(simd_normalize(after.axis), SIMD3(1, 0, 0), "axis turned to +X")

        p.performUndo()
        XCTAssertEqual(simd_normalize(p.force.manualPrimitives(for: planeID).first { $0.id == id }!.axis),
                       simd_normalize(before.axis), "undo reverts the rotation")
    }

    /// The rotated axis reaches the RUN through the spec's `axisDir` — no schema change
    /// (BLOCKED-STOP: rotation is expressed by the direction vector).
    func testRotatedAxisReachesTheRun() {
        let (p, _, planeID) = project()
        let id = p.addManualPrimitive(.bolt, to: planeID)!
        p.rotateManualPrimitive(id: id, in: planeID, to: SIMD3(1, 0, 0), snap: false)
        let spec = try! XCTUnwrap(p.clearanceSpecs().first { $0.manual != nil })
        let dir = simd_normalize(try! XCTUnwrap(spec.manual).axisDir)
        XCTAssertEqual(dir, SIMD3(1, 0, 0), "the run gets the rotated axis_dir")
    }

    /// COPY produces an INDEPENDENT primitive (G6): editing the copy leaves the original
    /// untouched, and the two have distinct ids + centres.
    func testCopyProducesIndependentPrimitive() {
        let (p, _, planeID) = project()
        let orig = p.addManualPrimitive(.bolt, to: planeID)!
        let copy = try! XCTUnwrap(p.copyManualPrimitive(id: orig, in: planeID))
        XCTAssertNotEqual(copy, orig, "the copy has a fresh id")
        XCTAssertEqual(p.force.manualPrimitives(for: planeID).count, 2)

        // Edit ONLY the copy.
        p.setManualMargin(id: copy, in: planeID, mm: 9.0)
        let o = p.force.manualPrimitives(for: planeID).first { $0.id == orig }!
        let c = p.force.manualPrimitives(for: planeID).first { $0.id == copy }!
        XCTAssertNil(o.override.concentricMarginMM, "the original is untouched by editing the copy")
        XCTAssertEqual(c.override.concentricMarginMM, 9.0, "the copy took the edit")
        XCTAssertNotEqual(o.center, c.center, "the copy is nudged clear of the original")
    }

    func testCopyAddsASecondRunClearance() {
        let (p, _, planeID) = project()
        let orig = p.addManualPrimitive(.bolt, to: planeID)!
        let before = p.clearanceSpecs().count
        p.copyManualPrimitive(id: orig, in: planeID)
        XCTAssertEqual(p.clearanceSpecs().count, before + 1, "the copy is its own run clearance")
    }

    /// G2 — grabbing an AUTO-found clearance's gizmo converts it to an explicit MANUAL
    /// primitive: the auto face is suppressed, a manual primitive of the SAME geometry is
    /// added (so the run's clearance count and its resolved value are unchanged), and the
    /// conversion is explicit in the model (a real ManualPrimitive + a suppressed face).
    func testConvertAutoBoreToManualPreservesTheClearance() {
        let (p, boreID, _) = project()                   // face 1: cylinder r=2.5, anchored → auto-clears
        XCTAssertEqual(p.clearanceSpecs().count, 1)
        let autoMargin = p.clearanceMetric(groupID: boreID, faceID: 1, role: .margin)!.resolved

        let id = try! XCTUnwrap(p.convertAutoClearanceToManual(face: 1, in: boreID))
        XCTAssertTrue(p.force.isClearanceFaceSuppressed(1), "the auto face no longer clears")
        XCTAssertEqual(p.clearanceSpecs().count, 1, "still exactly one clearance — now manual")
        let mp = p.force.manualPrimitives(for: boreID).first { $0.id == id }!
        XCTAssertEqual(mp.kind, .bolt)
        XCTAssertEqual(mp.radiusMM, 2.5, accuracy: 1e-6, "the manual bolt matches the bore radius")
        let key = ProjectModel.manualFaceKey(id)
        XCTAssertEqual(p.clearanceMetric(groupID: boreID, faceID: key, role: .margin)!.resolved,
                       autoMargin, accuracy: 1e-6, "the resolved value does not jump on conversion")
    }

    /// G4 — a MOVED primitive reaches the job: the serialized manual geometry's axisPoint
    /// equals the dragged centre. `snap: false` (the magnet override) makes the move exact.
    func testGizmoMoveReachesTheJob() {
        let (p, _, planeID) = project()
        let id = p.addManualPrimitive(.bolt, to: planeID)!
        // Resolve a translate through the SAME pure math the gesture uses, then commit it.
        let drag = PrimitiveGizmo.Drag(
            handle: .free, startCenter: p.force.manualPrimitives(for: planeID).first { $0.id == id }!.center,
            startAxis: SIMD3(0, 0, 1),
            grab: .init(origin: SIMD3(0, 0, 100), dir: SIMD3(0, 0, -1)), viewDir: SIMD3(0, 0, -1))
        let moved = drag.resolve(currentRay: .init(origin: SIMD3(20, 30, 100), dir: SIMD3(0, 0, -1))).center
        p.moveManualPrimitive(id: id, in: planeID, to: moved, snap: false)

        let spec = try! XCTUnwrap(p.clearanceSpecs().first { $0.manual != nil })
        let g = try! XCTUnwrap(spec.manual)
        XCTAssertEqual(g.axisPoint.x, moved.x, accuracy: 1e-6)
        XCTAssertEqual(g.axisPoint.y, moved.y, accuracy: 1e-6)
        XCTAssertEqual(g.axisPoint.z, moved.z, accuracy: 1e-6)
        // …and the rendered volume centres there too (picture == run — B2 for a dragged primitive).
        let key = ProjectModel.manualFaceKey(id)
        XCTAssertNotNil(p.clearanceVolumes().first { $0.volume.faceID == key })
    }

    // MARK: - PLANE Length / Width extents (manual-plane-length-width)

    /// P5 — the DEFAULT a plane loads with. A freshly placed manual plane is SQUARE:
    /// `halfUMM == halfWMM == 0.2·bounds-radius`, i.e. full Length == full Width. An
    /// existing project keeps whatever half-extents its sidecar stored, unchanged; this
    /// pins the placement default so a regression in `defaultFace`/`addManualPrimitive`
    /// is caught.
    func testNewManualPlaneDefaultsToASquareFootprint() {
        let (p, boreID, _) = project()
        let id = p.addManualPrimitive(.face, to: boreID)!
        let mp = p.force.manualPrimitives(for: boreID).first { $0.id == id }!
        XCTAssertGreaterThan(mp.halfUMM, 0, "a new plane has a real in-plane extent (not zero)")
        XCTAssertEqual(mp.halfUMM, mp.halfWMM, accuracy: 1e-9, "a new plane is square by default")
    }

    /// P1 (+ the ÷2 boundary) — the FULL length/width a user types lands as the CENTRED
    /// half-extent the core wants, and reaches the run spec. Typing 40 mm of Length →
    /// `halfUMM == 20`; 24 mm of Width → `halfWMM == 12`. The value the user typed is the
    /// value that reaches the job (asserted again end-to-end in `testEditedPlaneExtents…`).
    func testSetPlaneLengthWidthConvertsFullToHalfAndReachesSpec() {
        let (p, boreID, _) = project()
        let id = p.addManualPrimitive(.face, to: boreID)!
        p.setManualLength(id: id, in: boreID, mm: 40)
        p.setManualWidth(id: id, in: boreID, mm: 24)
        let mp = p.force.manualPrimitives(for: boreID).first { $0.id == id }!
        XCTAssertEqual(mp.halfUMM, 20, accuracy: 1e-9, "full Length 40 → half-extent 20")
        XCTAssertEqual(mp.halfWMM, 12, accuracy: 1e-9, "full Width 24 → half-extent 12")

        let g = try! XCTUnwrap(p.clearanceSpecs().first { $0.manual != nil && $0.kind == .face }?.manual)
        XCTAssertEqual(g.halfUMM, 20, accuracy: 1e-9, "the typed Length reaches the run spec (halved)")
        XCTAssertEqual(g.halfWMM, 12, accuracy: 1e-9, "the typed Width reaches the run spec (halved)")
    }

    /// P1 end-to-end — the typed extent survives all the way to `job.json`. A plane whose
    /// Length/Width the user edited serializes `half_u_mm`/`half_w_mm` = the HALF of what
    /// was typed (the ÷2 happens once, at the model boundary; nothing halves it twice).
    func testEditedPlaneExtentsReachTheJobJSON() throws {
        let (p, boreID, _) = project()
        let id = p.addManualPrimitive(.face, to: boreID)!
        p.setManualLength(id: id, in: boreID, mm: 50)
        p.setManualWidth(id: id, in: boreID, mm: 18)

        let req = RunRequest(
            modelPath: "/tmp/part.stl", material: "PLA", materialsPath: "", rulesPath: "",
            resolution: 96, projectName: "plane-extents",
            anchorFaceIDs: [1], loadGroups: [], minimizePlastic: true,
            buildDirection: SIMD3(0, 0, 1), infillPercent: 40,
            designBox: nil, keepOutBoxes: [], clearances: p.clearanceSpecs(),
            faceProtections: [], faceProtectionDepthMM: -1)
        let cfg = RemoteRunnerConfig(host: "127.0.0.1", port: 8757, expectedFingerprint: "test")
        let run = RemoteRun(config: cfg, request: req, progress: { _, _, _ in true }, onVariant: { _ in })
        let job = try XCTUnwrap(JSONSerialization.jsonObject(with: try run.buildJobJSON()) as? [String: Any])
        let loads = try XCTUnwrap(job["loads"] as? [String: Any])
        let clist = try XCTUnwrap(loads["clearances"] as? [[String: Any]])
        let face = try XCTUnwrap(clist.first { ($0["kind"] as? String) == "face" })
        let geo = try XCTUnwrap(face["geometry"] as? [String: Any])
        XCTAssertEqual(geo["half_u_mm"] as? Double, 25, "typed Length 50 → half_u_mm 25 in job.json")
        XCTAssertEqual(geo["half_w_mm"] as? Double, 9, "typed Width 18 → half_w_mm 9 in job.json")
    }

    /// P2 — the RENDERED slab matches the entered extents. After editing Length/Width, the
    /// resolved clearance VOLUME the viewport draws carries the identical half-extents the
    /// spec does (picture == run), because both read `mp.halfUMM`/`halfWMM` — one source.
    func testRenderedSlabMatchesEnteredExtents() {
        let (p, boreID, _) = project()
        let id = p.addManualPrimitive(.face, to: boreID)!
        p.setManualLength(id: id, in: boreID, mm: 40)   // → halfU 20
        p.setManualWidth(id: id, in: boreID, mm: 24)    // → halfW 12
        let key = ProjectModel.manualFaceKey(id)
        let vol = try! XCTUnwrap(p.clearanceVolumes().first { $0.volume.faceID == key }).volume
        guard case let .slab(_, _, _, _, halfU, halfV, _) = vol.shape else { return XCTFail("plane → slab") }
        XCTAssertEqual(Double(halfU), 20, accuracy: 1e-4, "the drawn slab's U half-extent == entered Length/2")
        XCTAssertEqual(Double(halfV), 12, accuracy: 1e-4, "the drawn slab's W half-extent == entered Width/2")
    }

    /// P4 — an extent edit registers in the EXISTING UndoHistory: undo reverts it, redo
    /// re-applies it (the same debounced auto-commit that covers Depth, add, move, delete).
    func testUndoRedoCoversAPlaneExtentEdit() {
        let (p, boreID, _) = project()
        let id = p.addManualPrimitive(.face, to: boreID)!
        p.performUndo(); p.performRedo()                 // settle the ADD as its own step
        let original = p.force.manualPrimitives(for: boreID).first { $0.id == id }!.halfUMM

        p.setManualLength(id: id, in: boreID, mm: 40)
        let edited = p.force.manualPrimitives(for: boreID).first { $0.id == id }!.halfUMM
        XCTAssertEqual(edited, 20, accuracy: 1e-9)
        XCTAssertNotEqual(edited, original, "the edit changed the half-extent")

        p.performUndo()
        XCTAssertEqual(p.force.manualPrimitives(for: boreID).first { $0.id == id }!.halfUMM, original,
                       accuracy: 1e-9, "undo reverts the extent edit")
        p.performRedo()
        XCTAssertEqual(p.force.manualPrimitives(for: boreID).first { $0.id == id }!.halfUMM, edited,
                       accuracy: 1e-9, "redo re-applies it")
    }

    /// An extent has no "Auto": an emptied field (nil) is a NO-OP (never zeroes the slab),
    /// and a non-positive entry is floored to one grid step so the footprint stays non-degenerate.
    func testPlaneExtentIgnoresNilAndFloorsNonPositive() {
        let (p, boreID, _) = project()
        let id = p.addManualPrimitive(.face, to: boreID)!
        p.setManualLength(id: id, in: boreID, mm: 40)
        p.setManualLength(id: id, in: boreID, mm: nil)   // emptied field → ignored
        XCTAssertEqual(p.force.manualPrimitives(for: boreID).first { $0.id == id }!.halfUMM, 20,
                       accuracy: 1e-9, "an emptied field keeps the current extent")
        p.setManualWidth(id: id, in: boreID, mm: 0)      // zero → floored, not collapsed
        XCTAssertEqual(p.force.manualPrimitives(for: boreID).first { $0.id == id }!.halfWMM,
                       ClearanceQuantize.stepMM, accuracy: 1e-9, "zero floors to one grid step")
    }

    /// The snap OVERRIDE: with `snap: false` a placement near a strong detent target is NOT
    /// pulled onto it — the finger wins (the explicit override the handoff requires).
    func testSnapOverrideKeepsAFreePlacement() {
        let (p, boreID, _) = project()
        let id = p.addManualPrimitive(.bolt, to: boreID)!
        // A centre 0.5 mm off the bore axis (well within the 3 mm snap) — snap ON pulls it on.
        p.moveManualPrimitive(id: id, in: boreID, to: SIMD3(0.5, 0.5, 4), snap: true)
        let snapped = p.force.manualPrimitives(for: boreID).first { $0.id == id }!.center
        XCTAssertEqual(snapped.x, 0, accuracy: 1e-4, "snap ON drops it onto the bore axis")
        // Same placement with snap OFF stays exactly where the finger put it.
        p.moveManualPrimitive(id: id, in: boreID, to: SIMD3(0.5, 0.5, 4), snap: false)
        let free = p.force.manualPrimitives(for: boreID).first { $0.id == id }!.center
        XCTAssertEqual(free, SIMD3(0.5, 0.5, 4), "snap OFF keeps the free placement")
    }
}
