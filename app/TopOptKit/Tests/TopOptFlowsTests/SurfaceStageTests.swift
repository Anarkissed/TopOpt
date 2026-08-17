// SurfaceStageTests.swift — the SURFACE stage (task 2026-08-15-lattice-and-face-ui
// §6), built after the maintainer asked for it directly.
//
//   §6(a)  no primitives visible in this mode
//   §6(b)  the model's WIREFRAME — B-rep edges, not every triangle edge
//   §6(g)  the hovered cut line, from the point the picker used to discard
//   §6(h)  rotate with 15° detents
//   §6(i)  the cut is a HALF-SPACE, not a line drawn on the face
//   §6(j)  persisted as a point and a normal in model space

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

final class SurfaceStageTests: XCTestCase {

    // ─────────────────────────────────────────────────────────────────────
    // MARK: fixture — a box whose top face is tessellated into FOUR triangles
    //
    // The point of the fixture: face 1's own tessellation has an interior edge
    // (the diagonal, and the cross through the middle). A "wireframe" that draws
    // every triangle edge shows those; a B-REP wireframe does not.

    /// A unit square in z = 1 split into 4 triangles about a centre vertex
    /// (face 1), sitting on a square in z = 0 (face 0). The two faces share no
    /// vertices, as a STEP tessellation writes them.
    private func twoFaceMesh() -> ViewerMesh {
        var v: [Float] = []
        func V(_ x: Float, _ y: Float, _ z: Float) { v += [x, y, z] }
        // face 0 — the base, two triangles (verts 0..3)
        V(0, 0, 0); V(10, 0, 0); V(10, 10, 0); V(0, 10, 0)
        // face 1 — the top, FOUR triangles about a centre (verts 4..8)
        V(0, 0, 10); V(10, 0, 10); V(10, 10, 10); V(0, 10, 10); V(5, 5, 10)
        var idx: [Int32] = []
        var f: [Int32] = []
        func T(_ a: Int32, _ b: Int32, _ c: Int32, _ face: Int32) {
            idx += [a, b, c]; f.append(face)
        }
        T(0, 1, 2, 0); T(0, 2, 3, 0)
        T(4, 5, 8, 1); T(5, 6, 8, 1); T(6, 7, 8, 1); T(7, 4, 8, 1)
        return ViewerMesh(vertices: v, indices: idx, faceIDs: f,
                          faceGeometry: [
                            StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, -1)),
                            StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1)),
                          ])
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: §6(b) — the wireframe is B-REP edges, not every triangle edge

    /// ★ THE WHOLE POINT. Face 1's four triangles meet at a centre vertex; those
    /// four interior spokes, and the base's diagonal, are TESSELLATION, not
    /// geometry. Drawing them turns a bore into a fan and a fillet into noise,
    /// which is the opposite of "so faces are easy to see".
    func testTheWireframeDrawsBRepEdgesAndNotTessellation() {
        let mesh = twoFaceMesh()
        let segs = SurfaceWireframe.segmentCount(of: mesh)

        // Each face is a closed square with 4 boundary edges → 8 segments.
        // The interior spokes (4 on the top, 1 diagonal on the base) must be gone.
        XCTAssertEqual(segs, 8,
                       "§6(b): only the two squares' RIMS are B-rep/boundary edges "
                       + "— the 4 centre spokes and the base diagonal are the "
                       + "face's own tessellation and must not be drawn")

        // And the naive reading really would have drawn more, so this is not a
        // test of an empty set agreeing with itself.
        var everyEdge = Set<[Int32]>()
        var i = 0
        while i + 2 < mesh.indices.count {
            let t = [mesh.indices[i], mesh.indices[i + 1], mesh.indices[i + 2]]
            for e in 0..<3 {
                everyEdge.insert([Int32(min(t[e], t[(e + 1) % 3])),
                                  Int32(max(t[e], t[(e + 1) % 3]))])
            }
            i += 3
        }
        XCTAssertGreaterThan(everyEdge.count, segs,
                             "the naive every-triangle-edge set is strictly larger")
    }

    /// A mesh with NO face partition draws NOTHING rather than everything — a
    /// wireframe of every triangle is worse than no wireframe.
    func testAMeshWithNoFacePartitionDrawsNoWireframe() {
        let v: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0]
        let m = ViewerMesh(vertices: v, indices: [0, 1, 2], faceIDs: [])
        XCTAssertEqual(SurfaceWireframe.edges(of: m).count, 0)
    }

    /// The buffer is a flat line list: 3 floats per vertex, 2 vertices per segment.
    func testTheWireframeBufferIsAWellFormedLineList() {
        let e = SurfaceWireframe.edges(of: twoFaceMesh())
        XCTAssertEqual(e.count % 6, 0, "6 floats per segment")
        XCTAssertEqual(e.count / 6, SurfaceWireframe.segmentCount(of: twoFaceMesh()))
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: §6(g) — the hovered point, from the ray the picker already casts

    /// ★ THE POINT THE PICKER DISCARDED. `pickTriangle` computed the ray parameter
    /// to find the nearest triangle and returned only the index.
    func testTheHitCarriesThePointAndTheFace() throws {
        let mesh = twoFaceMesh()
        // Straight down the −z axis through (5, 5): must land on the TOP face.
        let hit = try XCTUnwrap(FacePicker.hit(rayOrigin: SIMD3(5, 5, 50),
                                               rayDir: SIMD3(0, 0, -1), mesh: mesh))
        XCTAssertEqual(hit.faceID, 1, "the top face is nearer than the base")
        XCTAssertEqual(hit.point.z, 10, accuracy: 1e-4, "on the top surface")
        XCTAssertEqual(hit.point.x, 5, accuracy: 1e-4)
        XCTAssertEqual(hit.point.y, 5, accuracy: 1e-4)
        XCTAssertEqual(abs(hit.normal.z), 1, accuracy: 1e-5, "the face's own normal")
    }

    /// A ray that misses returns nil rather than a nearest-anything.
    func testARayThatMissesReturnsNil() {
        XCTAssertNil(FacePicker.hit(rayOrigin: SIMD3(100, 100, 50),
                                    rayDir: SIMD3(0, 0, -1), mesh: twoFaceMesh()))
    }

    /// ★ THE HOVER PREVIEW LINE lies IN the face and IN the cut plane — it is the
    /// trace of one on the other, which is what makes it read as a line on the
    /// surface rather than a floating stick.
    func testThePreviewLineLiesInTheFaceAndInTheCutPlane() throws {
        let cut = try XCTUnwrap(SurfaceCut.at(rayOrigin: SIMD3(5, 5, 50),
                                              rayDir: SIMD3(0, 0, -1),
                                              mesh: twoFaceMesh()))
        let seg = cut.previewSegment(halfLengthMM: 4)
        let dir = simd_normalize(seg.b - seg.a)
        XCTAssertEqual(simd_dot(dir, cut.faceNormal), 0, accuracy: 1e-9,
                       "§6(g): the line lies IN the face")
        XCTAssertEqual(simd_dot(dir, cut.normal), 0, accuracy: 1e-9,
                       "…and IN the cut plane")
        XCTAssertEqual(simd_distance(seg.a, seg.b), 8, accuracy: 1e-9,
                       "half-length either side of the hovered point")
        // and it passes through the hovered point
        XCTAssertEqual(simd_distance((seg.a + seg.b) / 2, cut.point), 0, accuracy: 1e-9)
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: §6(h) — rotate, with 15° detents

    func testTheDetentIsEveryFifteenDegrees() {
        XCTAssertEqual(SurfaceCut.detentDegrees, 15)
        XCTAssertEqual(SurfaceCut.snap(7.0), 0, accuracy: 1e-12)
        XCTAssertEqual(SurfaceCut.snap(8.0), 15, accuracy: 1e-12)
        XCTAssertEqual(SurfaceCut.snap(37.0), 30, accuracy: 1e-12)
        XCTAssertEqual(SurfaceCut.snap(-8.0), -15, accuracy: 1e-12)
    }

    /// ★ ROTATING KEEPS THE PLANE STANDING UP OUT OF THE FACE. If it did not, the
    /// preview line would leave the surface as you turned it.
    func testRotatingKeepsTheCutPlanePerpendicularToTheFace() throws {
        let cut = try XCTUnwrap(SurfaceCut.at(rayOrigin: SIMD3(5, 5, 50),
                                              rayDir: SIMD3(0, 0, -1),
                                              mesh: twoFaceMesh()))
        for deg in stride(from: 0.0, through: 345.0, by: 15.0) {
            let r = cut.rotated(by: deg)
            XCTAssertEqual(simd_dot(r.normal, r.faceNormal), 0, accuracy: 1e-9,
                           "at \(deg)° the cut plane still stands up out of the face")
            XCTAssertEqual(simd_length(r.normal), 1, accuracy: 1e-9)
            XCTAssertEqual(r.point, cut.point, "rotation turns, it does not move")
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: §6(i)/(j) — a half-space, persisted as geometry

    /// ★ THE CUT REACHES PR 331's OWN SPLIT, as a point and a normal — never as
    /// "region 24, half A", which a re-import renumbers out from under you.
    func testTheCutCommitsAsAPointAndANormal() throws {
        var regions = FaceRegionModel()
        let parent = regions.union(faces: [1], named: "top")
        let cut = try XCTUnwrap(SurfaceCut.at(rayOrigin: SIMD3(5, 5, 50),
                                              rayDir: SIMD3(0, 0, -1),
                                              mesh: twoFaceMesh()))
        let kids = regions.splitManual(parent, point: cut.point, normal: cut.normal)
        XCTAssertEqual(kids.count, 2, "§6(i): a half-space test makes TWO sides")

        let child = try XCTUnwrap(regions.region(kids[0]))
        let stored = try XCTUnwrap(child.cuts.last)
        XCTAssertEqual(stored.point, cut.point, "§6(j): the POINT is persisted")
        XCTAssertEqual(stored.normal, cut.normal, "§6(j): and the NORMAL")
        XCTAssertEqual(child.parentID, parent)
        // The two children take opposite senses, so a voxel lands in exactly one.
        let other = try XCTUnwrap(regions.region(kids[1]))
        XCTAssertEqual(other.cuts.last?.normal, -cut.normal)
        XCTAssertNotEqual(child.cuts.last?.strict, other.cuts.last?.strict,
                          "one side takes its boundary non-strictly, the other strictly "
                          + "— so a point exactly on the plane is in ONE child")
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: §6(a) + the stage table

    /// ★ "NO PRIMITIVES ARE VISIBLE IN THIS MODE. None. Not dimmed — hidden."
    func testTheSurfaceStageHidesEveryPrimitiveAndShowsTheWireframe() {
        let v = WorkspaceStageVisibility.of(.surface)
        XCTAssertFalse(v.designBox)
        XCTAssertFalse(v.groupPrimitives)
        XCTAssertFalse(v.keepOuts)
        XCTAssertFalse(v.latticeDepthPlanes)
        XCTAssertFalse(v.latticeControls)
        XCTAssertTrue(v.wireframe, "§6(b): the wireframe is the point of this stage")
        XCTAssertTrue(v.surfaceEditing)
        XCTAssertEqual(v.rowSections, [.clearanceEditor],
                       "and no lattice section survives in the Selections list")
    }

    /// ★ SUPERSEDED 2026-08-16 — THE TOPOLOGY PAGE GETS IT TOO.
    ///
    /// This asserted that the wireframe was the Surface stage's alone. The
    /// maintainer then asked for the opposite: "We should keep wireframe and xray
    /// view throughout the entire app. Please add to the TO page side-by-side just
    /// below the position gizmo." Kept, inverted, rather than deleted — the column
    /// is a PERMISSION now (which stages offer the control), and it still has to be
    /// false somewhere or it would not be a table.
    ///
    /// The lattice stage stays false on its own merits: it shows a lattice preview,
    /// not the imported B-rep, so the edge set would describe a surface that stage
    /// is not drawing. See `ViewModeStageTests`.
    /// ★ SUPERSEDED TWICE, AND BOTH TIMES BY THE MAINTAINER WIDENING IT. First
    /// "only the Surface stage", then "the TO page too", now all three. The column
    /// is a PERMISSION — which stages offer the control — and it is now true
    /// everywhere, so what is left to assert is that the DEFAULT is off: a view aid
    /// is something you reach for, not the resting state of a page.
    func testEveryStageOffersTheWireframeAndItIsOffByDefault() {
        for stage in WorkspaceStage.allCases {
            XCTAssertTrue(WorkspaceStageVisibility.of(stage).wireframe,
                          "\(stage.title)")
        }
    }

    /// ★ "WHERE YOU GO" ABOVE "WHAT YOU CONFIGURE" — the navigation column, and
    /// Surface reachable from BOTH other stages (§6, the maintainer's own ask).
    func testSurfaceIsReachableFromBothOtherStages() {
        XCTAssertTrue(WorkspaceStage.topology.forward.contains(.surface))
        XCTAssertTrue(WorkspaceStage.lattice.forward.contains(.surface))
        XCTAssertEqual(WorkspaceStage.topology.forward, [.lattice, .surface],
                       "the TO page offers both onward stages")
        XCTAssertEqual(WorkspaceStage.lattice.forward, [.surface],
                       "the lattice page's column is Surface, with Settings BELOW it")
    }

    /// Topology is the root — every other stage goes back to it, and it has no
    /// back button of its own.
    func testTopologyIsTheRoot() {
        XCTAssertNil(WorkspaceStage.topology.back)
        XCTAssertEqual(WorkspaceStage.lattice.back, .topology)
        XCTAssertEqual(WorkspaceStage.surface.back, .topology)
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: ★ §6(a) — "NONE. NOT DIMMED — HIDDEN."

    /// ★ THE FALL-THROUGH THAT DREW THE TOPOLOGY STAGE'S BOXES ON THIS ONE.
    ///
    /// `stageVolumeItems` read `latticeDepthPlanes ? planes : keepOuts` — a two-way
    /// choice written when there were two stages. A third stage that wants NEITHER
    /// took the else branch, so the Surface stage drew the keep-out volumes over
    /// the surface it exists to show. The visibility table already said so; the
    /// call site did not read it. Pinned here as a PROPERTY of the table rather
    /// than of one call site, so the same mistake in a fourth stage fails.
    func testAStageThatWantsNeitherVolumeSetAsksForNeither() {
        let v = WorkspaceStageVisibility.of(.surface)
        XCTAssertFalse(v.keepOuts, "no keep-out boxes")
        XCTAssertFalse(v.latticeDepthPlanes, "and no depth planes")
        XCTAssertFalse(v.designBox)
        XCTAssertFalse(v.groupPrimitives)

        // The other two stages each want exactly ONE of the two sets, which is
        // what made a binary choice look sufficient.
        let topo = WorkspaceStageVisibility.of(.topology)
        let latt = WorkspaceStageVisibility.of(.lattice)
        XCTAssertTrue(topo.keepOuts)
        XCTAssertFalse(topo.latticeDepthPlanes)
        XCTAssertTrue(latt.latticeDepthPlanes)
        XCTAssertFalse(latt.keepOuts)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ §6(i)/(j) — COMMITTING THE CUT THROUGH THE PROJECT
//
// The cut divides a REGION, because a region is what carries a role, a depth and
// a lattice choice. These tests pin the two cases the view can hand it: a face
// that already has a region, and one that does not.

@MainActor
final class SurfaceCutCommitTests: XCTestCase {

    /// Two coplanar-ish faces on one part, each a square.
    private func twoFaceProject() -> (ProjectModel, UUID) {
        var v: [Float] = []
        func V(_ x: Float, _ y: Float, _ z: Float) { v += [x, y, z] }
        V(0, 0, 0); V(10, 0, 0); V(10, 10, 0); V(0, 10, 0)
        V(0, 0, 10); V(10, 0, 10); V(10, 10, 10); V(0, 10, 10)
        let idx: [Int32] = [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7]
        let mesh = ViewerMesh(vertices: v, indices: idx, faceIDs: [0, 0, 1, 1],
                              faceGeometry: [
                                StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, -1)),
                                StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1)),
                              ])
        let p = ProjectModel(id: UUID(), name: "Cut", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = mesh
        p.selection.addGroup()
        p.selection.pickFaces([0, 1])
        return (p, p.selection.groups[0].id)
    }

    private func topCut(_ p: ProjectModel) -> SurfaceCut {
        SurfaceCut.at(rayOrigin: SIMD3(5, 5, 50), rayDir: SIMD3(0, 0, -1),
                      mesh: p.viewerMesh!)!
    }

    /// ★ A FACE WITH NO REGION GETS ONE, and the two halves land in the group
    /// that already owned the face — otherwise the cut would be invisible in the
    /// Selections list, which is the only place a role can be given to it.
    func testCuttingAFaceWithNoRegionMakesOneAndJoinsItsGroup() throws {
        let (p, gid) = twoFaceProject()
        XCTAssertNil(p.surfaceCutTarget(face: 1), "no region yet")

        let kids = p.commitSurfaceCut(topCut(p))
        XCTAssertEqual(kids.count, 2, "§6(i): two halves")

        let parent = try XCTUnwrap(p.faceRegions.region(kids[0])?.parentID)
        let g = try XCTUnwrap(p.selection.groups.first { $0.id == gid })
        XCTAssertTrue(g.regionIDs.contains(parent),
                      "the manufactured parent joined the group that owned face 1")
        XCTAssertEqual(p.latticeRegionMemberFaces(parent), [1],
                       "and it resolves to exactly the face that was cut")
    }

    /// ★ THE FACE PARTITION IS UNTOUCHED. LAYER 1 is what projection and every
    /// analytic-surface lookup stand on; a cut is LAYER 2 and must not renumber it.
    func testTheCutDoesNotRepartitionTheFaces() {
        let (p, _) = twoFaceProject()
        let before = p.viewerMesh!.faceIDs
        p.commitSurfaceCut(topCut(p))
        XCTAssertEqual(p.viewerMesh!.faceIDs, before,
                       "§6(j): the CAD face ids are never rewritten by a cut")
    }

    /// ★ CUTTING A PIECE THAT WAS ALREADY CUT divides THAT PIECE — the deepest
    /// region under the point — not its parent all over again.
    func testASecondCutDividesTheDeepestPieceUnderThePoint() throws {
        let (p, _) = twoFaceProject()
        let first = p.commitSurfaceCut(topCut(p))
        XCTAssertEqual(first.count, 2)

        let target = try XCTUnwrap(p.surfaceCutTarget(face: 1))
        XCTAssertTrue(first.contains(target),
                      "the deepest region holding face 1 is one of the halves, "
                      + "not the parent it was cut from")

        let second = p.commitSurfaceCut(topCut(p).rotated(by: 90))
        XCTAssertEqual(second.count, 2)
        XCTAssertEqual(p.faceRegions.region(second[0])?.parentID, target,
                       "the second cut hangs off the HALF, so the tree deepens")
    }

    /// A cut on a face the ray misses commits nothing — there is no
    /// nearest-anything fallback.
    func testAMissCommitsNothing() {
        let (p, _) = twoFaceProject()
        let before = p.faceRegions.regions.count
        XCTAssertNil(SurfaceCut.at(rayOrigin: SIMD3(99, 99, 50),
                                   rayDir: SIMD3(0, 0, -1), mesh: p.viewerMesh!))
        XCTAssertEqual(p.faceRegions.regions.count, before)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ THE SURFACE STAGE'S COLOUR, AND ITS TOOLBOX
//
// Maintainer, 2026-08-14: "all colours from the TO page cannot be the same in the
// Surface page … they should all have a slight blue hue to differentiate faces
// that can be modified and faces that can't", and "I need to see the different
// faces after the cut is made. And select each individually".

final class SurfaceTintTests: XCTestCase {

    /// A box: face 0 the base, face 1 the top. Two triangles each, no shared verts.
    private func mesh() -> ViewerMesh {
        var v: [Float] = []
        func V(_ x: Float, _ y: Float, _ z: Float) { v += [x, y, z] }
        V(0, 0, 0); V(10, 0, 0); V(10, 10, 0); V(0, 10, 0)
        V(0, 0, 10); V(10, 0, 10); V(10, 10, 10); V(0, 10, 10)
        return ViewerMesh(vertices: v,
                          indices: [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7],
                          faceIDs: [0, 0, 1, 1],
                          faceGeometry: [
                            StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, -1)),
                            StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1)),
                          ])
    }

    /// ★ ONLY A GROUPED FACE IS TINTED. That IS the rule: colour on this stage
    /// means "this face can be modified", and nothing else.
    func testOnlyGroupedFacesAreTinted() {
        let m = mesh()
        let s = SurfaceTint.states(mesh: m, groupedFaces: [1],
                                   regions: FaceRegionModel(), selected: nil)
        // ★ ONE STATE PER *DRAW* VERTEX — one per INDEX, the length the renderer's
        // flattened vertex list has. A buffer sized to the unique positions is
        // silently rejected by `setVertexTints`, which is exactly how this shipped
        // invisible the first time.
        XCTAssertEqual(s.count, m.indices.count, "one state per DRAW vertex")
        XCTAssertEqual(Array(s[0..<6]), Array(repeating: .untinted, count: 6),
                       "face 0's two triangles are ungrouped — no colour, because "
                       + "the face cannot be acted on")
        XCTAssertEqual(Array(s[6..<12]), Array(repeating: .grouped, count: 6),
                       "face 1's two triangles are grouped and therefore selectable")
    }

    /// ★ NOTHING GROUPED, NOTHING UPLOADED.
    func testAnEmptyTintProducesNoBuffer() {
        XCTAssertTrue(SurfaceTint.buffer(mesh: mesh(), groupedFaces: [],
                                         regions: FaceRegionModel(),
                                         selected: nil).isEmpty)
    }

    /// ★ EIGHT FLOATS PER DRAW VERTEX: rgba, then flags. The stride must match the
    /// vertex descriptor's `layouts[2].stride`; `setVertexTints` refuses anything
    /// else, and a refusal is silent — the stage simply looks untinted.
    func testTheBufferIsEightFloatsPerDrawVertex() {
        let m = mesh()
        let b = SurfaceTint.buffer(mesh: m, groupedFaces: [0, 1],
                                   regions: FaceRegionModel(), selected: nil)
        XCTAssertEqual(b.count, m.indices.count * 8,
                       "rgba + flags per DRAW vertex — the layout the descriptor "
                       + "declares and the only length the renderer will accept")
        // Nothing is selected, so no fragment is a member and the cut test is off.
        for i in stride(from: 4, to: b.count, by: 8) {
            XCTAssertEqual(b[i], 0, "no selection → no member flag")
        }
    }

    /// ★ THE MEMBER FLAG MARKS THE SELECTED REGION'S FACES — the fragments the
    /// half-space test applies to. The CPU decides MEMBERSHIP (a per-face fact);
    /// the GPU decides SIDE (a per-point fact). That split is what puts the
    /// boundary exactly on the plane instead of on the nearest triangle edge.
    func testTheMemberFlagMarksTheSelectedRegionsFaces() throws {
        let m = mesh()
        var regions = FaceRegionModel()
        let parent = regions.union(faces: [1], named: "top")
        let kids = regions.splitManual(parent, point: SIMD3(5, 5, 10),
                                       normal: SIMD3(1, 0, 0))
        // ★ THE TESTED SET IS THE WHOLE TRUTH — a face is fragment-tested iff it
        // is named here. There is deliberately NO fallback: inferring it from the
        // per-triangle state dimmed every picked WHOLE face, because a union of
        // whole faces names nothing and the shader then had no chains to run.
        let b = SurfaceTint.buffer(mesh: m, groupedFaces: [1],
                                   regions: regions, selected: kids[0],
                                   fragmentTested: [1])
        // Face 0 is indices 0..5 (not a member), face 1 is 6..11 (the member).
        for v in 0..<6 { XCTAssertEqual(b[v * 8 + 4], 0, "face 0 is not tested") }
        for v in 6..<12 { XCTAssertEqual(b[v * 8 + 4], 1, "face 1 is") }
    }

    /// ★ THE PLANE HANDED TO THE SHADER IS THE REGION'S OWN CUT, in the sense it
    /// was stored — so `d >= 0` IS the selected side and the shader needs no sign
    /// of its own. Asserted by evaluating the plane at points either side.
    func testThePlaneIsOrientedSoTheSelectedSideIsPositive() throws {
        let m = mesh()
        var regions = FaceRegionModel()
        let parent = regions.union(faces: [1], named: "top")
        let kids = regions.splitManual(parent, point: SIMD3(5, 5, 10),
                                       normal: SIMD3(1, 0, 0))
        let sel = kids[0]
        let plane = try XCTUnwrap(SurfaceTint.planeFor(sel, in: regions))

        func d(_ p: SIMD3<Float>) -> Float {
            simd_dot(SIMD3<Float>(plane.x, plane.y, plane.z), p) + plane.w
        }
        let inside = FaceRegionGeometry.inside(SIMD3(8, 5, 10),
                                               regions.region(sel)?.cuts ?? [])
        XCTAssertEqual(d(SIMD3(8, 5, 10)) >= 0, inside,
                       "the shader's test agrees with the model's `inside`")
        XCTAssertEqual(d(SIMD3(2, 5, 10)) >= 0,
                       FaceRegionGeometry.inside(SIMD3(2, 5, 10),
                                                 regions.region(sel)?.cuts ?? []),
                       "on both sides — one shared definition of the half-space")
        XCTAssertNotEqual(d(SIMD3(8, 5, 10)) >= 0, d(SIMD3(2, 5, 10)) >= 0,
                          "and the two sides really are different sides")
    }

    /// Nothing selected → no plane → the shader draws exactly as it did before the
    /// cut test existed.
    func testNoSelectionMeansNoPlane() {
        XCTAssertNil(SurfaceTint.planeFor(nil, in: FaceRegionModel()))
    }

    /// ★ THE TWO HALVES OF A CUT FACE GET DIFFERENT COLOURS — which a per-FACE tint
    /// could never do, because a cut does not create a face and both halves keep
    /// the same id. This is the whole reason the tint is per VERTEX.
    func testTheTwoHalvesOfACutFaceAreColouredDifferently() throws {
        let m = mesh()
        var regions = FaceRegionModel()
        let parent = regions.union(faces: [1], named: "top")
        let kids = regions.splitManual(parent, point: SIMD3(5, 5, 10),
                                       normal: SIMD3(1, 0, 0))
        XCTAssertEqual(kids.count, 2)

        let s = SurfaceTint.states(mesh: m, groupedFaces: [1],
                                   regions: regions, selected: kids[0],
                                   fragmentTested: [1])
        // ★ ONE COLOUR PER TRIANGLE, decided by its CENTROID — so a triangle is
        // never a gradient between two states. Face 1's triangles are indices
        // 6..8 ([4,5,6], centroid x = 6.67, the +x side) and 9..11 ([4,6,7],
        // centroid x = 3.33, the −x side). kids[0] takes +x.
        XCTAssertEqual(Array(s[6..<9]), Array(repeating: .selected, count: 3),
                       "the +x triangle is FLAT selected across all three vertices")
        XCTAssertEqual(Array(s[9..<12]), Array(repeating: .sibling, count: 3),
                       "and the −x triangle is FLAT sibling — no vertex of either "
                       + "carries the other's colour, so the GPU has nothing to "
                       + "interpolate and the fill cannot smear")
        XCTAssertTrue(s.contains(.selected) && s.contains(.sibling),
                      "★ both halves are present and DIFFERENT — which a per-FACE "
                      + "tint could never show, since they share face id 1")
        XCTAssertNotEqual(SurfaceTint.colour(.selected), SurfaceTint.colour(.sibling),
                          "and the two states are actually different colours")
    }

    /// ★ ONE HUE. The states differ in brightness, not in colour.
    func testEveryTintIsTheSameBlueHue() {
        for c in [SurfaceTint.grouped, SurfaceTint.sibling, SurfaceTint.selected] {
            XCTAssertGreaterThan(c.z, c.y, "blue dominates green")
            XCTAssertGreaterThan(c.y, c.x, "and green dominates red — a blue hue")
        }
        XCTAssertLessThan(SurfaceTint.grouped.w, SurfaceTint.sibling.w)
        XCTAssertLessThan(SurfaceTint.sibling.w, SurfaceTint.selected.w)
    }

    /// ★ SELECTING A HALF — the tap's POINT decides, because its face id cannot.
    func testThePointSelectsTheHalfThatWasTapped() throws {
        let m = mesh()
        var regions = FaceRegionModel()
        let parent = regions.union(faces: [1], named: "top")
        let kids = regions.splitManual(parent, point: SIMD3(5, 5, 10),
                                       normal: SIMD3(1, 0, 0))

        let plusX = try XCTUnwrap(SurfaceTint.regionAt(point: SIMD3(8, 5, 10), face: 1,
                                                       mesh: m, regions: regions))
        let minusX = try XCTUnwrap(SurfaceTint.regionAt(point: SIMD3(2, 5, 10), face: 1,
                                                        mesh: m, regions: regions))
        XCTAssertNotEqual(plusX, minusX,
                          "★ two taps on the SAME face id select DIFFERENT pieces")
        XCTAssertTrue(kids.contains(plusX))
        XCTAssertTrue(kids.contains(minusX))
    }

    /// An uncut face selects its own region, not one of nothing.
    func testAnUncutFaceSelectsItsOwnRegion() throws {
        let m = mesh()
        var regions = FaceRegionModel()
        let r = regions.union(faces: [1], named: "top")
        XCTAssertEqual(SurfaceTint.regionAt(point: SIMD3(5, 5, 10), face: 1,
                                            mesh: m, regions: regions), r)
    }
}

final class SurfaceToolTests: XCTestCase {

    /// ★ THE DEFAULT IS SELECT (maintainer, explicitly: "cut should *not* be set as
    /// the default tool"). Arriving on a stage with a destructive tool armed means
    /// the first exploratory tap has already edited the model.
    func testTheDefaultToolIsSelectAndItEditsNothing() {
        XCTAssertEqual(SurfaceTool.initial, .select)
        XCTAssertFalse(SurfaceTool.initial.edits,
                       "the default must be the tool that changes nothing")
    }

    func testEveryOtherToolEdits() {
        for t in SurfaceTool.allCases where t != .select {
            XCTAssertTrue(t.edits, "\(t.title) commits a change")
        }
    }

    func testTheTrayCarriesEveryToolWithSelectFirst() {
        XCTAssertEqual(SurfaceTool.allCases,
                       [.select, .similar, .cut, .union, .pattern])
        XCTAssertEqual(SurfaceTool.allCases.first, .select, "select leads the tray")
        XCTAssertEqual(SurfaceTool.allCases[1], .similar,
                       "★ Similar is a SELECTION aid, so it sits beside select "
                       + "rather than among the tools that cut and combine")
    }

    /// A tray of icons must not be a guessing game — every tool carries a glyph and
    /// a one-line hint, and the hint stays one line.
    func testEveryToolHasAnIconAndAHint() {
        for t in SurfaceTool.allCases {
            XCTAssertFalse(t.icon.isEmpty, "\(t.title) needs a glyph")
            XCTAssertFalse(t.hint.isEmpty, "\(t.title) needs a hint")
            XCTAssertLessThanOrEqual(t.hint.split(separator: " ").count, 9,
                                     "the hint is one line, not a paragraph")
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ THE CUT AS GEOMETRY — the lines, the centre, and the union
//
// Maintainer, 2026-08-14: "Where are the cut lines? We need to see what it will
// look like", "the cuts need to be visible in the wireframe view after any cut is
// made", "The cut should always automatically be in the middle of the face
// selected … I tried cutting again and the cut line was in the exact spot it had
// been when the two faces were one", and "how can union work without selecting
// more than one face at a time?".

final class SurfaceCutLineTests: XCTestCase {

    /// One flat 10x10 square (face 0) as two triangles, in z = 0.
    private func square() -> ViewerMesh {
        let v: [Float] = [0, 0, 0, 10, 0, 0, 10, 10, 0, 0, 10, 0]
        return ViewerMesh(vertices: v, indices: [0, 1, 2, 0, 2, 3], faceIDs: [0, 0],
                          faceGeometry: [StepFaceGeometry(kind: .plane,
                                                          planeNormal: SIMD3(0, 0, 1))])
    }

    /// ★ THE TRACE IS THE PLANE'S REAL CURVE ON THE SURFACE — not a staircase
    /// along triangle edges, which is what a coloured fill can only ever give.
    func testAPlaneThroughTheMiddleTracesAcrossTheWholeFace() {
        let m = square()
        let cut = RegionCut(point: SIMD3(5, 5, 0), normal: SIMD3(1, 0, 0))
        let seg = SurfaceCutLines.trace(plane: cut, faces: [0], in: m)

        XCTAssertEqual(seg.count % 6, 0, "6 floats per segment")
        XCTAssertGreaterThan(seg.count, 0, "the plane crosses the square, so it traces")

        // Every traced point lies ON the plane (x == 5) and INSIDE the square.
        var i = 0
        while i + 2 < seg.count {
            XCTAssertEqual(seg[i], 5, accuracy: 1e-4, "on the cut plane")
            XCTAssertGreaterThanOrEqual(seg[i + 1], -1e-4)
            XCTAssertLessThanOrEqual(seg[i + 1], 10 + 1e-4)
            i += 3
        }
    }

    /// A plane that misses the face traces nothing — no stray segment at the edge.
    func testAPlaneThatMissesTracesNothing() {
        let cut = RegionCut(point: SIMD3(50, 0, 0), normal: SIMD3(1, 0, 0))
        XCTAssertEqual(SurfaceCutLines.trace(plane: cut, faces: [0], in: square()).count, 0)
    }

    /// ★ A COMMITTED CUT PRODUCES A LINE — this is what makes a split face read as
    /// two pieces in the wireframe.
    func testACommittedCutIsTraced() {
        let m = square()
        var regions = FaceRegionModel()
        let parent = regions.union(faces: [0], named: "face")
        regions.splitManual(parent, point: SIMD3(5, 5, 0), normal: SIMD3(1, 0, 0))
        XCTAssertGreaterThan(SurfaceCutLines.committed(regions: regions, in: m).count, 0)
    }

    /// ★ AND EACH BOUNDARY IS DRAWN ONCE. The two children of a split hold the
    /// same plane with opposite senses, and a child inherits its parent's cuts —
    /// so a naive walk draws every ancestor's line once per descendant. On a 3x3
    /// pattern that is the same nine lines nine times, which reads as a thick
    /// mis-registered smear rather than as a grid.
    func testEachBoundaryIsTracedExactlyOnce() {
        let m = square()
        var regions = FaceRegionModel()
        let parent = regions.union(faces: [0], named: "face")
        let kids = regions.splitManual(parent, point: SIMD3(5, 5, 0),
                                       normal: SIMD3(1, 0, 0))
        let once = SurfaceCutLines.committed(regions: regions, in: m).count

        // Cut one HALF again: the new boundary adds lines, the old one must not
        // be re-drawn for the grandchildren.
        regions.splitManual(kids[0], point: SIMD3(7, 5, 0), normal: SIMD3(0, 1, 0))
        let twice = SurfaceCutLines.committed(regions: regions, in: m).count
        XCTAssertGreaterThan(twice, once, "the second cut adds its own trace")
        XCTAssertLessThan(twice, once * 3,
                          "but the first boundary is not re-traced once per child")
    }

    /// ★ NO REGIONS, NO LINES — the wireframe is unchanged until something is cut.
    func testAnUncutPartAddsNoLines() {
        XCTAssertEqual(SurfaceCutLines.committed(regions: FaceRegionModel(),
                                                 in: square()).count, 0)
    }
}

@MainActor
final class SurfaceSecondCutTests: XCTestCase {

    private func project() -> (ProjectModel, ViewerMesh) {
        let v: [Float] = [0, 0, 0, 10, 0, 0, 10, 10, 0, 0, 10, 0]
        let mesh = ViewerMesh(vertices: v, indices: [0, 1, 2, 0, 2, 3], faceIDs: [0, 0],
                              faceGeometry: [StepFaceGeometry(kind: .plane,
                                                              planeNormal: SIMD3(0, 0, 1))])
        let p = ProjectModel(id: UUID(), name: "Cut2", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = mesh
        p.selection.addGroup()
        p.selection.pickFaces([0])
        return (p, mesh)
    }

    /// ★ THE SECOND CUT GOES THROUGH THE MIDDLE OF THE PIECE, NOT OF THE FACE.
    ///
    /// `centred(onFace:)` reads the FACE's frame, and a cut does not change the
    /// face — so cutting a half put the line back at the face's centre, which is
    /// exactly where the first cut already is: "the cut line was in the exact spot
    /// it had been when the two faces were one".
    func testTheSecondCutIsCentredOnTheHalfNotTheWholeFace() throws {
        let (p, mesh) = project()
        let first = try XCTUnwrap(SurfaceCut.centred(onFace: 0, in: mesh))
        XCTAssertEqual(first.point.x, 5, accuracy: 0.6, "the face's own middle")

        // Cut it in two down x = 5, then aim at the +x half.
        let kids = p.commitSurfaceCut(
            SurfaceCut(point: SIMD3(5, 5, 0), normal: SIMD3(1, 0, 0),
                       faceID: 0, faceNormal: SIMD3(0, 0, 1)))
        XCTAssertEqual(kids.count, 2)
        let plusX = try XCTUnwrap(kids.first {
            FaceRegionGeometry.inside(SIMD3(8, 5, 0),
                                      p.faceRegions.region($0)?.cuts ?? [])
        })

        let second = try XCTUnwrap(SurfaceCut.centred(onRegion: plusX, of: 0,
                                                      regions: p.faceRegions, in: mesh))
        XCTAssertGreaterThan(second.point.x, 6,
                             "★ the middle of the +x HALF (x ≈ 7.5), not the face's "
                             + "middle at x = 5 — where the first cut already is")
        XCTAssertNotEqual(second.point.x, first.point.x, accuracy: 0.001)
    }

    /// ★ MOVE slides the plane along its OWN normal — the only direction that
    /// moves a plane at all.
    func testMovingACutSlidesItAlongItsNormal() {
        let c = SurfaceCut(point: SIMD3(5, 5, 0), normal: SIMD3(1, 0, 0),
                           faceID: 0, faceNormal: SIMD3(0, 0, 1))
        let m = c.moved(byMM: 2)
        XCTAssertEqual(m.point.x, 7, accuracy: 1e-9)
        XCTAssertEqual(m.point.y, 5, accuracy: 1e-9, "and not sideways")
        XCTAssertEqual(m.normal, c.normal, "moving does not turn it")
    }

    /// ★ TWO HALVES OF ONE FACE ARE TWO PIECES, and a `Set<FaceID>` cannot hold
    /// them — both carry the same id. This is the defect that made union's
    /// multi-select unable to reach two, pinned as a property of the ids.
    func testTheTwoHalvesOfACutFaceAreDistinctRegionsSharingOneFaceID() throws {
        let (p, _) = project()
        let kids = p.commitSurfaceCut(
            SurfaceCut(point: SIMD3(5, 5, 0), normal: SIMD3(1, 0, 0),
                       faceID: 0, faceNormal: SIMD3(0, 0, 1)))
        XCTAssertEqual(kids.count, 2)
        XCTAssertNotEqual(kids[0], kids[1], "two DISTINCT regions…")
        XCTAssertEqual(p.latticeRegionMemberFaces(kids[0]),
                       p.latticeRegionMemberFaces(kids[1]),
                       "…resolving to the SAME face — so a set of face ids collapses "
                       + "them to one entry and the second tap toggles the first off")
        XCTAssertEqual(Set([kids[0], kids[1]]).count, 2,
                       "a set of REGIONS keeps them apart, which is what union needs")
    }

    /// A hand-picked union stores its members and carries no filter: with no
    /// filter, `add` IS the membership, which is what a multi-select means.
    func testAHandPickedUnionStoresExactlyTheFacesPicked() throws {
        let v: [Float] = [0, 0, 0, 10, 0, 0, 10, 10, 0, 0, 10, 0,
                          0, 0, 5, 10, 0, 5, 10, 10, 5, 0, 10, 5]
        let mesh = ViewerMesh(vertices: v,
                              indices: [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7],
                              faceIDs: [0, 0, 1, 1],
                              faceGeometry: [
                                StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1)),
                                StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1)),
                              ])
        let p = ProjectModel(id: UUID(), name: "U", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = mesh
        p.selection.addGroup()
        p.selection.pickFaces([0, 1])

        let rid = try XCTUnwrap(p.commitSurfaceUnion(faces: [0, 1]))
        let r = try XCTUnwrap(p.faceRegions.region(rid))
        XCTAssertFalse(r.filter.any, "hand-picked: no filter defines it")
        XCTAssertEqual(r.add, [0, 1], "the members ARE what was tapped")
        XCTAssertEqual(FaceRegionGeometry.members(of: r, in: mesh), [0, 1])
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ §7 — WHICH WAY THE PATTERN RUNS
//
// Maintainer, 2026-08-14: "Pattern still needs to be in-line with the longest flat
// side" and "Pattern still needs rotation icon".

final class SurfacePatternAxisTests: XCTestCase {

    /// A long thin rectangle in z = 0: 40 along x, 6 along y. Its longest straight
    /// edge runs along x.
    private func slab() -> ViewerMesh {
        let v: [Float] = [0, 0, 0, 40, 0, 0, 40, 6, 0, 0, 6, 0]
        return ViewerMesh(vertices: v, indices: [0, 1, 2, 0, 2, 3], faceIDs: [0, 0],
                          faceGeometry: [StepFaceGeometry(kind: .plane,
                                                          planeNormal: SIMD3(0, 0, 1))])
    }

    /// ★ THE GRID LINES UP WITH THE LONGEST EDGE. Folded into [-45, 45), because
    /// the grid is symmetric every 90° — a 91° alignment and a 1° one give the
    /// same pattern, and the smaller number is the one a person would have typed.
    func testTheAlignmentFollowsTheLongestStraightEdge() {
        let a = SurfacePatternAxis.alignmentDegrees(face: 0, in: slab())
        XCTAssertGreaterThanOrEqual(a, -45)
        XCTAssertLessThan(a, 45)
        XCTAssertEqual(abs(a), 0, accuracy: 1e-6,
                       "the long edge runs along the frame's own u — no correction "
                       + "needed, and the automatic answer says so rather than "
                       + "inventing a rotation")
    }

    /// A face with no boundary returns 0 rather than a wrong angle — the frame's
    /// own orientation stays in charge.
    func testAFaceWithNoBoundaryLeavesTheFrameAlone() {
        let v: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0]
        let m = ViewerMesh(vertices: v, indices: [], faceIDs: [])
        XCTAssertEqual(SurfacePatternAxis.alignmentDegrees(face: 0, in: m), 0)
    }

    /// ★ ROTATING THE FRAME TURNS THE GRID AND MOVES NOTHING ELSE — the pattern
    /// spins about its own centre and stays on the surface.
    func testRotatingTheFrameKeepsItOnTheSurface() {
        let m = slab()
        let f = FaceRegionGeometry.frame(members: [0], in: m)
        XCTAssertTrue(f.valid)
        let r = f.rotatedInPlane(byDegrees: 30, members: [0], in: m)

        XCTAssertEqual(r.origin, f.origin, "the centre does not move")
        XCTAssertEqual(simd_length(r.u), 1, accuracy: 1e-9)
        XCTAssertEqual(simd_length(r.v), 1, accuracy: 1e-9)
        XCTAssertEqual(simd_dot(r.u, r.v), 0, accuracy: 1e-9, "still orthogonal")
        // Both axes stay IN the original plane, so the grid stays on the face.
        let n = simd_normalize(simd_cross(f.u, f.v))
        XCTAssertEqual(simd_dot(r.u, n), 0, accuracy: 1e-9)
        XCTAssertEqual(simd_dot(r.v, n), 0, accuracy: 1e-9)
        // And it really turned.
        XCTAssertLessThan(simd_dot(r.u, f.u), 0.9999)
    }

    /// Zero is a no-op, so an unrotated pattern is byte-identical to one that
    /// never went through the rotation at all.
    func testZeroRotationIsANoOp() {
        let m = slab()
        let f = FaceRegionGeometry.frame(members: [0], in: m)
        XCTAssertEqual(f.rotatedInPlane(byDegrees: 0, members: [0], in: m).u, f.u)
        XCTAssertEqual(f.rotatedInPlane(byDegrees: 0, members: [0], in: m).v, f.v)
    }

    /// ★ THE EXTENT IS RE-MEASURED ALONG THE NEW AXES — the defect that made the
    /// preview draw nothing and the commit produce a nonsense shape.
    ///
    /// The slab is 40 x 6. Turned 90°, "along u" and "along v" swap, so the bounds
    /// must swap with them. Left alone, the grid is placed at 40 mm of parameter
    /// across a 6 mm axis and every cut lands off the face.
    func testRotatingAlsoReMeasuresTheExtent() {
        let m = slab()
        let f = FaceRegionGeometry.frame(members: [0], in: m)
        let uSpan = f.uHi - f.uLo, vSpan = f.vHi - f.vLo
        XCTAssertEqual(max(uSpan, vSpan), 40, accuracy: 1e-6)
        XCTAssertEqual(min(uSpan, vSpan), 6, accuracy: 1e-6)

        let r = f.rotatedInPlane(byDegrees: 90, members: [0], in: m)
        XCTAssertEqual(r.uHi - r.uLo, vSpan, accuracy: 1e-6,
                       "u now runs where v did, so it spans what v spanned")
        XCTAssertEqual(r.vHi - r.vLo, uSpan, accuracy: 1e-6)
    }

    /// ★ AND THE GRID STILL LANDS ON THE FACE AT ANY ANGLE — the property that
    /// actually matters, asserted end to end: cells are produced and their planes
    /// TRACE, which is what makes the preview visible.
    func testTheGridTracesAtEveryAngle() {
        let m = slab()
        let f = FaceRegionGeometry.frame(members: [0], in: m)
        for deg in stride(from: 0.0, through: 90.0, by: 15.0) {
            let r = f.rotatedInPlane(byDegrees: deg, members: [0], in: m)
            let cells = FaceRegionGeometry.gridSplitCells(r, n: 3, m: 1)
            XCTAssertEqual(cells.count, 3, "3 cells at \(deg)°")
            let lines = SurfaceCutLines.preview(cells: cells, face: 0, in: m)
            XCTAssertGreaterThan(lines.count, 0,
                                 "★ at \(deg)° the grid must still CROSS the face — "
                                 + "with stale bounds the cuts land off it and the "
                                 + "preview draws nothing. VERIFIED DISCRIMINATING: "
                                 + "the bounds-free rotation returns 0 segments here")
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ CLIPPING A PATTERN TO ONE PIECE
//
// Maintainer, 2026-08-15: "Pattern is within the face selected - but as you can
// see, the two rows I'd selected is not visible..."

final class SurfaceClipTests: XCTestCase {

    /// The right half of x = 5.
    private let rightHalf = [RegionCut(point: SIMD3(5, 0, 0), normal: SIMD3(1, 0, 0))]

    /// One segment, as the flat list the tracer produces.
    private func seg(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> [Float] {
        [a.x, a.y, a.z, b.x, b.y, b.z]
    }

    /// ★ THE DEFECT. A long line that CROSSES the boundary must be TRIMMED to the
    /// piece — not thrown away. Dropping it by midpoint is what made every ROW line
    /// vanish: a row runs the full length of the face, so its midpoint sits in the
    /// sibling half while most of the line is inside the piece.
    func testASegmentCrossingTheBoundaryIsTrimmedNotDropped() throws {
        // Runs 0 → 20 in x; the midpoint (10) is INSIDE here, so flip it: run the
        // line 0 → 12 with midpoint 6 inside, then one 0 → 8 with midpoint 4
        // OUTSIDE — the case the old rule silently discarded.
        let crossing = seg(SIMD3(0, 1, 0), SIMD3(8, 1, 0))   // midpoint x = 4, outside
        let out = SurfaceCutLines.clip(crossing, to: rightHalf)

        XCTAssertEqual(out.count, 6, "★ the inside part SURVIVES — it is not dropped")
        XCTAssertEqual(out[0], 5, accuracy: 1e-4, "trimmed to the boundary at x = 5")
        XCTAssertEqual(out[3], 8, accuracy: 1e-4, "and keeps its inside end")
    }

    /// A segment wholly inside is untouched — clipping must not nibble at lines it
    /// has no business changing.
    func testAWhollyInsideSegmentIsUnchanged() {
        let inside = seg(SIMD3(6, 0, 0), SIMD3(9, 0, 0))
        XCTAssertEqual(SurfaceCutLines.clip(inside, to: rightHalf), inside)
    }

    /// A segment wholly outside is dropped.
    func testAWhollyOutsideSegmentIsDropped() {
        XCTAssertEqual(SurfaceCutLines.clip(seg(SIMD3(0, 0, 0), SIMD3(3, 0, 0)),
                                            to: rightHalf).count, 0)
    }

    /// No cuts means no clipping — an uncut face's grid is drawn entire.
    func testNoCutsMeansNoClipping() {
        let s = seg(SIMD3(0, 0, 0), SIMD3(9, 0, 0))
        XCTAssertEqual(SurfaceCutLines.clip(s, to: []), s)
    }

    /// ★ TRIMMED AGAINST EVERY HALF-SPACE IN TURN, so a piece bounded by two cuts
    /// keeps only the span inside both — a grid cell, not a strip.
    func testASegmentIsTrimmedByEveryCut() throws {
        let band = [RegionCut(point: SIMD3(5, 0, 0), normal: SIMD3(1, 0, 0)),
                    RegionCut(point: SIMD3(9, 0, 0), normal: SIMD3(-1, 0, 0))]
        let out = SurfaceCutLines.clip(seg(SIMD3(0, 0, 0), SIMD3(20, 0, 0)), to: band)
        XCTAssertEqual(out.count, 6)
        XCTAssertEqual(out[0], 5, accuracy: 1e-4)
        XCTAssertEqual(out[3], 9, accuracy: 1e-4, "both ends trimmed, one per cut")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ LIGHTING A PIECE, NOT ITS FACE
//
// Maintainer, 2026-08-15: "why are they being considered one face when I tapped
// only one of them??"

final class SurfacePickChainTests: XCTestCase {

    private func splitProject() -> (FaceRegionModel, [RegionID], ViewerMesh) {
        let v: [Float] = [0, 0, 0, 10, 0, 0, 10, 10, 0, 0, 10, 0]
        let mesh = ViewerMesh(vertices: v, indices: [0, 1, 2, 0, 2, 3], faceIDs: [0, 0],
                              faceGeometry: [StepFaceGeometry(kind: .plane,
                                                              planeNormal: SIMD3(0, 0, 1))])
        var regions = FaceRegionModel()
        let parent = regions.union(faces: [0], named: "face")
        let kids = regions.splitManual(parent, point: SIMD3(5, 5, 0),
                                        normal: SIMD3(1, 0, 0))
        return (regions, kids, mesh)
    }

    /// ★ ONE PICKED PIECE YIELDS ONE CHAIN, and that chain's half-spaces contain
    /// the piece and EXCLUDE its sibling — which is exactly what a per-face
    /// highlight could not express, and why one tap appeared to light two pieces.
    func testAPickedPieceLightsItselfAndNotItsSibling() throws {
        let (regions, kids, _) = splitProject()
        let chains = SurfaceTint.pickChains([kids[0]], in: regions)
        XCTAssertEqual(chains.count, 1, "one piece, one chain")
        let chain = try XCTUnwrap(chains.first)
        XCTAssertFalse(chain.isEmpty)

        func inside(_ p: SIMD3<Float>) -> Bool {
            chain.allSatisfy { simd_dot(SIMD3(  $0.x, $0.y, $0.z), p) + $0.w >= 0 }
        }
        // kids[0] takes the +x side.
        XCTAssertTrue(inside(SIMD3(8, 5, 0)), "its own side is lit")
        XCTAssertFalse(inside(SIMD3(2, 5, 0)),
                       "★ and its SIBLING is not — the two share face 0, so a "
                       + "face-keyed highlight lights both and a tap looks like two")
    }

    /// Two picked pieces give two independent chains — the fragment stage lights a
    /// fragment inside ANY of them.
    func testTwoPickedPiecesGiveTwoChains() {
        let (regions, kids, _) = splitProject()
        XCTAssertEqual(SurfaceTint.pickChains(kids, in: regions).count, 2)
    }

    /// ★ AN UNCUT PIECE IS DROPPED, NOT SENT AS AN EMPTY CHAIN. "Inside no
    /// half-spaces" is trivially true everywhere, so an empty chain would light the
    /// whole part.
    func testAnUncutPieceContributesNoChain() {
        var regions = FaceRegionModel()
        let whole = regions.union(faces: [0], named: "whole")
        XCTAssertEqual(SurfaceTint.pickChains([whole], in: regions).count, 0)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ THE UNION TOOL, REWRITTEN
//
// Maintainer, 2026-08-15: "I think it might be best to completely *re-write* the
// union tool. Patching it together is making things stranger."
//
// ★ THE RULE: a union combines FACES, and absorbs any splits inside them. These
// tests are that sentence, in order.

final class SurfaceUnionTests: XCTestCase {

    /// Two faces; face 0 is split in two, face 1 is whole.
    private func fixture() -> (FaceRegionModel, ViewerMesh, [RegionID], RegionID) {
        var v: [Float] = []
        func V(_ x: Float, _ y: Float, _ z: Float) { v += [x, y, z] }
        V(0, 0, 0); V(10, 0, 0); V(10, 10, 0); V(0, 10, 0)
        V(0, 0, 5); V(10, 0, 5); V(10, 10, 5); V(0, 10, 5)
        let mesh = ViewerMesh(vertices: v,
                              indices: [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7],
                              faceIDs: [0, 0, 1, 1],
                              faceGeometry: [
                                StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1)),
                                StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1)),
                              ])
        var regions = FaceRegionModel()
        let parent = regions.union(faces: [0], named: "face 0")
        let halves = regions.splitManual(parent, point: SIMD3(5, 5, 0),
                                          normal: SIMD3(1, 0, 0))
        let whole = regions.union(faces: [1], named: "face 1")
        return (regions, mesh, halves, whole)
    }

    // ── picking ────────────────────────────────────────────────────────────

    /// ★ TAP TO ADD, TAP AGAIN TO DROP — and the two pieces of ONE face are two
    /// distinct picks, which is what a `Set<FaceID>` could never represent.
    func testTogglingAccumulatesAndTwoPiecesOfOneFaceAreTwoPicks() {
        let (_, _, halves, _) = fixture()
        var u = SurfaceUnion()
        XCTAssertTrue(u.isEmpty)

        u.toggle(halves[0])
        XCTAssertEqual(u.count, 1)
        XCTAssertFalse(u.hasEnoughToCombine, "one piece is not a union — it is that piece")

        u.toggle(halves[1])
        XCTAssertEqual(u.count, 2, "★ two pieces of the SAME face are two picks")
        XCTAssertTrue(u.hasEnoughToCombine,
                      "two pieces is enough to WANT a union; whether it can commit\n"
                      + "is a separate question the rule above answers")

        u.toggle(halves[0])
        XCTAssertEqual(u.count, 1, "tapping again drops it")
        XCTAssertTrue(u.contains(halves[1]))
    }

    /// ★ THE COUNT IS ALWAYS STATED. A tap that toggled a piece OFF and a tap that
    /// never registered must not read the same.
    func testTheHintAlwaysStatesTheCount() {
        let (regions, mesh, halves, whole) = fixture()
        var u = SurfaceUnion()
        XCTAssertTrue(u.hint(regions: regions, mesh: mesh).contains("Tap pieces"))
        u.toggle(whole)
        XCTAssertTrue(u.hint(regions: regions, mesh: mesh).contains("1 piece"))
        u.toggle(halves[0])
        XCTAssertTrue(u.hint(regions: regions, mesh: mesh).contains("2 pieces"))
    }

    // ── what a commit does ─────────────────────────────────────────────────

    /// ★ TWO PIECES AND IT COMMITS — the rule, restored now that a region can hold
    /// a union of PARTS.
    func testTwoPiecesCanCommit() {
        let (_, _, halves, whole) = fixture()
        var u = SurfaceUnion()
        u.toggle(halves[0])
        XCTAssertFalse(u.canCommit, "one piece is not a union")
        u.toggle(whole)
        XCTAssertTrue(u.canCommit)
    }

    /// ★ A WHOLE FACE IS A VALID PICK, AND IS DRAWN DIRECTLY. It has no half-spaces,
    /// so it yields no chain for the fragment test — and with the test armed over
    /// it, its fragments fell through to the unselected colour and went dim. That is
    /// "union only seems to work with *CUT* pieces": an ordinary face registered in
    /// the set and looked like nothing had happened.
    func testAWholeFacePickIsColouredDirectlyAndNotFragmentTested() {
        let (regions, mesh, halves, whole) = fixture()
        var u = SurfaceUnion()
        u.toggle(whole)

        XCTAssertEqual(u.wholeFacePicks(regions: regions, mesh: mesh), [1],
                       "the whole face is coloured per triangle…")
        XCTAssertEqual(u.facesTouched(regions: regions, mesh: mesh), [],
                       "…and is NOT handed to the shader, which would dim it")
        XCTAssertEqual(u.partialPicks(regions: regions), [])

        // Add a PART: now the shader is given that face, and only that one.
        u.toggle(halves[0])
        XCTAssertEqual(u.partialPicks(regions: regions), [halves[0]])
        XCTAssertEqual(u.facesTouched(regions: regions, mesh: mesh), [0])
        XCTAssertEqual(u.wholeFacePicks(regions: regions, mesh: mesh), [1],
                       "the whole face is still drawn directly")
    }

    /// The hint states the count and invites the commit.
    func testTheHintInvitesTheCommit() {
        let (regions, mesh, halves, whole) = fixture()
        var u = SurfaceUnion()
        u.toggle(halves[0]); u.toggle(whole)
        XCTAssertTrue(u.hint(regions: regions, mesh: mesh).contains("2 pieces"))
        XCTAssertTrue(u.hint(regions: regions, mesh: mesh).contains("✓"))
    }
}






// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ §7 — PIECES THAT ARE ACTUALLY ON THE FACE
//
// Maintainer, 2026-08-15: "There are meant to be 3 columns, only 2 are mostly
// visible and the third is barely in the face."

final class SurfacePatternAreaTests: XCTestCase {

    /// ★ A TAPERED FACE — a triangle, 40 long, full width at x = 0 and a point at
    /// x = 40. Its area is concentrated at the wide end, so equal PARAMETER steps
    /// and equal AREA steps disagree sharply. On a rectangle they agree, which is
    /// why the distinction went unnoticed until a real part showed it.
    private func wedge() -> ViewerMesh {
        let v: [Float] = [0, -6, 0, 0, 6, 0, 40, 0, 0]
        return ViewerMesh(vertices: v, indices: [0, 1, 2], faceIDs: [0],
                          faceGeometry: [StepFaceGeometry(kind: .plane,
                                                          planeNormal: SIMD3(0, 0, 1))])
    }

    /// A finer wedge, so the area distribution has something to quantise over.
    private func tessellatedWedge(strips: Int = 40) -> ViewerMesh {
        var v: [Float] = []
        var idx: [Int32] = []
        var fids: [Int32] = []
        func halfWidth(_ x: Double) -> Float { Float(6 * (1 - x / 40)) }
        for s in 0...strips {
            let x = Float(s) * 40 / Float(strips)
            let h = halfWidth(Double(x))
            v += [x, -h, 0, x, h, 0]
        }
        for s in 0..<strips {
            let a = Int32(s * 2), b = a + 1, c = a + 2, d = a + 3
            idx += [a, b, c, b, d, c]
            fids += [0, 0]
        }
        return ViewerMesh(vertices: v, indices: idx, faceIDs: fids,
                          faceGeometry: [StepFaceGeometry(kind: .plane,
                                                          planeNormal: SIMD3(0, 0, 1))])
    }

    /// ★ EVERY COLUMN SPANS A COMPARABLE LENGTH — the measure is ARC, not area.
    ///
    /// ★ THIS TEST USED TO ASSERT EQUAL AREA, and that was my invention rather than
    /// the requirement. Measured on his own part, three columns by area already gave
    /// shares of 0.31 / 0.35 / 0.34 — the areas were equal and the pieces still
    /// looked wrong, because on a strip whose width varies the area balance is
    /// nowhere near the length balance. "Equally spaced/distant pieces" is length.
    ///
    /// On a TAPER the two genuinely disagree: equal length gives the narrow end less
    /// material (11% of the area here) and that is correct — it is the same length
    /// of strip, and it is what an even pattern looks like.
    func testEveryColumnSpansAComparableLength() throws {
        let m = tessellatedWedge()
        let frame = FaceRegionGeometry.frame(members: [0], in: m)
        XCTAssertTrue(frame.valid)

        let cells = SurfacePatternAxis.areaCells(face: 0, frame: frame,
                                                 columns: 3, rows: 1, in: m)
        XCTAssertEqual(cells.count, 3)

        // ★ `drawn`, NOT `cuts`. A cell's cuts include the LATERAL BOUNDS that
        // confine it to its own stretch of the strip; only `drawn` is the subset
        // that actually separates two pieces.
        var ts = cells.flatMap { c in
            c.drawnCuts.map { simd_dot($0.point - frame.origin, frame.u) }
        }.sorted()
        ts = Array(Set(ts.map { ($0 * 1e6).rounded() / 1e6 })).sorted()
        XCTAssertEqual(ts.count, 2, "three columns, two dividers")

        let span = frame.uHi - frame.uLo
        let first = ts[0] - frame.uLo
        let middle = ts[1] - ts[0]
        let last = frame.uHi - ts[1]
        for (name, len) in [("first", first), ("middle", middle), ("last", last)] {
            XCTAssertEqual(len / span, 1.0 / 3, accuracy: 0.08,
                           "★ the \(name) column spans a third of the length — "
                           + "\(Int(len / span * 100))%")
        }
    }

    /// ★ AND THE NEGATIVE CONTROL: the old even-parameter division really does
    /// starve a column on this face, so the test above is not passing vacuously.
    func testEvenParameterDivisionStarvesTheTipColumn() {
        let m = tessellatedWedge()
        let frame = FaceRegionGeometry.frame(members: [0], in: m)
        let even = FaceRegionGeometry.gridSplitCells(frame, n: 3, m: 1)
        let samples = SurfacePatternAxis.areaSamples(face: 0, frame: frame, in: m)
        let total = samples.reduce(0.0) { $0 + $1.area }

        let shares = even.map { c in
            samples.filter { s in
                let p = frame.origin + frame.u * s.u + frame.v * s.v
                return FaceRegionGeometry.inside(p, c.cuts)
            }.reduce(0.0) { $0 + $1.area } / total
        }
        // Even PARAMETER steps on this wedge do give equal lengths (its centreline
        // is straight), so the interesting failure is area — recorded to show the
        // two measures genuinely diverge here and the choice is a real one.
        XCTAssertLessThan(shares.min() ?? 1, 0.15,
                          "on a taper the even-length grid gives the tip column "
                          + "little MATERIAL — the deliberate trade for equal spacing")
    }

    /// A rectangle divides the same either way: the two ideas only come apart when
    /// the face is not uniform, which is why this went unnoticed.
    func testOnARectangleAreaAndParameterAgree() {
        let v: [Float] = [0, 0, 0, 40, 0, 0, 40, 6, 0, 0, 6, 0]
        let m = ViewerMesh(vertices: v, indices: [0, 1, 2, 0, 2, 3], faceIDs: [0, 0],
                           faceGeometry: [StepFaceGeometry(kind: .plane,
                                                           planeNormal: SIMD3(0, 0, 1))])
        let frame = FaceRegionGeometry.frame(members: [0], in: m)
        let cells = SurfacePatternAxis.areaCells(face: 0, frame: frame,
                                                 columns: 2, rows: 1, in: m)
        XCTAssertEqual(cells.count, 2)
    }

    // ── the rotation, folded ───────────────────────────────────────────────

    /// ★ −405° IS −45°. A grid is symmetric every 90°, so an angle outside one
    /// quarter-turn names a grid already reachable inside it — and reads as a bug.
    func testTheRotationFoldsIntoAQuarterTurn() {
        XCTAssertEqual(SurfacePatternAxis.foldAngle(-405), -45, accuracy: 1e-9)
        XCTAssertEqual(SurfacePatternAxis.foldAngle(0), 0, accuracy: 1e-9)
        XCTAssertEqual(SurfacePatternAxis.foldAngle(90), 0, accuracy: 1e-9)
        XCTAssertEqual(SurfacePatternAxis.foldAngle(100), 10, accuracy: 1e-9)
        XCTAssertEqual(SurfacePatternAxis.foldAngle(-100), -10, accuracy: 1e-9)
        for a in stride(from: -720.0, through: 720.0, by: 7.5) {
            let f = SurfacePatternAxis.foldAngle(a)
            XCTAssertGreaterThanOrEqual(f, -45)
            XCTAssertLessThan(f, 45, "always inside one quarter-turn")
        }
    }
}



// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ THE UNION COMMITS — AND TAKES NOTHING IT WAS NOT GIVEN

@MainActor
final class SurfaceUnionPartsTests: XCTestCase {

    private func project() -> ProjectModel {
        var v: [Float] = []
        func V(_ x: Float, _ y: Float, _ z: Float) { v += [x, y, z] }
        V(0, 0, 0); V(10, 0, 0); V(10, 10, 0); V(0, 10, 0)
        V(0, 0, 5); V(10, 0, 5); V(10, 10, 5); V(0, 10, 5)
        V(0, 0, 9); V(10, 0, 9); V(10, 10, 9); V(0, 10, 9)
        let mesh = ViewerMesh(vertices: v,
                              indices: [0, 1, 2, 0, 2, 3,
                                        4, 5, 6, 4, 6, 7,
                                        8, 9, 10, 8, 10, 11],
                              faceIDs: [0, 0, 1, 1, 2, 2],
                              faceGeometry: (0..<3).map { _ in
                                  StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1))
                              })
        let p = ProjectModel(id: UUID(), name: "U", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = mesh
        p.selection.addGroup()
        p.selection.pickFaces([0, 1, 2])
        return p
    }

    /// ★ TWO ORDINARY FACES COMBINE. No cut anywhere — "We need to be able to
    /// combine faces that have been automatically made."
    func testTwoWholeFacesCombine() throws {
        let p = project()
        let a = try XCTUnwrap(p.surfaceEnsureRegion(for: 1))
        let b = try XCTUnwrap(p.surfaceEnsureRegion(for: 2))
        var u = SurfaceUnion()
        u.toggle(a); u.toggle(b)
        XCTAssertTrue(u.canCommit)

        let rid = try XCTUnwrap(p.commitSurfaceUnion(u))
        XCTAssertEqual(p.surfaceResolvedFaces(rid), [1, 2])
    }

    /// ★ AND IT TAKES NOTHING ELSE. One half of a cut face + a whole face resolves
    /// to exactly those two; the sibling half is NOT dragged in. The maintainer's
    /// rule, in terms: "DO NOT EVER JOIN ANY PIECES WITHOUT A PERSON ACTIVELY
    /// SELECTING THEM!"
    func testAUnionTakesOnlyThePiecesItWasGiven() throws {
        let p = project()
        let halves = p.commitSurfaceCut(
            SurfaceCut(point: SIMD3(5, 5, 0), normal: SIMD3(1, 0, 0),
                       faceID: 0, faceNormal: SIMD3(0, 0, 1)))
        XCTAssertEqual(halves.count, 2)
        let other = try XCTUnwrap(p.surfaceEnsureRegion(for: 1))

        var u = SurfaceUnion()
        u.toggle(halves[0]); u.toggle(other)
        let rid = try XCTUnwrap(p.commitSurfaceUnion(u))

        let leaves = Set(p.faceRegions.resolvedLeaves(rid))
        XCTAssertEqual(leaves, Set([halves[0], other]),
                       "★ exactly the two pieces tapped")
        XCTAssertFalse(leaves.contains(halves[1]),
                       "★ the sibling half was NOT taken — it was never selected")
        XCTAssertNotNil(p.faceRegions.region(halves[1]),
                        "and it still exists on its own; nothing was dissolved")
    }

    /// The parts become the union's children, so one operation adds ONE row.
    func testThePartsFoldUnderTheUnion() throws {
        let p = project()
        let a = try XCTUnwrap(p.surfaceEnsureRegion(for: 1))
        let b = try XCTUnwrap(p.surfaceEnsureRegion(for: 2))
        var u = SurfaceUnion(); u.toggle(a); u.toggle(b)
        let rid = try XCTUnwrap(p.commitSurfaceUnion(u))

        XCTAssertEqual(Set(p.faceRegions.children(of: rid).map(\.id)), Set([a, b]))
        XCTAssertFalse(p.faceRegions.roots.contains { $0.id == a },
                       "a part is no longer a root row of its own")
    }

    /// ★ BYTE-IDENTITY HOLDS: `parts` is omitted when empty, so a project that
    /// never made a union encodes exactly as it did before this field existed.
    func testAnUnusedPartsListIsNotEncoded() throws {
        var regions = FaceRegionModel()
        _ = regions.union(faces: [0], named: "plain")
        let json = try XCTUnwrap(String(data: try JSONEncoder().encode(regions),
                                        encoding: .utf8))
        XCTAssertFalse(json.contains("parts"),
                       "★ no `parts` key on a project that never made a union")

        _ = regions.union(faces: [1], named: "b")
        let ids = regions.regions.map(\.id)
        _ = regions.unionOfParts(ids, named: "u")
        let back = try JSONDecoder().decode(
            FaceRegionModel.self, from: try JSONEncoder().encode(regions))
        XCTAssertEqual(back.regions.first { $0.isUnionOfParts }?.parts, ids,
                       "and a union round-trips")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ §6(c) — "THE ONES LIKE THIS ONE"
//
// ★ MEASURED ON HIS OWN PART BEFORE A CONTROL WAS WIRED TO IT. `M2_verticalStand`
// has 78 faces: 36 planes, 12 cylinders, 30 other. Matching on KIND ALONE — what
// the first draft did — gave:
//
//     biggest plane    -> 36 faces (46% of the model)
//     biggest "other"  -> 30 faces (38%)
//     biggest cylinder -> 12 (every cylinder, any radius)
//     a small bore     -> 19 (every small feature)
//
// "Every plane" is not what a person means by "the ones like this". With kind AND
// a size band, and bores matched by RADIUS ahead of the blend rule:
//
//     biggest plane    -> 4        biggest cylinder -> 1
//     biggest "other"  -> 1        a small bore     -> 6  (the holes of its size)

@MainActor
final class SurfaceSimilarTests: XCTestCase {

    /// Four faces: two ~equal planes, one much larger plane, one tiny plane.
    private func project() -> ProjectModel {
        var v: [Float] = []
        var idx: [Int32] = []
        var fids: [Int32] = []
        func quad(_ w: Float, _ h: Float, _ z: Float, _ face: Int32) {
            let b = Int32(v.count / 3)
            v += [0, 0, z, w, 0, z, w, h, z, 0, h, z]
            idx += [b, b + 1, b + 2, b, b + 2, b + 3]
            fids += [face, face]
        }
        quad(10, 10, 0, 0)      // 100 mm²
        quad(10, 11, 1, 1)      // 110 mm² — like face 0
        quad(60, 60, 2, 2)      // 3600 mm² — much bigger
        quad(1, 1, 3, 3)        // 1 mm² — tiny
        let mesh = ViewerMesh(vertices: v, indices: idx, faceIDs: fids,
                              faceGeometry: (0..<4).map { _ in
                                  StepFaceGeometry(kind: .plane,
                                                   planeNormal: SIMD3(0, 0, 1))
                              })
        let p = ProjectModel(id: UUID(), name: "S", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = mesh
        return p
    }

    /// ★ SIMILAR MEANS SAME KIND *AND* COMPARABLE SIZE. Kind alone would sweep in
    /// the 3600 mm² face along with the two 100 mm² ones.
    func testSimilarIsKindAndSizeNotKindAlone() throws {
        let p = project()
        let f = try XCTUnwrap(p.surfaceSimilarFilter(to: 0))
        let matched = Set(FaceRegionGeometry.match(f, in: p.viewerMesh!))

        XCTAssertTrue(matched.contains(0), "itself")
        XCTAssertTrue(matched.contains(1), "and the face of comparable size")
        XCTAssertFalse(matched.contains(2),
                       "★ NOT the 36x larger face — 'every plane' is not 'similar'")
        XCTAssertFalse(matched.contains(3), "nor the tiny one")
    }

    /// ★ A BORE MATCHES BY RADIUS, AND THAT RULE COMES FIRST. Measured: a 9 mm²
    /// cylinder fell through the blend branch and matched 19 faces — every small
    /// feature on the part — when what was wanted was the other holes of its size.
    func testABoreMatchesByRadiusAheadOfTheBlendRule() throws {
        var v: [Float] = []
        var idx: [Int32] = []
        var fids: [Int32] = []
        for i in 0..<3 {
            let b = Int32(v.count / 3)
            let z = Float(i)
            v += [0, 0, z, 1, 0, z, 1, 1, z, 0, 1, z]
            idx += [b, b + 1, b + 2, b, b + 2, b + 3]
            fids += [Int32(i), Int32(i)]
        }
        // Faces 0 and 1 are 3 mm bores; face 2 is a 12 mm one.
        let mesh = ViewerMesh(vertices: v, indices: idx, faceIDs: fids,
                              faceGeometry: [
                                StepFaceGeometry(kind: .cylinder, cylinderRadiusMM: 3,
                                                 axisPoint: .zero, axisDir: SIMD3(0, 0, 1)),
                                StepFaceGeometry(kind: .cylinder, cylinderRadiusMM: 3,
                                                 axisPoint: .zero, axisDir: SIMD3(0, 0, 1)),
                                StepFaceGeometry(kind: .cylinder, cylinderRadiusMM: 12,
                                                 axisPoint: .zero, axisDir: SIMD3(0, 0, 1)),
                              ])
        let p = ProjectModel(id: UUID(), name: "B", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = mesh

        let f = try XCTUnwrap(p.surfaceSimilarFilter(to: 0))
        XCTAssertEqual(f.kind, "cylinder")
        XCTAssertEqual(f.cylinderRadiusMM, 3, accuracy: 1e-6,
                       "★ the RADIUS is the rule — 'all the M3 holes', not "
                       + "'every cylinder'")
        let matched = Set(FaceRegionGeometry.match(f, in: mesh))
        XCTAssertTrue(matched.contains(0))
        XCTAssertTrue(matched.contains(1), "the other bore of that size")
        XCTAssertFalse(matched.contains(2), "and not the 12 mm one")
    }

    /// ★ THE RULE IS STORED, NOT THE MATCHES. PR 331 measured why: a stored id list
    /// is "a stale id list wearing a filter's clothes", and a simulated CAD edit
    /// grew a 24-face union to 32. A committed similar-selection carries its FILTER.
    func testCommittingStoresTheRuleAndNotTheMatchedIDs() throws {
        let p = project()
        p.selection.addGroup()
        p.selection.pickFaces([0, 1])
        let f = try XCTUnwrap(p.surfaceSimilarFilter(to: 0))
        let rid = try XCTUnwrap(p.commitSurfaceUnion(f, named: "Like face 0"))

        let r = try XCTUnwrap(p.faceRegions.region(rid))
        XCTAssertTrue(r.filter.any, "★ the FILTER defines it")
        XCTAssertTrue(r.add.isEmpty,
                      "★ and the matches are NOT copied in — the filter IS the "
                      + "membership, re-evaluated on every import")
        XCTAssertEqual(r.filterMatchedAtAuthor, 2,
                       "what it matched when authored, so drift is REPORTED")
    }

    /// A face with nothing like it yields a rule that matches only itself, and the
    /// confirm has nothing to combine.
    func testAFaceWithNothingLikeItMatchesOnlyItself() throws {
        let p = project()
        let f = try XCTUnwrap(p.surfaceSimilarFilter(to: 2))
        XCTAssertEqual(p.surfaceMatchCount(f), 1)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ A PICKED WHOLE FACE MUST LIGHT
//
// Maintainer, 2026-08-15: "When attempting to select/union/cut any face, the blue
// selection doesn't happen. The blue selection seems to only happen to *CUT*
// pieces."

final class SurfaceWholeFaceHighlightTests: XCTestCase {

    private func mesh() -> ViewerMesh {
        var v: [Float] = []
        func V(_ x: Float, _ y: Float, _ z: Float) { v += [x, y, z] }
        V(0, 0, 0); V(10, 0, 0); V(10, 10, 0); V(0, 10, 0)
        V(0, 0, 5); V(10, 0, 5); V(10, 10, 5); V(0, 10, 5)
        return ViewerMesh(vertices: v,
                          indices: [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7],
                          faceIDs: [0, 0, 1, 1],
                          faceGeometry: [
                            StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1)),
                            StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1)),
                          ])
    }

    /// ★ PICKED, NOT TESTED, THEREFORE LIT. A union of ordinary faces names NO
    /// fragment-tested faces — there are no half-spaces to test. The picked face
    /// must carry the SELECTED colour outright.
    ///
    /// The old code inferred the tested set when none was named, marked the picked
    /// face as tested, and drew it in the neutral wash — while the shader's pick
    /// block never ran because there were no chains. A selection that lit only for
    /// cut pieces.
    func testAPickedWholeFaceCarriesTheSelectedColour() {
        let m = mesh()
        let b = SurfaceTint.buffer(mesh: m, groupedFaces: [0, 1],
                                   regions: FaceRegionModel(), selected: nil,
                                   picked: [1], fragmentTested: [])
        let sel = SurfaceTint.colour(.selected)
        // Face 1 is draw vertices 6..11.
        for v in 6..<12 {
            XCTAssertEqual(b[v * 8], sel.x, accuracy: 1e-6, "picked face is SELECTED")
            XCTAssertEqual(b[v * 8 + 3], sel.w, accuracy: 1e-6)
            XCTAssertEqual(b[v * 8 + 4], 0,
                           "★ and NOT flagged for the fragment test, which would "
                           + "hand it to a shader that has nothing to test it with")
        }
        // Face 0 stays the selectable wash.
        let grouped = SurfaceTint.colour(.grouped)
        for v in 0..<6 {
            XCTAssertEqual(b[v * 8 + 3], grouped.w, accuracy: 1e-6)
        }
    }

    /// A picked whole face AND a tested cut face coexist: one is coloured directly,
    /// the other is handed to the shader.
    func testAWholeFaceAndACutFaceUseTheirOwnMechanisms() {
        let m = mesh()
        var regions = FaceRegionModel()
        let parent = regions.union(faces: [0], named: "f0")
        let kids = regions.splitManual(parent, point: SIMD3(5, 5, 0),
                                        normal: SIMD3(1, 0, 0))
        let b = SurfaceTint.buffer(mesh: m, groupedFaces: [0, 1],
                                   regions: regions, selected: kids[0],
                                   picked: [1], fragmentTested: [0])
        for v in 0..<6 { XCTAssertEqual(b[v * 8 + 4], 1, "the cut face is tested") }
        for v in 6..<12 { XCTAssertEqual(b[v * 8 + 4], 0, "the whole face is not") }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ SIX PIECES MEANS SIX DISTINCT PIECES
//
// Maintainer, 2026-08-15: "I attempted to cut this face into *SIX* equal pieces.
// It turned it into *THREE* … AND THEN! I tried tapping on the middle section and
// it selected *both* the furthest left and the middle section - because there is
// no real yellow cut line between the other two."

final class SurfaceGridDistinctnessTests: XCTestCase {

    /// A long strip, finely tessellated, so a 6-way split is entirely reasonable.
    private func strip(strips: Int = 60) -> ViewerMesh {
        var v: [Float] = []
        var idx: [Int32] = []
        var fids: [Int32] = []
        for s in 0...strips {
            let x = Float(s) * 60 / Float(strips)
            v += [x, 0, 0, x, 8, 0]
        }
        for s in 0..<strips {
            let a = Int32(s * 2), b = a + 1, c = a + 2, d = a + 3
            idx += [a, b, c, b, d, c]
            fids += [0, 0]
        }
        return ViewerMesh(vertices: v, indices: idx, faceIDs: fids,
                          faceGeometry: [StepFaceGeometry(kind: .plane,
                                                          planeNormal: SIMD3(0, 0, 1))])
    }

    /// ★ EVERY DIVIDER IS DISTINCT AND INSIDE THE FACE. Two identical dividers make
    /// coincident cells: no line between them, and a tap lands in both.
    func testTheDividersAreStrictlyIncreasingAndInterior() {
        let m = strip()
        let frame = FaceRegionGeometry.frame(members: [0], in: m)
        let samples = SurfacePatternAxis.areaSamples(face: 0, frame: frame, in: m)
        let cuts = SurfacePatternAxis.quantiles(samples.map { ($0.u, $0.area) },
                                                parts: 6,
                                                lo: frame.uLo, hi: frame.uHi)
        XCTAssertEqual(cuts.count, 5, "six pieces need five dividers")
        for i in 1..<cuts.count {
            XCTAssertGreaterThan(cuts[i], cuts[i - 1],
                                 "★ strictly increasing — equal dividers make "
                                 + "coincident cells with no line between them")
        }
        XCTAssertGreaterThan(cuts.first!, frame.uLo)
        XCTAssertLessThan(cuts.last!, frame.uHi)
    }

    /// ★ SIX ASKED FOR, SIX DELIVERED — and each is a DIFFERENT half-space set, so
    /// a tap can only ever land in one.
    func testSixPiecesAreSixDistinctCells() {
        let m = strip()
        let frame = FaceRegionGeometry.frame(members: [0], in: m)
        let cells = SurfacePatternAxis.areaCells(face: 0, frame: frame,
                                                 columns: 6, rows: 1, in: m)
        XCTAssertEqual(cells.count, 6)

        // Sample across the strip: every point lands in exactly ONE cell.
        for k in 0..<60 {
            let u = frame.uLo + (frame.uHi - frame.uLo) * (Double(k) + 0.5) / 60
            let p = frame.origin + frame.u * u
            let hits = cells.filter { FaceRegionGeometry.inside(p, $0.cuts) }.count
            XCTAssertEqual(hits, 1,
                           "★ a point belongs to exactly one piece — \(hits) at u=\(u) "
                           + "means cells coincide and a tap selects two")
        }
    }

    /// ★ WHEN DIVIDERS WOULD COINCIDE, NOTHING IS RETURNED — rather than silently
    /// delivering fewer pieces than were set, which is how six became three.
    ///
    /// This is the GEOMETRY floor: dividers closer than a thousandth of the face
    /// leave no surface between them. Refusing an over-fine grid on PRINTABILITY
    /// grounds is a different question, answered downstream by the sliver guard
    /// against `kRegionSliverFloorVoxels` — this layer only refuses the impossible.
    func testCoincidingDividersRefuseRatherThanUnderDeliver() {
        let m = strip()
        let frame = FaceRegionGeometry.frame(members: [0], in: m)
        let cells = SurfacePatternAxis.areaCells(face: 0, frame: frame,
                                                 columns: 5000, rows: 1, in: m)
        XCTAssertTrue(cells.isEmpty,
                      "★ refuse, so the panel can say why — under-delivering is how "
                      + "six pieces silently became three")
    }

    /// A grid fine enough to be geometrically fine but too fine to PRINT is the
    /// sliver guard's call, and it still produces distinct cells here.
    func testAFineButPossibleGridStillProducesDistinctCells() {
        let m = strip()
        let frame = FaceRegionGeometry.frame(members: [0], in: m)
        let cells = SurfacePatternAxis.areaCells(face: 0, frame: frame,
                                                 columns: 12, rows: 1, in: m)
        XCTAssertEqual(cells.count, 12)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ SURFACE EDITS ARE UNDOABLE
//
// Maintainer, 2026-08-15: "Please make undo and redo work in the surface stage.
// Including the two finger double tap and three finger double tap."

@MainActor
final class SurfaceUndoTests: XCTestCase {

    private func project() -> ProjectModel {
        let v: [Float] = [0, 0, 0, 10, 0, 0, 10, 10, 0, 0, 10, 0]
        let mesh = ViewerMesh(vertices: v, indices: [0, 1, 2, 0, 2, 3], faceIDs: [0, 0],
                              faceGeometry: [StepFaceGeometry(kind: .plane,
                                                              planeNormal: SIMD3(0, 0, 1))])
        let p = ProjectModel(id: UUID(), name: "U", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = mesh
        p.selection.addGroup()
        p.selection.pickFaces([0])
        return p
    }

    /// ★ THE REGION LAYER IS IN THE UNDO SLICE. It was not — `EditSnapshot` carried
    /// selection, force, design box, paint and lattice, and NOT `faceRegions`. So
    /// undo saw no change to reverse after a cut: the gestures and the header button
    /// were wired correctly the whole time and had nothing to act on.
    func testTheSnapshotCarriesTheRegionLayer() {
        let p = project()
        let before = p.editSnapshot
        p.commitSurfaceCut(SurfaceCut(point: SIMD3(5, 5, 0), normal: SIMD3(1, 0, 0),
                                      faceID: 0, faceNormal: SIMD3(0, 0, 1)))
        XCTAssertNotEqual(p.editSnapshot, before,
                          "★ a cut CHANGES the snapshot — otherwise undo has "
                          + "nothing to reverse and silently does nothing")
        XCTAssertTrue(p.canUndoNow, "and undo is offered")
    }

    /// ★ AND UNDO REVERSES IT. Round-trip through the same history every other edit
    /// uses, which is what the two-finger gesture drives.
    func testUndoingACutRestoresTheUncutRegions() {
        let p = project()
        let before = p.faceRegions.regions.count
        p.commitSurfaceCut(SurfaceCut(point: SIMD3(5, 5, 0), normal: SIMD3(1, 0, 0),
                                      faceID: 0, faceNormal: SIMD3(0, 0, 1)))
        XCTAssertGreaterThan(p.faceRegions.regions.count, before)

        p.performUndo()
        XCTAssertEqual(p.faceRegions.regions.count, before,
                       "★ the cut is gone after undo")

        p.performRedo()
        XCTAssertGreaterThan(p.faceRegions.regions.count, before,
                             "and redo puts it back")
    }

    /// A union undoes through the same path.
    func testUndoingAUnionRestoresTheSeparatePieces() throws {
        let p = project()
        let halves = p.commitSurfaceCut(
            SurfaceCut(point: SIMD3(5, 5, 0), normal: SIMD3(1, 0, 0),
                       faceID: 0, faceNormal: SIMD3(0, 0, 1)))
        XCTAssertEqual(halves.count, 2)
        var u = SurfaceUnion(); u.toggle(halves[0]); u.toggle(halves[1])
        let rid = try XCTUnwrap(p.commitSurfaceUnion(u))
        XCTAssertNotNil(p.faceRegions.region(rid))

        p.performUndo()
        XCTAssertNil(p.faceRegions.region(rid), "★ the union is gone")
        XCTAssertNotNil(p.faceRegions.region(halves[0]),
                        "and the pieces it combined are back on their own")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ THREE THINGS THAT LOOKED WRONG ON DEVICE
//
// Maintainer, 2026-08-15: "The pattern doesn't go to the selected face, now." /
// "when you try to select the full unioned face the cut line shows up again" /
// "Select doesn't make any face blue - it only highlights cut faces."

@MainActor
final class SurfaceFinalisationTests: XCTestCase {

    private func project() -> (ProjectModel, ViewerMesh) {
        var v: [Float] = []
        func V(_ x: Float, _ y: Float, _ z: Float) { v += [x, y, z] }
        V(0, 0, 0); V(40, 0, 0); V(40, 10, 0); V(0, 10, 0)
        V(0, 0, 6); V(40, 0, 6); V(40, 10, 6); V(0, 10, 6)
        let mesh = ViewerMesh(vertices: v,
                              indices: [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7],
                              faceIDs: [0, 0, 1, 1],
                              faceGeometry: [
                                StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1)),
                                StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1)),
                              ])
        let p = ProjectModel(id: UUID(), name: "F", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = mesh
        p.selection.addGroup()
        p.selection.pickFaces([0, 1])
        return (p, mesh)
    }

    /// ★ A SELECTED WHOLE FACE IS BLUE. It has no half-spaces, so it never reached
    /// the cut classification and never reached the shader — it stayed the pale
    /// selectable wash however hard you tapped it.
    func testSelectingAWholeFaceMakesItSelected() throws {
        let (p, mesh) = project()
        let rid = try XCTUnwrap(p.surfaceEnsureRegion(for: 1))
        let s = SurfaceTint.states(mesh: mesh, groupedFaces: [0, 1],
                                   regions: p.faceRegions, selected: rid,
                                   fragmentTested: [])
        // Face 1 is draw vertices 6..11.
        XCTAssertEqual(Array(s[6..<12]), Array(repeating: .selected, count: 6),
                       "★ the selected whole face reads as SELECTED")
        XCTAssertEqual(Array(s[0..<6]), Array(repeating: .grouped, count: 6),
                       "and its neighbour stays the selectable wash")
    }

    /// ★ A UNION'S INTERNAL BOUNDARY STOPS BEING DRAWN. The parts still exist — a
    /// union takes only what it was given and dissolves nothing — but the line
    /// between them is no longer an edge of anything.
    func testAUnionsInternalCutLineIsNoLongerTraced() throws {
        let (p, mesh) = project()
        let halves = p.commitSurfaceCut(
            SurfaceCut(point: SIMD3(20, 5, 0), normal: SIMD3(1, 0, 0),
                       faceID: 0, faceNormal: SIMD3(0, 0, 1)))
        XCTAssertEqual(halves.count, 2)
        let before = SurfaceCutLines.committed(regions: p.faceRegions, in: mesh)
        XCTAssertGreaterThan(before.count, 0, "the cut is drawn while it is a cut")

        var u = SurfaceUnion(); u.toggle(halves[0]); u.toggle(halves[1])
        XCTAssertNotNil(p.commitSurfaceUnion(u))

        let after = SurfaceCutLines.committed(regions: p.faceRegions, in: mesh)
        XCTAssertEqual(after.count, 0,
                       "★ once combined, the boundary between the parts is not an "
                       + "edge — drawing it says the opposite of what happened")
        XCTAssertNotNil(p.faceRegions.region(halves[0]),
                        "and the parts still exist; nothing was dissolved")
    }

    /// ★ THE PATTERN DIVIDES THE PIECE THAT WAS TAPPED. Looked up instead of
    /// carried, the target becomes "the deepest region on this face" — one
    /// particular half, not necessarily the one under the finger.
    func testThePatternDividesThePieceItWasGiven() throws {
        let (p, _) = project()
        let halves = p.commitSurfaceCut(
            SurfaceCut(point: SIMD3(20, 5, 0), normal: SIMD3(1, 0, 0),
                       faceID: 0, faceNormal: SIMD3(0, 0, 1)))
        // The two halves are +x and −x of x = 20.
        let plusX = try XCTUnwrap(halves.first {
            FaceRegionGeometry.inside(SIMD3(30, 5, 0),
                                      p.faceRegions.region($0)?.cuts ?? [])
        })
        let minusX = try XCTUnwrap(halves.first { $0 != plusX })

        // Pattern the −x half explicitly.
        let a = try XCTUnwrap(p.surfacePatternPreview(face: 0, columns: 2, rows: 1,
                                                      piece: minusX))
        XCTAssertEqual(a.cells.count, 2)
        // Its divider must lie inside the −x half, not the +x one.
        let midpoints = a.cells.flatMap { $0.cuts.map(\.point.x) }
        XCTAssertTrue(midpoints.allSatisfy { $0 < 20 },
                      "★ the grid falls inside the piece it was given (x < 20), "
                      + "not on its sibling")

        let b = try XCTUnwrap(p.surfacePatternPreview(face: 0, columns: 2, rows: 1,
                                                      piece: plusX))
        XCTAssertTrue(b.cells.flatMap { $0.cuts.map(\.point.x) }.allSatisfy { $0 > 20 },
                      "and the other half's grid falls in the other half")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ THE GRID IS MEASURED, NOT SAMPLED
//
// Maintainer, 2026-08-15: "Pattern isn't going all the way across the face - even
// though it's on the right one."
//
// ★ THREE SAMPLING SCHEMES GOT THIS WRONG BEFORE IT WAS MEASURED PROPERLY:
//   * per-triangle CENTROID — lumps a triangle's mass at one point, so on a coarse
//     piece several quantiles fall inside one step and the dividers bunch;
//   * per-VERTEX — lumps the mass at the corners: on a rectangle both triangles sit
//     at ±20, the median computes as −20, and the grid refuses outright;
//   * filtering whole triangles by "is a point of it inside the piece" — a half
//     bounded at x = 20 may have vertices only at x = 0, so its extent collapses.
//
// The quantity actually wanted — how much of the piece lies left of a line — is
// exact and cheap: clip and measure. It is monotonic, so bisection finds each split.

final class SurfaceGridExactnessTests: XCTestCase {

    /// A plain 40 x 6 rectangle as two triangles: the case vertex-sampling failed.
    private func rect() -> ViewerMesh {
        let v: [Float] = [0, 0, 0, 40, 0, 0, 40, 6, 0, 0, 6, 0]
        return ViewerMesh(vertices: v, indices: [0, 1, 2, 0, 2, 3], faceIDs: [0, 0],
                          faceGeometry: [StepFaceGeometry(kind: .plane,
                                                          planeNormal: SIMD3(0, 0, 1))])
    }

    /// ★ HALF THE RECTANGLE IS HALF WAY ALONG IT. Two triangles only, so every
    /// sampling proxy got this wrong; measuring gets it exactly right.
    func testTheMedianOfARectangleIsItsMiddle() {
        let m = rect()
        let f = FaceRegionGeometry.frame(members: [0], in: m)
        let polys = SurfacePatternAxis.piecePolygons(face: 0, in: m, within: [])
        let total = polys.reduce(0.0) { $0 + SurfacePatternAxis.polygonArea($1) }
        XCTAssertEqual(total, 240, accuracy: 1e-6, "40 x 6")

        // Area below the frame's midpoint must be exactly half.
        let mid = (f.uLo + f.uHi) / 2
        let half = SurfacePatternAxis.areaBelow(polys, origin: f.origin,
                                             axis: f.u, below: mid)
        XCTAssertEqual(half, total / 2, accuracy: 1e-6,
                       "★ measured, not sampled — the middle really is the middle")
    }

    /// ★ AND THE DIVIDERS LAND WHERE THEY SHOULD, spanning the piece rather than
    /// bunching in a band.
    func testThreeColumnsAreEvenlySpacedOnARectangle() {
        let m = rect()
        let f = FaceRegionGeometry.frame(members: [0], in: m)
        let cells = SurfacePatternAxis.areaCells(face: 0, frame: f,
                                                 columns: 3, rows: 1, in: m)
        XCTAssertEqual(cells.count, 3)

        let polys = SurfacePatternAxis.piecePolygons(face: 0, in: m, within: [])
        let total = polys.reduce(0.0) { $0 + SurfacePatternAxis.polygonArea($1) }
        for c in cells {
            let area = polys.reduce(0.0) {
                $0 + SurfacePatternAxis.polygonArea(
                    SurfacePatternAxis.clipPolygon($1, to: c.cuts))
            }
            XCTAssertEqual(area / total, 1.0 / 3, accuracy: 0.02,
                           "★ each column holds a third of the piece — not a band "
                           + "at one end with the rest empty")
        }
    }

    /// Clipping a polygon to a half-space keeps the right part, exactly.
    func testClippingKeepsTheCorrectArea() {
        let square: [SIMD3<Double>] = [SIMD3(0, 0, 0), SIMD3(10, 0, 0),
                                       SIMD3(10, 10, 0), SIMD3(0, 10, 0)]
        XCTAssertEqual(SurfacePatternAxis.polygonArea(square), 100, accuracy: 1e-9)
        let half = SurfacePatternAxis.clipPolygon(
            square, to: [RegionCut(point: SIMD3(5, 0, 0), normal: SIMD3(1, 0, 0))])
        XCTAssertEqual(SurfacePatternAxis.polygonArea(half), 50, accuracy: 1e-9,
                       "half the square, to the +x side of x = 5")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ §6(c) — ISOLATE: ITS OWN FACE, DISCONNECTED FROM EVERYTHING
//
// Maintainer: "Make all the similar faces (even if it's a singular one) into its
// own face - disconnecting from every other face it is currently connected with."

@MainActor
final class SurfaceIsolateTests: XCTestCase {

    private func project() -> (ProjectModel, ViewerMesh) {
        var v: [Float] = []
        func V(_ x: Float, _ y: Float, _ z: Float) { v += [x, y, z] }
        for i in 0..<3 {
            let z = Float(i)
            V(0, 0, z); V(10, 0, z); V(10, 10, z); V(0, 10, z)
        }
        var idx: [Int32] = []
        var fids: [Int32] = []
        for i in 0..<3 {
            let b = Int32(i * 4)
            idx += [b, b + 1, b + 2, b, b + 2, b + 3]
            fids += [Int32(i), Int32(i)]
        }
        let mesh = ViewerMesh(vertices: v, indices: idx, faceIDs: fids,
                              faceGeometry: (0..<3).map { _ in
                                  StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1))
                              })
        let p = ProjectModel(id: UUID(), name: "I", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = mesh
        p.selection.addGroup()
        p.selection.pickFaces([0, 1, 2])
        return (p, mesh)
    }

    /// ★ THE ISOLATED FACES LEAVE EVERY REGION THAT HELD THEM. Making a new region
    /// is not enough on its own: the face would keep the role and depth of whatever
    /// else still contains it, and "its own face" would not be what happened.
    func testIsolatingTakesTheFacesOutOfAnExistingRegion() throws {
        let (p, mesh) = project()
        // A union of faces 0 and 1.
        let together = try XCTUnwrap(p.commitSurfaceUnion(faces: [0, 1]))
        XCTAssertEqual(p.latticeRegionMemberFaces(together), [0, 1])

        var f = RegionFilter(); f.kind = "plane"
        f.minAreaMM2 = 0; f.maxAreaMM2 = 0
        // Isolate face 1 explicitly.
        let rid = try XCTUnwrap(p.faceRegions.isolate(faces: [1], named: "just 1",
                                                      in: mesh))
        XCTAssertEqual(p.latticeRegionMemberFaces(rid), [1], "it has its own region")
        XCTAssertEqual(p.latticeRegionMemberFaces(together), [0],
                       "★ and it is GONE from the union that held it")
    }

    /// ★ A FILTER-DEFINED REGION IS CORRECTED BY HAND, not rewritten. PR 331 built
    /// `remove` for exactly this (§2c: "a heuristic that cannot be corrected by hand
    /// is worse than no heuristic") — the filter stays, the exception is recorded.
    func testIsolatingCorrectsAFilterDefinedRegionRatherThanBreakingIt() throws {
        let (p, mesh) = project()
        var filter = RegionFilter(); filter.kind = "plane"
        let all = try XCTUnwrap(p.commitSurfaceUnion(filter, named: "all planes"))
        XCTAssertEqual(p.latticeRegionMemberFaces(all).count, 3)

        _ = p.faceRegions.isolate(faces: [2], named: "just 2", in: mesh)
        let r = try XCTUnwrap(p.faceRegions.region(all))
        XCTAssertTrue(r.filter.any, "the filter still defines it")
        XCTAssertEqual(r.remove, [2], "★ with an explicit, correctable exception")
        XCTAssertEqual(p.latticeRegionMemberFaces(all), [0, 1])
    }

    /// ★ A REGION LEFT WITH NOTHING IS DISSOLVED — an empty region is a row that
    /// resolves to no surface.
    func testARegionEmptiedByIsolationIsDissolved() throws {
        let (p, mesh) = project()
        let only = try XCTUnwrap(p.surfaceEnsureRegion(for: 2))
        _ = p.faceRegions.isolate(faces: [2], named: "just 2", in: mesh)
        XCTAssertNil(p.faceRegions.region(only),
                     "★ the region that held nothing else is gone")
    }

    /// ★ ONE FACE IS A LEGITIMATE ISOLATION — it is how you pull a single face out
    /// of a union, which is why the control is enabled at a single match.
    func testIsolatingASingleFaceWorks() throws {
        let (p, mesh) = project()
        let rid = try XCTUnwrap(p.faceRegions.isolate(faces: [0], named: "one",
                                                       in: mesh))
        XCTAssertEqual(p.latticeRegionMemberFaces(rid), [0])
    }

    /// Isolating nothing does nothing.
    func testIsolatingNothingIsARefusal() {
        let (p, mesh) = project()
        XCTAssertNil(p.faceRegions.isolate(faces: [], named: "x", in: mesh))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ §7 — CUTS SQUARE TO A CURVED STRIP
//
// Maintainer, 2026-08-15: "Pattern now goes across the whole face but it isn't
// making multiple equally spaced/sized pieces on a curve. Works well on straight
// face."

final class SurfaceCurvedPatternTests: XCTestCase {

    /// A strip that bends through a quarter turn in the XY plane, constant width.
    private func curvedStrip(steps: Int = 48) -> ViewerMesh {
        var v: [Float] = []
        var idx: [Int32] = []
        var fids: [Int32] = []
        let radius = 40.0, halfWidth = 3.0
        for s in 0...steps {
            let t = Double(s) / Double(steps) * (.pi / 2)
            let c = SIMD2(cos(t), sin(t))
            let inner = c * (radius - halfWidth), outer = c * (radius + halfWidth)
            v += [Float(inner.x), Float(inner.y), 0, Float(outer.x), Float(outer.y), 0]
        }
        for s in 0..<steps {
            let a = Int32(s * 2), b = a + 1, c = a + 2, d = a + 3
            idx += [a, b, c, b, d, c]
            fids += [0, 0]
        }
        return ViewerMesh(vertices: v, indices: idx, faceIDs: fids,
                          faceGeometry: [StepFaceGeometry(kind: .plane,
                                                          planeNormal: SIMD3(0, 0, 1))])
    }

    /// ★ THE DIVIDERS FOLLOW THE BEND. Planes perpendicular to ONE global axis slice
    /// a curving strip obliquely, so the pieces look uneven however the material is
    /// shared. Each divider now faces along the centreline THERE, so the cuts stay
    /// square to the strip and the normals genuinely differ from one another.
    func testTheDividersTurnWithTheStrip() {
        let m = curvedStrip()
        let f = FaceRegionGeometry.frame(members: [0], in: m)
        let cells = SurfacePatternAxis.areaCells(face: 0, frame: f,
                                                 columns: 4, rows: 1, in: m)
        XCTAssertEqual(cells.count, 4)

        // Collect the distinct divider normals.
        var normals: [SIMD3<Double>] = []
        for c in cells {
            for cut in c.cuts {
                let n = simd_normalize(cut.normal)
                let nn = (n.x + n.y + n.z) < 0 ? -n : n
                if !normals.contains(where: { simd_length($0 - nn) < 1e-6 }) {
                    normals.append(nn)
                }
            }
        }
        XCTAssertGreaterThanOrEqual(normals.count, 3,
                                    "★ three interior dividers, each facing a "
                                    + "DIFFERENT way — a single global axis would "
                                    + "give one normal for all of them")

        // And no two are parallel: the strip really turns between them.
        for i in 0..<normals.count {
            for j in (i + 1)..<normals.count {
                XCTAssertLessThan(abs(simd_dot(normals[i], normals[j])), 0.999,
                                  "dividers \(i) and \(j) are not parallel")
            }
        }
    }

    /// ★ AND THE PIECES HOLD EQUAL MATERIAL — the bend fix must not undo the taper
    /// fix. Position is still the k/n split of AREA; only the orientation changed.
    func testEachPieceOfACurveHoldsAnEqualShare() {
        let m = curvedStrip()
        let f = FaceRegionGeometry.frame(members: [0], in: m)
        let cells = SurfacePatternAxis.areaCells(face: 0, frame: f,
                                                 columns: 4, rows: 1, in: m)
        let polys = SurfacePatternAxis.piecePolygons(face: 0, in: m, within: [])
        let total = polys.reduce(0.0) { $0 + SurfacePatternAxis.polygonArea($1) }

        for c in cells {
            let area = polys.reduce(0.0) {
                $0 + SurfacePatternAxis.polygonArea(
                    SurfacePatternAxis.clipPolygon($1, to: c.cuts))
            }
            XCTAssertEqual(area / total, 0.25, accuracy: 0.06,
                           "★ a quarter of the strip each, around the bend")
        }
    }

    /// On a STRAIGHT face the tangent is the axis, so this reduces to the plain
    /// area division — the case that already worked must be untouched.
    func testAStraightFaceStillGetsParallelDividers() {
        let v: [Float] = [0, 0, 0, 40, 0, 0, 40, 6, 0, 0, 6, 0]
        let m = ViewerMesh(vertices: v, indices: [0, 1, 2, 0, 2, 3], faceIDs: [0, 0],
                           faceGeometry: [StepFaceGeometry(kind: .plane,
                                                           planeNormal: SIMD3(0, 0, 1))])
        let f = FaceRegionGeometry.frame(members: [0], in: m)
        let cells = SurfacePatternAxis.areaCells(face: 0, frame: f,
                                                 columns: 3, rows: 1, in: m)
        XCTAssertEqual(cells.count, 3)
        let normals = cells.flatMap { $0.cuts.map { simd_normalize($0.normal) } }
        for n in normals {
            XCTAssertEqual(abs(simd_dot(n, f.u)), 1, accuracy: 1e-3,
                           "★ straight face: every divider is square to the axis")
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ §7 — A U-SHAPED STRIP IS WALKED, NOT SLICED
//
// Maintainer, 2026-08-15, reading his own screenshot correctly: "It looks like the
// two in the center are equal sized - and that maybe it's assuming the two end
// pieces wrap around and are the same piece? And then when I drop the pattern to 2
// columns it places the line at the far left side."
//
// ★ HE HAD IT EXACTLY RIGHT. Every earlier attempt parametrised the face by a plane
// sweeping a straight axis. On a U-shaped strip that plane cuts BOTH ARMS at once:
// the slab holds material from each, its centroid lands in the OPENING of the U
// where there is no surface, and the "centreline" is a path through empty space.
//
// Measured on his part before and after:
//     face 15   axis walk  16% / 48% / 36%     spine walk  0.34 / 0.67 of the arc
//     face 16   axis walk  22% / 42% / 36%     spine walk  0.33 / 0.68
// and the spine's arc/chord is 3.86 — it really does wrap round.

final class SurfaceRibbonSpineTests: XCTestCase {

    /// A U-shaped ribbon: down one arm, round the bend, up the other. Both arms lie
    /// close together in x, so any plane perpendicular to a straight axis cuts them
    /// both — the exact shape that defeated the axis walk.
    private func uStrip(steps: Int = 40) -> ViewerMesh {
        var v: [Float] = []
        var idx: [Int32] = []
        var fids: [Int32] = []
        let halfWidth = 2.0

        // Centreline: down x = -10, semicircle at the bottom, up x = +10.
        var spine: [SIMD2<Double>] = []
        for i in 0...steps { spine.append(SIMD2(-10, 40 - Double(i) / Double(steps) * 40)) }
        for i in 1...steps {
            let t = Double(i) / Double(steps) * Double.pi
            spine.append(SIMD2(-10 * cos(t), -10 * sin(t)))
        }
        for i in 1...steps { spine.append(SIMD2(10, Double(i) / Double(steps) * 40)) }

        for (i, c) in spine.enumerated() {
            // Offset across the local direction.
            let prev = spine[max(0, i - 1)], next = spine[min(spine.count - 1, i + 1)]
            var d = next - prev
            if simd_length(d) < 1e-9 { d = SIMD2(0, 1) }
            let n = simd_normalize(SIMD2(-d.y, d.x)) * halfWidth
            v += [Float(c.x - n.x), Float(c.y - n.y), 0,
                  Float(c.x + n.x), Float(c.y + n.y), 0]
        }
        for s in 0..<(spine.count - 1) {
            let a = Int32(s * 2), b = a + 1, c = a + 2, d = a + 3
            idx += [a, b, c, b, d, c]
            fids += [0, 0]
        }
        return ViewerMesh(vertices: v, indices: idx, faceIDs: fids,
                          faceGeometry: [StepFaceGeometry(kind: .plane,
                                                          planeNormal: SIMD3(0, 0, 1))])
    }

    /// ★ THE SPINE FOLLOWS THE U. Its arc is far longer than the straight distance
    /// between its ends — which is the property no axis sweep can represent.
    func testTheSpineWrapsRoundTheBend() throws {
        let m = uStrip()
        let spine = try XCTUnwrap(SurfacePatternAxis.ribbonSpine(face: 0, in: m,
                                                                 within: []))
        XCTAssertGreaterThan(spine.count, 20, "a real walk, not a few steps")

        var arc = 0.0
        for i in 1..<spine.count { arc += simd_length(spine[i] - spine[i - 1]) }
        let chord = simd_length(spine[spine.count - 1] - spine[0])
        XCTAssertGreaterThan(arc / max(chord, 1e-9), 2.0,
                             "★ the spine goes the long way round — the ends are "
                             + "near each other but the strip between them is not")
    }

    /// ★ AND THE DIVIDERS LAND AT EQUAL DISTANCE ALONG IT. This is the number the
    /// maintainer was reading off the screen: three columns must be thirds.
    func testThreeColumnsAreThirdsAlongTheStrip() throws {
        let m = uStrip()
        let spine = try XCTUnwrap(SurfacePatternAxis.ribbonSpine(face: 0, in: m,
                                                                 within: []))
        var cum: [Double] = [0]
        for i in 1..<spine.count {
            cum.append(cum[i - 1] + simd_length(spine[i] - spine[i - 1]))
        }
        let arc = cum[cum.count - 1]

        let cuts = SurfacePatternAxis.alongSpine(spine, parts: 3)
        XCTAssertEqual(cuts.count, 2)

        func fraction(of p: SIMD3<Double>) -> Double {
            var best = 0.0, bestD = Double.greatestFiniteMagnitude
            for i in spine.indices {
                let d = simd_length(spine[i] - p)
                if d < bestD { bestD = d; best = cum[i] / arc }
            }
            return best
        }
        XCTAssertEqual(fraction(of: cuts[0].point), 1.0 / 3, accuracy: 0.05)
        XCTAssertEqual(fraction(of: cuts[1].point), 2.0 / 3, accuracy: 0.05)
    }

    /// ★ TWO COLUMNS SPLIT IN THE MIDDLE OF THE STRIP — at the bottom of the U, not
    /// "at the far left side".
    func testTwoColumnsSplitAtTheMiddleOfTheStrip() throws {
        let m = uStrip()
        let spine = try XCTUnwrap(SurfacePatternAxis.ribbonSpine(face: 0, in: m,
                                                                 within: []))
        let cuts = SurfacePatternAxis.alongSpine(spine, parts: 2)
        XCTAssertEqual(cuts.count, 1)
        // Half way along a U that starts and ends at the top is the BOTTOM.
        XCTAssertLessThan(cuts[0].point.y, 0,
                          "★ the midpoint of the strip is round the bend, not at "
                          + "one end — y = \(cuts[0].point.y)")
        XCTAssertEqual(cuts[0].point.x, 0, accuracy: 3,
                       "and centred across the U's opening")
    }

    /// A broad patch has no spine to speak of, and says so — the axis walk is the
    /// better answer there and this must decline rather than invent one.
    func testABroadPatchHasNoSpine() {
        let v: [Float] = [0, 0, 0, 10, 0, 0, 10, 10, 0, 0, 10, 0]
        let m = ViewerMesh(vertices: v, indices: [0, 1, 2, 0, 2, 3], faceIDs: [0, 0],
                           faceGeometry: [StepFaceGeometry(kind: .plane,
                                                           planeNormal: SIMD3(0, 0, 1))])
        XCTAssertNil(SurfacePatternAxis.ribbonSpine(face: 0, in: m, within: []))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ WHAT REACHES THE LATTICE — NO OVERLAP
//
// Maintainer, 2026-08-15: "the cuts and unions and patterns and everything we do
// here needs to last until the lattice section. These faces *NEED* to be passed to
// the list of faces. There cannot be overlap. It can't have the original face and
// the other two cut faces from it. It needs to only bring in the cut faces. And
// same with a union; it can't pass along the 3 cut faces over, it needs to only
// pass along the singular union'ed face."

@MainActor
final class SurfaceHandoffTests: XCTestCase {

    private func project() -> ProjectModel {
        var v: [Float] = []
        func V(_ x: Float, _ y: Float, _ z: Float) { v += [x, y, z] }
        for i in 0..<3 {
            let z = Float(i) * 4
            V(0, 0, z); V(10, 0, z); V(10, 10, z); V(0, 10, z)
        }
        var idx: [Int32] = []
        var fids: [Int32] = []
        for i in 0..<3 {
            let b = Int32(i * 4)
            idx += [b, b + 1, b + 2, b, b + 2, b + 3]
            fids += [Int32(i), Int32(i)]
        }
        let mesh = ViewerMesh(vertices: v, indices: idx, faceIDs: fids,
                              faceGeometry: (0..<3).map { _ in
                                  StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1))
                              })
        let p = ProjectModel(id: UUID(), name: "H", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = mesh
        p.selection.addGroup()
        p.selection.pickFaces([0, 1, 2])
        return p
    }

    /// ★ A CUT PASSES ITS PIECES, NOT ITS PARENT. Both describe the same surface;
    /// emitting both gives it two roles and two depths and the run keeps one at
    /// random.
    func testACutPassesOnlyItsPieces() throws {
        let p = project()
        let halves = p.commitSurfaceCut(
            SurfaceCut(point: SIMD3(5, 5, 0), normal: SIMD3(1, 0, 0),
                       faceID: 0, faceNormal: SIMD3(0, 0, 1)))
        XCTAssertEqual(halves.count, 2)
        let parent = try XCTUnwrap(p.faceRegions.region(halves[0])?.parentID)

        let g = try XCTUnwrap(p.selection.groups.first)
        let effective = Set(p.surfaceEffectiveRegions(of: g))
        XCTAssertEqual(effective, Set(halves), "★ the two pieces…")
        XCTAssertFalse(effective.contains(parent), "★ …and NOT the face they came from")
    }

    /// ★ A UNION PASSES ITSELF, NOT ITS PARTS.
    func testAUnionPassesOnlyItself() throws {
        let p = project()
        let a = try XCTUnwrap(p.surfaceEnsureRegion(for: 1))
        let b = try XCTUnwrap(p.surfaceEnsureRegion(for: 2))
        var u = SurfaceUnion(); u.toggle(a); u.toggle(b)
        let rid = try XCTUnwrap(p.commitSurfaceUnion(u))

        let g = try XCTUnwrap(p.selection.groups.first)
        let effective = Set(p.surfaceEffectiveRegions(of: g))
        XCTAssertTrue(effective.contains(rid), "★ the union…")
        XCTAssertFalse(effective.contains(a), "★ …and NOT its parts")
        XCTAssertFalse(effective.contains(b))
    }

    /// ★ AND NO SURFACE IS DESCRIBED TWICE.
    ///
    /// ★ NOT "no face id appears twice" — that would be the wrong property, and
    /// asserting it failed for the right reason. The two halves of a cut BOTH live
    /// on the face they came from: they share its id and are disjoint halves of it.
    /// Nothing is duplicated there.
    ///
    /// What must never happen is an ANCESTOR being emitted alongside its
    /// descendants — the parent covers exactly the surface its children cover
    /// between them, so both together describe it twice, each with its own role and
    /// depth, and the run keeps whichever was written last.
    func testNoEffectiveRegionIsAnAncestorOfAnother() throws {
        let p = project()
        // Cut face 0, union faces 1 and 2 — both shapes at once.
        _ = p.commitSurfaceCut(SurfaceCut(point: SIMD3(5, 5, 0), normal: SIMD3(1, 0, 0),
                                          faceID: 0, faceNormal: SIMD3(0, 0, 1)))
        let a = try XCTUnwrap(p.surfaceEnsureRegion(for: 1))
        let b = try XCTUnwrap(p.surfaceEnsureRegion(for: 2))
        var u = SurfaceUnion(); u.toggle(a); u.toggle(b)
        _ = p.commitSurfaceUnion(u)

        let g = try XCTUnwrap(p.selection.groups.first)
        let effective = p.surfaceEffectiveRegions(of: g)
        XCTAssertFalse(effective.isEmpty)

        /// Every region above `id` in the tree — parents, and any union holding it.
        func ancestors(_ id: RegionID) -> Set<RegionID> {
            var out: Set<RegionID> = []
            var cur = id
            var guard_ = 0
            while guard_ < 32 {
                guard_ += 1
                if let parent = p.faceRegions.region(cur)?.parentID,
                   p.faceRegions.region(parent) != nil {
                    out.insert(parent); cur = parent; continue
                }
                break
            }
            for r in p.faceRegions.regions where r.parts.contains(id) { out.insert(r.id) }
            return out
        }
        for id in effective {
            let clash = ancestors(id).intersection(effective)
            XCTAssertTrue(clash.isEmpty,
                          "★ region \(id) is emitted alongside its ancestor(s) "
                          + "\(clash) — the same surface, described twice")
        }
    }

    /// An untouched group is unchanged: every region it holds is its own effective
    /// region, so a project that never used this stage emits exactly what it did.
    func testAnUntouchedGroupIsUnchanged() throws {
        let p = project()
        let r = try XCTUnwrap(p.surfaceEnsureRegion(for: 0))
        let g = try XCTUnwrap(p.selection.groups.first)
        XCTAssertEqual(p.surfaceEffectiveRegions(of: g), [r])
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ PIECES ARE FIRST-CLASS ON THE TOPOLOGY PAGE
//
// Maintainer, 2026-08-15: "I want to be able to go *back* to the TO page and
// deselect any face that I have cut up as its own piece, removing it from the
// Group. I would also like to be able to add it to another Group - these faces
// need to be selectable afterwards."

@MainActor
final class SurfacePieceReassignmentTests: XCTestCase {

    private func cutProject() -> (ProjectModel, [RegionID]) {
        let v: [Float] = [0, 0, 0, 10, 0, 0, 10, 10, 0, 0, 10, 0]
        let mesh = ViewerMesh(vertices: v, indices: [0, 1, 2, 0, 2, 3], faceIDs: [0, 0],
                              faceGeometry: [StepFaceGeometry(kind: .plane,
                                                              planeNormal: SIMD3(0, 0, 1))])
        let p = ProjectModel(id: UUID(), name: "R", material: "PLA",
                             process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = mesh
        p.selection.addGroup()
        p.selection.pickFaces([0])
        let halves = p.commitSurfaceCut(
            SurfaceCut(point: SIMD3(5, 5, 0), normal: SIMD3(1, 0, 0),
                       faceID: 0, faceNormal: SIMD3(0, 0, 1)))
        return (p, halves)
    }

    /// ★ ONE PIECE CAN LEAVE A GROUP WHILE ITS SIBLING STAYS. They are independent
    /// pieces now — that was the maintainer's own answer to the question.
    func testRemovingOnePieceLeavesItsSiblingInTheGroup() throws {
        let (p, halves) = cutProject()
        let gid = try XCTUnwrap(p.selection.groups.first?.id)
        p.selection.addRegions(halves, to: gid)
        // The cut also put the PARENT in the group — that is how a cut hands its
        // pieces on before either has been touched individually.
        XCTAssertTrue(Set(p.selection.groups[0].regionIDs).isSuperset(of: Set(halves)))

        p.selection.removeRegions([halves[0]])
        XCTAssertFalse(p.selection.groups[0].regionIDs.contains(halves[0]))
        XCTAssertTrue(p.selection.groups[0].regionIDs.contains(halves[1]),
                      "★ the sibling is untouched — independent pieces")
    }

    /// ★ A PIECE BELONGS TO EXACTLY ONE GROUP. Adding it to another moves it, so it
    /// can never be claimed twice — which would give one surface two roles.
    func testAddingAPieceToAnotherGroupMovesIt() throws {
        let (p, halves) = cutProject()
        let a = try XCTUnwrap(p.selection.groups.first?.id)
        p.selection.addRegions([halves[0]], to: a)

        p.selection.addGroup()
        let b = try XCTUnwrap(p.selection.groups.last?.id)
        XCTAssertNotEqual(a, b)

        // The move, as the tap performs it: remove everywhere, then add.
        p.selection.removeRegions([halves[0]])
        p.selection.addRegions([halves[0]], to: b)

        let inA = p.selection.groups.first { $0.id == a }?.regionIDs ?? []
        let inB = p.selection.groups.first { $0.id == b }?.regionIDs ?? []
        XCTAssertFalse(inA.contains(halves[0]), "★ gone from the first group")
        XCTAssertTrue(inB.contains(halves[0]), "★ and in the second")
    }

    /// ★ AND THE HAND-OFF FOLLOWS. A piece moved to another group is emitted under
    /// THAT group — the resolver reads the same membership the taps write.
    func testAMovedPieceIsEmittedUnderItsNewGroup() throws {
        let (p, halves) = cutProject()
        let a = try XCTUnwrap(p.selection.groups.first?.id)
        p.selection.addRegions(halves, to: a)
        p.selection.addGroup()
        let b = try XCTUnwrap(p.selection.groups.last?.id)

        p.selection.removeRegions([halves[1]])
        p.selection.addRegions([halves[1]], to: b)

        let ga = try XCTUnwrap(p.selection.groups.first { $0.id == a })
        let gb = try XCTUnwrap(p.selection.groups.first { $0.id == b })
        XCTAssertEqual(p.surfaceEffectiveRegions(of: ga), [halves[0]])
        XCTAssertEqual(p.surfaceEffectiveRegions(of: gb), [halves[1]],
                       "★ each group carries exactly the piece it holds")
    }
}
