// Headless tests for Face protection (handoff 124 — preserve-skin) across the app
// layers: the ForceModel "Protect" affix + global depth, ProjectModel spec
// derivation, ResultsModel honesty notes, OutcomeCodec persistence round-trip, and
// a compile check of the crosshatch MSL. The GPU crosshatch itself is maintainer
// device QA; its LOGIC + the shader's compilability are pinned here.

import XCTest
import Metal
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FaceProtectionTests: XCTestCase {

    // MARK: - ForceModel: the Protect affix + global depth

    private func groups(_ faces: [FaceID]) -> (SelectionModel, [UUID]) {
        var m = SelectionModel()
        for f in faces { m.addGroup(); m.pickFaces([f]) }
        return (m, m.groups.map { $0.id })
    }

    func testProtectAffixTogglesAndIsExplicit() {
        let (_, ids) = groups([1])
        var fm = ForceModel()
        XCTAssertFalse(fm.isProtected(ids[0]))
        fm.setProtected(ids[0], true)
        XCTAssertTrue(fm.isProtected(ids[0]))
        fm.setProtected(ids[0], false)
        XCTAssertFalse(fm.isProtected(ids[0]), "removing a protection clears it (minimal map)")
    }

    func testProtectOnlyGroupIsACompleteDeclaration() {
        let (sel, ids) = groups([1])
        var fm = ForceModel()
        // A bare pending group blocks Optimize…
        XCTAssertTrue(fm.hasPending(in: sel.groups))
        // …until it carries an attribute. Protect-only is complete, like keep-clear-only.
        fm.setProtected(ids[0], true)
        XCTAssertTrue(fm.isProtectOnly(ids[0]))
        XCTAssertFalse(fm.hasPending(in: sel.groups),
                       "a protect-only selection does not block Optimize")
    }

    func testDefaultGlobalDepthMatchesCoreDefault() {
        let fm = ForceModel()
        XCTAssertEqual(fm.faceProtectDepthMM, FaceProtection.defaultDepthMM, accuracy: 1e-9)
        XCTAssertEqual(FaceProtection.defaultDepthMM, 5.0, accuracy: 1e-9,
                       "the app default mirrors the core kFaceProtectionDepthDefaultMm")
    }

    func testProtectStateRoundTripsThroughCodable() throws {
        let (_, ids) = groups([1, 2])
        var fm = ForceModel()
        fm.setProtected(ids[0], true)
        fm.faceProtectDepthMM = 8.0
        let data = try JSONEncoder().encode(fm)
        let back = try JSONDecoder().decode(ForceModel.self, from: data)
        XCTAssertTrue(back.isProtected(ids[0]))
        XCTAssertFalse(back.isProtected(ids[1]))
        XCTAssertEqual(back.faceProtectDepthMM, 8.0, accuracy: 1e-9)
    }

    func testProtectionFreeSnapshotOmitsTheKeys() throws {
        // THE ONE RULE at the persistence layer: with no protection and the default
        // depth, the encoded snapshot carries neither new key (byte-identical to a
        // pre-124 snapshot for these fields).
        let fm = ForceModel()
        let obj = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(fm)) as? [String: Any] ?? [:]
        XCTAssertNil(obj["faceProtect"], "no protection → the affix key is omitted")
        XCTAssertNil(obj["faceProtectDepthMM"], "default depth → the depth key is omitted")
    }

    // MARK: - ProjectModel: spec derivation

    private func planeMesh() -> ViewerMesh {
        // Two faces: id 1 and id 2, each a small quad in the z=0 plane.
        let verts: [Float] = [0,0,0, 1,0,0, 1,1,0, 0,1,0,  2,0,0, 3,0,0, 3,1,0, 2,1,0]
        let indices: [Int32] = [0,1,2, 0,2,3,  4,5,6, 4,6,7]
        let faceIDs: [Int32] = [1,1, 2,2]
        let plane = StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0,0,1),
                                     planeOrigin: SIMD3(0,0,0))
        let geo: [StepFaceGeometry] = [StepFaceGeometry(kind: .other), plane, plane]
        return ViewerMesh(vertices: verts, indices: indices, faceIDs: faceIDs, faceGeometry: geo)
    }

    private func project() -> (ProjectModel, [UUID]) {
        let p = ProjectModel(id: UUID(), name: "P", material: "PLA", process: .fdm,
                             importedFile: nil, importedMesh: nil)
        p.viewerMesh = planeMesh()
        var sel = SelectionModel()
        sel.addGroup(); sel.pickFaces([1])
        sel.addGroup(); sel.pickFaces([2])
        p.selection = sel
        return (p, sel.groups.map { $0.id })
    }

    func testNoProtectionYieldsEmptySpecs() {
        let (p, _) = project()
        let specs = p.faceProtectionSpecs()
        XCTAssertTrue(specs.faceIDs.isEmpty, "THE ONE RULE: no protection → no face ids")
        XCTAssertEqual(specs.depthMM, FaceProtection.defaultDepthMM, accuracy: 1e-9)
    }

    func testProtectedGroupFacesAndGlobalDepthAreDerived() {
        let (p, ids) = project()
        p.force.setProtected(ids[0], true)
        p.force.faceProtectDepthMM = 6.0
        let specs = p.faceProtectionSpecs()
        XCTAssertEqual(specs.faceIDs, [1], "only the protected group's face is sent")
        XCTAssertEqual(specs.depthMM, 6.0, accuracy: 1e-9, "the ONE global depth is sent")
        // Protect the second group too → both faces, deduped, one global depth.
        p.force.setProtected(ids[1], true)
        XCTAssertEqual(Set(p.faceProtectionSpecs().faceIDs), [1, 2])
    }

    // MARK: - ResultsModel: honesty notes

    func testFaceProtectionNotesFormatting() {
        let notes = ResultsModel.faceProtectionNotes([
            AppliedFaceProtection(faceID: 4, voxelsFrozen: 120, depthVoxels: 3, thinnerThanDepth: false),
            AppliedFaceProtection(faceID: 7, voxelsFrozen: 40, depthVoxels: 5, thinnerThanDepth: true),
            AppliedFaceProtection(faceID: 9, voxelsFrozen: 0, depthVoxels: 3, thinnerThanDepth: false),
        ])
        XCTAssertEqual(notes.count, 3)
        XCTAssertTrue(notes[0].contains("face 4") && notes[0].contains("120 voxels"))
        XCTAssertFalse(notes[0].contains("thinner"))
        XCTAssertTrue(notes[1].contains("thinner than the depth"),
                      "the honest edge surfaces when the face was thinner than the depth")
        XCTAssertTrue(notes[2].contains("no solid"), "a zero-voxel protection is surfaced, not hidden")
    }

    func testFaceProtectionNotesSurfacedOnResultsModel() {
        let oc = OptimizeOutcome(
            variants: [], stoppedOnMargin: false, cancelled: false, acceptedCount: 0,
            appliedFaceProtections: [
                AppliedFaceProtection(faceID: 4, voxelsFrozen: 120, depthVoxels: 3, thinnerThanDepth: false)])
        let m = ResultsModel(projectName: "P", outcome: oc)
        XCTAssertEqual(m.faceProtectionNotes.count, 1)
    }

    // MARK: - OutcomeCodec: persistence round-trip

    func testAppliedFaceProtectionsRoundTrip() throws {
        let o = OptimizeOutcome(
            variants: [], stoppedOnMargin: false, cancelled: false, acceptedCount: 0,
            appliedFaceProtections: [
                AppliedFaceProtection(faceID: 4, voxelsFrozen: 120, depthVoxels: 3, thinnerThanDepth: false),
                AppliedFaceProtection(faceID: 7, voxelsFrozen: 40, depthVoxels: 5, thinnerThanDepth: true)])
        let back = try OutcomeCodec.decode(try OutcomeCodec.encode(OutcomeCodec.dto(from: o)))
        XCTAssertEqual(back.appliedFaceProtections, o.appliedFaceProtections,
                       "a reopened run keeps its honest protection notes (no honesty drop)")
    }

    func testLegacyBlobWithoutProtectionsDecodes() throws {
        // A pre-124 blob has no `appliedFaceProtections` key → decodes to empty, never
        // failing the whole outcome (the 108-class honesty round-trip discipline).
        let data = try OutcomeCodec.encode(OutcomeCodec.dto(from: OptimizeOutcome(
            variants: [], stoppedOnMargin: false, cancelled: false, acceptedCount: 0)))
        let obj = try PropertyListSerialization.propertyList(
            from: data, options: PropertyListSerialization.ReadOptions(), format: nil)
        var plist = try XCTUnwrap(obj as? [String: Any])
        plist.removeValue(forKey: "appliedFaceProtections")
        let stripped = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .binary, options: 0)
        let back = try OutcomeCodec.decode(stripped)
        XCTAssertTrue(back.appliedFaceProtections.isEmpty)
    }

    // MARK: - Shader: the crosshatch MSL compiles

    func testViewerShaderCompiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device (headless CI without a GPU)")
        }
        let lib = try device.makeLibrary(source: MeshRenderer.viewerShaderSourceForTesting, options: nil)
        XCTAssertNotNil(lib.makeFunction(name: "viewer_vertex"), "viewer_vertex missing")
        XCTAssertNotNil(lib.makeFunction(name: "viewer_fragment"),
                        "viewer_fragment missing — the handoff-124 crosshatch must not break the MSL")
    }
}
