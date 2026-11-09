// PieceKeepClearDrawTests.swift — E4 (j), the reviewer's ruling 2026-11-08 21:32 item 2: "The wire and the drawing ship in
// one slice, so a release never clears something the screen doesn't show." A cut piece's Keep clear is DRAWN as the run
// keeps it clear: its face's own volume (a bolt's cylinder, a flat face's slab) clipped by the piece's cuts, the way core's
// resolve_clearance_from_region builds it. And "No silent no-ops": a Keep clear set on a piece that is neither a hole nor
// flat says, in one plain line, that it does nothing there.
//   • the geometry: a clipped cylinder / slab keeps only the cut's side and is closed by a cap; a cut that keeps nothing
//     draws nothing; an unclipped volume is the whole solid (control);
//   • the project: a flat piece and an anchored hole's piece each draw ONE clipped volume, on the piece's side only (the
//     unclipped one reaches past the cut — the control), and never the whole face's; what is drawn is what is sent;
//   • the renderer: the clipped volume's triangles all lie on the kept side (the unclipped one's do not);
//   • the line: on for a piece that is neither, off with Keep clear off and for a flat piece; on his screen.
import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class PieceKeepClearDrawTests: XCTestCase {

    // MARK: the geometry (headless)

    private let up = RegionCut(point: SIMD3(0, 0, 5), normal: SIMD3(0, 0, 1))
    private func bolt() -> ClearanceVolume {
        ClearanceVolume(faceID: 3, kind: .bolt, shape: .cylinder(axisPoint: .zero, axisDir: SIMD3(0, 0, 1), radiusMM: 2,
                                                                 tLo: 0, tHi: 10))
    }
    private func zRange(_ polys: [ClearancePolygon]) -> (lo: Float, hi: Float) {
        let z = polys.flatMap(\.points).map(\.z)
        return (z.min() ?? .nan, z.max() ?? .nan)
    }

    func testAnUnclippedVolumeIsTheWholeSolid() {
        let polys = bolt().solidPolygons()
        XCTAssertEqual(polys.count, ClearanceVolume.ringSegments + 2, "control: the side quads and two caps")
        XCTAssertEqual(zRange(polys).lo, 0, accuracy: 1e-5)
        XCTAssertEqual(zRange(polys).hi, 10, accuracy: 1e-5)
    }

    func testACylinderCutAcrossKeepsOnlyItsSideAndIsClosed() {
        let v = bolt().clipped(by: [up])
        XCTAssertEqual(v.clips, [up])
        let polys = v.solidPolygons()
        XCTAssertEqual(zRange(polys).lo, 5, accuracy: 1e-4, "★ nothing below the cut")
        XCTAssertEqual(zRange(polys).hi, 10, accuracy: 1e-4)
        let caps = polys.filter { $0.points.allSatisfy { abs($0.z - 5) < 1e-4 } }
        XCTAssertEqual(caps.count, 1, "★ the cut is closed by one cap")
        XCTAssertEqual(caps.first?.points.count, ClearanceVolume.ringSegments, "the cap is the cylinder's ring")
        XCTAssertTrue(v.solidEdges().contains { abs($0.0.z - 5) < 1e-4 && abs($0.1.z - 5) < 1e-4 }, "★ the cap's outline is drawn")
        XCTAssertNil(v.rayEntry(origin: SIMD3(0, 0, 50), dir: SIMD3(0, 0, -1)), "a piece's volume is not tappable")
        XCTAssertNotNil(bolt().rayEntry(origin: SIMD3(0, 0, 50), dir: SIMD3(0, 0, -1)), "control: a whole face's is")
    }

    func testACylinderCutAlongKeepsHalfOfIt() {
        let v = bolt().clipped(by: [RegionCut(point: .zero, normal: SIMD3(1, 0, 0))])
        let xs = v.solidPolygons().flatMap(\.points).map(\.x)
        XCTAssertGreaterThanOrEqual(xs.min() ?? -1, -1e-4, "★ the half with x ≥ 0 only")
        XCTAssertEqual(xs.max() ?? 0, 2, accuracy: 1e-4)
    }

    func testASlabCutTwiceIsTheirCorner() {
        let slab = ClearanceVolume(faceID: 1, kind: .face, shape: .slab(center: .zero, normal: SIMD3(0, 0, 1),
                                                                        uAxis: SIMD3(1, 0, 0), vAxis: SIMD3(0, 1, 0),
                                                                        halfU: 5, halfV: 5, depthMM: 2))
        let cuts = [RegionCut(point: SIMD3(1, 0, 0), normal: SIMD3(1, 0, 0)),
                    RegionCut(point: SIMD3(0, -2, 0), normal: SIMD3(0, -1, 0))]
        let pts = slab.clipped(by: cuts).solidPolygons().flatMap(\.points)
        XCTAssertFalse(pts.isEmpty)
        for c in cuts { XCTAssertTrue(pts.allSatisfy { simd_dot($0 - SIMD3<Float>(c.point), SIMD3<Float>(c.normal)) >= -1e-4 }) }
        XCTAssertEqual(pts.map(\.x).max() ?? 0, 5, accuracy: 1e-4)
        XCTAssertEqual(pts.map(\.y).min() ?? 0, -5, accuracy: 1e-4)
    }

    func testACutThatKeepsNothingDrawsNothing() {
        let away = RegionCut(point: SIMD3(0, 0, 20), normal: SIMD3(0, 0, 1))
        XCTAssertTrue(bolt().clipped(by: [away]).solidPolygons().isEmpty)
        XCTAssertTrue(bolt().clipped(by: [away]).solidEdges().isEmpty)
    }

    // MARK: the project

    /// The Topology piece tap's move (EditFacesStageTests): the piece out of every group, into a new one.
    private func movePiece(_ piece: RegionID, _ p: ProjectModel) -> UUID {
        let g = p.selection.addGroup()
        for grp in p.selection.groups { p.surfaceDetachPiece(piece, from: grp.id) }
        p.selection.removeRegions([piece])
        for grp in p.selection.groups { p.selection.removeFaces(p.surfaceResolvedFaces(piece), from: grp.id) }
        p.selection.addRegions([piece], to: g)
        return g
    }

    private func kept(_ v: ClearanceVolume, by cuts: [RegionCut]) -> Bool {
        let pts = v.solidPolygons().flatMap(\.points)
        return !pts.isEmpty && cuts.allSatisfy { c in
            let n = simd_normalize(SIMD3<Float>(c.normal))
            return pts.allSatisfy { simd_dot($0 - SIMD3<Float>(c.point), n) >= -1e-3 }
        }
    }
    private func reachesPast(_ v: ClearanceVolume, _ cuts: [RegionCut]) -> Bool {
        let whole = ClearanceVolume(faceID: v.faceID, kind: v.kind, shape: v.shape)
        return !kept(whole, by: cuts)
    }

    /// ★ What is drawn is what is sent: each group's piece volumes and its piece clearances agree, kind for kind.
    private func assertDrawnIsSent(_ p: ProjectModel, file: StaticString = #filePath, line: UInt = #line) {
        let sentKinds = Set(p.clearanceSpecs().filter { $0.regionID >= 0 }.map { "\($0.kind)" })
        let drawnKinds = Set(p.clearanceVolumes().filter { !$0.volume.clips.isEmpty }.map { "\($0.volume.kind)" })
        XCTAssertEqual(drawnKinds, sentKinds, "★ a piece's Keep clear is drawn exactly when it is sent", file: file, line: line)
    }

    func testAFlatPiecesKeepClearIsDrawnOnItsSideOnly() throws {
        let p = EditFacesStageTests.twoFaceProject()
        let half = try XCTUnwrap(p.commitSurfaceCut(EditFacesStageTests.topCut(p)).last, "the cut leaves two pieces")
        let cuts = try XCTUnwrap(p.faceRegions.region(half)).cuts
        let g = movePiece(half, p)
        XCTAssertTrue(p.clearanceVolumes().filter { $0.groupID == g }.isEmpty, "control: Keep clear off draws nothing")
        p.force.setKeepClearAffix(g, .on)

        let mine = p.clearanceVolumes().filter { $0.groupID == g }.map(\.volume)
        XCTAssertEqual(mine.count, 1, "★ the piece's Keep clear is drawn: \(mine)")
        let v = try XCTUnwrap(mine.first)
        XCTAssertEqual(v.kind, .face)
        XCTAssertEqual(v.clips, cuts, "★ clipped by the piece's own cuts — the ones the job sends")
        XCTAssertTrue(kept(v, by: cuts), "★ drawn on the piece's side of the cut only")
        XCTAssertTrue(reachesPast(v, cuts), "control: the whole face's slab reaches past the cut")
        XCTAssertFalse(p.clearanceVolumes().contains { $0.volume.clips.isEmpty && $0.volume.faceID == v.faceID },
                       "never the whole face's slab")
        assertDrawnIsSent(p)
    }

    func testAnAnchoredHolesPieceIsDrawnAsItsHalfOfTheBolt() throws {
        let p = try FlexiblePressFixtures.lBracketProject("PieceKeepClearDrawTests")
        let mesh = try XCTUnwrap(p.viewerMesh)
        let bore = try XCTUnwrap(FaceTopology.faceIDs(in: mesh).first { FaceTopology.isFastenerBore($0, in: mesh) },
                                 "premise: his l bracket has a bolt hole")
        let geo = try XCTUnwrap(mesh.faceGeometry(bore))
        let axis = simd_normalize(SIMD3<Double>(geo.axisDir))
        let span = try XCTUnwrap(mesh.faceAxialSpan(bore, axisPoint: SIMD3<Float>(geo.axisPoint), axisDir: SIMD3<Float>(axis)))
        let mid = SIMD3<Double>(geo.axisPoint) + axis * Double(span.lo + span.hi) / 2
        let pieces = p.commitSurfaceCut(SurfaceCut(point: mid, normal: axis, faceID: bore, faceNormal: axis))
        let half = try XCTUnwrap(pieces.first)
        let cuts = try XCTUnwrap(p.faceRegions.region(half)).cuts
        let g = movePiece(half, p)
        p.force.makeAnchor(g)

        let mine = p.clearanceVolumes().filter { $0.groupID == g }.map(\.volume)
        XCTAssertEqual(mine.count, 1, "★ the anchored hole's piece draws its Keep clear by default: \(mine)")
        let v = try XCTUnwrap(mine.first)
        XCTAssertEqual(v.kind, .bolt)
        XCTAssertEqual(v.clips, cuts)
        XCTAssertTrue(kept(v, by: cuts), "★ only its half of the hole's cylinder")
        XCTAssertTrue(reachesPast(v, cuts), "control: the whole hole's cylinder reaches past the cut")
        XCTAssertFalse(p.clearanceVolumes().contains { $0.groupID == g && $0.volume.clips.isEmpty },
                       "never the whole hole's cylinder in its group")
        assertDrawnIsSent(p)

        p.force.setKeepClearAffix(g, .suppressed)
        XCTAssertTrue(p.clearanceVolumes().filter { $0.groupID == g }.isEmpty, "control: Keep clear off → nothing drawn")
        assertDrawnIsSent(p)
    }

    // MARK: the plain line

    func testAPieceThatIsNeitherSaysSoInOneLine() throws {
        let p = PieceKeepClearTests.roundedEdgeProject()
        let mesh = try XCTUnwrap(p.viewerMesh)
        let half = try XCTUnwrap(p.commitSurfaceCut(try XCTUnwrap(SurfaceCut.centred(onFace: 0, in: mesh))).first)
        let g = movePiece(half, p)
        let group = { try XCTUnwrap(p.selection.groups.first { $0.id == g }) }
        XCTAssertNil(p.keepClearIdlePiecesLine(try group()), "control: Keep clear off, no line")
        p.force.setKeepClearAffix(g, .on)
        XCTAssertEqual(p.keepClearIdlePiecesLine(try group()),
                       "Keep clear does nothing on one piece here: it is neither a hole nor flat.")
        XCTAssertTrue(p.clearanceVolumes().filter { $0.groupID == g }.isEmpty, "★ and nothing is drawn for it")
        assertDrawnIsSent(p)
    }

    func testAFlatPieceHasNoLine() throws {
        let p = EditFacesStageTests.twoFaceProject()
        let half = try XCTUnwrap(p.commitSurfaceCut(EditFacesStageTests.topCut(p)).last)
        let g = movePiece(half, p)
        p.force.setKeepClearAffix(g, .on)
        XCTAssertNil(p.keepClearIdlePiecesLine(try XCTUnwrap(p.selection.groups.first { $0.id == g })),
                     "control: a flat piece keeps clear, so no line")
    }
}

