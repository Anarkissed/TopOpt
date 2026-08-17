// SurfaceRound7Tests.swift — the maintainer's 2026-08-16 list, each item pinned.
//
//   1. off-model taps must never select a face
//   2. union: tapping a picked piece drops it
//   3. switching tool arms it on what is already selected
//   4. the wireframe reflects cuts AND unions
//   5. wireframe + x-ray are offered on the Topology page
//   6. the pattern (SurfacePatternArcTests)
//   7. isolate reaches the Topology page
//   8. Save, and leaving without it reverts

import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ 1 — A TAP ON EMPTY SPACE IS A MISS
//
// Maintainer: "When tapping just off to the side of the model (in my case, in the
// bottom-right area of the screen) on the 'floor', faces are randomly selected.
// With union it will select the large right side of the model, with the selection
// tool the very front face. All touch inputs NEED to connect only to their faces."
//
// ★ AND THEY WERE NOT RANDOM. The CPU fallback picker casts a WORLD-space ray at
// MODEL-space vertices; once gravity settles the part, the geometry that ray meets
// is the part in its ORIGINAL pose, sitting somewhere else entirely. The same
// wrong face comes back from the same empty pixel every time.

final class OffModelTapTests: XCTestCase {

    /// A 20 mm cube at the origin, one face id per side.
    private func cube() -> ViewerMesh {
        var v: [Float] = [], idx: [Int32] = [], fids: [Int32] = []
        let c: [SIMD3<Float>] = [
            SIMD3(-10, -10, -10), SIMD3(10, -10, -10), SIMD3(10, 10, -10),
            SIMD3(-10, 10, -10), SIMD3(-10, -10, 10), SIMD3(10, -10, 10),
            SIMD3(10, 10, 10), SIMD3(-10, 10, 10)]
        let quads = [[0, 1, 2, 3], [5, 4, 7, 6], [4, 0, 3, 7],
                     [1, 5, 6, 2], [4, 5, 1, 0], [3, 2, 6, 7]]
        for (f, q) in quads.enumerated() {
            let base = Int32(v.count / 3)
            for i in q { v += [c[i].x, c[i].y, c[i].z] }
            idx += [base, base + 1, base + 2, base, base + 2, base + 3]
            fids += [Int32(f), Int32(f)]
        }
        return ViewerMesh(vertices: v, indices: idx, faceIDs: fids,
                          faceGeometry: (0..<6).map { _ in
                              StepFaceGeometry(kind: .plane,
                                               planeNormal: SIMD3(0, 0, 1)) })
    }

