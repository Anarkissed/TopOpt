// LatticePlaceChipsTests — ★ HIS PICK OF 11-17 ("Yes, add a chip to ask what it should be"), on the new engine: a chip on each
// face a region's prism runs into that no rule decides (core's rule D23, LatticeReview's places), Lattice by default (open
// cells, what the engine makes there), Solid = a thin skin (depth 0: core's two line widths, LatticeReview 11-17) with the
// lattice behind it, as a chip's Protect entry (protect_chip), so the place stays listed and can be answered again.
//   * for real, through the bridge on a part like core's own test (a 60 x 60 x 20 block, lattice 18 mm deep under its top, a
//     tunnel running in under it): the tunnel's faces are places, the top (its own face) never; answered Solid, the place
//     stays listed and is solid now; RED CONTROL: asked with other settings than the last layout's, none;
//   * the app: an answer stored under the old chips' keys becomes ONE chip skin at depth 0, never merged with his own skins;
//     the chip's words name no face number; the file job carries protect_chip only when some skin is a chip's (RED
//     CONTROL: none, the bytes as before).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class LatticePlaceChipsTests: XCTestCase {

    /// A binary STL of a block of grid cells (xs, ys, zs), the cells `filled` says, its boundary as quads.
    static func gridSTL(_ xs: [Float], _ ys: [Float], _ zs: [Float], filled: (Int, Int, Int) -> Bool) -> Data {
        var tris: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        let c = [xs, ys, zs], n = [xs.count - 1, ys.count - 1, zs.count - 1]
        func full(_ i: Int, _ j: Int, _ k: Int) -> Bool { i >= 0 && j >= 0 && k >= 0 && i < n[0] && j < n[1] && k < n[2] && filled(i, j, k) }
        for i in 0..<n[0] { for j in 0..<n[1] { for k in 0..<n[2] where full(i, j, k) {
            let ijk = [i, j, k]
            for axis in 0..<3 { for sign in [-1, 1] {
                var o = ijk; o[axis] += sign
                if full(o[0], o[1], o[2]) { continue }
                let at = c[axis][ijk[axis] + (sign > 0 ? 1 : 0)]
                let a1 = (axis + 1) % 3, a2 = (axis + 2) % 3
                var q: [SIMD3<Float>] = []
                for v in 0..<4 {
                    var p = SIMD3<Float>(repeating: 0)
                    p[axis] = at
                    p[a1] = c[a1][ijk[a1] + ((v == 1 || v == 2) ? 1 : 0)]
                    p[a2] = c[a2][ijk[a2] + (v >= 2 ? 1 : 0)]
                    q.append(p)
                }
                if sign < 0 { q.swapAt(1, 3) }
                var nn = SIMD3<Float>(repeating: 0); nn[axis] = Float(sign)
                tris.append((nn, q[0], q[1], q[2]))
                tris.append((nn, q[0], q[2], q[3]))
            } }
        } } }
        var d = Data(count: 80)
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func f3(_ v: SIMD3<Float>) { for s in [v.x, v.y, v.z] { var x = s.bitPattern.littleEndian; d.append(Data(bytes: &x, count: 4)) } }
        u32(UInt32(tris.count))
        for t in tris { f3(t.0); f3(t.1); f3(t.2); f3(t.3); d.append(Data(count: 2)) }
        return d
    }

    /// The pseudo-face of `mesh` whose triangles all lie on the plane `axis` = `at` facing `sign`.
    static func face(_ m: ImportedMesh, axis: Int, sign: Float, at: Float) -> Int32? {
        var found: Int32?
        for t in 0..<(m.indices.count / 3) {
            let p = (0..<3).map { v -> SIMD3<Float> in
                let b = Int(m.indices[3 * t + v]) * 3
                return SIMD3(m.vertices[b], m.vertices[b + 1], m.vertices[b + 2])
            }
            guard p.allSatisfy({ abs($0[axis] - at) < 1e-4 }) else { continue }
            let nrm = simd_cross(p[1] - p[0], p[2] - p[0])
            guard nrm[axis] * sign > 0 else { continue }
            found = m.faceIDs[t]
        }
        return found
    }

    func testThePlacesOfATunnelUnderTheLatticeForRealAndAChipsAnswer() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("places-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("tunnel.stl").path
        try Self.gridSTL([0, 20, 40, 60], [0, 30, 60], [0, 5, 12, 20]) { !($0 == 1 && $1 == 0 && $2 == 1) }
            .write(to: URL(fileURLWithPath: path))
        let mesh = try TopOptKit.importMesh(path: path)
        let top = try XCTUnwrap(Self.face(mesh, axis: 2, sign: 1, at: 20), "the top")
        let floor = try XCTUnwrap(Self.face(mesh, axis: 2, sign: 1, at: 5), "the tunnel's floor")

        let session = try await LatticeLayoutSession.open(path: path)
        addTeardownBlock { session.close() }
        var s = LatticeLayoutSession.Settings()
        s.regions = [.init(id: 1, faces: [top], depthMM: 18)]
        s.cellMaxMM = 6
        _ = try await session.lay(s)
        let (places, ms) = try await session.places(s)
        print("LATTICE-PLACES tunnel: \(places.count) places in \(String(format: "%.1f", ms)) ms: "
              + places.map { "region \($0.region), \($0.faces.count) faces, \(Int($0.areaMM2)) mm2, \($0.solidNow ? "solid" : "lattice")" }
                .joined(separator: "; "))
        XCTAssertFalse(places.isEmpty, "★ the tunnel the lattice runs into asks")
        XCTAssertTrue(places.contains { $0.faces.contains(floor) }, "★ its floor is a place")
        XCTAssertFalse(places.contains { $0.faces.contains(top) }, "the region's own face never")
        XCTAssertTrue(places.allSatisfy { $0.region == 1 && $0.areaMM2 >= 100 && !$0.solidNow }, "Lattice now, at least 100 mm2")
        for p in places { XCTAssertEqual(simd_length(p.normal), 1, accuracy: 1e-3, "an outward unit normal") }

        // RED CONTROL: asked with settings that are not the last layout's: none
        var other = s
        other.regions[0].depthMM = 4
        let none = try await session.places(other)
        XCTAssertTrue(none.places.isEmpty, "RED CONTROL: other settings than the last layout's: none")

        // his answer "Solid" on the floor's place: a chip skin at depth 0; the place stays listed, solid now
        let floorPlace = try XCTUnwrap(places.first { $0.faces.contains(floor) })
        var answered = s
        answered.protect = [.init(id: 2, faces: floorPlace.faces, depthMM: 0, chip: true)]
        _ = try await session.lay(answered)
        let after = try await session.places(answered).places
        XCTAssertTrue(after.contains { $0.faces.contains(floor) && $0.solidNow }, "★ answered Solid: still asked, solid now")
        // his own Protect skin on the same faces (not a chip's): a rule, no place
        var own = s
        own.protect = [.init(id: 2, faces: floorPlace.faces, depthMM: 0)]
        _ = try await session.lay(own)
        let ownPlaces = try await session.places(own).places
        XCTAssertFalse(ownPlaces.contains { $0.faces.contains(floor) }, "his own skin: no chip there")
    }

    @MainActor
    func testAChipsAnswerIsOneChipSkinAndTheJobCarriesIt() throws {
        var l = LatticeSettings()
        XCTAssertNil(LatticeLayoutPreview.chipSkin(l, id: 9), "no answer: no chip skin")
        l.bandTreatments = ["face:12": true, "face:7": true, "face:30": false, "cap:abc": true]
        let chip = try XCTUnwrap(LatticeLayoutPreview.chipSkin(l, id: 9))
        XCTAssertEqual(chip.faces, [7, 12], "the faces answered Solid (the old chips' keys), Lattice answers left out")
        XCTAssertEqual(chip.depthMM, 0, "★ depth 0: core's two line widths, the lattice kept behind it")
        XCTAssertTrue(chip.chip)
        // never merged with his own skins (a merge would make it his rule and take the chip away)
        let merged = LatticeLayoutPreview.mergedByDepth([.init(id: 1, faces: [3], depthMM: 0)]) + [chip]
        XCTAssertEqual(merged.filter(\.chip).count, 1)

        // the chip's words: Solid / Lattice, the face named without a number (his rule)
        let d = LatticeLayoutPreview.chipDecisions([.init(region: 1, faces: [7, 12], point: .zero, normal: SIMD3(0, 0, 1),
                                                          areaMM2: 400, solidNow: true)])
        XCTAssertEqual(d.first?.kind, .place)
        XCTAssertEqual(d.first?.memberKeys, ["face:7", "face:12"])
        XCTAssertEqual(d.first?.label, "These 2 faces")
        XCTAssertFalse(d.first?.label.contains { $0.isNumber && $0 != "2" } ?? true, "no face number")
        XCTAssertEqual(LatticeBandChipText.segments(.place).solid, "Solid")
        XCTAssertEqual(LatticeBandChipText.segments(.place).open, "Lattice")
        XCTAssertEqual(LatticeBandChipLayout.treatment(choosing: true, for: try XCTUnwrap(d.first)), true, "Solid is stored")
        XCTAssertNil(LatticeBandChipLayout.treatment(choosing: false, for: try XCTUnwrap(d.first)), "Lattice is the default: cleared")

        // the file job: protect_chip only when some skin is a chip's
        var s = LatticeLayoutSession.Settings()
        s.protect = [.init(id: 1, faces: [3], depthMM: 2)]
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: try LatticeFileJob.build(s, modelName: "p.step")) as? [String: Any])
        XCTAssertNil((plain["layout"] as? [String: Any])?["protect_chip"], "RED CONTROL: no chip skin, no key")
        s.protect.append(chip)
        let job = try XCTUnwrap(JSONSerialization.jsonObject(with: try LatticeFileJob.build(s, modelName: "p.step")) as? [String: Any])
        XCTAssertEqual((job["layout"] as? [String: Any])?["protect_chip"] as? [Int], [0, 1], "★ the job says which skin is a chip's")
    }
}
#endif
