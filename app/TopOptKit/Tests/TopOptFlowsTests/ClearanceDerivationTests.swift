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

    /// An octagonal-prism bore WALL (curved bore, faces 1 & 2) capped by a planar
    /// octagon (face 3), with per-face B-rep geometry attached: faces 1/2 are a
    /// cylinder of radius 2.5 about +Z, face 3 a plane with +Z outward normal.
    ///
    /// The wall triangles are wound so their geometric normals point INWARD, toward
    /// the axis — a genuine through-HOLE, exactly as a real STL import winds a bore
    /// (the outward-from-solid normal of a hole wall faces into the cavity). This
    /// matters for `isFastenerBore` (handoff 2026-07-29), whose concavity vote
    /// separates a real hole from a convex boss / outer rim; a peg-wound octagon
    /// (normals outward) would be — correctly — rejected as not-a-fastener-bore.
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
            // Concave (inward-normal) winding — a hole wall, not a peg (see doc above).
            indices += [B(k), T(k + 1), B(k + 1), B(k), T(k), T(k + 1)]
            faceIDs += [1, 1]   // the WHOLE barrel is one pseudo-face (a full-wrap hole)
        }
        for k in 0..<n { indices += [topCentre, T(k), T(k + 1)]; faceIDs += [3] }
        // The bore is ONE face wrapping the full 360° — as the dihedral segmenter keeps
        // a smoothly-tessellated barrel (it fragments only on coarse >35° facets, the
        // PR-167 caveat). A ≥ 300°-wrap concave cylinder is a fastener bore (2026-07-29).
        // faceGeometry indexed by face id (size 4): 0/2 unused, 1 cylinder, 3 plane.
        let cyl = StepFaceGeometry(kind: .cylinder, cylinderRadiusMM: 2.5,
                                   axisPoint: SIMD3(0, 0, 0), axisDir: SIMD3(0, 0, 1))
        let plane = StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1),
                                     planeOrigin: SIMD3(0, 0, 10))
        let geo: [StepFaceGeometry] = [StepFaceGeometry(kind: .other), cyl,
                                       StepFaceGeometry(kind: .other), plane]
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

    // MARK: - fastener-bore gate (handoff 2026-07-29, clearance-heuristic-fix)

    /// A cylinder-wall face (id 1) of `segments` quads of a regular n-gon about +Z,
    /// wound `concave` (a hole) or convex (a boss / outer rim). `hasRadius == false`
    /// attaches an `.other` face geometry (a curved-but-not-a-fitted-cylinder face —
    /// the blank-Auto class). The wall wraps ≈ `segments/n · 360°`.
    private func cylWallMesh(n: Int, segments: Int, concave: Bool,
                             r: Float = 2.5, hasRadius: Bool = true) -> ViewerMesh {
        let ring = segments == n            // a full ring wraps; a partial arc does not
        let count = ring ? n : segments + 1
        var verts: [Float] = []
        for k in 0..<count { let a = Float(k) * (2 * .pi / Float(n)); verts += [r*cos(a), r*sin(a), 0] }
        for k in 0..<count { let a = Float(k) * (2 * .pi / Float(n)); verts += [r*cos(a), r*sin(a), 10] }
        var indices: [Int32] = []; var faceIDs: [Int32] = []
        func B(_ k: Int) -> Int32 { Int32(k % count) }
        func T(_ k: Int) -> Int32 { Int32(count + (k % count)) }
        for k in 0..<segments {
            if concave { indices += [B(k), T(k + 1), B(k + 1), B(k), T(k), T(k + 1)] }   // inward
            else       { indices += [B(k), B(k + 1), T(k + 1), B(k), T(k + 1), T(k)] }   // outward
            faceIDs += [1, 1]
        }
        let wall = hasRadius
            ? StepFaceGeometry(kind: .cylinder, cylinderRadiusMM: Double(r),
                               axisPoint: SIMD3(0, 0, 0), axisDir: SIMD3(0, 0, 1))
            : StepFaceGeometry(kind: .other)
        return ViewerMesh(vertices: verts, indices: indices, faceIDs: faceIDs,
                          faceGeometry: [StepFaceGeometry(kind: .other), wall])
    }

    /// A full concave through-hole is a fastener bore.
    func testFastenerBoreAcceptsConcaveFullHole() {
        let mesh = cylWallMesh(n: 8, segments: 8, concave: true)
        XCTAssertTrue(FaceTopology.isFastenerBore(1, in: mesh))
    }

    /// A full CONVEX ring (a boss / a round plate's outer rim) is a fitted cylinder and
    /// wraps 360° — but its walls face AWAY from the axis, so it is NOT a fastener bore.
    /// This is the `filleted_bore_plate` 22 mm-rim false positive the old test offered as
    /// a bolt hole. `isCurved` still calls it curved; the gate is what rejects it.
    func testFastenerBoreRejectsConvexRim() {
        let mesh = cylWallMesh(n: 8, segments: 8, concave: false)
        XCTAssertTrue(FaceTopology.isCurved(1, in: mesh), "the old 5° test accepts it")
        XCTAssertFalse(FaceTopology.isFastenerBore(1, in: mesh), "the gate rejects the convex rim")
    }

    /// A concave cylinder covering only a shallow arc (a rounded pocket corner, not a
    /// through-hole) wraps far below 300° and is rejected.
    func testFastenerBoreRejectsShallowArc() {
        let mesh = cylWallMesh(n: 8, segments: 2, concave: true)   // ~90° of wrap
        XCTAssertTrue(FaceTopology.isCurved(1, in: mesh))
        XCTAssertFalse(FaceTopology.isFastenerBore(1, in: mesh))
    }

    /// A curved face the segmenter could NOT fit as a cylinder (`.other`, no radius) —
    /// a sphere patch, cone, or pocket blend — is the source of every blank "— mm Auto"
    /// row. `isCurved` accepts it (→ a bore with no radius → blank); the gate rejects it.
    func testFastenerBoreRejectsNonCylinderCurvedFace() {
        let mesh = cylWallMesh(n: 8, segments: 8, concave: true, hasRadius: false)
        XCTAssertTrue(FaceTopology.isCurved(1, in: mesh), "curved, so the old test proposed a bore")
        XCTAssertFalse(FaceTopology.isFastenerBore(1, in: mesh), "no fitted radius → not a bore, no blank row")
    }

    /// C2: a non-cylinder curved face on an anchored group proposes NO auto clearance —
    /// so there is no bore row that could render a blank Auto pill, and the run stays
    /// byte-identical (empty specs / volumes).
    func testNonBoreCurvedFaceProducesNoBlankClearance() {
        let p = ProjectModel(id: UUID(), name: "P", material: "PLA", process: .fdm,
                             importedFile: nil, importedMesh: nil)
        p.viewerMesh = cylWallMesh(n: 8, segments: 8, concave: true, hasRadius: false)
        var sel = SelectionModel(); sel.addGroup(); sel.pickFaces([1]); p.selection = sel
        p.force.makeAnchor(sel.groups[0].id)
        XCTAssertFalse(p.autoClearanceApplies(sel.groups[0], in: p.viewerMesh!),
                       "a non-fitted curved face does not arm the auto rule")
        XCTAssertTrue(p.clearanceSpecs().isEmpty, "no bogus bore spec")
        XCTAssertTrue(p.clearanceVolumes().isEmpty, "no blank bore volume")
    }

    /// A convex boss on an anchored group likewise proposes nothing (over-finding fix).
    func testConvexBossDoesNotAutoClear() {
        let p = ProjectModel(id: UUID(), name: "P", material: "PLA", process: .fdm,
                             importedFile: nil, importedMesh: nil)
        p.viewerMesh = cylWallMesh(n: 8, segments: 8, concave: false)   // convex, has radius
        var sel = SelectionModel(); sel.addGroup(); sel.pickFaces([1]); p.selection = sel
        p.force.makeAnchor(sel.groups[0].id)
        XCTAssertTrue(p.clearanceSpecs().isEmpty, "a convex cylinder is not a fastener bore")
    }

    /// C4: a manually-added primitive is emitted regardless of the gate — the escape
    /// hatch forces a clearance onto a face the tightened detector would reject.
    func testManualPrimitiveUnaffectedByGate() {
        let p = ProjectModel(id: UUID(), name: "P", material: "PLA", process: .fdm,
                             importedFile: nil, importedMesh: nil)
        p.viewerMesh = cylWallMesh(n: 8, segments: 2, concave: true)   // a face the gate rejects
        var sel = SelectionModel(); sel.addGroup(); sel.pickFaces([1]); p.selection = sel
        let gid = sel.groups[0].id
        let mp = ManualPrimitive(kind: .bolt, center: SIMD3(0, 0, 5), axis: SIMD3(0, 0, 1),
                                 radiusMM: 3, halfLengthMM: 5)
        _ = p.force.addManualPrimitive(mp, to: gid)
        let specs = p.clearanceSpecs()
        XCTAssertEqual(specs.count, 1, "the manual bolt is emitted even though the face fails the gate")
        XCTAssertEqual(specs.first?.kind, .bolt)
    }
}
