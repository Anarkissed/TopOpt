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

    // ★ release (4), the reviewer's 11-09 20:10Z item 2: the walls that glow are CORE's
    // (`lattice_solid_fallback_reasons`, LatticeTypes' SOLID 7def1f22), not the app's own measure.

    /// A 60 mm block with a 2 mm fin, 2 mm voxels, octet at an 8 mm cell, a 0.45 mm line: core keeps the fin
    /// solid as too thin (codes 1–3) and lattices the block's middle. The block's middle is the CONTROL: a code
    /// there would mean the glow lights everything.
    private func blockWithFin(fin: Bool) -> LatticeVoxelGrid {
        let nx = 40, ny = 30, nz = 30
        var v = [Float](repeating: 0, count: nx * ny * nz)
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx {
            let inBlock = i < 30
            let inFin = fin && i >= 30 && j == 15
            if inBlock || inFin { v[i + nx * (j + ny * k)] = 1 }
        } } }
        return LatticeVoxelGrid(nx: nx, ny: ny, nz: nz, origin: .zero, spacing: SIMD3(2, 2, 2), values: v)
    }

    func testTheGlowIsCoresMaskTheFinNotTheBlock() throws {
        let g = blockWithFin(fin: true)
        let r = TopOptKit.latticeSolidFallbackReasons(nx: g.nx, ny: g.ny, nz: g.nz, spacing: g.spacing,
                                                      solid: g.values.map { $0 > 0.5 }, topology: "octet",
                                                      cellMM: 8, lineWidthMM: 0.45)
        XCTAssertEqual(r.count, g.values.count, "★ core answered, one code per voxel")
        let at = { (i: Int, j: Int, k: Int) in r[i + g.nx * (j + g.ny * k)] }
        XCTAssertEqual(at(39, 0, 15), 255, "air is not part")
        var finThin = 0, fin = 0
        for k in 4..<26 { for i in 34..<40 { fin += 1; if TopOptKit.solidFallbackGlowCodes.contains(at(i, 15, k)) { finThin += 1 } } }
        XCTAssertEqual(finThin, fin, "★ every fin voxel away from the block is left solid as too thin")
        XCTAssertFalse(TopOptKit.solidFallbackGlowCodes.contains(at(15, 15, 15)), "CONTROL: the block's middle is latticed")

        let thin = try XCTUnwrap(LatticeThinWallGlow.coreThin(solid: g, latticed: g, topology: "octet",
                                                              cellMM: 8, lineWidthMM: 0.45, organic: false))
        XCTAssertTrue(thin[36 + g.nx * (15 + g.ny * 15)], "★ the glow lights the fin")
        XCTAssertFalse(thin[15 + g.nx * (15 + g.ny * 15)], "… and not the block")
        let nothingLatticed = LatticeVoxelGrid(nx: g.nx, ny: g.ny, nz: g.nz, origin: .zero, spacing: g.spacing,
                                               values: [Float](repeating: 0, count: g.values.count))
        XCTAssertEqual(LatticeThinWallGlow.coreThin(solid: g, latticed: nothingLatticed, topology: "octet",
                                                    cellMM: 8, lineWidthMM: 0.45, organic: false)?.contains(true), false,
                       "★ only where he latticed")
    }

    /// No core answer → no glow, never a guess: a stretched grid, an unknown type, no line width.
    func testNoCoreAnswerMeansNoGlow() {
        let g = blockWithFin(fin: true)
        let solid = g.values.map { $0 > 0.5 }
        XCTAssertTrue(TopOptKit.latticeSolidFallbackReasons(nx: g.nx, ny: g.ny, nz: g.nz, spacing: SIMD3(2, 2, 3), solid: solid,
                                                            topology: "octet", cellMM: 8, lineWidthMM: 0.45).isEmpty)
        XCTAssertTrue(TopOptKit.latticeSolidFallbackReasons(nx: g.nx, ny: g.ny, nz: g.nz, spacing: g.spacing, solid: solid,
                                                            topology: "no-such-type", cellMM: 8, lineWidthMM: 0.45).isEmpty)
        XCTAssertTrue(TopOptKit.latticeSolidFallbackReasons(nx: g.nx, ny: g.ny, nz: g.nz, spacing: g.spacing, solid: solid,
                                                            topology: "octet", cellMM: 8, lineWidthMM: 0).isEmpty)
        XCTAssertNil(LatticeThinWallGlow.coreThin(solid: g, latticed: g, topology: "no-such-type",
                                                  cellMM: 8, lineWidthMM: 0.45, organic: false))
    }

    /// The page's bake asks core for the walls and lets core clear the line too (one source for line and glow).
    func testThePageGlowsCoresWalls() throws {
        let src = try FlexibleSource.code("WorkspacePlaceholder.swift")
        XCTAssertTrue(src.contains("LatticeThinWallGlow.coreThin("), "★ the glow's walls are core's")
        XCTAssertFalse(src.contains("LatticeStructuralThinWalls.mask("), "★ not the app's own measure")
        XCTAssertTrue(src.contains("if let c = coreThin, !c.contains(true) { thinWalls = nil }"),
                      "★ core saying no wall stays solid clears the line as well")
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
