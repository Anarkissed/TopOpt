import XCTest
import simd
@testable import TopOptFlows

/// ★ A group's FACE REGIONS reach the lattice (his 2026-09-22 00:31: "Face 23 & like it"
/// carried an include role and a 12 mm depth and was never latticed — the emission walked
/// the group's direct faces only).
final class LatticeRegionEmissionFaceRegionsTests: XCTestCase {

    private let gid = UUID()
    private func plane(_ f: FaceID) -> LatticeRegionEmission.ResolvedFace {
        .plane(center: SIMD3(Double(f), 0, 0), normal: SIMD3(0, 0, 1), halfUMM: 10, halfWMM: 10,
               outlineLoops: [[SIMD2(-10, -10), SIMD2(10, -10), SIMD2(10, 10), SIMD2(-10, 10)]])
    }

    func testAUnionOfWholeFacesIsEmittedAsOnePrismPerMemberUnderTheRegionsKey() {
        let group = SelectionGroup(id: gid, name: "C", colorIndex: 0, faces: [15], regionIDs: [101])
        let key = LatticeSelectableRef.region(group: gid, region: 101).key
        let r = LatticeRegionEmission.regions(
            groups: [group], roles: [gid: .include],
            primitives: { _ in [] }, includePrimitives: [],
            faceDepthMM: 4,
            selectableDepthMM: [key: 12, LatticeSelectableRef.face(group: gid, face: 15).key: 13],
            selectableDensity: [key: 0.3],
            regionMembers: { _, rid in rid == 101 ? [23, 24] : nil },
            resolve: { self.plane($0) })
        XCTAssertEqual(r.regions.count, 3, "the direct face and the region's two members")
        let members = r.regions.filter { $0.selectableKey == key }
        XCTAssertEqual(members.count, 2)
        XCTAssertEqual(Set(members.compactMap { $0.faceID }), [23, 24])
        for m in members {
            XCTAssertEqual(m.depthMM, 12, "the REGION's depth")
            XCTAssertEqual(m.role, .include)
            XCTAssertEqual(m.relativeDensity ?? 0, 0.3, accuracy: 1e-9, "the region's density")
        }
        XCTAssertEqual(r.regions.first { $0.faceID == 15 }?.depthMM, 13)
    }

    func testACutSectorAndAnExcludedRegionEmitNothing() {
        let group = SelectionGroup(id: gid, name: "C", colorIndex: 0, faces: [], regionIDs: [101, 102])
        let excluded = LatticeSelectableRef.region(group: gid, region: 102).key
        let r = LatticeRegionEmission.regions(
            groups: [group], roles: [gid: .include],
            primitives: { _ in [] }, includePrimitives: [],
            faceDepthMM: 4,
            selectableRoles: [excluded: .exclude],
            regionMembers: { _, rid in rid == 101 ? nil : [30] },   // 101 is a cut sector
            resolve: { self.plane($0) })
        XCTAssertEqual(r.regions.filter { $0.role == .include }.count, 0)
    }

    func testAMemberThatIsAlsoADirectFaceIsEmittedOnce() {
        let group = SelectionGroup(id: gid, name: "C", colorIndex: 0, faces: [23], regionIDs: [101])
        let r = LatticeRegionEmission.regions(
            groups: [group], roles: [gid: .include],
            primitives: { _ in [] }, includePrimitives: [],
            faceDepthMM: 4,
            regionMembers: { _, _ in [23, 24] },
            resolve: { self.plane($0) })
        XCTAssertEqual(r.regions.compactMap { $0.faceID }.sorted(), [23, 24])
    }

    /// ★ THE FRAME ON THE WIRE (core note 4): the axes `outline_uv` is in, as core's own
    /// plane_basis builds them — for a +z face u is −world y — and only when asked.
    func testTheFaceFrameAxesRideWithTheOutlineWhenTheCoreTakesThem() {
        var r = LatticeRegionSpec(role: .include, kind: .face)
        r.origin = .zero; r.normal = SIMD3(0, 0, 1); r.depthMM = 10
        r.outlineLoops = [[SIMD2(-10, -10), SIMD2(10, -10), SIMD2(10, 10), SIMD2(-10, 10)]]
        let with = r.wireDictionary(frameAxes: true)
        let geo = with["geometry"] as? [String: Any] ?? with
        XCTAssertEqual(geo["frame_u"] as? [Double], [0, -1, 0], "core's plane_basis: u = cross(x, n)")
        XCTAssertEqual(geo["frame_w"] as? [Double], [1, 0, 0])
        let without = r.wireDictionary(frameAxes: false)
        let geo2 = without["geometry"] as? [String: Any] ?? without
        XCTAssertNil(geo2["frame_u"]); XCTAssertNil(geo2["frame_w"])
        XCTAssertNotNil(geo2["outline_uv"])
    }
}
