// ★ his 11-09: Structural's "can't lattice here" — the walls GLOW electric blue, everything else dims, and a two-button
// pop-up asks once per project (Switch to Aesthetic │ Continue with Structural); the cell hint only in a Manual cell mode.
import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

final class LatticeThinWallGlowTests: XCTestCase {
    private func grid(_ n: Int) -> LatticeVoxelGrid {
        LatticeVoxelGrid(nx: n, ny: 1, nz: 1, origin: .zero, spacing: SIMD3(1, 1, 1), values: [Float](repeating: 1, count: n))
    }

    /// The glow is 1 on the walls, falls off through the part over ~4 mm, and air stays 0.
    func testTheGlowFadesThroughThePartAndNotIntoAir() {
        let g = grid(12)
        var thin = [Bool](repeating: false, count: 12); thin[2] = true
        var inside = [Bool](repeating: true, count: 12); inside[0] = false   // voxel 0 is air
        let f = LatticeThinWallGlow.field(thin: thin, inside: inside, grid: g)
        XCTAssertEqual(f[2], 1, accuracy: 1e-6, "★ full glow on the wall")
        XCTAssertGreaterThan(f[3], f[4]); XCTAssertGreaterThan(f[4], f[5]); XCTAssertGreaterThan(f[5], 0)
        XCTAssertEqual(f[8], 0, "★ nothing past the fall-off")
        XCTAssertEqual(f[0], 0, "★ air never glows")
    }

    /// A vertex over the walls glows (flags.w > 0, blue albedo); elsewhere it is dimmed; the view breathes only with a glow.
    func testTheVerticesGlowOverTheWallsAndDimElsewhere() {
        // two triangles in z = 0.5 over a 6 × 1 × 1 grid: one over voxel 0, one over voxel 5
        let pos: [Float] = [0, 0, 0.5, 0.4, 0, 0.5, 0, 0.4, 0.5,   5, 0, 0.5, 5.4, 0, 0.5, 5, 0.4, 0.5]
        let mesh = ViewerMesh(vertices: pos, indices: [0, 1, 2, 3, 4, 5], faceIDs: [0, 1])
        let g = LatticeVoxelGrid(nx: 6, ny: 1, nz: 1, origin: .zero, spacing: SIMD3(1, 1, 1), values: [Float](repeating: 1, count: 6))
        let field: [Float] = [1, 0.5, 0, 0, 0, 0]
        let t = LatticeThinWallGlow.vertexTints(mesh: mesh, grid: g, field: field)
        XCTAssertEqual(t.count, 6 * 8)
        XCTAssertGreaterThan(t[7], 0.5, "★ the vertex over the wall glows")
        XCTAssertEqual(t[2], LatticeThinWallGlow.blueRGBA.z, "… with the blue albedo")
        XCTAssertEqual(t[3 * 8 + 7], 0, "★ the far vertex does not")
        XCTAssertEqual(t[3 * 8 + 3], LatticeThinWallGlow.dimRGBA.w, "… it is dimmed")
        XCTAssertTrue(LatticeThinWallGlow.anyGlow(t))
        XCTAssertFalse(LatticeThinWallGlow.anyGlow([Float](repeating: 0, count: 16)))
        // the breathe stays in 0.7 … 1.0
        for k in 0..<40 {
            let b = MeshRenderer.glowBreathe(at: Double(k) * 0.13)
            XCTAssertGreaterThanOrEqual(b, 0.7 - 1e-6); XCTAssertLessThanOrEqual(b, 1 + 1e-6)
        }
    }

    /// His rules for the pop-up: by itself only on Structural, Lattice Setup, walls found, not answered; the cell hint only
    /// where he set the cell by hand ("If in auto, then the cell would have gone as small as possible to fit").
    func testThePopUpsRules() {
        let f = LatticeStructuralThinWalls.Finding(minWallMM: 20, share: 0.63)
        XCTAssertTrue(LatticeThinWallPrompt.opensByItself(finding: f, structural: true, setupUp: true, seen: false))
        XCTAssertFalse(LatticeThinWallPrompt.opensByItself(finding: f, structural: true, setupUp: true, seen: true), "★ quiet after Continue")
        XCTAssertFalse(LatticeThinWallPrompt.opensByItself(finding: f, structural: false, setupUp: true, seen: false), "never under Aesthetic")
        XCTAssertFalse(LatticeThinWallPrompt.opensByItself(finding: nil, structural: true, setupUp: true, seen: false), "no walls, no pop-up")
        let auto = LatticeThinWallPrompt.body(f, cellsPerMember: 5, manualCell: false)
        let manual = LatticeThinWallPrompt.body(f, cellsPerMember: 5, manualCell: true)
        XCTAssertTrue(auto.contains("thinner than 20 mm") && auto.contains("5 cells") && auto.contains("Aesthetic lattices thin walls"))
        XCTAssertFalse(auto.contains("smaller cell"), "★ no cell hint in Auto")
        XCTAssertTrue(manual.contains("a smaller cell may lattice some of them"), "★ the hint in a Manual cell mode")
        XCTAssertEqual(LatticeThinWallPrompt.switchTitle, "Switch to Aesthetic")
        XCTAssertEqual(LatticeThinWallPrompt.continueTitle, "Continue with Structural")
    }

