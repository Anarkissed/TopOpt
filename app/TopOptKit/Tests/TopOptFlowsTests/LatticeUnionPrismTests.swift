import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★ HIS iPAD NOTES 11-10 (img 1/2): "After setting up a union of faces, I selected them and set them to 'no lattice' but
/// no face-prism was visible … any cut/patterned/unioned faces are not respected in the lattice stage to create
/// face-prisms from." A union of PIECES lists its faces only through its parts; the prism builder read the union's own
/// face list (empty), so Lattice and No lattice drew nothing (Protect skin is a colour, which read the parts — so it showed).
/// The run already took the union through its parts; the prism now reads them the same way.
@MainActor
final class LatticeUnionPrismTests: XCTestCase {
    typealias T = LatticeSectorOutlineTests

    /// The split pad with its group holding ONE union: the cut piece 'top A' (x ≥ 50) + the whole +x side.
    private func unionPad(role: LatticeGroupRole) throws -> (p: ProjectModel, gid: UUID, union: RegionID) {
        let pad = T.splitPad()
        let p = pad.p
        let side = p.faceRegions.union(faces: [3], named: "Face 3")
        let u = try XCTUnwrap(p.faceRegions.unionOfParts([pad.a, side], named: "Union of 2"), "premise: the union is made")
        XCTAssertTrue(try XCTUnwrap(p.faceRegions.region(u)).isUnionOfParts)
        p.selection.removeRegions([pad.a])
        p.selection.addRegions([u], to: pad.gid)
        p.force.sync(groups: p.selection.groups)
        p.lattice.groupRoles[pad.gid] = role
        p.writeLatticeDepthMM(.region(group: pad.gid, region: u), mm: 6)
        return (p, pad.gid, u)
    }

    private func plane(_ p: ProjectModel, _ gid: UUID, _ rid: RegionID) -> ProjectModel.LatticeDepthPlane? {
        let key = LatticeSelectableRef.region(group: gid, region: rid).key
        return p.latticeDepthPlanes().first { $0.ref.key == key }
    }

    private func base(_ pl: ProjectModel.LatticeDepthPlane) throws -> [SIMD3<Float>] {
        guard case let .shell(s) = pl.volume.shape else { XCTFail("the prism is the surface's offset shell"); return [] }
        return s.base
    }

    /// ★ Lattice: the union draws ONE prism over BOTH its parts — the piece clipped to its own half, the side whole.
    func testAUnionOfPiecesDrawsItsPrism() throws {
        let (p, gid, u) = try unionPad(role: .include)
        let pl = try XCTUnwrap(plane(p, gid, u), "★ the union's prism is drawn")
        XCTAssertEqual(pl.role, .include)
        XCTAssertEqual(pl.depthMM, 6, accuracy: 1e-9, "★ at the union's own depth")
        let b = try base(pl)
        let top = b.filter { abs($0.z - 20) < 1e-3 && $0.x < 100 - 1e-3 }
        let side = b.filter { abs($0.x - 100) < 1e-3 && $0.z < 20 - 1e-3 }
        XCTAssertFalse(top.isEmpty, "★ over the piece 'top A'")
        XCTAssertFalse(side.isEmpty, "★ over the whole side")
        XCTAssertTrue(top.allSatisfy { $0.x >= 50 - 1e-3 }, "★ the piece stays its own half: nothing over 'top B'")
        // the run takes the same union (control: the emission already read the parts)
        XCTAssertFalse(T.prisms(p, gid, u).isEmpty, "control: the run lattices the union")
    }

    /// ★ No lattice: the same prism, as an exclude (img 2: "set them to 'no lattice' but no face-prism was visible").
    func testAUnionSetToNoLatticeDrawsItsPrism() throws {
        let (p, gid, u) = try unionPad(role: .exclude)
        let pl = try XCTUnwrap(plane(p, gid, u), "★ the No-lattice union's prism is drawn")
        XCTAssertEqual(pl.role, .exclude)
        XCTAssertFalse(try base(pl).isEmpty)
    }

    /// CONTROL: a single cut piece drew its prism before this fix, and draws the same one now.
    func testACutPieceAloneStillDrawsItsOwnHalf() throws {
        let pad = T.splitPad()
        let pl = try XCTUnwrap(plane(pad.p, pad.gid, pad.a), "control: a cut piece's prism")
        let b = try base(pl)
        XCTAssertFalse(b.isEmpty)
        XCTAssertTrue(b.filter { abs($0.z - 20) < 1e-3 }.allSatisfy { $0.x >= 50 - 1e-3 }, "control: its own half only")
    }
}
