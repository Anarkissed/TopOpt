// ProjectStoreSidecarTests.swift — the project store carries what the selections
// were authored against (task project-store-sidecars, chip Q-A from handoff
// 2026-07-31-analyze-loadcase-resolution).
//
// THE BUG: `ProjectStore.save` copied ONLY the model file. The face-overrides
// sidecar (`<model>.faces`, the painted pseudo-faces) and the clearance sidecar
// (`<model>.clearances.json`) live next to the ORIGINAL import path and were
// never copied. On reopen, `AppModel.restoreFromDisk` re-imports from the store
// copy; without the sidecar the painted pseudo-faces do not exist — while the
// restored SelectionModel groups still reference their ids. RUN SIM / Optimize
// then throw "face_id out of range", or tag the wrong faces.
//
// These tests drive the REAL flow (AppModel + ProjectStore + the bridge
// importer) against a temp directory and the committed cube fixture:
//   Q1 — save with painted faces + groups, reopen, every group's ids resolve to
//        the SAME faces (same ids, face count, tagged voxel counts). Written to
//        FAIL on the pre-fix store (the sidecar never arrived in the store).
//   Q2 — a project saved WITHOUT the sidecar (an existing/legacy project) opens
//        without crashing and says plainly which groups cannot resolve.
//   Q3 — the round trip runs SIM: reopen → analyze under the declared load,
//        with the resolved load magnitude and per-group tagged voxel counts
//        all non-zero, and deterministic across a re-run.

import XCTest
import TopOptKit
@testable import TopOptFlows