#if canImport(AppKit) && canImport(MetalKit)
import AppKit
import MetalKit

@MainActor
final class PieceKeepClearDrawRenderTests: XCTestCase {

    /// The renderer's triangle corners for these items (x, y, z of each 7-float vertex).
    private func corners(_ items: [ClearanceRenderItem]) throws -> [SIMD3<Float>] {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let mr = try XCTUnwrap(MeshRenderer(device: device, sampleCount: 4))
        mr.setClearanceVolumes(items)
        guard let buf = mr.clearanceFaceBuffer else { return [] }
        let f = buf.contents().bindMemory(to: Float.self, capacity: mr.clearanceFaceCount * 7)
        return (0..<mr.clearanceFaceCount).map { SIMD3(f[7 * $0], f[7 * $0 + 1], f[7 * $0 + 2]) }
    }

    /// ★ The viewport draws the piece's half of the bolt: every triangle corner on the kept side of the cut.
    func testTheViewportDrawsOnlyTheKeptSide() throws {
        let whole = ClearanceVolume(faceID: 3, kind: .bolt, shape: .cylinder(axisPoint: .zero, axisDir: SIMD3(0, 0, 1),
                                                                             radiusMM: 2, tLo: 0, tHi: 10))
        let cut = RegionCut(point: SIMD3(0, 0, 5), normal: SIMD3(0, 0, 1))
        let all = try corners([ClearanceRenderItem(volume: whole, selected: false)])
        XCTAssertTrue(all.contains { $0.z < 4.9 }, "control: the whole hole's cylinder is drawn below the cut")
        let piece = try corners([ClearanceRenderItem(volume: whole.clipped(by: [cut]), selected: false)])
        XCTAssertFalse(piece.isEmpty, "★ the piece's volume is drawn")
        XCTAssertTrue(piece.allSatisfy { $0.z >= 5 - 1e-3 }, "★ only on the piece's side: \(piece.map(\.z).min() ?? .nan)")
        XCTAssertTrue(piece.contains { abs($0.z - 5) < 1e-3 }, "★ closed at the cut")
    }
}