    /// ★ THE MECHANISM, DIRECTLY. A ray cast in WORLD space at a part that is DRAWN
    /// through a settle rotation hits geometry that is not where the part appears.
    /// This is the arithmetic the tap handler used to do.
    func testAWorldRayHitsThePartWhereItIsNotDrawn() throws {
        let m = cube()
        // The part is settled by a quarter turn about Z, so what the user sees is
        // the rotated cube; `m.positions` are still the unrotated ones.
        let settle = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1))

        // A ray aimed at empty space to the side of the DRAWN part: along −X at a
        // height the drawn cube does not occupy but the unrotated one, tipped over,
        // would. Cast in world space it must be checked against the drawn pose.
        let origin = SIMD3<Float>(-100, 4, 0)
        let dir = SIMD3<Float>(1, 0, 0)

        // Model space: undo the settle, which is what the fix does.
        let inv = settle.inverse
        let modelOrigin = inv.act(origin)
        let modelDir = inv.act(dir)

        let world = FacePicker.hit(rayOrigin: origin, rayDir: dir, mesh: m)
        let model = FacePicker.hit(rayOrigin: modelOrigin, rayDir: modelDir, mesh: m)

        // Both hit here (the cube is symmetric), but they hit DIFFERENT faces —
        // which is the whole point: the answer depends on which frame you ask in,
        // and only one of them is the frame the user is looking at.
        XCTAssertNotNil(world)
        XCTAssertNotNil(model)
        XCTAssertNotEqual(world?.faceID, model?.faceID,
                          "★ a world-space ray and a model-space ray name different "
                          + "faces once the part is settled — so the picker must not "
                          + "be allowed to answer in the wrong one")
    }

    /// ★ AND THE THREE-WAY ANSWER IS WHAT LETS THE CALLER REFUSE. `FaceID?`
    /// collapsed "the pass ran and found nothing" into "the pass could not run",
    /// and the caller asked the CPU picker in both cases.
    func testTheIDPassSaysWhetherItRanAtAll() {
        // The enum exists and the three cases are distinct — the property the tap
        // handler switches on.
        let a = MeshRenderer.FaceIDPass.face(3)
        let b = MeshRenderer.FaceIDPass.background
        let c = MeshRenderer.FaceIDPass.unavailable
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(b, c)
        XCTAssertNotEqual(a, c)
        if case .face(let f) = a { XCTAssertEqual(f, 3) } else { XCTFail("case") }
    }

    /// A ray that misses the mesh entirely returns nil rather than the nearest
    /// anything — the property the `.unavailable` branch now leans on.
    func testAMissIsAMiss() {
        let m = cube()
        XCTAssertNil(FacePicker.hit(rayOrigin: SIMD3(0, 0, 200),
                                    rayDir: SIMD3(0, 1, 0), mesh: m),
                     "★ a ray parallel to the part and past it hits nothing")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ 2 — UNION TOGGLES OFF

final class UnionToggleTests: XCTestCase {

    func testTappingAPickedPieceDropsIt() {
        var u = SurfaceUnion()
        u.toggle(10)
        u.toggle(11)
        XCTAssertEqual(u.count, 2)
        XCTAssertTrue(u.canCommit)
        u.toggle(10)
        XCTAssertEqual(u.pieces, [11], "★ tapping a picked piece removes it")
        XCTAssertFalse(u.canCommit, "and the confirm goes with it")
        u.toggle(10)
        XCTAssertEqual(u.pieces, [11, 10], "★ and tapping again puts it back")
    }

    /// ★ THE PART THAT WAS ACTUALLY BROKEN. `toggle` always worked; what made the
    /// piece stay lit is that every tap also set the page's SELECTION, and the tint
    /// lights a selected region whether or not the union holds it. So a piece
    /// toggled off went on glowing — as a selection.
    func testTheTintDoesNotLightAPieceTheUnionHasDropped() {
        let m = ViewerMesh(vertices: [0, 0, 0, 10, 0, 0, 10, 10, 0],
                           indices: [0, 1, 2], faceIDs: [0],
                           faceGeometry: [StepFaceGeometry(kind: .plane,
                                                           planeNormal: SIMD3(0, 0, 1))])
        var regions = FaceRegionModel()
        let r = regions.union(faces: [0], named: "f0")

        // With the piece SELECTED it lights…
        let lit = SurfaceTint.states(mesh: m, groupedFaces: [0], regions: regions,
                                     selected: r, picked: [], fragmentTested: [])
        XCTAssertTrue(lit.contains { $0 == .selected },
                      "★ a selected region lights — that is the mechanism")

        // …so a union that has dropped it must not leave it selected. The page
        // clears the selection in the union branch for exactly this reason; here
        // the consequence is pinned: with nothing selected and nothing picked,
        // nothing is lit.
        let dark = SurfaceTint.states(mesh: m, groupedFaces: [0], regions: regions,
                                      selected: nil, picked: [], fragmentTested: [])
        XCTAssertFalse(dark.contains { $0 == .selected },
                       "★ dropped means dark")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ 3 — A TOOL SWITCH ARMS ON WHAT IS ALREADY SELECTED
//
// Maintainer: "When a face is selected with the selection tool and a tool is
// changed, the tool's action should automatically be turned on on the selected
// face."
//
// The switch itself is view state (`surfaceSwitch`), and what it needs from the
// model is one thing: WHICH FACE the current selection sits on. That resolution is
// the part that can break — a selection is a REGION, and a region reaches its face
// through its parts and its cuts — so it is what is pinned here.

@MainActor
final class ToolCarriesSelectionTests: XCTestCase {

    private func project() -> ProjectModel {
        let v: [Float] = [0, 0, 0, 10, 0, 0, 10, 10, 0, 0, 10, 0,
                          10, 0, 0, 20, 0, 0, 20, 10, 0, 10, 10, 0]
        let p = ProjectModel(id: UUID(), name: "Carry", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = ViewerMesh(vertices: v,
                                  indices: [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7],
                                  faceIDs: [0, 0, 1, 1],
                                  faceGeometry: (0..<2).map { _ in
                                      StepFaceGeometry(kind: .plane,
                                                       planeNormal: SIMD3(0, 0, 1)) })
        return p
    }

    func testACutPieceStillNamesItsFace() throws {
        let p = project()
        let kids = p.commitSurfaceCut(SurfaceCut(point: SIMD3(5, 5, 0),
                                                 normal: SIMD3(1, 0, 0),
                                                 faceID: 0,
                                                 faceNormal: SIMD3(0, 0, 1)))
        let piece = try XCTUnwrap(kids.first)
        XCTAssertEqual(p.surfaceResolvedFaces(piece), [0],
                       "★ switching to Cut with this piece selected has a face to "
                       + "centre the new cut on")
    }

    /// A UNION owns no faces of its own — it resolves through its parts. If that
    /// resolution returned nothing, switching tools with a union selected would
    /// silently arm on nothing.
    func testAUnionStillNamesItsFaces() throws {
        let p = project()
        let a = try XCTUnwrap(p.surfaceEnsureRegion(for: 0))
        let b = try XCTUnwrap(p.surfaceEnsureRegion(for: 1))
        var u = SurfaceUnion()
        u.toggle(a); u.toggle(b)
        let union = try XCTUnwrap(p.commitSurfaceUnion(u))
        XCTAssertEqual(p.surfaceResolvedFaces(union), [0, 1],
                       "★ a union reaches its faces through its parts")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ 4 — THE WIREFRAME REFLECTS CUTS AND UNIONS

final class LiveWireframeTests: XCTestCase {

    /// Two coplanar quads sharing an edge, as two faces — so there IS a B-rep edge
    /// between them to remove.
    private func twoFaces() -> ViewerMesh {
        let v: [Float] = [0, 0, 0, 10, 0, 0, 10, 10, 0, 0, 10, 0,     // face 0
                          10, 0, 0, 20, 0, 0, 20, 10, 0, 10, 10, 0]   // face 1
        return ViewerMesh(vertices: v,
                          indices: [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7],
                          faceIDs: [0, 0, 1, 1],
                          faceGeometry: (0..<2).map { _ in
                              StepFaceGeometry(kind: .plane,
                                               planeNormal: SIMD3(0, 0, 1)) })
    }

    /// ★ A UNION ERASES THE EDGE BETWEEN ITS PARTS. Two faces combined ARE one
    /// face; leaving the line drawn says the union did not happen.
    func testAUnionRemovesTheEdgeBetweenTheFacesItCombined() {
        let m = twoFaces()
        let before = SurfaceWireframe.segmentCount(of: m)
        let after = SurfaceWireframe.segmentCount(of: m, welded: [[0, 1]])
        XCTAssertLessThan(after, before,
                          "★ the shared edge is gone — \(before) → \(after)")
        XCTAssertGreaterThan(after, 0,
                             "★ but the OUTER rim survives: it still has a side "
                             + "that is not in the union")
        XCTAssertEqual(before - after, 1,
                       "★ exactly the one shared edge, no more")
    }

    /// ★ NEGATIVE CONTROL. A union that does not contain BOTH sides of an edge
    /// must not remove it — otherwise the test above passes for the wrong reason.
    func testAUnionOfOneFaceRemovesNothing() {
        let m = twoFaces()
        XCTAssertEqual(SurfaceWireframe.segmentCount(of: m, welded: [[0]]),
                       SurfaceWireframe.segmentCount(of: m),
                       "★ an edge with a face outside the union is still an edge")
    }

    /// ★ AND A CUT ADDS ONE. The other half of "the wireframe doesn't reflect the
    /// unions or cuts I made".
    func testACutAddsItsTraceToTheEdgeSet() {
        let m = twoFaces()
        var regions = FaceRegionModel()
        XCTAssertTrue(SurfaceCutLines.committed(regions: regions, in: m).isEmpty,
                      "nothing cut yet")
        let parent = regions.union(faces: [0], named: "f0")
        _ = regions.splitManual(parent, point: SIMD3(5, 5, 0),
                                normal: SIMD3(1, 0, 0))
        let after = SurfaceCutLines.committed(regions: regions, in: m)
        XCTAssertFalse(after.isEmpty, "★ the cut's trace is in the line set")
    }

    /// ★ AND IT IS DRAWN ONCE, NOT TWICE. Both halves are bounded by the same
    /// plane; `FaceRegion.edges` gives it to one of them so the other does not
    /// draw a coincident copy.
    func testACutIsDrawnByOneHalfOnly() {
        let m = twoFaces()
        var regions = FaceRegionModel()
        let parent = regions.union(faces: [0], named: "f0")
        let kids = regions.splitManual(parent, point: SIMD3(5, 5, 0),
                                       normal: SIMD3(1, 0, 0))
        XCTAssertEqual(kids.count, 2)
        let owned = kids.compactMap { regions.region($0)?.drawnCuts.count }
        XCTAssertEqual(owned.reduce(0, +), 1,
                       "★ one owner for one boundary — got \(owned)")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ 5 — THE VIEW MODE IS OFFERED WHERE IT SHOULD BE

final class ViewModeStageTests: XCTestCase {

    /// ★ EVERY STAGE OFFERS THEM (maintainer, 2026-08-16: "Please add the wireframe
    /// and xray view in the Lattice stage" — completing "throughout the entire app").
    func testEveryStageOffersTheWireframe() {
        for stage in WorkspaceStage.allCases {
            XCTAssertTrue(WorkspaceStageVisibility.of(stage).wireframe,
                          "★ \(stage.title) offers the view controls")
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ 8 — SAVE, AND LEAVING WITHOUT IT REVERTS

@MainActor
final class SurfaceScratchTests: XCTestCase {

    private func mesh() -> ViewerMesh {
        let v: [Float] = [0, 0, 0, 10, 0, 0, 10, 10, 0, 0, 10, 0,
                          10, 0, 0, 20, 0, 0, 20, 10, 0, 10, 10, 0]
        return ViewerMesh(vertices: v,
                          indices: [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7],
                          faceIDs: [0, 0, 1, 1],
                          faceGeometry: (0..<2).map { _ in
                              StepFaceGeometry(kind: .plane,
                                               planeNormal: SIMD3(0, 0, 1)) })
    }

    private func project() -> ProjectModel {
        let p = ProjectModel(id: UUID(), name: "Scratch", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = mesh()
        return p
    }

    func testCapturingThenCuttingIsDetectedAsAnEdit() throws {
        let p = project()
        let snap = p.surfaceCaptureScratch()
        XCTAssertFalse(p.surfaceHasEdits(since: snap), "★ nothing done yet")

        p.commitSurfaceCut(SurfaceCut(point: SIMD3(5, 5, 0), normal: SIMD3(1, 0, 0),
                                      faceID: 0, faceNormal: SIMD3(0, 0, 1)))
        XCTAssertTrue(p.surfaceHasEdits(since: snap),
                      "★ a cut is an edit — this is what enables Save")
    }

    /// ★ LEAVING WITHOUT SAVING PUTS IT ALL BACK.
    func testRestoringUndoesEverySurfaceEdit() {
        let p = project()
        let before = p.faceRegions
        let snap = p.surfaceCaptureScratch()

        p.commitSurfaceCut(SurfaceCut(point: SIMD3(5, 5, 0), normal: SIMD3(1, 0, 0),
                                      faceID: 0, faceNormal: SIMD3(0, 0, 1)))
        p.commitSurfacePattern(face: 1, columns: 2, rows: 1)
        XCTAssertNotEqual(p.faceRegions, before, "★ the model really did change")

        p.surfaceRestore(snap)
        XCTAssertEqual(p.faceRegions, before,
                       "★ 'everything should reset when you leave and come back'")
        XCTAssertFalse(p.surfaceHasEdits(since: snap))
    }

    /// ★ AND GROUP MEMBERSHIP GOES BACK TOO. Restoring the regions while leaving
    /// ownership as the edits left it would reinstate the old regions under new
    /// owners — a state neither before nor after.
    func testRestoringPutsGroupMembershipBack() throws {
        let p = project()
        p.selection.addGroup()
        let gid = try XCTUnwrap(p.selection.activeGroupID)
        p.selection.addFaces([0], to: gid)
        let snap = p.surfaceCaptureScratch()
        XCTAssertTrue(p.selection.groups.first(where: { $0.id == gid })?
                        .regionIDs.isEmpty ?? false)

        p.commitSurfaceCut(SurfaceCut(point: SIMD3(5, 5, 0), normal: SIMD3(1, 0, 0),
                                      faceID: 0, faceNormal: SIMD3(0, 0, 1)))
        XCTAssertFalse(p.selection.groups.first(where: { $0.id == gid })?
                        .regionIDs.isEmpty ?? true,
                       "★ the cut handed its parent region to the group")

        p.surfaceRestore(snap)
        XCTAssertTrue(p.selection.groups.first(where: { $0.id == gid })?
                        .regionIDs.isEmpty ?? false,
                      "★ and the revert took it back out")
    }

    /// A save is just a new baseline — nothing is written, what changes is what
    /// leaving would undo.
    func testSavingMakesTheEditsTheNewBaseline() {
        let p = project()
        var snap = p.surfaceCaptureScratch()
        p.commitSurfaceCut(SurfaceCut(point: SIMD3(5, 5, 0), normal: SIMD3(1, 0, 0),
                                      faceID: 0, faceNormal: SIMD3(0, 0, 1)))
        let saved = p.faceRegions

        snap = p.surfaceCaptureScratch()          // ← what Save does
        XCTAssertFalse(p.surfaceHasEdits(since: snap))
        p.surfaceRestore(snap)
        XCTAssertEqual(p.faceRegions, saved,
                       "★ leaving after a save keeps the work")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ 7 — AN ISOLATED PIECE REACHES THE TOPOLOGY PAGE

@MainActor
final class IsolateReachesTopologyTests: XCTestCase {

    private func mesh() -> ViewerMesh {
        let v: [Float] = [0, 0, 0, 10, 0, 0, 10, 10, 0, 0, 10, 0,
                          10, 0, 0, 20, 0, 0, 20, 10, 0, 10, 10, 0]
        return ViewerMesh(vertices: v,
                          indices: [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7],
                          faceIDs: [0, 0, 1, 1],
                          faceGeometry: (0..<2).map { _ in
                              StepFaceGeometry(kind: .plane,
                                               planeNormal: SIMD3(0, 0, 1)) })
    }

    /// ★ THE DEFECT, STATED AS A PROPERTY. A group holds BOTH a face list and a
    /// region list, and what it CONTAINS is the union of the two with the regions
    /// subtracted from the faces. Drop the region and leave the bare face behind
    /// and the group still contains the surface — "it stayed connected to its
    /// group."
    /// ★ SHOWN THROUGH A CUT, WHICH STILL JOINS ITS GROUP. This used to be shown
    /// through an isolate, and the 2026-08-16 device round changed that rule: an
    /// isolate now stands alone (`IsolateStandsAloneTests`). The PROPERTY is the
    /// same either way and is what matters — a group holds both a face list and a
    /// region list, and dropping one without the other leaves the surface in the
    /// group by the membership nobody touched.
    func testDroppingARegionMustAlsoDropTheBareFace() throws {
        let p = ProjectModel(id: UUID(), name: "Isolate", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = mesh()
        p.selection.addGroup()
        let gid = try XCTUnwrap(p.selection.activeGroupID)
        p.selection.addFaces([0, 1], to: gid)

        // A cut manufactures a region for the face and hands it to the group.
        let kids = p.commitSurfaceCut(SurfaceCut(point: SIMD3(5, 5, 0),
                                                 normal: SIMD3(1, 0, 0),
                                                 faceID: 0,
                                                 faceNormal: SIMD3(0, 0, 1)))
        XCTAssertFalse(kids.isEmpty)
        var g = try XCTUnwrap(p.selection.groups.first { $0.id == gid })
        XCTAssertFalse(g.regionIDs.isEmpty, "★ the cut handed its region over")

        // Now take the regions out — WITHOUT touching the faces, the old behaviour.
        p.selection.removeRegions(g.regionIDs)
        g = try XCTUnwrap(p.selection.groups.first { $0.id == gid })
        XCTAssertTrue(p.latticeRegionCoveredFaces(g).isEmpty)
        XCTAssertFalse(g.faces.isEmpty,
                       "★ …and the bare faces are STILL there, which is exactly why "
                       + "deselecting on the TO page appeared to do nothing")

        // Removing both is what actually deselects it.
        p.selection.removeFaces([0, 1], from: gid)
        let after = p.selection.groups.first { $0.id == gid }
        XCTAssertTrue(after == nil || (after!.faces.isEmpty && after!.regionIDs.isEmpty),
                      "★ region AND face together — then it is out")
    }

    /// An isolate really does take the faces out of every other region, so the
    /// piece is its own thing rather than a second name for the same surface.
    func testIsolatingDetachesFromEveryOtherRegion() throws {
        let m = mesh()
        var regions = FaceRegionModel()
        let both = regions.union(faces: [0, 1], named: "both")
        XCTAssertEqual(Set(FaceRegionGeometry.members(of: regions.region(both)!,
                                                      in: m)), [0, 1])

        let solo = try XCTUnwrap(regions.isolate(faces: [0], named: "just 0", in: m))
        XCTAssertEqual(FaceRegionGeometry.members(of: regions.region(solo)!, in: m),
                       [0])
        XCTAssertEqual(FaceRegionGeometry.members(of: regions.region(both)!, in: m),
                       [1],
                       "★ 'disconnecting from every other face it is currently "
                       + "connected with'")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ 9 — A CUT THAT DETACHES A SCRAP MAKES IT ITS OWN PIECE
//
// Maintainer, 2026-08-16: "If a cut leaves a small piece alone, it should be its
// own part. So if I cut an irregular shape in half, and part of it crosses an arc,
// the end of that arc, even if it's a tiny piece, should be its *own* face."

final class DetachedPieceTests: XCTestCase {

    /// ★ A U-SHAPED FACE, cut across the OPENING. One side of the plane holds the
    /// bottom of the U — one patch. The other holds the TWO ARM TIPS, which do not
    /// touch each other: exactly the shape he describes.
    private func uFace() -> ViewerMesh {
        var v: [Float] = [], idx: [Int32] = [], fids: [Int32] = []
        var line: [SIMD2<Double>] = []
        let steps = 20
        for i in 0...steps { line.append(SIMD2(-10, 30 - Double(i) / Double(steps) * 30)) }
        for i in 1...steps {
            let t = Double(i) / Double(steps) * Double.pi
            line.append(SIMD2(-10 * cos(t), -10 * sin(t)))
        }
        for i in 1...steps { line.append(SIMD2(10, Double(i) / Double(steps) * 30)) }
        for (i, c) in line.enumerated() {
            let prev = line[max(0, i - 1)], next = line[min(line.count - 1, i + 1)]
            var d = next - prev
            if simd_length(d) < 1e-9 { d = SIMD2(0, 1) }
            let n = simd_normalize(SIMD2(-d.y, d.x)) * 2.0
            v += [Float(c.x - n.x), Float(c.y - n.y), 0,
                  Float(c.x + n.x), Float(c.y + n.y), 0]
        }
        for s in 0..<(line.count - 1) {
            let a = Int32(s * 2)
            idx += [a, a + 1, a + 2, a + 1, a + 3, a + 2]
            fids += [0, 0]
        }
        return ViewerMesh(vertices: v, indices: idx, faceIDs: fids,
                          faceGeometry: [StepFaceGeometry(kind: .plane,
                                                          planeNormal: SIMD3(0, 0, 1))])
    }

    func testTheTwoArmTipsAreSeenAsTwoPatches() throws {
        let m = uFace()
        var regions = FaceRegionModel()
        let parent = regions.union(faces: [0], named: "u")
        // Cut horizontally at y = 15: above it are the two arm tips, below is the U.
        let kids = regions.splitManual(parent, point: SIMD3(0, 15, 0),
                                       normal: SIMD3(0, 1, 0))
        XCTAssertEqual(kids.count, 2)

        let upper = try XCTUnwrap(regions.region(kids[0]))
        let lower = try XCTUnwrap(regions.region(kids[1]))
        XCTAssertEqual(SurfaceComponents.components(of: upper, in: m).count, 2,
                       "★ the two arm tips do not touch — two patches")
        XCTAssertEqual(SurfaceComponents.components(of: lower, in: m).count, 1,
                       "★ and the bottom of the U is one")
    }

    /// ★ AND THEY BECOME TWO REGIONS, each holding exactly its own patch.
    func testTheDetachedTipsBecomeTheirOwnPieces() throws {
        let m = uFace()
        var regions = FaceRegionModel()
        let parent = regions.union(faces: [0], named: "u")
        let kids = regions.splitManual(parent, point: SIMD3(0, 15, 0),
                                       normal: SIMD3(0, 1, 0))
        let pieces = regions.splitDetached(kids[0], in: m)
        XCTAssertEqual(pieces.count, 2,
                       "★ 'even if it's a tiny piece, it should be its own face'")

        // Each piece holds one patch, and no triangle is in two of them.
        let parts = SurfaceComponents.components(
            of: try XCTUnwrap(regions.region(kids[0])), in: m)
        for pid in pieces {
            let cuts = try XCTUnwrap(regions.region(pid)).cuts
            let held = parts.filter { part in
                part.allSatisfy {
                    guard let c = SurfaceComponents.centroid($0, in: m) else { return false }
                    return FaceRegionGeometry.inside(c, cuts)
                }
            }
            XCTAssertEqual(held.count, 1, "★ one piece, one patch")
        }
    }

    /// ★ NEGATIVE CONTROL. A cut through the middle of a plain strip leaves each
    /// side connected, and nothing is split — otherwise the check above would be
    /// passing on a rule that splits everything.
    func testAnOrdinaryCutSplitsNothingFurther() throws {
        let m = ArcTestMesh.straightStrip(length: 60)
        var regions = FaceRegionModel()
        let parent = regions.union(faces: [0], named: "strip")
        let kids = regions.splitManual(parent, point: SIMD3(30, 0, 0),
                                       normal: SIMD3(1, 0, 0))
        for k in kids {
            XCTAssertEqual(SurfaceComponents.components(
                of: try XCTUnwrap(regions.region(k)), in: m).count, 1)
            XCTAssertTrue(regions.splitDetached(k, in: m).isEmpty,
                          "★ one patch, nothing to detach")
        }
    }

    /// ★ AND WHERE NO PLANE SEPARATES THE PATCHES, NOTHING IS SPLIT. Verified
    /// rather than assumed: a split that does not separate would give two regions
    /// that claim each other's surface.
    func testEveryOfferedSplitActuallySeparates() throws {
        let m = uFace()
        var regions = FaceRegionModel()
        let parent = regions.union(faces: [0], named: "u")
        let kids = regions.splitManual(parent, point: SIMD3(0, 15, 0),
                                       normal: SIMD3(0, 1, 0))
        let upper = try XCTUnwrap(regions.region(kids[0]))
        let parts = SurfaceComponents.components(of: upper, in: m)
        guard let offered = SurfaceComponents.detachedPieces(of: upper, in: m) else {
            return XCTFail("expected a split")
        }
        XCTAssertEqual(offered.count, parts.count)
        for (i, cuts) in offered.enumerated() {
            for tri in parts[i] {
                let c = try XCTUnwrap(SurfaceComponents.centroid(tri, in: m))
                XCTAssertTrue(FaceRegionGeometry.inside(c, cuts),
                              "★ piece \(i) holds all of its own patch")
            }
            for (k, other) in parts.enumerated() where k != i {
                for tri in other {
                    let c = try XCTUnwrap(SurfaceComponents.centroid(tri, in: m))
                    XCTAssertFalse(FaceRegionGeometry.inside(c, cuts),
                                   "★ and none of patch \(k)")
                }
            }
        }
    }

    /// The pieces reach the lattice as SEPARATE selections — the parent is
    /// superseded by them, so nothing is described twice.
    @MainActor
    func testTheDetachedPiecesAreWhatReachesTheLattice() throws {
        let p = ProjectModel(id: UUID(), name: "Detach", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = uFace()
        p.selection.addGroup()
        let gid = try XCTUnwrap(p.selection.activeGroupID)
        p.selection.addFaces([0], to: gid)

        let leaves = p.commitSurfaceCut(SurfaceCut(point: SIMD3(0, 15, 0),
                                                   normal: SIMD3(0, 1, 0),
                                                   faceID: 0,
                                                   faceNormal: SIMD3(0, 0, 1)))
        XCTAssertEqual(leaves.count, 3,
                       "★ two arm tips plus the bottom of the U — \(leaves.count)")
        let g = try XCTUnwrap(p.selection.groups.first { $0.id == gid })
        let effective = p.surfaceEffectiveRegions(of: g)
        XCTAssertEqual(Set(effective), Set(leaves),
                       "★ the deepest pieces are what the run receives, with no "
                       + "parent describing the same surface again")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ ROUND 7b — the 2026-08-16 device findings
//
//   "The isolated face was not selectable on its own and when I accidentally
//    selected the face next to it, it was part of the group of faces that were
//    highlighted. These must be selectable and cannot be part of a group."
//
//   "Make the Save button much larger and place it where the greyed out 'Lattice'
//    button is (removing the greyed out lattice button)."
//
//   "Looking at the arc again … it is just an arc … The pattern isn't working."

@MainActor
final class IsolateStandsAloneTests: XCTestCase {

    private func project() -> ProjectModel {
        let v: [Float] = [0, 0, 0, 10, 0, 0, 10, 10, 0, 0, 10, 0,
                          10, 0, 0, 20, 0, 0, 20, 10, 0, 10, 10, 0]
        let p = ProjectModel(id: UUID(), name: "Alone", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = ViewerMesh(vertices: v,
                                  indices: [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7],
                                  faceIDs: [0, 0, 1, 1],
                                  faceGeometry: (0..<2).map { _ in
                                      StepFaceGeometry(kind: .plane,
                                                       planeNormal: SIMD3(0, 0, 1)) })
        return p
    }

    /// ★ ISOLATING TAKES THE FACES OUT OF THE GROUP TOO. Disconnecting at the
    /// region layer while leaving them owned at the GROUP layer is what made a
    /// neighbour's tap light the isolated piece: they were still groupmates.
    func testAnIsolatedPieceLeavesItsOldGroupEntirely() throws {
        let p = project()
        p.selection.addGroup()
        let gid = try XCTUnwrap(p.selection.activeGroupID)
        p.selection.addFaces([0, 1], to: gid)

        var f = RegionFilter(); f.kind = "plane"
        f.minAreaMM2 = 1; f.maxAreaMM2 = 500
        let rid = try XCTUnwrap(p.commitSurfaceIsolate(f, named: "isolated"))

        let g = p.selection.groups.first { $0.id == gid }
        XCTAssertFalse(g?.regionIDs.contains(rid) ?? false,
                       "★ the isolate must not join the group it came from")
        XCTAssertTrue((g?.faces.isEmpty ?? true),
                      "★ and the bare faces go with it — otherwise the group still "
                      + "contains the surface by its other membership")
    }

    /// …and it is then free to be given to a group by a tap on the Topology page.
    func testAnIsolatedPieceCanBeGivenToAGroup() throws {
        let p = project()
        var f = RegionFilter(); f.kind = "plane"
        f.minAreaMM2 = 1; f.maxAreaMM2 = 500
        let rid = try XCTUnwrap(p.commitSurfaceIsolate(f, named: "isolated"))
        XCTAssertNil(p.selection.groups.first { $0.regionIDs.contains(rid) },
                     "★ owned by nobody to begin with")

        p.selection.addGroup()
        let gid = try XCTUnwrap(p.selection.activeGroupID)
        p.selection.addRegions([rid], to: gid)
        let g = try XCTUnwrap(p.selection.groups.first { $0.id == gid })
        XCTAssertEqual(p.latticeRegionCoveredFaces(g), [0, 1],
                       "★ and once given, the group really does contain it")
    }
}

final class SurfaceStageHasNoOnwardNavTests: XCTestCase {

    /// The greyed-out "Lattice" button is gone from the Surface stage — Save has
    /// that slot. Nothing becomes unreachable: Topology is still top-left.
    func testSurfaceOffersNoForwardStage() {
        XCTAssertTrue(WorkspaceStage.surface.forward.isEmpty,
                      "★ the slot belongs to Save")
        XCTAssertTrue(WorkspaceStage.topology.forward.contains(.surface))
        XCTAssertTrue(WorkspaceStage.lattice.forward.contains(.surface))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ A LOOP STOPS AT AN ISOLATED PIECE
//
// Maintainer, 2026-08-16, with the pattern finally working: "I select-similar'd
// the same curved face, saved, and went back to the TO page. I couldn't select the
// face. I selected the face next to it, and it was automatically selected with it
// … it should be its own isolated face."
//
// ★ ISOLATING HAD WORKED AND WAS OVERRULED A LAYER DOWN. `FaceTopology.loop` walks
// the run of connected CURVED faces — the "tap a bore, get the whole tube" rule —
// and it is pure geometry with no knowledge of regions. His band is curved and
// touches curved neighbours, so tapping any of them swept it in regardless.

@MainActor
final class LoopStopsAtIsolatedPieceTests: XCTestCase {

    /// Three curved faces in a row, sharing vertices where they meet — so
    /// `FaceTopology.adjacency` (which keys on the WELDED vertex index) sees them
    /// as neighbours and `loop` walks all three.
    private func curvedRun() -> ViewerMesh {
        var v: [Float] = [], idx: [Int32] = [], fids: [Int32] = []
        // ONE ring of stations, so consecutive quads share their vertex indices.
        let quadsPerFace = 6, faces = 3
        for k in 0...(quadsPerFace * faces) {
            let a = Double(k) * 5 * .pi / 180
            v += [Float(50 * cos(a)), Float(50 * sin(a)), 0]
            v += [Float(50 * cos(a)), Float(50 * sin(a)), 10]
        }
        for k in 0..<(quadsPerFace * faces) {
            let a = Int32(k * 2)
            idx += [a, a + 1, a + 2, a + 1, a + 3, a + 2]
            let f = Int32(k / quadsPerFace)
            fids += [f, f]
        }
        return ViewerMesh(vertices: v, indices: idx, faceIDs: fids,
                          faceGeometry: (0..<faces).map { _ in
                              StepFaceGeometry(kind: .cylinder,
                                               planeNormal: SIMD3(0, 0, 1)) })
    }

    private func project() -> ProjectModel {
        let p = ProjectModel(id: UUID(), name: "Loop", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = curvedRun()
        return p
    }

    /// ★ THE MECHANISM, FIRST. Without a region, the loop really does take all
    /// three — otherwise the test below proves nothing.
    func testTheLoopTakesTheWholeCurvedRunToBeginWith() throws {
        let p = project()
        let mesh = try XCTUnwrap(p.viewerMesh)
        let raw = FaceTopology.loop(fromFace: 0, in: mesh)
        XCTAssertEqual(Set(raw), [0, 1, 2],
                       "★ connected curved faces walk together — this is the rule "
                       + "the region layer has to be able to veto")
        XCTAssertEqual(p.surfaceLoopRespectingRegions(raw, from: 0), raw,
                       "★ and with no regions at all, nothing is vetoed")
    }

    /// ★ ONCE A FACE IS ISOLATED, ITS NEIGHBOUR'S LOOP LEAVES IT ALONE.
    func testAnIsolatedFaceIsNotSweptUpByItsNeighbour() throws {
        let p = project()
        let mesh = try XCTUnwrap(p.viewerMesh)
        var f = RegionFilter(); f.kind = "cylinder"
        f.cylinderRadiusMM = 0                       // match by kind + size band
        f.minAreaMM2 = 1; f.maxAreaMM2 = 1e9
        // Isolate face 2 explicitly through the model, as ✂ does.
        _ = p.faceRegions.isolate(faces: [2], named: "just 2", in: mesh)

        let raw = FaceTopology.loop(fromFace: 0, in: mesh)
        XCTAssertTrue(raw.contains(2), "★ geometry still proposes it")
        let kept = p.surfaceLoopRespectingRegions(raw, from: 0)
        XCTAssertFalse(kept.contains(2),
                       "★ …and the region layer vetoes it — \(kept)")
        XCTAssertTrue(kept.contains(0), "★ the tapped face survives its own veto")
    }

    /// ★ AND AN ISOLATE OF SEVERAL FACES STILL SELECTS TOGETHER. They share a
    /// region, so the rule keeps them — a veto that split its own isolate would be
    /// the opposite mistake.
    func testAMultiFaceIsolateStillSelectsAsOne() throws {
        let p = project()
        let mesh = try XCTUnwrap(p.viewerMesh)
        _ = p.faceRegions.isolate(faces: [1, 2], named: "1 and 2", in: mesh)
        let kept = p.surfaceLoopRespectingRegions(
            FaceTopology.loop(fromFace: 1, in: mesh), from: 1)
        XCTAssertTrue(kept.contains(1) && kept.contains(2),
                      "★ the isolate's own faces stay together — \(kept)")
        XCTAssertFalse(kept.contains(0),
                       "★ but the face outside it does not come along")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ AN UNOWNED PIECE IS SELECTABLE — the nil == nil trap
//
// Maintainer, 2026-08-16: "the face is still not selectable on its own in the TO
// page. It is impossible to highlight it as part of any group selection."

final class TopologyPieceTapTests: XCTestCase {

    /// ★ THE ONE THAT WAS WRONG. An isolated piece is owned by NOBODY, and on a
    /// fresh page NOTHING is active — so the old `owner?.id == activeGroupID` test
    /// compared nil to nil, said "already in the active group", removed it and
    /// stopped. The piece could never be picked up at all.
    func testAnUnownedPieceWithNothingActiveIsTakenNotDropped() {
        XCTAssertEqual(TopologyPieceTap.route(owner: nil, active: nil),
                       .moveToActive,
                       "★ nil owner is not 'owned by the active group'")
    }

    func testAnUnownedPieceJoinsTheActiveGroup() {
        XCTAssertEqual(TopologyPieceTap.route(owner: nil, active: UUID()),
                       .moveToActive)
    }

    /// The behaviour that was correct and must stay: tapping a piece already in the
    /// group being built takes it back out.
    func testAPieceInTheActiveGroupIsDropped() {
        let g = UUID()
        XCTAssertEqual(TopologyPieceTap.route(owner: g, active: g), .removeOnly)
    }

    /// And a piece belonging to a DIFFERENT group moves across.
    func testAPieceInAnotherGroupMoves() {
        XCTAssertEqual(TopologyPieceTap.route(owner: UUID(), active: UUID()),
                       .moveToActive)
    }

    /// A piece someone else owns while nothing is active still moves — it must not
    /// fall into the removal branch just because `active` is nil.
    func testAnOwnedPieceWithNothingActiveMoves() {
        XCTAssertEqual(TopologyPieceTap.route(owner: UUID(), active: nil),
                       .moveToActive)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ THE TOP-RIGHT CHROME LINES UP WITH THE GIZMO'S *VISIBLE* TOP

final class GizmoAlignmentTests: XCTestCase {

    /// ★ THE FRAME IS NOT THE GLASS. The housing is `housingFraction` of the frame
    /// and centred, so a control padded by `gizmoInset` alone sits above the gizmo's
    /// visible edge by half the leftover — about 10.5 pt at the standard size, which
    /// is what "the Save button is too high" was.
    func testTheAlignedTopClearsTheGizmosTransparentMargin() {
        let margin = PageChrome.gizmoSize * (1 - GizmoLayout.housingFraction) / 2
        XCTAssertEqual(PageChrome.gizmoVisualInset, margin, accuracy: 1e-9)
        XCTAssertEqual(PageChrome.gizmoAlignedTop,
                       PageChrome.gizmoInset + margin, accuracy: 1e-9)
        XCTAssertGreaterThan(PageChrome.gizmoAlignedTop, PageChrome.gizmoInset,
                             "★ it really is lower than the frame's own inset")
    }

    /// ★ AND IT IS DERIVED, NOT A CONSTANT. Change the housing fraction and the
    /// alignment follows — a hard-coded 10.5 would silently stop matching.
    func testItTracksTheHousingFraction() {
        XCTAssertEqual(PageChrome.gizmoVisualInset
                       + PageChrome.gizmoSize * GizmoLayout.housingFraction
                       + PageChrome.gizmoVisualInset,
                       PageChrome.gizmoSize, accuracy: 1e-9,
                       "★ margin + housing + margin is the whole frame")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ A GROUP HELD BY REGION IS STILL A GROUP
//
// Maintainer, 2026-08-16: "It's showing as something was selected — but it won't
// show the highlight … the 'load/anchor…' is not close to the actual face."
//
// He tapped the isolated band, it joined Group A, the panel said so — and the model
// stayed grey while the role chips sat at the bottom of the screen. Both are the
// same cause as every "it stayed connected to its group" before them, from the
// other side: a group has TWO memberships and three more places read only one.

@MainActor
final class RegionHeldGroupTests: XCTestCase {

    private func project() -> ProjectModel {
        let v: [Float] = [0, 0, 0, 10, 0, 0, 10, 10, 0, 0, 10, 0,
                          10, 0, 0, 20, 0, 0, 20, 10, 0, 10, 10, 0]
        let p = ProjectModel(id: UUID(), name: "Held", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = ViewerMesh(vertices: v,
                                  indices: [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7],
                                  faceIDs: [0, 0, 1, 1],
                                  faceGeometry: (0..<2).map { _ in
                                      StepFaceGeometry(kind: .plane,
                                                       planeNormal: SIMD3(0, 0, 1)) })
        return p
    }

    /// ★ THE GROUP RESOLVES TO ITS FACES THROUGH THE REGION — which is what the
    /// tint, the centroid and the load arrow all need and none of them asked for.
    func testAGroupHoldingOnlyARegionStillNamesItsFaces() throws {
        let p = project()
        var f = RegionFilter(); f.kind = "plane"
        f.minAreaMM2 = 1; f.maxAreaMM2 = 500
        let rid = try XCTUnwrap(p.commitSurfaceIsolate(f, named: "isolated"))
        p.selection.addGroup()
        let gid = try XCTUnwrap(p.selection.activeGroupID)
        p.selection.addRegions([rid], to: gid)

        let g = try XCTUnwrap(p.selection.groups.first { $0.id == gid })
        XCTAssertTrue(g.faces.isEmpty, "★ it holds NO bare faces — that is the case")
        XCTAssertEqual(p.latticeRegionCoveredFaces(g), [0, 1],
                       "★ …and still contains both faces, through its region")
    }

    /// ★ AND IT IS NOT SWEPT AWAY AS EMPTY. Three cleanups tested `faces.isEmpty`
    /// alone, so a region-held group was deleted the moment anything triggered a
    /// sweep — the selection appeared and then vanished.
    func testARegionHeldGroupSurvivesTheEmptyGroupSweeps() throws {
        let p = project()
        var f = RegionFilter(); f.kind = "plane"
        f.minAreaMM2 = 1; f.maxAreaMM2 = 500
        let rid = try XCTUnwrap(p.commitSurfaceIsolate(f, named: "isolated"))
        p.selection.addGroup()
        let gid = try XCTUnwrap(p.selection.activeGroupID)
        p.selection.addRegions([rid], to: gid)

        p.selection.clearActive()
        XCTAssertNotNil(p.selection.groups.first { $0.id == gid },
                        "★ clearActive must not delete it")

        p.selection.addGroup()
        p.selection.pickFaces([0])
        XCTAssertNotNil(p.selection.groups.first { $0.id == gid },
                        "★ nor a later pick's sweep")
    }

    /// A group with neither faces nor regions IS empty and must still be dropped —
    /// otherwise the fix above just leaks empty rows.
    func testATrulyEmptyGroupIsStillDropped() {
        var s = SelectionModel()
        s.addGroup()
        let gid = s.activeGroupID
        XCTAssertNotNil(gid)
        s.clearActive()
        XCTAssertTrue(s.groups.isEmpty,
                      "★ nothing in either membership is still nothing")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ SELECT-SIMILAR: A MULTI-SELECT OF KINDS, AND WHAT ✂ MAKES OF IT
//
// Maintainer, 2026-08-16:
//   "Select-similar should *also* have multi-select … (and another tap de-selects it)"
//   "if they are *not* directly attached to one another, they should separate into
//    isolated pieces … However, if multi-select connects the pieces, then they are
//    all made into a single face group."
//   "What exactly does the checkbox of the 'select-similar' do? … please remove"

final class SurfaceSimilarMultiSelectTests: XCTestCase {

    private func filter(_ kind: String) -> RegionFilter {
        var f = RegionFilter(); f.kind = kind; return f
    }

    func testTappingASecondKindAddsIt() {
        var s = SurfaceSimilar()
        s.toggle(seed: 1, filter: filter("plane")) { _ in [] }
        s.toggle(seed: 9, filter: filter("cylinder")) { _ in [] }
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s.seeds, [1, 9])
    }

    /// ★ A SECOND TAP ON A COVERED FACE DROPS ITS KIND — and it need not be the
    /// same face that added it. Keying on the seed alone would leave every other
    /// face of a kind unable to switch that kind off.
    func testTappingAnyFaceOfASelectedKindDropsThatKind() {
        var s = SurfaceSimilar()
        s.toggle(seed: 1, filter: filter("plane")) { _ in [] }
        XCTAssertEqual(s.count, 1)
        // Face 4 is covered by the pick already held.
        s.toggle(seed: 4, filter: filter("plane")) { p in
            p.seed == 1 ? [1, 4, 7] : []
        }
        XCTAssertTrue(s.isEmpty, "★ a tap on a selected face removes its kind")
    }

    func testClearEmptiesEverything() {
        var s = SurfaceSimilar()
        s.toggle(seed: 1, filter: filter("plane")) { _ in [] }
        s.clear()
        XCTAssertTrue(s.isEmpty)
    }
}

@MainActor
final class IsolateSplitsByConnectivityTests: XCTestCase {

    /// Four coplanar quads in a row: 0–1 touch, 2 stands apart, 3 touches 2.
    /// So {0,1} is one connected group and {2,3} another.
    private func strip() -> ViewerMesh {
        var v: [Float] = [], idx: [Int32] = [], fids: [Int32] = []
        func quad(_ x0: Float, _ x1: Float, _ f: Int32) {
            let b = Int32(v.count / 3)
            v += [x0, 0, 0, x1, 0, 0, x1, 10, 0, x0, 10, 0]
            idx += [b, b + 1, b + 2, b, b + 2, b + 3]
            fids += [f, f]
        }
        quad(0, 10, 0)      // touches face 1 at x = 10
        quad(10, 20, 1)
        quad(50, 60, 2)     // far away
        quad(60, 70, 3)     // touches face 2 at x = 60
        return ViewerMesh(vertices: v, indices: idx, faceIDs: fids,
                          faceGeometry: (0..<4).map { _ in
                              StepFaceGeometry(kind: .plane,
                                               planeNormal: SIMD3(0, 0, 1)) })
    }

    private func project() -> ProjectModel {
        let p = ProjectModel(id: UUID(), name: "Split", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = strip()
        return p
    }

    /// ★ FACES THAT DO NOT TOUCH BECOME SEPARATE PIECES.
    func testDisconnectedMatchesBecomeSeparatePieces() throws {
        let p = project()
        let made = p.commitSurfaceIsolate(faces: [0, 2], named: "alike")
        XCTAssertEqual(made.count, 2,
                       "★ face 0 and face 2 do not touch — two pieces")
        XCTAssertEqual(Set(made.map { Set(p.surfaceResolvedFaces($0)) }),
                       [[0], [2]])
    }

    /// ★ AND FACES THAT DO TOUCH STAY ONE. "If multi-select connects the pieces,
    /// then they are all made into a single face group."
    func testConnectedMatchesStayOnePiece() throws {
        let p = project()
        let made = p.commitSurfaceIsolate(faces: [0, 1], named: "alike")
        XCTAssertEqual(made.count, 1, "★ 0 and 1 share an edge — one piece")
        XCTAssertEqual(Set(p.surfaceResolvedFaces(try XCTUnwrap(made.first))),
                       [0, 1])
    }

    /// The mixed case: two clusters, one of them two faces wide.
    func testTwoClustersComeOutAsTwo() throws {
        let p = project()
        let made = p.commitSurfaceIsolate(faces: [0, 1, 2, 3], named: "alike")
        XCTAssertEqual(made.count, 2)
        XCTAssertEqual(Set(made.map { Set(p.surfaceResolvedFaces($0)) }),
                       [[0, 1], [2, 3]])
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ A PIECE CAN LEAVE A GROUP THAT HOLDS ITS PARENT
//
// Maintainer, 2026-08-16: "I attempted to cut out one of the faces of the 3
// isolated/grouped faces above and it didn't disconnect it. Instead, it made it not
// be able to be de-selectable/re-selectable."

@MainActor
final class DetachPieceFromGroupTests: XCTestCase {

    private func project() -> ProjectModel {
        let v: [Float] = [0, 0, 0, 10, 0, 0, 10, 10, 0, 0, 10, 0,
                          10, 0, 0, 20, 0, 0, 20, 10, 0, 10, 10, 0]
        let p = ProjectModel(id: UUID(), name: "Detach", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = ViewerMesh(vertices: v,
                                  indices: [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7],
                                  faceIDs: [0, 0, 1, 1],
                                  faceGeometry: (0..<2).map { _ in
                                      StepFaceGeometry(kind: .plane,
                                                       planeNormal: SIMD3(0, 0, 1)) })
        return p
    }

    /// ★ THE FREEZE, AND WHY. A group holding a cut's PARENT contains every child
    /// implicitly (`surfaceEffectiveRegions` expands it), so removing one child
    /// changed nothing — the parent went on speaking for it. The face stayed lit
    /// whatever was tapped, and adding it back did nothing either.
    func testRemovingAChildWhoseParentIsHeldUsedToChangeNothing() throws {
        let p = project()
        p.selection.addGroup()
        let gid = try XCTUnwrap(p.selection.activeGroupID)
        p.selection.addFaces([0], to: gid)
        let kids = p.commitSurfaceCut(SurfaceCut(point: SIMD3(5, 5, 0),
                                                 normal: SIMD3(1, 0, 0),
                                                 faceID: 0,
                                                 faceNormal: SIMD3(0, 0, 1)))
        let piece = try XCTUnwrap(kids.first)
        var g = try XCTUnwrap(p.selection.groups.first { $0.id == gid })
        XCTAssertTrue(p.surfaceEffectiveRegions(of: g).contains(piece),
                      "★ the group contains the piece — through its parent")

        // The naive removal: the piece is not itself in `regionIDs`, so this is a
        // no-op and the group STILL contains it. This is the frozen state.
        p.selection.removeRegions([piece])
        g = try XCTUnwrap(p.selection.groups.first { $0.id == gid })
        XCTAssertTrue(p.surfaceEffectiveRegions(of: g).contains(piece),
                      "★ …and it is still there, which is the bug")
    }

    /// ★ THE FIX: the ancestor is replaced by the pieces it stands for, and then
    /// the one piece can leave.
    func testDetachingReplacesTheAncestorWithItsOtherPieces() throws {
        let p = project()
        p.selection.addGroup()
        let gid = try XCTUnwrap(p.selection.activeGroupID)
        p.selection.addFaces([0], to: gid)
        let kids = p.commitSurfaceCut(SurfaceCut(point: SIMD3(5, 5, 0),
                                                 normal: SIMD3(1, 0, 0),
                                                 faceID: 0,
                                                 faceNormal: SIMD3(0, 0, 1)))
        XCTAssertEqual(kids.count, 2)
        let piece = try XCTUnwrap(kids.first)

        p.surfaceDetachPiece(piece, from: gid)
        let g = try XCTUnwrap(p.selection.groups.first { $0.id == gid })
        let effective = p.surfaceEffectiveRegions(of: g)
        XCTAssertFalse(effective.contains(piece),
                       "★ the piece is out — \(effective)")
        XCTAssertTrue(effective.contains(kids[1]),
                      "★ and its SIBLING is still in, which is the point of "
                      + "expanding rather than dropping the parent wholesale")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ ONE RIGHT-HAND LINE
//
// Maintainer, 2026-08-16: "the view buttons are too close to the edge. Please put
// them in-line with the gizmo and all the chips at the bottom-right corner. The
// padding to the right needs to be *exactly* the same … I am very particular about
// keeping things lined up perfectly."
//
// There were THREE right-hand edges on one screen: the view toggles on 8 (the
// gizmo's FRAME inset), the gizmo's visible glass on 18.5, and the bottom-right chip
// stack on `edge` (24). Each was individually defensible and together they were
// three lines.

final class RightEdgeAlignmentTests: XCTestCase {

    /// ★ THE INVARIANT: the gizmo's VISIBLE edge is `PageChrome.edge`, the same
    /// number every other right-side control pads by. Derived, so changing `edge`
    /// moves all of them together and changing the gizmo's housing fraction is
    /// absorbed rather than leaving it 10 pt proud.
    func testTheGizmosGlassSitsExactlyOnTheSharedEdge() {
        XCTAssertEqual(PageChrome.gizmoInset + PageChrome.gizmoVisualInset,
                       PageChrome.edge, accuracy: 1e-9,
                       "★ the gizmo's glass and the chips share one line")
    }

    /// …and the top is the same number, so the gizmo's glass is inset equally from
    /// the top and the side rather than by two different constants.
    func testTheTopAlignmentIsTheSameNumberAsTheSide() {
        XCTAssertEqual(PageChrome.gizmoAlignedTop, PageChrome.edge, accuracy: 1e-9)
    }

    /// ★ THE FRAME INSET IS SMALLER THAN THE EDGE, and that is the whole point —
    /// the transparent margin is what the two differ by.
    func testTheFrameIsInsetLessThanTheGlass() {
        XCTAssertLessThan(PageChrome.gizmoInset, PageChrome.edge)
        XCTAssertEqual(PageChrome.edge - PageChrome.gizmoInset,
                       PageChrome.gizmoVisualInset, accuracy: 1e-9)
    }

    /// ★ A CONTROL UNDER THE GIZMO CLEARS ITS TOUCH TARGET, not just its picture.
    /// The frame takes the orbit gesture over its whole square, so a control that
    /// merely cleared the glass would have its top strip swallowed.
    func testBelowGizmoClearsTheFrameNotJustTheGlass() {
        let frameBottom = PageChrome.gizmoInset + PageChrome.gizmoSize
        XCTAssertGreaterThanOrEqual(PageChrome.belowGizmo, frameBottom,
                                    "★ it must clear the gesture target")
        // …and it still reads as about one edge-width below the glass.
        let glassBottom = PageChrome.gizmoAlignedTop + PageChrome.gizmoSize
            - PageChrome.gizmoVisualInset * 2
        XCTAssertEqual(PageChrome.belowGizmo - glassBottom, PageChrome.edge,
                       accuracy: 4,
                       "★ and reads as an even margin below it")
    }

    /// ★ AND THE CLEARANCE STILL DESCRIBES THE GIZMO. `gizmoClearance` is what
    /// chrome to the LEFT of the gizmo pads by; it has to keep clearing the frame
    /// now that the frame moved.
    func testTheLeftwardClearanceStillClearsTheFrame() {
        XCTAssertGreaterThanOrEqual(PageChrome.gizmoClearance,
                                    PageChrome.gizmoInset + PageChrome.gizmoSize,
                                    "★ chrome left of the gizmo cannot overlap it")
    }
}
