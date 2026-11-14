import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★ ONE ORDER FOR ONE OUTLINE (maintainer, 2026-09-30, ruling 1). The outline loops are built
/// in ONE place (`LatticeFaceOutline.loopsWithNeighbours`); each starts at its smallest world
/// vertex, the loops are ordered by their rotated vertex sequence, the walk's winding is kept,
/// and each edge's neighbour stays on its edge — whatever order the mesh lists its triangles in.
final class LatticeFaceOutlineOrderTests: XCTestCase {

    /// A mesh from (a, b, c, face) triangles over a vertex list.
    private func mesh(_ verts: [SIMD3<Float>], _ tris: [(Int32, Int32, Int32, Int32)]) -> ViewerMesh {
        let faces = Set(tris.map { $0.3 })
        return ViewerMesh(vertices: verts.flatMap { [$0.x, $0.y, $0.z] },
                          indices: tris.flatMap { [$0.0, $0.1, $0.2] },
                          faceIDs: tris.map { $0.3 },
                          faceGeometry: (0...(faces.max() ?? 0)).map { _ in
                              StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1)) })
    }

    /// `VariantFacePrismFixture.bandedCube`'s vertices and triangles, as data.
    private let cubeVerts: [SIMD3<Float>] = [
        SIMD3(0, 0, 0), SIMD3(10, 0, 0), SIMD3(10, 10, 0), SIMD3(0, 10, 0),
        SIMD3(0, 0, 10), SIMD3(10, 0, 10), SIMD3(10, 10, 10), SIMD3(0, 10, 10),
        SIMD3(10, 0, 9), SIMD3(10, 10, 9), SIMD3(0, 0, 9), SIMD3(0, 10, 9)]
    private let cubeTris: [(Int32, Int32, Int32, Int32)] = [
        (0, 3, 2, 0), (0, 2, 1, 0), (4, 5, 6, 1), (4, 6, 7, 1),
        (0, 1, 8, 2), (0, 8, 10, 2), (10, 8, 5, 2), (10, 5, 4, 2),
        (1, 2, 9, 3), (1, 9, 8, 3),
        (2, 3, 11, 4), (2, 11, 9, 4), (9, 11, 7, 4), (9, 7, 6, 4),
        (3, 0, 10, 5), (3, 10, 11, 5), (11, 10, 4, 5), (11, 4, 7, 5),
        (8, 9, 6, 8), (8, 6, 5, 8)]

    /// Face 2 of the banded cube (the y = 0 wall, split at z 9): its outline and neighbours.
    private func face2(_ m: ViewerMesh) -> [(loop: LatticeFaceOutline.Loop, neighbours: [FaceID?])] {
        LatticeFaceOutline.loopsWithNeighbours(triangles: { $0 < m.faceIDs.count && m.faceIDs[$0] == 2 },
                                               in: m, normal: SIMD3(0, -1, 0), origin: .zero)
    }
    private func same(_ a: [(loop: LatticeFaceOutline.Loop, neighbours: [FaceID?])],
                      _ b: [(loop: LatticeFaceOutline.Loop, neighbours: [FaceID?])]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.loop == $1.loop && $0.neighbours == $1.neighbours }
    }

    func testTheOutlineStartsAtItsSmallestVertexWhateverTheTriangleOrder() {
        let plain = mesh(cubeVerts, cubeTris)
        let reversed = mesh(cubeVerts, cubeTris.reversed())
        let rotated = mesh(cubeVerts, cubeTris.reversed().map { ($0.1, $0.2, $0.0, $0.3) })   // winding kept
        // precondition: in the reversed mesh the first face-2 triangle met does not hold (0,0,0),
        // so its scan order really starts the walk somewhere else
        let firstFace2 = cubeTris.reversed().first { $0.3 == 2 }!
        XCTAssertFalse([firstFace2.0, firstFace2.1, firstFace2.2].contains(0), "control: the permutation moves the scan start")
        let a = face2(plain), b = face2(reversed), c = face2(rotated)
        XCTAssertEqual(a.count, 1)
        XCTAssertTrue(same(a, b), "★ the same outline whatever the triangle order")
        XCTAssertTrue(same(a, c), "★ …and whatever vertex each triangle starts at")
        // ★ it starts at the smallest world vertex, (0,0,0) — the plane origin here
        XCTAssertEqual(a[0].loop.first, SIMD2(0, 0))
        XCTAssertEqual(a[0].loop.count, 6)
    }

    func testEachNeighbourStaysOnItsEdge() throws {
        // the permuted mesh, so the rotation to the smallest vertex is not the identity
        let m = mesh(cubeVerts, cubeTris.reversed().map { ($0.1, $0.2, $0.0, $0.3) })
        let out = face2(m)
        XCTAssertEqual(out.count, 1)
        let (loop, nb) = (out[0].loop, out[0].neighbours)
        // project the world points the way the builder does (normal (0,-1,0), origin 0)
        let (u, v) = LatticeRegionMask.basis(SIMD3<Double>(0, -1, 0))
        func p(_ w: SIMD3<Double>) -> SIMD2<Double> { SIMD2(simd_dot(w, u), simd_dot(w, v)) }
        func neighbour(from a: SIMD3<Double>, to b: SIMD3<Double>) -> FaceID?? {
            guard let i = loop.indices.first(where: { loop[$0] == p(a) && loop[($0 + 1) % loop.count] == p(b) }) else { return nil }
            return nb[i]
        }
        XCTAssertEqual(neighbour(from: SIMD3(0, 0, 0), to: SIMD3(10, 0, 0)), .some(0), "the bottom")
        XCTAssertEqual(neighbour(from: SIMD3(10, 0, 0), to: SIMD3(10, 0, 9)), .some(3), "★ the +x wall's lower face")
        XCTAssertEqual(neighbour(from: SIMD3(10, 0, 9), to: SIMD3(10, 0, 10)), .some(8), "★ …and its band")
        XCTAssertEqual(neighbour(from: SIMD3(10, 0, 10), to: SIMD3(0, 0, 10)), .some(1), "the top")
        XCTAssertEqual(neighbour(from: SIMD3(0, 0, 10), to: SIMD3(0, 0, 9)), .some(5))
        XCTAssertEqual(neighbour(from: SIMD3(0, 0, 9), to: SIMD3(0, 0, 0)), .some(5))
        XCTAssertEqual(loop.first, p(SIMD3(0, 0, 0)), "and it starts at the smallest vertex")
    }

    func testAnOuterLoopComesFirst() {
        // a 20 × 20 square with a 10 × 10 hole, one face, in the z = 0 plane
        let v: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(20, 0, 0), SIMD3(20, 20, 0), SIMD3(0, 20, 0),
                                 SIMD3(5, 5, 0), SIMD3(15, 5, 0), SIMD3(15, 15, 0), SIMD3(5, 15, 0)]
        let tris: [(Int32, Int32, Int32, Int32)] = [(0, 1, 5, 0), (0, 5, 4, 0), (1, 2, 6, 0), (1, 6, 5, 0),
                                                    (2, 3, 7, 0), (2, 7, 6, 0), (3, 0, 4, 0), (3, 4, 7, 0)]
        func loops(_ t: [(Int32, Int32, Int32, Int32)]) -> [(loop: LatticeFaceOutline.Loop, neighbours: [FaceID?])] {
            let m = mesh(v, t)
            return LatticeFaceOutline.loopsWithNeighbours(triangles: { _ in true }, in: m,
                                                          normal: SIMD3(0, 0, 1), origin: .zero)
        }
        let a = loops(tris), b = loops(tris.reversed())
        XCTAssertEqual(a.count, 2)
        XCTAssertTrue(same(a, b), "★ one order whatever the triangle order")
        // the outer loop (it holds the smallest vertex) comes first
        let xs = a[0].loop.map(\.x), ys = a[0].loop.map(\.y)
        XCTAssertEqual((xs.max() ?? 0) - (xs.min() ?? 0), 20, accuracy: 1e-9)
        XCTAssertEqual((ys.max() ?? 0) - (ys.min() ?? 0), 20, accuracy: 1e-9)
    }

    func testAPinchVertexChainsOneWay() {
        // two squares of one face touching at a corner: the vertex (10,10) has four rim edges
        let v: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(10, 0, 0), SIMD3(10, 10, 0), SIMD3(0, 10, 0),
                                 SIMD3(20, 10, 0), SIMD3(20, 20, 0), SIMD3(10, 20, 0)]
        let tris: [(Int32, Int32, Int32, Int32)] = [(0, 1, 2, 0), (0, 2, 3, 0), (2, 4, 5, 0), (2, 5, 6, 0)]
        var seen = Set<String>()
        for _ in 0..<200 {
            let m = mesh(v, tris)
            let out = LatticeFaceOutline.loopsWithNeighbours(triangles: { _ in true }, in: m,
                                                             normal: SIMD3(0, 0, 1), origin: .zero)
            seen.insert(out.map { "\($0.loop)\($0.neighbours)" }.joined(separator: "|"))
        }
        print("PINCH distinct chainings \(seen.count) of 200")
        XCTAssertEqual(seen.count, 1, "★ a pinch vertex chains one way, every call")
    }
}
