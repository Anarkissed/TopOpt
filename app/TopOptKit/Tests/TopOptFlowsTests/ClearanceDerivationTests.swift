// Headless tests for the keep-clear v2 DERIVATION: ProjectModel turning the affix
// attribute + the exact bridge geometry into the run's clearance specs and the
// rendered volumes. Covers the auto (anchored-bore) rule, the auto-suppression
// override, the explicit affix on planes, and that the drawn volume uses the same
// resolved numbers the specs send. The wire format is unchanged; these pin the
// APP-side mapping onto it.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class ClearanceDerivationTests: XCTestCase {

    /// An octagonal-prism wall (curved bore, faces 1 & 2) capped by a planar octagon
    /// (face 3), with per-face B-rep geometry attached: faces 1/2 are a cylinder of
    /// radius 2.5 about +Z, face 3 a plane with +Z outward normal. Mirrors the
    /// FaceSelection octagon fixture but carries `faceGeometry` (keep-clear v2).
    private func borePlusPlaneMesh() -> ViewerMesh {
        let n = 8
        var verts: [Float] = []
        let r: Float = 2.5
        for k in 0..<n { let a = Float(k) * (2 * .pi / Float(n)); verts += [r*cos(a), r*sin(a), 0] }
        for k in 0..<n { let a = Float(k) * (2 * .pi / Float(n)); verts += [r*cos(a), r*sin(a), 10] }
        verts += [0, 0, 10]
        let topCentre: Int32 = 16
        var indices: [Int32] = []
        var faceIDs: [Int32] = []
        func B(_ k: Int) -> Int32 { Int32(k % n) }
        func T(_ k: Int) -> Int32 { Int32(n + (k % n)) }
        for k in 0..<n {
            indices += [B(k), B(k + 1), T(k + 1), B(k), T(k + 1), T(k)]
            let id: Int32 = k < 4 ? 1 : 2
            faceIDs += [id, id]
        }
        for k in 0..<n { indices += [topCentre, T(k), T(k + 1)]; faceIDs += [3] }
        // faceGeometry indexed by face id (size 4): 0 unused, 1&2 cylinder, 3 plane.
        let cyl = StepFaceGeometry(kind: .cylinder, cylinderRadiusMM: 2.5,
                                   axisPoint: SIMD3(0, 0, 0), axisDir: SIMD3(0, 0, 1))
        let plane = StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1),
                                     planeOrigin: SIMD3(0, 0, 10))
        let geo: [StepFaceGeometry] = [StepFaceGeometry(kind: .other), cyl, cyl, plane]
        return ViewerMesh(vertices: verts, indices: indices, faceIDs: faceIDs, faceGeometry: geo)
    }

    /// A project with the bore+plane mesh, an anchor group on the bore (face 1) and a
    /// bare group on the plane (face 3). Returns the project + the two group ids.
    private func project() -> (ProjectModel, boreID: UUID, planeID: UUID) {
        let p = ProjectModel(id: UUID(), name: "P", material: "PLA", process: .fdm,
                             importedFile: nil, importedMesh: nil)
        p.viewerMesh = borePlusPlaneMesh()
        var sel = SelectionModel()
        sel.addGroup(); sel.pickFaces([1])          // bore group
        sel.addGroup(); sel.pickFaces([3])          // plane group
        p.selection = sel
        let ids = sel.groups.map { $0.id }
        p.force.makeAnchor(ids[0])                  // anchor the bore
        return (p, ids[0], ids[1])
    }

    // MARK: - clearanceSpecs

    func testAnchoredBoreAutoClearanceIsDerived() {
        let (p, _, _) = project()
        let specs = p.clearanceSpecs()
        XCTAssertEqual(specs.count, 1, "the anchored bore auto-gets one bolt clearance")
        XCTAssertEqual(specs.first?.faceID, 1)
        XCTAssertEqual(specs.first?.kind, .bolt)
        // Un-overridden → 0 sentinels (the core re-derives). Wire format unchanged.
        XCTAssertEqual(specs.first?.concentricMarginMM, 0)
        XCTAssertEqual(specs.first?.axialClearanceMM, 0)
    }

    func testAutoSuppressionOverrideDropsTheClearance() {
        let (p, boreID, _) = project()
        // Toggle the auto bore OFF → an explicit suppression → NOT in the run.
        p.force.setKeepClear(boreID, on: false, autoDefault: p.keepClearAutoDefault(
            p.selection.groups.first { $0.id == boreID }!))
        XCTAssertEqual(p.force.keepClearAffix(for: boreID), .suppressed)
        XCTAssertTrue(p.clearanceSpecs().isEmpty, "suppressed auto clearance is omitted (sent as such)")
    }

    func testExplicitAffixOnPlaneAddsSlab() {
        let (p, _, planeID) = project()
        p.force.setKeepClearAffix(planeID, .on)
        let specs = p.clearanceSpecs()
        // The bore still auto-clears (bolt), the plane now clears too (slab).
        XCTAssertEqual(specs.count, 2)
        XCTAssertTrue(specs.contains { $0.faceID == 3 && $0.kind == .face })
        XCTAssertTrue(specs.contains { $0.faceID == 1 && $0.kind == .bolt })
    }

    func testNoKeepClearMeansEmptySpecs() {
        // A load/anchor-only project with the bore NOT anchored → no clearance at all,
        // preserving the empty-list byte-identical path.
        let p = ProjectModel(id: UUID(), name: "P", material: "PLA", process: .fdm,
                             importedFile: nil, importedMesh: nil)
        p.viewerMesh = borePlusPlaneMesh()
        var sel = SelectionModel()
        sel.addGroup(); sel.pickFaces([3])          // plane only, will be a load
        p.selection = sel
        let id = sel.groups[0].id
        p.force.makeLoad(id)
        XCTAssertTrue(p.clearanceSpecs().isEmpty)
    }

    func testOverrideThreadsThroughToSpec() {
        let (p, boreID, _) = project()
        p.force.setClearanceMargin(boreID, mm: 4.0)
        let spec = p.clearanceSpecs().first { $0.faceID == 1 }
        XCTAssertEqual(spec?.concentricMarginMM, 4.0, "the user number reaches the run")
    }

    // MARK: - clearanceVolumes (render data source)

    func testBoreVolumeUsesExactRadiusAndAutoSuggestion() {
        let (p, _, _) = project()
        let vols = p.clearanceVolumes()
        XCTAssertEqual(vols.count, 1)
        guard case let .cylinder(_, _, radius, tLo, tHi) = vols[0].volume.shape else {
            return XCTFail("expected a cylinder")
        }
        // Auto margin = bore radius (2.5) → drawn radius = 2.5 + 2.5 = 5.0 (the run's).
        XCTAssertEqual(radius, 5.0, accuracy: 1e-4)
        // Tessellation span z∈[0,10], auto axial = 2×2.5 = 5 each side → [-5, 15].
        XCTAssertEqual(tLo, -5.0, accuracy: 1e-3)
        XCTAssertEqual(tHi, 15.0, accuracy: 1e-3)
    }

    func testSuppressedBoreDrawsNoVolume() {
        let (p, boreID, _) = project()
        p.force.setKeepClearAffix(boreID, .suppressed)
        XCTAssertTrue(p.clearanceVolumes().isEmpty)
    }

    // MARK: - clearanceHandles (Phase B drag anchors)

    func testBoreHandlesMatchTheRenderedVolume() {
        let (p, _, _) = project()
        let entries = p.clearanceHandles()
        XCTAssertEqual(entries.count, 1, "one cleared face (the anchored bore)")
        let handles = entries[0].handles
        // Wall (margin) + ONE end cap (axial) — round 3 item 9: a single
                // axial handle per keep-clear cylinder (the second cap was removed).
                XCTAssertEqual(handles.count, 2)
                XCTAssertNotNil(handles.first { $0.role == .margin })
                XCTAssertNotNil(handles.first { $0.role == .axialHi })
                XCTAssertNil(handles.first { $0.role == .axialLo },
                             "the low cap must NOT come back — one axial handle only")
        // The wall handle carries the EXACT bore radius (2.5), and the +cap measures
        // from the fixed tessellation end (span.hi = 10) — the same numbers the run
        // freezes, so a drag reads off the true geometry.
        let margin = handles.first { $0.role == .margin }!
        XCTAssertEqual(margin.boreRadiusMM, 2.5, accuracy: 1e-4)
        let hi = handles.first { $0.role == .axialHi }!
        XCTAssertEqual(hi.boreEndT, 10, accuracy: 1e-3)
    }

    func testSuppressedBoreHasNoHandles() {
        let (p, boreID, _) = project()
        p.force.setKeepClearAffix(boreID, .suppressed)
        XCTAssertTrue(p.clearanceHandles().isEmpty)
    }

    func testExplicitPlaneAffixAddsDepthHandle() {
        let (p, _, planeID) = project()
        p.force.setKeepClearAffix(planeID, .on)
        let planeEntry = try! XCTUnwrap(p.clearanceHandles().first { $0.faceID == 3 })
        XCTAssertEqual(planeEntry.handles.count, 1)
        XCTAssertEqual(planeEntry.handles[0].role, .slabDepth)
    }
}