    /// Once per project: the answer is saved (and older bytes unchanged while unanswered); choosing Structural again shows
    /// it once more; Switch to Aesthetic changes the mode only, in one Undo step.
    @MainActor
    func testOncePerProjectAndTheSwitch() throws {
        var s = LatticeSettings(enabled: true)
        s.stageMode = .structural
        let plain = try JSONEncoder().encode(s)
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("thinWallsNoticeSeen"), "★ not written while unanswered")
        s.thinWallsNoticeSeen = true
        let back = try JSONDecoder().decode(LatticeSettings.self, from: JSONEncoder().encode(s))
        XCTAssertTrue(back.thinWallsNoticeSeen, "★ the answer is kept with the project")
        XCTAssertEqual(s.previewBakeInputs, { var t = s; t.thinWallsNoticeSeen = false; return t.previewBakeInputs }(),
                       "answering never re-bakes the picture")
        s.chooseLatticeType(.structural)
        XCTAssertFalse(s.thinWallsNoticeSeen, "★ choosing Structural again shows it once more")

        let p = ProjectModel(id: UUID(), name: "P", material: "PLA", process: .fdm, importedFile: nil, importedMesh: nil)
        p.lattice = LatticeSettings(enabled: true)
        p.lattice.stageMode = .structural
        p.lattice.wholePart = true
        p.lattice.cellMM = 6
        p.seedUndoBaseline()
        p.switchLatticeStageMode(to: .aesthetic)
        XCTAssertEqual(p.lattice.stageMode, .aesthetic, "★ Switch to Aesthetic")
        XCTAssertTrue(p.lattice.wholePart && p.lattice.cellMM == 6, "★ nothing else moves")
        p.performUndo()
        XCTAssertEqual(p.lattice.stageMode, .structural, "★ one Undo step")
    }
}

#if canImport(AppKit) && canImport(MetalKit)
/// ★ HIS STAND IN THE REAL PAGE (HIS_PROJECT_DIR): Structural, the whole part latticed — the pop-up comes by itself; Continue
/// closes it and saves the answer; a tap on the note re-opens it; Switch to Aesthetic changes the mode and closes it.
final class LatticeThinWallGlowHostedTests: XCTestCase {
    @MainActor
    func testHisStandShowsThePopUpOnceAndTheNoteReopensIt() throws {
        let s = try HisStand1109LatticeTests.restore()
        let p = s.pm
        p.lattice.chooseLatticeType(.structural)
        p.lattice.wholePart = true
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("thin-glow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let core = FlexibleHisProject.repoRoot.appendingPathComponent("core")
        let app = AppModel(materialsPath: core.appendingPathComponent("src/materials/materials.json").path,
                           store: ProjectStore(rootDir: root))
        let h = AppBuildHost(WorkspacePlaceholder(model: app, project: p), size: AppBuildHost.landscape13, test: self)
        h.pump(2)
        try h.pickFromMenu("capsuleMenu", "Structural", what: "the stage menu")
        h.pump(1.5)
        if h.frames.all["view-Lattice preview-on"] == nil { try h.tap("view-Lattice preview", "the lattice preview", settle: 1) }
        // his stand bakes for a while in a debug build
        let end = Date().addingTimeInterval(420)
        while h.frames.all["lattice-thin-walls-card"] == nil, Date() < end { h.pump(2) }
        _ = try h.onScreen("lattice-thin-walls-card", "★ the pop-up, by itself")
        _ = try h.onScreen("lattice-thin-walls-switch", "★ Switch to Aesthetic")
        try h.tap("lattice-thin-walls-continue", "Continue with Structural", settle: 1)
        XCTAssertNil(h.frames.all["lattice-thin-walls-card"], "★ closed")
        XCTAssertTrue(p.lattice.thinWallsNoticeSeen, "★ the answer is saved")
        try h.tap("lattice-thin-walls-note", "the note", settle: 1)
        _ = try h.onScreen("lattice-thin-walls-card", "★ the note re-opens it")
        try h.tap("lattice-thin-walls-switch", "Switch to Aesthetic", settle: 1.5)
        XCTAssertEqual(p.lattice.stageMode, .aesthetic, "★ the mode changed")
        XCTAssertNil(h.frames.all["lattice-thin-walls-card"], "★ closed")
    }
}
#endif