@MainActor
final class ProjectStoreSidecarTests: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    private static func core(_ rel: String) -> String {
        repoRoot.appendingPathComponent("core/\(rel)").path
    }
    private static var materialsPath: String { core("src/materials/materials.json") }
    private static var rulesPath: String { core("src/settings/rules.json") }
    private static var cubeSTL: String { core("tests/fixtures/stl/cube_10mm.stl") }

    /// One temp sandbox per test: an `import/` dir standing in for the picked
    /// file's location (so sidecars written next to the "original import" never
    /// touch the committed fixture) and a `store/` dir for the ProjectStore.
    private var sandbox: URL!
    private var importDir: URL!
    private var storeDir: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("topopt-sidecar-tests-\(UUID().uuidString)", isDirectory: true)
        importDir = sandbox.appendingPathComponent("import", isDirectory: true)
        storeDir = sandbox.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: importDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
    }

    private func appModel() -> AppModel {
        AppModel(materialsPath: Self.materialsPath, rulesPath: Self.rulesPath,
                 store: ProjectStore(rootDir: storeDir))
    }

    /// All triangle indices of face `id` in `mesh` (the tap-equivalent set).
    private func triangles(ofFace id: Int32, in mesh: ImportedMesh) -> [Int] {
        mesh.faceIDs.enumerated().filter { $0.element == id }.map { $0.offset }
    }

    /// Launch 1: import the cube from the sandboxed "original" location, paint
    /// native face 0's triangles into a Load group (6 kg), pick native face 1 as
    /// an Anchor group, persist the paint sidecar (the stroke-END path), and
    /// autosave via backHome. Returns what the reopen must reproduce.
    private func saveProjectWithPaintedLoad()
        throws -> (recentID: UUID, base: Int32, paintedTris: Set<Int>,
                   loadGroupID: UUID, loadGroupName: String, anchorGroupID: UUID,
                   anchorFaceID: Int32) {
        let src = importDir.appendingPathComponent("cube.stl")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: Self.cubeSTL), to: src)

        let m1 = appModel()
        m1.loadMaterials(); m1.newTopOpt(); m1.selectMaterial("PLA")
        XCTAssertTrue(m1.importFile(atPath: src.path, displayName: "Painted_Cube.stl"))
        m1.continueToWorkspace()
        let p = try XCTUnwrap(m1.project)
        let mesh = try XCTUnwrap(p.importedMesh)
        let base = Int32(mesh.faceCount)

        p.force.setGravity(faceNormal: SIMD3<Float>(0, 0, -1), face: 5)

        // Paint the whole of native face 0 — the paint-mode escape from a tap.
        let tris = triangles(ofFace: 0, in: mesh)
        XCTAssertFalse(tris.isEmpty)
        p.paintStroke(.add, triangles: tris)
        let loadGroup = try XCTUnwrap(p.selection.activeGroup,
                                      "the stroke created/activated a group")
        XCTAssertEqual(loadGroup.faces.filter { p.paint!.isPainted($0) }, [base],
                       "one painted pseudo-face, minted at baseFaceCount")
        p.force.makeLoad(loadGroup.id)
        p.force.setWeight(loadGroup.id, kg: 6.0)

        // A tapped (native-face) anchor group alongside the painted load.
        let anchorID = p.selection.addGroup()
        p.selection.pickFace(1)
        p.force.makeAnchor(anchorID)

        p.persistPaint()   // the stroke-END persistence the gesture layer does
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path + ".faces"),
                      "the paint sidecar exists next to the ORIGINAL import")

        m1.backHome()      // autosave into the store

        let recent = try XCTUnwrap(m1.recentProjects.first)
        return (recent.id, base, Set(tris), loadGroup.id, loadGroup.name,
                anchorID, 1)
    }

    // MARK: - Q1: the round trip (written to FAIL on the pre-fix store)

    func testQ1PaintedGroupsResolveToSameFacesAfterReopen() throws {
        let saved = try saveProjectWithPaintedLoad()

        // Tagged voxel counts against the ORIGINAL import (sidecar present) —
        // the ground truth the reopened project must reproduce.
        let srcPath = importDir.appendingPathComponent("cube.stl").path
        let originalLoadVoxels = try TopOptKit.tagStepFace(
            stepPath: srcPath, faceID: Int(saved.base), asFixture: false, resolution: 32)
        let originalAnchorVoxels = try TopOptKit.tagStepFace(
            stepPath: srcPath, faceID: Int(saved.anchorFaceID), asFixture: true, resolution: 32)
        XCTAssertGreaterThan(originalLoadVoxels, 0)
        XCTAssertGreaterThan(originalAnchorVoxels, 0)

        // Launch 2: a fresh AppModel over the same store directory.
        let m2 = appModel()
        let recent = try XCTUnwrap(m2.recentProjects.first(where: { $0.id == saved.recentID }))
        m2.open(recent)
        let restored = try XCTUnwrap(m2.project)
        let mesh = try XCTUnwrap(restored.importedMesh, "the store copy re-imports")
        let storePath = try XCTUnwrap(restored.importedFile?.path)

        // The store copy must carry the sidecar, so the re-import HAS the
        // painted pseudo-face. Pre-fix this fails: faceCount == base (the
        // painted id space is gone while the groups still reference it).
        XCTAssertEqual(Int32(mesh.faceCount), saved.base + 1,
                       "the reopened model carries the painted pseudo-face")

        // Same ids: every group's face ids still resolve on the re-import.
        for g in restored.selection.groups {
            for f in g.faces {
                XCTAssertLessThan(f, Int32(mesh.faceCount),
                                  "group “\(g.name)” face \(f) resolves on the reopened model")
            }
        }
        let loadGroup = try XCTUnwrap(
            restored.selection.groups.first(where: { $0.id == saved.loadGroupID }))
        XCTAssertEqual(loadGroup.faces, [saved.base], "the painted load kept its id")

        // Same faces: the painted face covers exactly the painted triangles.
        XCTAssertEqual(Set(triangles(ofFace: saved.base, in: mesh)), saved.paintedTris,
                       "the reopened painted face covers the same triangles")

        // Same tagged voxel counts, through the real bridge tagger.
        let reopenedLoadVoxels = try TopOptKit.tagStepFace(
            stepPath: storePath, faceID: Int(saved.base), asFixture: false, resolution: 32)
        let reopenedAnchorVoxels = try TopOptKit.tagStepFace(
            stepPath: storePath, faceID: Int(saved.anchorFaceID), asFixture: true, resolution: 32)
        XCTAssertEqual(reopenedLoadVoxels, originalLoadVoxels,
                       "the painted load tags the same voxels as before the save")
        XCTAssertEqual(reopenedAnchorVoxels, originalAnchorVoxels,
                       "the tapped anchor tags the same voxels as before the save")
    }

    // MARK: - Q2: an EXISTING (pre-fix) project opens legibly, not with a crash

    func testQ2LegacyProjectWithoutSidecarOpensWithNamedWarning() throws {
        let saved = try saveProjectWithPaintedLoad()

        // Simulate a project saved by the PRE-FIX store: strip the sidecars the
        // fixed save just copied, leaving exactly what an existing project has
        // on disk — the model copy and project.json, no `.faces`.
        let store = ProjectStore(rootDir: storeDir)
        let snap = try XCTUnwrap(store.snapshot(id: saved.recentID))
        let storeModel = store.modelPath(id: saved.recentID, fileName: snap.modelFileName)
        for suffix in ProjectStore.sidecarSuffixes {
            try? FileManager.default.removeItem(atPath: storeModel + suffix)
        }

        let m2 = appModel()
        let recent = try XCTUnwrap(m2.recentProjects.first(where: { $0.id == saved.recentID }))
        m2.open(recent)   // must not crash
        let restored = try XCTUnwrap(m2.project)
        XCTAssertNotNil(restored.viewerMesh, "the project still opens")

        // The warning names the group that cannot resolve and says how to recover.
        let warning = try XCTUnwrap(restored.restoreWarning,
                                    "a sidecar-less restore is detected and said plainly")
        XCTAssertTrue(warning.contains(saved.loadGroupName),
                      "the warning names the affected group: \(warning)")
        XCTAssertTrue(warning.lowercased().contains("re-paint"),
                      "the warning states the recovery: \(warning)")
        XCTAssertEqual(m2.toast, warning, "AppModel surfaces it at open")

        // The intact (tapped, native-face) anchor group is NOT named.
        XCTAssertFalse(warning.contains("Group B"),
                       "a group whose faces still resolve is not blamed: \(warning)")
    }

    /// The warning composer is pure — pin the nil (healthy) side too.
    func testQ2WarningNilWhenEveryGroupResolves() {
        var selection = SelectionModel()
        _ = selection.addGroup()
        selection.pickFace(3)
        XCTAssertNil(ProjectModel.unresolvableGroupsWarning(selection: selection, faceCount: 6))
        XCTAssertNotNil(ProjectModel.unresolvableGroupsWarning(selection: selection, faceCount: 3))
    }

    // MARK: - Q3: the reopened project RUNS SIM — resolved load + tagged voxels

    func testQ3RoundTripRunSimResolvesDeclaredLoad() throws {
        let saved = try saveProjectWithPaintedLoad()

        let m2 = appModel()
        let recent = try XCTUnwrap(m2.recentProjects.first(where: { $0.id == saved.recentID }))
        m2.open(recent)
        let restored = try XCTUnwrap(m2.project)
        let storePath = try XCTUnwrap(restored.importedFile?.path)
        XCTAssertNil(restored.restoreWarning, "a post-fix save reopens with no warning")

        // The load case the run/sim assembles from the restored state.
        let lc = restored.loadCase()
        XCTAssertEqual(lc.anchorFaceIDs, [Int(saved.anchorFaceID)])
        XCTAssertEqual(lc.loadGroups.count, 1, "the painted load survived the round trip")
        let force = try XCTUnwrap(lc.loadGroups.first).force
        let magnitude = (force.x * force.x + force.y * force.y + force.z * force.z).squareRoot()
        XCTAssertEqual(magnitude, 6.0 * 9.80665, accuracy: 1e-6,
                       "6 kg resolves to its real force (kgf → N)")

        // Per-group tagged voxel counts on the REOPENED model — non-zero, or the
        // traction/clamp never reaches the solver.
        let loadFace = try XCTUnwrap(lc.loadGroups.first?.faceIDs.first)
        let loadVoxels = try TopOptKit.tagStepFace(
            stepPath: storePath, faceID: loadFace, asFixture: false, resolution: 32)
        let anchorVoxels = try TopOptKit.tagStepFace(
            stepPath: storePath, faceID: Int(saved.anchorFaceID), asFixture: true, resolution: 32)
        XCTAssertGreaterThan(loadVoxels, 0, "the painted load tags voxels after reopen")
        XCTAssertGreaterThan(anchorVoxels, 0, "the anchor tags voxels after reopen")

        // RUN SIM itself (the on-device analyze path), on the reopened project.
        let sim = try TopOptKit.analyzeSolidLoadCase(
            modelPath: storePath, material: "PLA", materialsPath: Self.materialsPath,
            rulesPath: Self.rulesPath, resolution: 32,
            anchorFaceIDs: lc.anchorFaceIDs, loadGroups: lc.loadGroups,
            buildDirection: lc.buildDirection)
        XCTAssertFalse(sim.nonConvergent, "the sim solve converges")
        XCTAssertGreaterThan(sim.maxStressMPa, 0, "the declared load produced real stress")

        // Q6 within the round trip: the same sim on the same reopened project is
        // bit-identical — field included.
        let again = try TopOptKit.analyzeSolidLoadCase(
            modelPath: storePath, material: "PLA", materialsPath: Self.materialsPath,
            rulesPath: Self.rulesPath, resolution: 32,
            anchorFaceIDs: lc.anchorFaceIDs, loadGroups: lc.loadGroups,
            buildDirection: lc.buildDirection)
        XCTAssertEqual(sim, again, "RUN SIM on the reopened project is deterministic")

        print("Q3 EVIDENCE: |F|=\(magnitude) N, load voxels=\(loadVoxels), "
              + "anchor voxels=\(anchorVoxels), maxStress=\(sim.maxStressMPa) MPa, "
              + "maxDisp=\(sim.maxDisplacementMM) mm, accepted=\(sim.accepted)")
    }

    // MARK: - Q4: the bridge's empty-load-case refusal names group + reason

    func testQ4BridgeRefusalNamesGroupAndReason() throws {
        // A declared load group with ZERO force: the load case resolves to no
        // external load, and the bridge must surface core's per-group message —
        // not the old generic string.
        do {
            _ = try TopOptKit.analyzeSolidLoadCase(
                modelPath: Self.cubeSTL, material: "PLA", materialsPath: Self.materialsPath,
                rulesPath: Self.rulesPath, resolution: 32,
                anchorFaceIDs: [1],
                loadGroups: [.init(faceIDs: [0], force: SIMD3<Double>(0, 0, 0))])
            XCTFail("an empty load case must refuse to analyze")
        } catch {
            let msg = "\(error)"
            XCTAssertTrue(msg.contains("group 0"), "the refusal names the group: \(msg)")
            XCTAssertTrue(msg.contains("zero force"), "…and the reason: \(msg)")
            XCTAssertTrue(msg.contains("face 0"), "…and the group's faces: \(msg)")
            XCTAssertFalse(msg.contains("every group zero-force or tagged no voxels"),
                           "the old generic string is gone: \(msg)")
            print("Q4 EVIDENCE: \(msg)")
        }
    }

    // MARK: - Q6: saving is deterministic (same state → same bytes, stale-safe)

    func testQ6SaveSyncsSidecarsDeterministicallyAndDropsStaleOnes() throws {
        let saved = try saveProjectWithPaintedLoad()
        let store = ProjectStore(rootDir: storeDir)
        let snap = try XCTUnwrap(store.snapshot(id: saved.recentID))
        let src = importDir.appendingPathComponent("cube.stl")
        let storeModel = store.modelPath(id: saved.recentID, fileName: snap.modelFileName)

        // Save the identical snapshot VALUE twice: bytes identical. (The compare
        // is between two saves of the same decoded value, not against the live
        // model's encode — ForceModel's UUID-keyed dictionaries encode as arrays
        // in iteration order, so distinct instances may legitimately reorder.)
        let jsonURL = URL(fileURLWithPath: storeModel)
            .deletingLastPathComponent().appendingPathComponent("project.json")
        try store.save(snap, modelSource: src)
        let sidecar1 = try Data(contentsOf: URL(fileURLWithPath: storeModel + ".faces"))
        let json1 = try Data(contentsOf: jsonURL)
        try store.save(snap, modelSource: src)
        let sidecar2 = try Data(contentsOf: URL(fileURLWithPath: storeModel + ".faces"))
        let json2 = try Data(contentsOf: jsonURL)
        XCTAssertEqual(sidecar1, sidecar2, "the re-synced sidecar is byte-identical")
        XCTAssertEqual(json1, json2, "the snapshot encodes byte-identically")

        // A cleared paint overlay DELETES the source sidecar; the next save must
        // drop the store copy too (no stale resurrection on reopen).
        try FileManager.default.removeItem(atPath: src.path + ".faces")
        try store.save(snap, modelSource: src)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeModel + ".faces"),
                       "a deleted source sidecar is deleted from the store on save")
    }
}
