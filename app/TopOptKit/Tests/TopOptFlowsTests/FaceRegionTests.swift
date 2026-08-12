// FaceRegionTests — the region layer, app side (task 2026-08-14-face-regions).
//
// THE FIXTURE is the same banded cube core's `test_face_region.cpp` uses, built
// here as a ViewerMesh: a 10 mm cube whose +x wall is split at z = 9 into a
// 90 mm² wall and a 10 mm² BAND, with the three crossing side faces
// re-triangulated so the mesh carries NO T-junctions. The band is small and
// touches four larger faces — the shape of the maintainer's seven 16-voxel blend
// faces (41-47) beside his 10,554-voxel wall.
//
// Its top face is additionally split into THREE COPLANAR strips, which is what
// makes the expand-to-neighbours bar measurable: one tap must return all three
// and must NOT cross onto the band.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class FaceRegionTests: XCTestCase {

    // MARK: - fixture

    /// Face ids: 0 bottom, 1/6/7 the three coplanar TOP strips, 2 y=0, 3 the +x
    /// wall below z=9, 4 y=10, 5 x=0, 8 the +x BAND.
    private func bandedCube() -> ViewerMesh {
        var v: [Float] = []
        func V(_ x: Float, _ y: Float, _ z: Float) { v += [x, y, z] }
        V(0, 0, 0); V(10, 0, 0); V(10, 10, 0); V(0, 10, 0)          // 0..3
        V(0, 0, 10); V(10, 0, 10); V(10, 10, 10); V(0, 10, 10)      // 4..7
        V(10, 0, 9); V(10, 10, 9); V(0, 0, 9); V(0, 10, 9)          // 8..11
        // Top-face strip seams at y = 3 and y = 7.
        V(0, 3, 10); V(10, 3, 10); V(0, 7, 10); V(10, 7, 10)        // 12..15

        var idx: [Int32] = []
        var faces: [Int32] = []
        func T(_ a: Int32, _ b: Int32, _ c: Int32, _ f: Int32) {
            idx += [a, b, c]
            faces.append(f)
        }
        T(0, 3, 2, 0); T(0, 2, 1, 0)                                 // bottom
        // TOP, three coplanar strips: y 0-3, 3-7, 7-10.
        T(4, 5, 13, 1); T(4, 13, 12, 1)
        T(12, 13, 15, 6); T(12, 15, 14, 6)
        T(14, 15, 6, 7); T(14, 6, 7, 7)
        T(0, 1, 8, 2); T(0, 8, 10, 2); T(10, 8, 5, 2); T(10, 5, 4, 2)
        T(1, 2, 9, 3); T(1, 9, 8, 3)
        T(2, 3, 11, 4); T(2, 11, 9, 4); T(9, 11, 7, 4); T(9, 7, 6, 4)
        T(3, 0, 10, 5); T(3, 10, 11, 5); T(11, 10, 4, 5); T(11, 4, 7, 5)
        T(8, 9, 6, 8); T(8, 6, 5, 8)                                 // the BAND

        let normals: [SIMD3<Double>] = [
            SIMD3(0, 0, -1), SIMD3(0, 0, 1), SIMD3(0, -1, 0), SIMD3(1, 0, 0),
            SIMD3(0, 1, 0), SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 0, 1),
            SIMD3(1, 0, 0),
        ]
        let geo = normals.map {
            StepFaceGeometry(kind: .plane, planeNormal: $0)
        }
        return ViewerMesh(vertices: v, indices: idx, faceIDs: faces, faceGeometry: geo)
    }

    /// The same fixture with the two +x faces DECLARED cylindrical about a shared
    /// y-axis — a union of blends around one bore.
    private func boredCube() -> ViewerMesh {
        let m = bandedCube()
        var geo = m.faceGeometry
        for f in [3, 8] {
            geo[f] = StepFaceGeometry(kind: .cylinder, cylinderRadiusMM: 5,
                                      axisPoint: SIMD3(10, 0, 4.5),
                                      axisDir: SIMD3(0, 1, 0))
        }
        return ViewerMesh(vertices: m.positions, indices: m.indices.map { Int32(bitPattern: $0) },
                          faceIDs: m.faceIDs, faceGeometry: geo)
    }

    // MARK: - §2(d) EXPAND TO NEIGHBOURS — the cheapest win in the task

    func testOneTapGrabsTheWholeCoplanarWall() {
        let mesh = bandedCube()
        // ★ ONE TAP on any top strip returns ALL THREE. That is the mechanism
        // that turns his 23-tap load group into one tap.
        XCTAssertEqual(FaceRegionGeometry.expandCoplanar(from: 1, in: mesh), [1, 6, 7])
        XCTAssertEqual(FaceRegionGeometry.expandCoplanar(from: 6, in: mesh), [1, 6, 7])
    }

    func testExpandDoesNotCrossOntoADifferentSurface() {
        let mesh = bandedCube()
        // The BAND faces +x; the top faces +z. A tap on the band must not walk
        // onto the top, and a tap on the wall must not swallow the band —
        // the over-selection of handoff 2026-07-25-tap-overselect.
        XCTAssertEqual(FaceRegionGeometry.expandCoplanar(from: 8, in: mesh), [3, 8],
                       "the band and the wall below it ARE coplanar (+x); nothing else joins")
        XCTAssertFalse(FaceRegionGeometry.expandCoplanar(from: 1, in: mesh).contains(8))
    }

    func testExpandSameKindWalksABoreAndStopsAtThePlanes() {
        let mesh = boredCube()
        XCTAssertEqual(FaceRegionGeometry.expandSameKind(from: 3, in: mesh), [3, 8],
                       "the bore's two cylindrical faces, and no plane")
    }

    // MARK: - §2(a) THE BLEND HEURISTIC, and the correction it encodes

    func testBlendFilterMatchesTheSmallFaceBetweenTwoLargerOnes() {
        let mesh = bandedCube()
        var f = RegionFilter.blend(maxAreaMM2: 20)
        XCTAssertEqual(FaceRegionGeometry.match(f, in: mesh), [8],
                       "small AND touching two larger faces — the band alone")
        // ★ THE CORRECTION: a `kind` filter is NOT the blend filter. Every face
        // on this part is a plane, so "kind == other" — the naive reading of
        // "fillets and chamfers" — matches NOTHING and would have missed the
        // chamfer entirely.
        f = RegionFilter()
        f.kind = "other"
        XCTAssertTrue(FaceRegionGeometry.match(f, in: mesh).isEmpty)
        f.kind = "plane"
        XCTAssertEqual(FaceRegionGeometry.match(f, in: mesh).count, 9,
                       "and 'plane' catches the WHOLE part — 9 of 9")
    }

    func testAnUnsetFilterMatchesNothing() {
        // Not "everything". A region that silently swallowed the whole part
        // would be the worst possible default.
        XCTAssertTrue(FaceRegionGeometry.match(RegionFilter(), in: bandedCube()).isEmpty)
    }

    func testRadiusSignatureGrabsEveryBoreOfThatSize() {
        let mesh = boredCube()
        XCTAssertEqual(FaceRegionGeometry.match(.bores(radiusMM: 5), in: mesh), [3, 8])
        XCTAssertTrue(FaceRegionGeometry.match(.bores(radiusMM: 2.5), in: mesh).isEmpty)
    }

    // MARK: - §3 UNION

    func testUnionIsOneRegionAndIsDissolvableBackToItsMembers() {
        let mesh = bandedCube()
        var model = FaceRegionModel()
        let id = model.union(faces: [3, 8], named: "blends")
        XCTAssertEqual(model.regions.count, 1)
        XCTAssertEqual(FaceRegionGeometry.members(of: model.region(id)!, in: mesh), [3, 8])
        let back = model.dissolve(id, resolvedMembers: [3, 8])
        XCTAssertEqual(back, [3, 8], "a union must be dissolvable back to its members")
        XCTAssertTrue(model.isEmpty)
    }

    func testHandCorrectionSurvivesTheFilter() {
        let mesh = bandedCube()
        var model = FaceRegionModel()
        let id = model.union(faces: [], named: "blends",
                             filter: .blend(maxAreaMM2: 20), matchedAtAuthor: 1)
        model.addFace(3, to: id)
        XCTAssertEqual(FaceRegionGeometry.members(of: model.region(id)!, in: mesh), [3, 8],
                       "a heuristic that cannot be corrected by hand is worse than none")
        model.removeFace(8, from: id)
        XCTAssertEqual(FaceRegionGeometry.members(of: model.region(id)!, in: mesh), [3])
    }

    // MARK: - §3(c) DRIFT — reported, never absorbed

    func testFilterDriftIsReportedAgainstTheAuthorCount() {
        let mesh = bandedCube()
        var model = FaceRegionModel()
        _ = model.union(faces: [], named: "blends",
                        filter: .blend(maxAreaMM2: 20), matchedAtAuthor: 3)
        let now = [model.regions[0].id: FaceRegionGeometry.match(model.regions[0].filter,
                                                                 in: mesh).count]
        let drift = model.drift(matchedNow: now)
        XCTAssertEqual(drift.count, 1)
        XCTAssertEqual(drift[0].then, 3)
        XCTAssertEqual(drift[0].now, 1)
    }

    func testNoAuthorCountMeansNoDriftClaim() {
        var model = FaceRegionModel()
        _ = model.union(faces: [3], named: "hand-picked")
        XCTAssertTrue(model.drift(matchedNow: [:]).isEmpty,
                      "a hand-picked union has no filter and makes no drift claim")
    }

    // MARK: - §4 SPLIT

    func testGridSplitPartitionsTheRegion() {
        let mesh = bandedCube()
        let members: [FaceID] = [3]
        let frame = FaceRegionGeometry.frame(members: members, in: mesh)
        XCTAssertTrue(frame.valid)
        XCTAssertFalse(frame.cylindrical, "a planar wall gets the PCA frame")
        let cells = FaceRegionGeometry.gridSplitCells(frame, n: 2, m: 2)
        XCTAssertEqual(cells.count, 4)
        // The AREAS are the exact figures (the voxel counts round). Every sample
        // must land in exactly one cell: nothing unassigned, nothing double-counted.
        let a = FaceRegionGeometry.cellAreas(members: members, in: mesh,
                                             cells: cells, spacingMM: 1)
        XCTAssertEqual(a.unassigned, 0, accuracy: 1e-9, "no sample falls outside every cell")
        XCTAssertEqual(a.perCell.reduce(0, +), a.total, accuracy: 1e-9,
                       "the cells partition the region — no gap, no overlap")
        let counts = FaceRegionGeometry.cellVoxelCounts(members: members, in: mesh,
                                                        cells: cells, spacingMM: 1)
        XCTAssertEqual(counts.reduce(0, +), 90, accuracy: 2,
                       "and the rounded voxel view lands on the 90-voxel wall")
    }

    func testCylindricalGridUsesTheSharedAxis() {
        let mesh = boredCube()
        let frame = FaceRegionGeometry.frame(members: [3, 8], in: mesh)
        XCTAssertTrue(frame.cylindrical, "shared-axis cylinders get cylindrical coordinates")
        XCTAssertEqual(abs(frame.axisDir.y), 1, accuracy: 1e-9)
        let cells = FaceRegionGeometry.gridSplitCells(frame, n: 4, m: 2)
        XCTAssertEqual(cells.count, 8, "4 sectors x 2 axial slabs")
        let a = FaceRegionGeometry.cellAreas(members: [3, 8], in: mesh,
                                             cells: cells, spacingMM: 1)
        XCTAssertEqual(a.unassigned, 0, accuracy: 1e-9,
                       "the angular wrap is exact — no sample between two sectors")
        XCTAssertEqual(a.perCell.reduce(0, +), a.total, accuracy: 1e-9,
                       "the sector/slab cells partition too")
    }

    func testAMixedUnionFallsBackToPCAAndSaysSo() {
        let mesh = boredCube()
        // One cylinder + one plane cannot share an axis.
        XCTAssertFalse(FaceRegionGeometry.frame(members: [1, 3], in: mesh).cylindrical)
    }

    func testRotateButtonCyclesTheSnapCandidates() {
        let mesh = bandedCube()
        let snaps = FaceRegionGeometry.snapNormals(
            FaceRegionGeometry.frame(members: [3], in: mesh))
        XCTAssertEqual(snaps.count, 4)
        XCTAssertEqual(abs(snaps[0].y), 1, accuracy: 1e-6, "default cuts ACROSS the long axis")
        XCTAssertEqual(abs(snaps[1].z), 1, accuracy: 1e-6, "then along it")
    }

    func testManualSplitProducesTwoRevertableChildren() {
        var model = FaceRegionModel()
        let id = model.union(faces: [3], named: "wall")
        let kids = model.splitManual(id, point: SIMD3(10, 5, 4.5), normal: SIMD3(0, 1, 0))
        XCTAssertEqual(kids.count, 2)
        XCTAssertEqual(model.children(of: id).count, 2)
        model.revertSplit(id)
        XCTAssertTrue(model.children(of: id).isEmpty, "splits are a revertable stack")
    }

    // MARK: - §5 THE TWO CONSEQUENCES

    func testSliverGuardRefusesWithTheNumber() {
        let mesh = bandedCube()
        var sheet = FaceRegionSheetModel()
        var model = FaceRegionModel()
        let id = model.union(faces: [3], named: "wall")
        sheet.refresh(mesh: mesh, resolution: 10, model: model, selectedRegion: id)
        sheet.gridN = 10
        sheet.gridM = 10
        let bad = try! XCTUnwrap(sheet.gridPreview(of: model.region(id)!, in: mesh))
        XCTAssertFalse(bad.verdict.ok, "10x10 over a 90-voxel wall is refused")
        XCTAssertEqual(bad.verdict.maxCellsBudget, 5, "90 voxels over a floor of 16 buys five")
        XCTAssertTrue(bad.verdict.reason.contains("floor 16"))
        sheet.gridN = 2
        sheet.gridM = 2
        let ok = try! XCTUnwrap(sheet.gridPreview(of: model.region(id)!, in: mesh))
        XCTAssertTrue(ok.verdict.ok, "2x2 clears it")
    }

    func testAGridSplitAddsONERowNotFifty() {
        let mesh = bandedCube()
        var model = FaceRegionModel()
        let id = model.union(faces: [3], named: "wall")
        let frame = FaceRegionGeometry.frame(members: [3], in: mesh)
        model.splitGrid(id, cells: FaceRegionGeometry.gridSplitCells(frame, n: 5, m: 5))
        XCTAssertEqual(model.children(of: id).count, 25)
        var sheet = FaceRegionSheetModel()
        sheet.refresh(mesh: mesh, resolution: 10, model: model, selectedRegion: id)
        // ★ §5(b): collapsed by default. One operation, one row.
        XCTAssertEqual(sheet.rows.count, 1)
        XCTAssertEqual(sheet.rows[0].childCount, 25)
        model.setCollapsed(id, false)
        sheet.refresh(mesh: mesh, resolution: 10, model: model, selectedRegion: id)
        XCTAssertEqual(sheet.rows.count, 26, "expanded shows the parent and its cells")
    }

    func testRowsBelowTheFloorAreDimmedNotHidden() {
        let mesh = bandedCube()
        var model = FaceRegionModel()
        // The BAND is 10 mm² = 10 voxels at spacing 1, under the floor of 16.
        _ = model.union(faces: [8], named: "band")
        var sheet = FaceRegionSheetModel()
        sheet.refresh(mesh: mesh, resolution: 10, model: model, selectedRegion: nil)
        XCTAssertEqual(sheet.rows.count, 1, "still listed — hiding it would lose a real face")
        XCTAssertTrue(sheet.rows[0].underFloor)
    }

    // MARK: - §3(e) THE DOWNSTREAM CONTRACT

    func testAGroupCarriesRegionsAlongsideFaces() {
        var s = SelectionModel()
        let g = s.addGroup()
        s.pickFaces([3])
        s.addRegions([100], to: g)
        XCTAssertEqual(s.groups[0].faces, [3])
        XCTAssertEqual(s.groups[0].regionIDs, [100])
        XCTAssertEqual(s.groups[0].selectionCount, 2)
        XCTAssertEqual(s.groups[0].selectionLabel, "1 region · 1 face")
        XCTAssertEqual(s.group(forRegion: 100)?.id, g)
    }

    func testAGroupWithNoRegionsKeepsItsOldLabel() {
        var s = SelectionModel()
        _ = s.addGroup()
        s.pickFaces([3, 4])
        XCTAssertEqual(s.groups[0].selectionLabel, s.groups[0].faceLabel,
                       "an untouched group's copy does not move")
    }

    // MARK: - §3(c) PERSISTENCE

    func testARegionRoundTripsThroughTheProjectSnapshotAsItsDEFINITION() throws {
        var model = FaceRegionModel()
        let id = model.union(faces: [3, 8], named: "blends",
                             filter: .blend(maxAreaMM2: 20), matchedAtAuthor: 1)
        model.splitManual(id, point: SIMD3(1, 2, 3), normal: SIMD3(0, 1, 0))
        let data = try JSONEncoder().encode(model)
        let back = try JSONDecoder().decode(FaceRegionModel.self, from: data)
        XCTAssertEqual(back, model)
        // ★ The stored form is the DEFINITION: the filter and the cut geometry
        // survive, so a re-import re-evaluates rather than replaying a stale id list.
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("maxAreaMM2"))
        XCTAssertTrue(text.contains("normal"))
    }

    func testAProjectSavedBeforeRegionsStillDecodes() throws {
        // A SelectionGroup written before `regionIDs` existed.
        let legacy = """
        {"id":"\(UUID().uuidString)","name":"Group A","colorIndex":0,"faces":[3,4]}
        """
        let g = try JSONDecoder().decode(SelectionGroup.self,
                                         from: Data(legacy.utf8))
        XCTAssertEqual(g.faces, [3, 4])
        XCTAssertTrue(g.regionIDs.isEmpty)
    }
}
