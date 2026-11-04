// RedesignAnswersPinsTests.swift — B8, his answers of 2026-10-24 (rulings approved by him). These use only APIs that
// existed at 9c9d38b5, so on that tree the changed items fail on their assertions and the unchanged ones pass as pins (the
// red-first record is in the B8 commit message).

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class RedesignAnswersPinsTests: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    private static func src(_ file: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent("app/TopOptKit/Sources/TopOptFlows/\(file)"), encoding: .utf8)
    }

    // MARK: 3 — no "Sim" on the Cells page's Density row; Along "By stress" is the one place for it

    func testTheDensityRowOffersNoSimAndByStressSetsWhatSimSet() throws {
        let wiz = try Self.src("LatticeSetupWizard.swift")
        XCTAssertFalse(wiz.contains("LatticeDensityMode.sim.title"), "the Density row lists no Sim segment")
        XCTAssertTrue(wiz.contains("lattice-cells-along-"), "Along stays on the Cells page")

        // the SAME setting: Sim on the Density row was `setDensityMode(.sim)`; By stress is `chooseAlong(.load)`
        var s = LatticeSettings(enabled: true); s.simulateStresses = true
        var viaSim = LatticeWizardModel(settings: s); viaSim.setDensityMode(.sim)
        var viaAlong = LatticeWizardModel(settings: s); XCTAssertTrue(viaAlong.chooseAlong(.load))
        XCTAssertEqual(viaSim.densityMode, .sim)
        XCTAssertEqual(viaAlong.densityMode, .sim, "By stress sets the density Sim set")
        var a = viaSim.applied(to: s), b = viaAlong.applied(to: s)
        XCTAssertEqual(b.gradeAlong, .load, "…and records which way Along points (saved, never sent)")
        b.gradeAlong = a.gradeAlong
        XCTAssertEqual(a, b, "nothing else differs: one setting, one place")
        a.gradeAlong = .load
        XCTAssertEqual(LatticeGradeAlong.lit(stored: a.gradeAlong, densityMode: a.densityMode), .load)
        // without the simulation permission neither way can pick it
        var off = LatticeWizardModel(settings: s); off.setSimulateStresses(false)
        XCTAssertFalse(off.chooseAlong(.load))
        XCTAssertNotEqual(off.densityMode, .sim)
    }

    // MARK: 4 — Grade lives only on the Cells page

    func testGradeLivesOnlyOnTheCellsPage() throws {
        let ws = try Self.src("WorkspacePlaceholder.swift")
        XCTAssertFalse(ws.contains("lattice-regions-grade"), "no Grade pair on the Regions page")
        XCTAssertFalse(ws.contains("regionsGradeBox"))
        let wiz = try Self.src("LatticeSetupWizard.swift")
        XCTAssertTrue(wiz.contains("\"cells-grade-from\"") && wiz.contains("\"cells-grade-to\""), "the Cells page keeps it")
        XCTAssertEqual(LatticeCellsRow.rows(.structural).first, .grade)
        XCTAssertEqual(LatticeCellsRow.rows(.aesthetic).first, .grade)
    }

    // MARK: 5 — the full-screen lattice settings page is deleted

    func testTheFullScreenSettingsPageIsGone() throws {
        let wiz = try Self.src("LatticeSetupWizard.swift")
        for gone in ["private var stageView", "private var saveAndExit", "private var refreshSample", "private func playCurrent",
                     "private var wizardCard", "private func frameSample", "@ViewBuilder private var disclaimer",
                     "cellsPage == nil", "LatticeWizardReveal", "OrganicSampleCube.baked"] {
            XCTAssertFalse(wiz.contains(gone), "still in the settings page: \(gone)")
        }
        let model = try Self.src("LatticeWizardModel.swift")
        for gone in ["LatticeWizardCinematic", "playToken", "struct LatticeWizardReveal", "func stageMesh("] {
            XCTAssertFalse(model.contains(gone), "still in the wizard model: \(gone)")
        }
        let ws = try Self.src("WorkspacePlaceholder.swift")
        XCTAssertTrue(ws.contains(".cellsPage(regions: latticeRegionTabNames, closeToken: cellsCloseToken)"),
                      "the one presentation left is the Cells page")
        XCTAssertFalse(ws.contains(".stageCamera("), "no sample stage to aim a camera at")
    }

    // MARK: 6 — Optimize stays in the lattice ⌃ menu

    func testOptimizeStaysInTheLatticeMenu() throws {
        let ws = try Self.src("WorkspacePlaceholder.swift")
        let r = try XCTUnwrap(ws.range(of: "var latticeSplit: some View {"))
        let body = String(ws[r.lowerBound...].prefix(2400))
        XCTAssertTrue(body.contains("Button(\"Optimize with this lattice\") { requestRun() }"))
        XCTAssertTrue(body.contains(".accessibilityIdentifier(\"lattice-split-optimize\")"))
        XCTAssertTrue(body.contains(".disabled(!canOptimize)"))
    }

    // MARK: 8 — Paint on any non-STEP mesh

    func testPaintWorksOnEveryNonStepMesh() {
        for path in ["/p/part.stl", "/p/part.STL", "/p/part.3mf", "/p/part.3MF", "/p/part.obj", "/p/part.OBJ"] {
            XCTAssertEqual(EditFacesPaint.row(modelPath: path, editingFaces: true), .enabled(EditFacesCopy.paintSTL), path)
        }
        for path in ["/p/part.step", "/p/part.STEP", "/p/part.stp", "/p/part.STP"] {
            XCTAssertEqual(EditFacesPaint.row(modelPath: path, editingFaces: true), .greyed(EditFacesCopy.paintSTEP), path)
        }
        XCTAssertFalse(EditFacesCopy.paintSTL.contains("STL"), "the enabled line names no one mesh format")
    }

    // MARK: 9 — one edit action = one Undo

    func testOneCutAcrossSeveralFacesIsOneUndoAndSeparateCutsAreOneEach() {
        let p = EditFacesStageTests.twoFaceProject()
        let kids = p.commitSurfaceCut(faces: [0, 1])
        XCTAssertEqual(kids.count, 4, "one cut, both faces halved")
        p.performUndo()
        XCTAssertTrue(p.faceRegions.isEmpty, "ONE Undo takes back the whole cut")

        let q = EditFacesStageTests.twoFaceProject()
        _ = q.commitSurfaceCut(faces: [0])
        let afterFirst = q.faceRegions
        _ = q.commitSurfaceCut(faces: [1])
        q.performUndo()
        XCTAssertEqual(q.faceRegions, afterFirst, "the first Undo takes back only the second cut")
        q.performUndo()
        XCTAssertTrue(q.faceRegions.isEmpty, "the second Undo the first")
    }

    // MARK: 10 — Positive primitives keep today's frosty blue; the "stops short" rule stays

    func testPositivePrimitivesKeepTheFrostyBlueAndTheStopsShortRule() throws {
        let mv = try Self.src("MetalMeshView.swift")
        XCTAssertTrue(mv.contains("let faceTint = SIMD3<Float>(0.40, 0.58, 1.0)            // frosty blue"),
                      "the Positive (design box) glass keeps today's frosty blue")
        XCTAssertTrue(mv.contains("let faceRGB = positive ? SIMD3<Float>(0.40, 0.58, 1.0) :"), "a Positive cylinder too")
        XCTAssertEqual(DesignPrimitiveGaps.touchMM, 0.05)
        XCTAssertEqual(DesignPrimitiveGaps.nearMM(part: nil), 5)
        let small = MeshBounds(min: SIMD3(-4, -4, -4), max: SIMD3(4, 4, 4), isEmpty: false)
        XCTAssertEqual(DesignPrimitiveGaps.nearMM(part: small), small.radius * 0.25, accuracy: 1e-6)
        let big = MeshBounds(min: SIMD3(-100, -100, -100), max: SIMD3(100, 100, 100), isEmpty: false)
        XCTAssertEqual(DesignPrimitiveGaps.nearMM(part: big), 5, "capped at 5 mm")
    }
}
