// FlexibleRegionsTests — split sectors as loaded faces (task 2026-09-29-flexible-screens,
// overnight round). The pad's top face (pseudo-face 1) is split in half at x = 50 on the
// Surface stage's own model; both halves must reach core as regions, frame as 50 × 100
// sectors, be picked by the side of the tap, and round-trip through core's parser.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class FlexibleRegionsTests: XCTestCase {

    static var pad: (mesh: ViewerMesh, path: String) {
        let path = FlexibleStageTests.padSTL
        let m = try! TopOptKit.importMesh(path: path)
        return (ViewerMesh(vertices: m.vertices, indices: m.indices, faceIDs: m.faceIDs, pseudoFaces: true), path)
    }

    /// The top face split at x = 50: returns the model and the two sector ids.
    static func splitTop(_ mesh: ViewerMesh) -> (FaceRegionModel, [RegionID]) {
        var model = FaceRegionModel()
        // the top of the pad is the face whose triangles sit at z = 20
        var top: FaceID = -1
        for t in 0..<mesh.triangleCount {
            let i = Int(mesh.indices[3 * t]) * 3
            if abs(mesh.positions[i + 2] - 20) < 1e-3,
               abs(mesh.positions[Int(mesh.indices[3 * t + 1]) * 3 + 2] - 20) < 1e-3,
               abs(mesh.positions[Int(mesh.indices[3 * t + 2]) * 3 + 2] - 20) < 1e-3 { top = mesh.faceIDs[t]; break }
        }
        let whole = model.union(faces: [top], named: "top")
        let kids = model.splitManual(whole, point: SIMD3(50, 50, 20), normal: SIMD3(1, 0, 0))
        return (model, kids)
    }

    func testSectorsAreDeclaredNamedAndPicked() throws {
        let (mesh, _) = Self.pad
        let (model, kids) = Self.splitTop(mesh)
        XCTAssertEqual(kids.count, 2)
        let regions = FlexibleRegions(model: model, mesh: mesh)
        XCTAssertEqual(regions.sectors.map(\.id).sorted(), kids.sorted())
        XCTAssertEqual(regions.wire.count, 2)
        let top = regions.faces(of: FlexibleRegions.wireID(regions.sectors[0]), mesh: mesh)
        XCTAssertEqual(top.count, 1)
        // the tap's side picks the sector; a face without sectors stays whole
        let right = regions.region(at: SIMD3(80, 50, 20), face: top[0], mesh: mesh)
        let left = regions.region(at: SIMD3(20, 50, 20), face: top[0], mesh: mesh)
        XCTAssertTrue(FlexibleRegions.isSector(right))
        XCTAssertTrue(FlexibleRegions.isSector(left))
        XCTAssertNotEqual(left, right)
        XCTAssertEqual(regions.region(at: SIMD3(50, 0, 10), face: 2, mesh: mesh), 2)
        // names: a sector reads "face N · <its name>", and core's sentence is renamed
        XCTAssertTrue(regions.name(right, mesh: mesh).hasPrefix("face \(top[0]) · "))
        XCTAssertEqual(regions.renamed("face \(right) is too firm", mesh: mesh),
                       "\(regions.name(right, mesh: mesh)) is too firm")
        XCTAssertEqual(regions.renamed("face 3 is fine", mesh: mesh), "face 3 is fine")
        // membership by triangle centroid
        XCTAssertTrue(regions.contains(right, face: top[0], centroid: SIMD3(90, 10, 20), mesh: mesh))
        XCTAssertFalse(regions.contains(right, face: top[0], centroid: SIMD3(10, 10, 20), mesh: mesh))
    }

    func testCoreFramesEachSectorFromItsOwnHalf() throws {
        let (mesh, path) = Self.pad
        let (model, _) = Self.splitTop(mesh)
        let regions = FlexibleRegions(model: model, mesh: mesh)
        let right = regions.region(at: SIMD3(80, 50, 20), face: regions.faces(of: FlexibleRegions.wireID(regions.sectors[0]), mesh: mesh)[0], mesh: mesh)
        var s = FlexibleStageSettings(materialID: "varioshore_tpu", nozzleTempC: 220)
        s.setFace(FlexibleFaceSettings(faceRegionID: right, weightKg: 10, deepestMM: 3))
        var inputs = FlexibleJob.Inputs(modelPath: path, resolution: 50, beadWidthMM: 0.42, faceCount: 6, settings: s)
        inputs.sectorRegions = regions.wire
        // the run job reads back through core's parser with the sector as a loaded face
        let b = try FlexibleCore.parseJobBlock(try FlexibleJob.runJobJSON(inputs))
        XCTAssertEqual(b.faces.first?.faceRegionID, right)
        // and core frames the sector from its own half: 50 × 100, not the whole 100 × 100
        let scene = try FlexibleScene(jobJSON: try FlexibleJob.sceneJobJSON(inputs, fallbackMaterial: "varioshore_tpu"), jobDir: "/")
        let st = try scene.stack(face: right, rotation: 0)
        XCTAssertEqual(min(st.uExtentMM, st.vExtentMM), 50, accuracy: 2.5)
        XCTAssertEqual(max(st.uExtentMM, st.vExtentMM), 100, accuracy: 2.5)
        XCTAssertEqual(st.load.z, -1, accuracy: 1e-9)
        // every column's entry point is on the sector's side (x ≥ 50)
        let entries = try scene.fromUV(face: right, rotation: 0, st.columns.map { SIMD2($0.uMM, $0.vMM) })
        XCTAssertTrue(entries.allSatisfy { $0.x >= 50 - 1e-6 })
    }

    func testOverlayReplacesOnlyTheSectorsTriangles() throws {
        let (mesh, _) = Self.pad
        let (model, _) = Self.splitTop(mesh)
        let regions = FlexibleRegions(model: model, mesh: mesh)
        let topFace = regions.faces(of: FlexibleRegions.wireID(regions.sectors[0]), mesh: mesh)[0]
        let right = regions.region(at: SIMD3(80, 50, 20), face: topFace, mesh: mesh)
        var s = FlexibleStageSettings(materialID: "varioshore_tpu", nozzleTempC: 220)
        s.setFace(FlexibleFaceSettings(faceRegionID: right))
        var inputs = FlexibleJob.Inputs(modelPath: FlexibleStageTests.padSTL, resolution: 50, beadWidthMM: 0.42,
                                        faceCount: 6, settings: s)
        inputs.sectorRegions = regions.wire
        let scene = try FlexibleScene(jobJSON: try FlexibleJob.sceneJobJSON(inputs, fallbackMaterial: "varioshore_tpu"), jobDir: "/")
        let st = try scene.stack(face: right, rotation: 0)
        let centres = try scene.fromUV(face: right, rotation: 0, st.columns.map { SIMD2($0.uMM, $0.vMM) })
        let empty = FlexibleOverlayFace(key: FlexFaceKey(region: right, rotation: 0),
                                        faces: Set(regions.faces(of: right, mesh: mesh)),
                                        cuts: regions.cuts(of: right), stack: st, centres: centres)
        let o = FlexibleOverlayMesh.build(part: mesh, faces: [empty])
        // ★ RE-PINNED (round 3, item 2 — the hole): the sector's PART of the face is replaced,
        // not the triangles whose centroid is in it. The face is cut along x = 50 first, so a
        // triangle that crosses the cut keeps its x < 50 piece — which adds triangles, so the
        // old "fewer kept triangles than the part had" count no longer describes it. What
        // stays: exactly the other sector's 5000 mm² of the top, and nothing past the cut.
        var topArea = 0.0
        for i in 0..<o.keptTriangles.count where o.keptFace[i] == topFace {
            let p = (0..<3).map { j -> SIMD3<Double> in
                let v = 3 * i + j
                return SIMD3(Double(o.mesh.flat.positions[3 * v]), Double(o.mesh.flat.positions[3 * v + 1]),
                             Double(o.mesh.flat.positions[3 * v + 2]))
            }
            topArea += simd_length(simd_cross(p[1] - p[0], p[2] - p[0])) / 2
        }
        XCTAssertEqual(topArea, 5000, accuracy: 1e-3, "the other sector keeps its half of the top, and only that")
        XCTAssertTrue(o.keptFace.enumerated().allSatisfy { i, f in
            f != topFace || o.keptCentroid[i].x < 50 + 1e-6 })
    }
}