@MainActor
final class PieceKeepClearLineHostedTests: XCTestCase {

    /// ★ The line is on his screen, in the open group, while Keep clear is on and the piece gives nothing to keep clear.
    func testTheLineIsOnHisScreen() throws {
        let p = PieceKeepClearTests.roundedEdgeProject()
        // past the gravity step, as he is when he sets Keep clear (in that step the page shows no Selections panel)
        p.force.setGravity(direction: SIMD3<Float>(0, 0, -1))
        let mesh = try XCTUnwrap(p.viewerMesh)
        let half = try XCTUnwrap(p.commitSurfaceCut(try XCTUnwrap(SurfaceCut.centred(onFace: 0, in: mesh))).first)
        // the Topology piece tap's move (EditFacesStageTests): the piece out of every group, into a new one
        let g = p.selection.addGroup()
        for grp in p.selection.groups { p.surfaceDetachPiece(half, from: grp.id) }
        p.selection.removeRegions([half])
        for grp in p.selection.groups { p.selection.removeFaces(p.surfaceResolvedFaces(half), from: grp.id) }
        p.selection.addRegions([half], to: g)
        p.force.makeAnchor(g)
        p.force.setKeepClearAffix(g, .on)
        p.selection.setActive(g)
        p.force.sync(groups: p.selection.groups)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("piece-line-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let materials = FlexibleHisProject.repoRoot.appendingPathComponent("core/src/materials/materials.json").path
        let app = AppModel(materialsPath: materials, store: ProjectStore(rootDir: root))
        let h = AppBuildHost(WorkspacePlaceholder(model: app, project: p), size: AppBuildHost.landscape13, test: self)
        h.pump(3)
        let key = "keepClearIdlePieces-\(g.uuidString)"
        let line = try h.onScreen(key, "the line under the open group")
        XCTAssertGreaterThan(line.height, 8)
        try h.picture("piece_keep_clear_line.png")

        p.force.setKeepClearAffix(g, .suppressed)
        h.pump(1)
        XCTAssertNil(h.frames.all[key], "control: Keep clear off, the line goes")
    }
}
#endif
