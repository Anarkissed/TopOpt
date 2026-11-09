// ★ his iPad notes 11-09 (2:36 PM, Aesthetic, Start from All lattice − Lattice faces, Zone 1 54.1 × 30 × 90.8 mm No lattice):
// "the zone is only half working". The box he sees was drawn on the viewer's `planeBasis` while core and the preview's
// mask read a slab's half_u / half_w on core's `plane_basis` — for an up axis those differ by 90°, so a zone W ≠ D was
// drawn turned a quarter turn from the box the run lattices. Now the box, its handles and the region share core's basis.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class LatticeZoneBasisTests: XCTestCase {
    override func tearDown() { ManualPrimitive.controlZoneDrawnOnViewerBasis = false; super.tearDown() }

    /// The drawn outline's axes are core's: for an up axis, u = −y, w = +x (core/src/voxel/clearance.cpp plane_basis).
    func testTheBoxIsDrawnOnCoresBasis() {
        let (u, v) = corePlaneBasis(normal: SIMD3(0, 0, 1))
        XCTAssertEqual(u, SIMD3(0, -1, 0))
        XCTAssertEqual(v, SIMD3(1, 0, 0))
        let (cu, cw) = LatticeRegionMask.basisForTests(SIMD3(0, 0, 1))
        XCTAssertEqual(SIMD3<Double>(u), cu, "★ the preview's mask reads the same u")
        XCTAssertEqual(SIMD3<Double>(v), cw, "★ … and the same w")
        let oblique: [SIMD3<Float>] = [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0),
                                       simd_normalize(SIMD3<Float>(0.3, -0.5, 0.8)), simd_normalize(SIMD3<Float>(0.95, 0.1, 0.2))]
        for n in oblique {
            let (a, b) = corePlaneBasis(normal: n)
            let (ca, cb) = LatticeRegionMask.basisForTests(SIMD3<Double>(n))
            XCTAssertLessThan(simd_length(SIMD3<Double>(a) - ca), 1e-5, "\(n)")
            XCTAssertLessThan(simd_length(SIMD3<Double>(b) - cb), 1e-5, "\(n)")
        }
        ManualPrimitive.controlZoneDrawnOnViewerBasis = true
        XCTAssertEqual(corePlaneBasis(normal: SIMD3(0, 0, 1)).u, SIMD3(1, 0, 0), "control: the viewer's basis, as before")
    }

    /// ★ CORE ITSELF (its `plane_basis` through the bridge, the run's own route): the axes every hand-placed box is drawn on
    /// are core's, over the six axes and a spread of oblique normals; the control (the viewer's basis) is a quarter turn off
    /// on every axis-aligned normal.
    func testTheDrawnAxesAreCoresOwn() throws {
        let normals: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0), SIMD3(0, 0, 1),
                                       SIMD3(0, 0, -1), simd_normalize(SIMD3(0.3, -0.5, 0.8)), simd_normalize(SIMD3(0.95, 0.1, 0.2)),
                                       simd_normalize(SIMD3(0.89, 0.3, -0.34))]
        for n in normals {
            let core = try XCTUnwrap(TopOptKit.coreFacePlaneBasis(normal: SIMD3<Double>(n)), "bridge")
            let (u, v) = corePlaneBasis(normal: n)
            XCTAssertLessThan(simd_length(SIMD3<Double>(u) - core.u), 1e-5, "★ \(n): u")
            XCTAssertLessThan(simd_length(SIMD3<Double>(v) - core.w), 1e-5, "★ \(n): w")
        }
        for n in normals.prefix(6) {
            let core = try XCTUnwrap(TopOptKit.coreFacePlaneBasis(normal: SIMD3<Double>(n)))
            let viewer = planeBasis(normal: n)
            XCTAssertLessThan(abs(simd_dot(SIMD3<Double>(viewer.u), core.u)), 1e-6,
                              "control: the viewer's u is a quarter turn from core's on \(n)")
        }
    }

    /// ★ reviewer 11-09 19:55Z item 4: a hand-placed Topology Keep clear (W ≠ D) is drawn on core's axes — the box he sees is
    /// the solid core keeps clear (its job carries half_u / half_w with no frame; core reads them on `plane_basis`).
    @MainActor
    func testAHandPlacedKeepClearIsDrawnOnCoresAxes() throws {
        let p = ProjectModel(id: UUID(), name: "P", material: "PLA", process: .fdm, importedFile: nil, importedMesh: nil)
        let positions: [Float] = [0, 0, 0, 40, 0, 0, 40, 30, 0, 0, 30, 0]
        p.viewerMesh = ViewerMesh(vertices: positions, indices: [0, 1, 2, 0, 2, 3], faceIDs: [0, 0])
        var sel = SelectionModel()
        sel.addGroup(); sel.pickFaces([0])
        p.selection = sel
        let g = try XCTUnwrap(p.selection.groups.first).id
        p.force.makeAnchor(g)
        let mp = ManualPrimitive(kind: .face, center: SIMD3(20, 15, 0), axis: SIMD3(0, 0, 1), halfUMM: 12, halfWMM: 3)
        _ = p.force.addManualPrimitive(mp, to: g)
        func axes() throws -> SIMD3<Float> {
            let vol = try XCTUnwrap(p.clearanceVolumes().first { $0.volume.faceID == ProjectModel.manualFaceKey(mp.id) }, "the box").volume
            guard case let .slab(_, _, u, _, hu, _, _) = vol.shape else { XCTFail("a slab"); return .zero }
            XCTAssertEqual(hu, 12, accuracy: 1e-5)
            return u
        }
        let core = try XCTUnwrap(TopOptKit.coreFacePlaneBasis(normal: SIMD3(0, 0, 1)))
        XCTAssertLessThan(simd_length(SIMD3<Double>(try axes()) - core.u), 1e-6, "★ its 12 mm side drawn along core's u")
        ManualPrimitive.controlZoneDrawnOnViewerBasis = true
        XCTAssertGreaterThan(simd_length(SIMD3<Double>(try axes()) - core.u), 0.5, "control: drawn a quarter turn off, as before")
    }

    /// ★ HIS ZONE ON HIS STAND (HIS_PROJECT_DIR): a 54.1 × 30 × 90.8 mm No-lattice zone under Start from −, its box as the
    /// stage draws it. Every point inside the DRAWN box is inside the zone's region (so nothing there is latticed), and the
    /// corners of the box turned a quarter turn are not — red on the viewer's basis.
    @MainActor
    func testHisNoLatticeZoneCutsExactlyTheBoxHeSees() throws {
        let s = try HisStand1109LatticeTests.restore()
        let pm = s.pm
        pm.lattice.wholePart = true
        let id = try XCTUnwrap(pm.addLatticeZone(), "a zone")
        pm.setLatticeZoneSize(id, width: 54.1, depth: 30, height: 90.8)
        pm.lattice.groupRoles[id] = .exclude
        let mp = try XCTUnwrap(pm.latticeZonePrimitive(id))
        let ref = LatticeSelectableRef.primitive(mp.id)
        func check(_ label: String) throws -> (inside: Int, turned: Int) {
            let plane = try XCTUnwrap(pm.latticeDepthPlanes().first { $0.ref.key == ref.key }, "\(label): the zone's drawn box")
            guard case let .slab(c, n, u, v, hu, hv, depth) = plane.volume.shape else { XCTFail("a slab"); return (0, 0) }
            let region = try XCTUnwrap(pm.latticeJobRegions().regions.first { $0.selectableKey == ref.key }, "\(label): its region")
            XCTAssertEqual(region.role, .exclude)
            let C = SIMD3<Double>(Double(c.x), Double(c.y), Double(c.z))
            let N = SIMD3<Double>(Double(n.x), Double(n.y), Double(n.z))
            let U = SIMD3<Double>(Double(u.x), Double(u.y), Double(u.z))
            let V = SIMD3<Double>(Double(v.x), Double(v.y), Double(v.z))
            let HU = Double(hu), HV = Double(hv), D = Double(depth)
            var inside = 0, turned = 0, total = 0
            for a in stride(from: -0.9, through: 0.9, by: 0.3) {
                for b in stride(from: -0.9, through: 0.9, by: 0.3) {
                    for t in stride(from: 0.05, through: 0.95, by: 0.3) {
                        total += 1
                        let along: SIMD3<Double> = N * (t * D)
                        let pu: SIMD3<Double> = U * (a * HU)
                        let pv: SIMD3<Double> = V * (b * HV)
                        let p: SIMD3<Double> = C + pu + pv + along
                        if LatticeRegionMask.contains(p, region: region) { inside += 1 }
                        // the same point a quarter turn about the zone's axis through its middle
                        let qu: SIMD3<Double> = V * (a * HU)
                        let qv: SIMD3<Double> = U * (b * HV)
                        let q: SIMD3<Double> = C + qu - qv + along
                        if !LatticeRegionMask.contains(q, region: region) { turned += 1 }
                    }
                }
            }
            print("HIS1109 zone \(label): drawn-box samples inside the region \(inside)/\(total) · turned samples outside \(turned)")
            XCTAssertGreaterThan(total, 0)
            return (inside - total, turned)
        }
        let now = try check("now")
        ManualPrimitive.controlZoneDrawnOnViewerBasis = true
        let before = try check("before")
        ManualPrimitive.controlZoneDrawnOnViewerBasis = false
        XCTAssertLessThan(before.inside, 0, "control: on the viewer's basis the drawn box leaves part of itself outside the region")
        XCTAssertEqual(now.inside, 0, "★ every point of the box he sees is in the zone's region (inside − total)")
        XCTAssertGreaterThan(now.turned, 0, "★ and the box turned a quarter turn is not (W ≠ D)")
    }
}
