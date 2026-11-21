// LatticeLayoutCutPiecesTests — his ask 2026-11-14: "Can you ensure that ALL modifications done in cut faces is respected
// without question?" His "T", cut in Edit faces, was ignored by Protect skin and only partly kept by Lattice / No lattice: the
// app sent a cut piece to the new engine as its WHOLE parent face. Now a piece goes as itself (core's FacePiece, rule D22):
//   * the engine, on core's 10 mm STEP cube through the app's own session: a Lattice region given as half the top face lays
//     lattice under that half only, and a Protect skin given as half the top face is skin under that half only (RED CONTROL:
//     the same asks as whole faces cover both halves — what he saw);
//   * the page: a cut piece in a lattice group goes with its faces and its whole chain of cuts, as a region and as a Protect
//     skin; a union of whole faces goes as faces, as before;
//   * the Export job carries the same pieces (region_pieces, protect_pieces), and a job with none is the bytes it was.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class LatticeLayoutCutPiecesTests: XCTestCase {

    static var cube: String {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u.appendingPathComponent("core/tests/fixtures/step/cube.step").path
    }

    /// The cube's top face (+z), its centre and the box.
    func top() throws -> (face: Int32, centre: SIMD3<Double>, lo: SIMD3<Float>, hi: SIMD3<Float>) {
        let m = try TopOptKit.importMesh(path: Self.cube)
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for i in stride(from: 0, to: m.vertices.count, by: 3) {
            let v = SIMD3(m.vertices[i], m.vertices[i + 1], m.vertices[i + 2])
            lo = simd_min(lo, v); hi = simd_max(hi, v)
        }
        for t in 0..<(m.indices.count / 3) {
            let v = (0..<3).map { k -> SIMD3<Float> in
                let i = Int(m.indices[t * 3 + k]) * 3
                return SIMD3(m.vertices[i], m.vertices[i + 1], m.vertices[i + 2])
            }
            let n = simd_normalize(simd_cross(v[1] - v[0], v[2] - v[0]))
            if n.z > 0.99 {
                let c = (lo + hi) / 2
                return (m.faceIDs[t], SIMD3<Double>(Double(c.x), Double(c.y), Double(hi.z)), lo, hi)
            }
        }
        throw XCTSkip("no top face on the cube")
    }

    /// ★ The engine: a cut piece is laid as itself, never as its whole face.
    func testTheEngineLaysACutPieceAsItself() async throws {
        let t = try top()
        let keepX = LatticeLayoutSession.Cut(point: t.centre, normal: SIMD3(1, 0, 0))   // keeps x >= the centre
        let half = LatticeLayoutSession.Piece(faces: [t.face], cuts: [keepX])
        let session = try await LatticeLayoutSession.open(path: Self.cube)
        defer { session.close() }
        let side = Float(t.hi.x - t.lo.x) / 4
        let kept = SIMD3<Float>(Float(t.centre.x) + side, Float(t.centre.y), t.hi.z - 2.5)
        let cutOff = SIMD3<Float>(Float(t.centre.x) - side, Float(t.centre.y), t.hi.z - 2.5)

        // a Lattice region, five deep under the top face
        var s = LatticeLayoutSession.Settings()
        s.regions = [.init(id: 1, faces: [t.face], depthMM: 5, pieces: [half])]
        let laid = try await session.lay(s)
        XCTAssertTrue(laid.emptyRegions.isEmpty, "premise: the piece has a surface (\(laid.emptyRegions))")
        let w = try await session.whereAt([kept, cutOff])
        print("CUT-PIECES region: kept side \(w[0].why), cut-off side \(w[1].why)")
        XCTAssertNotEqual(w[0].why, .notAsked, "★ lattice is asked under the kept half")
        XCTAssertEqual(w[1].why, .notAsked, "★ and not under the half the cut took away")
        s.regions[0].pieces = []
        _ = try await session.lay(s)
        let whole = try await session.whereAt([kept, cutOff])
        XCTAssertNotEqual(whole[1].why, .notAsked, "RED CONTROL: the whole face (what the app sent) asks under both halves")

        // a Protect skin, two deep, the whole part lattice
        var p = LatticeLayoutSession.Settings()
        p.allLattice = true
        p.protect = [.init(id: 1, faces: [t.face], depthMM: 2, pieces: [half])]
        _ = try await session.lay(p)
        let shallowKept = SIMD3<Float>(kept.x, kept.y, t.hi.z - 1), shallowCut = SIMD3<Float>(cutOff.x, cutOff.y, t.hi.z - 1)
        let sk = try await session.whereAt([shallowKept, shallowCut])
        print("CUT-PIECES skin: kept side \(sk[0].why), cut-off side \(sk[1].why)")
        XCTAssertEqual(sk[0].why, .protectSkin, "★ the skin is under the kept half")
        XCTAssertNotEqual(sk[1].why, .protectSkin, "★ and not under the half the cut took away")
        p.protect[0].pieces = []
        _ = try await session.lay(p)
        let wholeSkin = try await session.whereAt([shallowCut])
        XCTAssertEqual(wholeSkin[0].why, .protectSkin, "RED CONTROL: the whole face skins both halves (what he saw on his T)")
    }

    /// His pad's fixture with Group C's first face row cut in two (as Edit faces cuts it), the kept half put in the group.
    func cutProject() throws -> (p: ProjectModel, group: UUID, face: FaceID, half: RegionID, cut: RegionCut) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        _ = try FlexibleR7M1Fixtures.hisLiveLattice(p)
        let g = try XCTUnwrap(p.latticeGroups.first { p.lattice.groupRoles[$0.id] == .include && !$0.faces.isEmpty },
                              "premise: a Lattice group with faces")
        let f = try XCTUnwrap(g.faces.first)
        let mesh = try XCTUnwrap(p.viewerMesh)
        var sum = SIMD3<Double>(0, 0, 0), n = 0, normal = SIMD3<Double>(0, 0, 1)
        for t in 0..<(mesh.indices.count / 3) where mesh.faceIDs[t] == f {
            let v = (0..<3).map { SIMD3<Double>(FaceRegionGeometry.position(UInt32(mesh.indices[t * 3 + $0]), mesh)) }
            if n == 0 { normal = simd_normalize(simd_cross(v[1] - v[0], v[2] - v[0])) }
            for x in v { sum += x; n += 1 }
        }
        XCTAssertGreaterThan(n, 0, "premise: the face has triangles")
        let centre = sum / Double(n)
        let along = simd_normalize(simd_cross(normal, abs(normal.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)))
        // the app's own Cut (Edit faces' commit), then the group holds the kept half only, as a tap on that half makes it
        let halves = p.commitSurfaceCut(SurfaceCut(point: centre, normal: along, faceID: f, faceNormal: normal))
        XCTAssertEqual(halves.count, 2, "premise: cut in two")
        var l = p.latticeList
        l.removeFaces([f], from: g.id)
        l.setRegions([halves[0]], for: g.id)
        p.latticeList = l
        let cut = try XCTUnwrap(p.faceRegions.region(halves[0])?.cuts.last)
        return (p, g.id, f, halves[0], cut)
    }

    /// ★ The page: a cut piece goes as its faces and its whole chain of cuts, as a region and as a Protect skin.
    func testThePageSendsACutPieceWithItsCuts() throws {
        let c = try cutProject()
        let s = LatticeLayoutPreview.settings(c.p)
        let region = try XCTUnwrap(s.regions.first { !$0.pieces.isEmpty }, "★ a region goes as pieces (\(s.regions))")
        XCTAssertEqual(region.pieces.count, 1)
        XCTAssertEqual(region.pieces[0].faces, [Int32(c.face)], "★ the piece's own face")
        XCTAssertEqual(region.pieces[0].cuts, [.init(point: c.cut.point, normal: c.cut.normal, strict: c.cut.strict)],
                       "★ and the cut that made it, exactly")
        let groups = c.p.latticeGroups.map { g in
            "\(g.name) role \(String(describing: c.p.lattice.groupRoles[g.id])) faces \(g.faces) regions \(g.regionIDs) refs \(c.p.latticeSelectableRefs(g).map(\.key))"
        }
        XCTAssertTrue(s.regions.filter { $0.pieces.isEmpty }.allSatisfy { !$0.faces.contains(Int32(c.face)) },
                      "★ the cut face \(c.face) is not also sent whole: regions \(s.regions.map { ($0.id, $0.faces, $0.noLattice, $0.pieces.count) }); groups \(groups)")
        // as a Protect skin
        c.p.lattice.skinGroups.insert(c.group)
        c.p.lattice.groupRoles[c.group] = .exclude
        let k = LatticeLayoutPreview.settings(c.p)
        XCTAssertTrue(k.protect.contains { $0.pieces.contains { $0.cuts.count == 1 && $0.faces == [Int32(c.face)] } },
                      "★ a Protect skin holds the piece with its cut (\(k.protect.map(\.pieces)))")
        // control: a union of whole faces goes as faces
        let plain = c.p.faceRegions.union(faces: [c.face], named: "whole")
        XCTAssertEqual(LatticeLayoutPreview.pieces(c.p, region: plain), [], "control: no cut, no pieces (the bytes as before)")
        XCTAssertEqual(LatticeLayoutPreview.pieces(c.p, region: c.half).first?.cuts.count, 1)
    }

    /// ★ Skins merged by depth keep their pieces; a whole-face skin beside them becomes a piece with no cut.
    func testSkinsMergedByDepthKeepTheirPieces() {
        let cut = LatticeLayoutSession.Cut(point: .zero, normal: SIMD3(1, 0, 0))
        let a = LatticeLayoutSession.Protect(id: 1, faces: [4], depthMM: 2, pieces: [.init(faces: [4], cuts: [cut])])
        let b = LatticeLayoutSession.Protect(id: 2, faces: [7], depthMM: 2)
        let m = LatticeLayoutPreview.mergedByDepth([a, b])
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m[0].pieces, [.init(faces: [4], cuts: [cut]), .init(faces: [7], cuts: [])], "★ both, the cut kept")
        XCTAssertEqual(LatticeLayoutPreview.mergedByDepth([b, .init(id: 3, faces: [9], depthMM: 2)])[0].pieces, [],
                       "control: whole faces merge as faces")
    }

    /// ★ The Export job carries the pieces; a job with none is the bytes it was.
    func testTheExportJobCarriesThePieces() throws {
        let cut = LatticeLayoutSession.Cut(point: SIMD3(1, 2, 3), normal: SIMD3(0, 0, -1), strict: true)
        var s = LatticeLayoutSession.Settings()
        s.regions = [.init(id: 1, faces: [3], depthMM: 4), .init(id: 2, faces: [5], depthMM: 4, pieces: [.init(faces: [5], cuts: [cut])])]
        s.protect = [.init(id: 3, faces: [8], depthMM: 2)]
        let job = try XCTUnwrap(try JSONSerialization.jsonObject(with: LatticeFileJob.build(s, modelName: "m.step")) as? [String: Any])
        let layout = try XCTUnwrap(job["layout"] as? [String: Any])
        let rp = try XCTUnwrap(layout["region_pieces"] as? [Any], "★ region_pieces is sent")
        XCTAssertEqual(rp.count, 2, "one entry per region")
        XCTAssertTrue(rp[0] is NSNull, "a region of faces: null")
        let piece = try XCTUnwrap((rp[1] as? [[String: Any]])?.first)
        XCTAssertEqual(piece["faces"] as? [Int], [5])
        let c = try XCTUnwrap((piece["cuts"] as? [[String: Any]])?.first)
        XCTAssertEqual(c["point"] as? [Double], [1, 2, 3])
        XCTAssertEqual(c["normal"] as? [Double], [0, 0, -1])
        XCTAssertEqual(c["strict"] as? Bool, true)
        XCTAssertNil(layout["protect_pieces"], "no skin holds a piece: no protect_pieces")
        s.regions[1].pieces = []
        let none = try XCTUnwrap(try JSONSerialization.jsonObject(with: LatticeFileJob.build(s, modelName: "m.step")) as? [String: Any])
        XCTAssertNil((none["layout"] as? [String: Any])?["region_pieces"], "control: no pieces, no key (the job's bytes as before)")
    }
}
#endif
