// LatticeSheetsAppTests — ★ SHEETS (gyroid, Schwarz-D) on the NEW lattice engine, app side (notes28 sheets SPEC rev 3, builder
// C; section 6, "App"): the catalog offers both sheets on the new engine and never on the old run; the field's parity — Swift
// against core (through the bridge) and the shader against Swift (5 µm), with a graded wall texture and across a blend band;
// the pass draws inside the engine's map and nothing outside; the dial's row, Auto's flag and the captions (each at most five
// words); Grade to / Grade from as walls; "Where regions meet" shown only with touching sheet regions, its default by stage,
// its fallback pop-up; Skin / Grade to shape greyed; the Not print-tested tag and its clearing; the type pictures exist and
// differ. Each check has its RED control (static switches, the existing way). Hosted tests have no SwiftUI accessibility tree:
// the page's words are pure (`LatticeSheets`), read here.
import XCTest
import simd
#if canImport(MetalKit)
import MetalKit
#endif
@testable import TopOptFlows
@testable import TopOptKit

final class LatticeSheetsAppTests: XCTestCase {

    static let sheets = ["gyroid", "schwarz_d"]

    /// His rule: a caption under a setting is at most five words.
    static func words(_ s: String) -> Int { s.split(whereSeparator: { $0 == " " }).count }

    /// A field as the engine lays one: a tilted frame, a graded wall (By stress: 3 × 2 × 2 centres), anchored off the origin.
    static func gradedField(_ kind: LatticeSheetField.Kind, cell: Double = 8) -> LatticeSheetField {
        let a0 = simd_normalize(SIMD3<Double>(1, 0.3, 0.1))
        let a1 = simd_normalize(simd_cross(SIMD3<Double>(0, 0, 1), a0))
        let a2 = simd_cross(a0, a1)
        let walls: [Float] = [0.9, 1.1, 1.4, 1.0, 1.25, 1.6, 0.95, 1.2, 1.5, 1.05, 1.35, 1.7]
        return LatticeSheetField(region: 1, frame: 0, kind: kind, origin: SIMD3(2, -3, 1), ax: [a0, a1, a2],
                                 anchor: SIMD3(0.5, -1.25, 0.75), cellMM: cell, n: SIMD3(3, 2, 2),
                                 lo: SIMD3(4.5, 2.75, 4.75), wallMM: walls)
    }
    /// Points over the field's grid and past its edges (the clamp), deterministic.
    static func points(_ n: Int = 400) -> [SIMD3<Float>] {
        var g = SeededGenerator(7)
        return (0..<n).map { _ in SIMD3(Float.random(in: -6...30, using: &g), Float.random(in: -8...22, using: &g),
                                        Float.random(in: -6...24, using: &g)) }
    }

    // MARK: 1 · the catalog: both sheets on the new engine, never on the old run

    func testTheCatalogOffersBothSheetsOnTheNewEngineAndNeverOnTheOldRun() {
        for id in Self.sheets {
            let f = LatticeLayoutSession.typeFacts(id)
            XCTAssertTrue(f.lays, "★ \(id): the engine lays it (core's family \"sheet\")")
            XCTAssertTrue(f.isSheet && LatticeSheets.isSheet(id), "\(id) is a sheet")
            XCTAssertEqual(f.s, 0, "\(id): no strut cell")
            XCTAssertNil(LatticeType.named(id), "\(id): no strut law in Swift (never octet in disguise)")
            for structural in [false, true] {
                let e = LatticeTypeCatalog.layoutEntriesFromCore(structural: structural).first { $0.id == id }
                XCTAssertEqual(e?.offered, true, "★ \(id) offered on the new engine (structural \(structural))")
            }
            XCTAssertTrue(LatticeTypeCatalog.newEngineShipped(id))
            XCTAssertFalse(LatticeTypeCatalog.batchShipped(id), "★ \(id): never the old run's")
            XCTAssertEqual(LatticeTypeCatalog.entriesFromCore().first { $0.id == id }?.offered, false, "★ the old run's picker")
            XCTAssertEqual(LatticeTypeCatalog.stageEntries(structural: false, newEngine: false).first { $0.id == id }?.offered, false,
                           "★ an STL part (the old run makes its lattice): not offered")
            XCTAssertNil(LatticeSettings(enabled: true, topologyID: id).runSpec(), "★ no old-run spec for a sheet")
        }
        XCTAssertFalse(LatticeLayoutSession.typeFacts("octet").isSheet, "a strut type is not a sheet")
        XCTAssertEqual(LatticeLayoutSession.typeFacts("octet").family, "strut")
        // RED CONTROL: one gate for both (as before) — the old run would carry a sheet
        LatticeTypeCatalog.controlSheetsOnOldRun = true
        defer { LatticeTypeCatalog.controlSheetsOnOldRun = false }
        XCTAssertTrue(LatticeTypeCatalog.batchShipped("gyroid"), "RED CONTROL: the old run's gate opens for the sheet")
    }

    func testCoreSaysWhatASheetIs() {
        let g = LatticeLayoutSession.typeFacts("gyroid"), d = LatticeLayoutSession.typeFacts("schwarz_d")
        XCTAssertEqual(g.openLook, 0.2066, accuracy: 1e-4); XCTAssertEqual(d.openLook, 0.1665, accuracy: 1e-4)
        XCTAssertEqual(g.touch, 0.4330, accuracy: 1e-4); XCTAssertEqual(d.touch, 0.3507, accuracy: 1e-4)
        XCTAssertEqual(g.structuralFloorCells, 10); XCTAssertEqual(d.structuralFloorCells, 9)
        XCTAssertEqual(g.floorCellMM, 4.36, accuracy: 0.01, "two lines over the open look"); XCTAssertEqual(d.floorCellMM, 5.41, accuracy: 0.01)
        // Auto's wall (SPEC 1.3): two lines up to 9.8 / 12.2 mm cells, then 0.444 of the open look
        XCTAssertEqual(LatticeSheets.autoWallMM("gyroid", cellMM: 8, lineWidthMM: 0.45), 0.90, accuracy: 1e-9)
        XCTAssertEqual(LatticeSheets.autoWallMM("gyroid", cellMM: 16, lineWidthMM: 0.45), 1.47, accuracy: 0.01)
        XCTAssertEqual(LatticeSheets.autoWallMM("schwarz_d", cellMM: 12, lineWidthMM: 0.45), 0.90, accuracy: 1e-9)
        XCTAssertEqual(LatticeSheets.autoWallMM("schwarz_d", cellMM: 16, lineWidthMM: 0.45), 1.18, accuracy: 0.01)
        XCTAssertEqual(LatticeSheets.percentSolid("gyroid", wallMM: 0.9, cellMM: 8), 34, "SPEC 1.3's table")
        XCTAssertEqual(LatticeSheets.autoWallMM("octet", cellMM: 8, lineWidthMM: 0.45), 0, "RED CONTROL: a strut type has none")
    }

    // MARK: 2 · the field: Swift against core, the shader against Swift

    func testTheSwiftFieldIsCoresField() throws {
        for kind in LatticeSheetField.Kind.allCases {
            let f = Self.gradedField(kind)
            let pts = Self.points()
            let core = try LatticeLayoutSession.sheetProbe(f, points: pts)
            let coreWall = try LatticeLayoutSession.sheetProbe(f, points: pts, wall: true)
            var worst = 0.0, worstWall = 0.0
            for (i, p) in pts.enumerated() {
                worst = Swift.max(worst, abs(f.distance(SIMD3<Double>(p)) - core[i]))
                worstWall = Swift.max(worstWall, abs(f.wallAt(SIMD3<Double>(p)) - coreWall[i]))
            }
            print("SHEETS parity Swift vs core (\(kind.id)): field \(worst * 1000) µm, wall \(worstWall * 1000) µm")
            XCTAssertLessThan(worstWall, 1e-4, "★ the wall is core's trilinear blend, clamped (float inputs)")
            XCTAssertLessThan(worst, 0.002, "★ the field is core's within 2 µm (the law's table)")
            // RED CONTROL: the cells' walls used unblended (nearest centre) — the field moves by more than 5 µm somewhere
            var stepped = f
            stepped.wallMM = f.wallMM.map { _ in f.wallMM[0] }
            let off = pts.map { abs(stepped.distance(SIMD3<Double>($0)) - f.distance(SIMD3<Double>($0))) }.max() ?? 0
            XCTAssertGreaterThan(off, 0.005, "RED CONTROL: a field with one wall is not the graded one")
        }
    }

    #if canImport(MetalKit)
    @MainActor
    func testTheShaderIsTheSwiftFieldWithinFiveMicrons() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let pass = try LatticeLayoutSheetPass(device: device)
        let fields = [Self.gradedField(.gyroid), Self.gradedField(.schwarzD, cell: 11)]
        pass.upload(LatticeSheetDrawing(token: 1, fields: fields))
        let pts = Self.points(600)
        let which = pts.indices.map { $0 % 2 }
        let gpu = try XCTUnwrap(pass.probe(pts, field: which))
        var worst = 0.0
        for (i, p) in pts.enumerated() {
            worst = Swift.max(worst, abs(Double(gpu[i]) - fields[which[i]].distance(SIMD3<Double>(p))))
        }
        print("SHEETS parity shader vs Swift: \(worst * 1000) µm over \(pts.count) points, graded walls")
        XCTAssertLessThan(worst, 0.005, "★ the shader's field is the Swift copy's within 5 µm")
        // ACROSS A BLEND BAND: the shader's mix against the Swift copy's (core's sheet_blend_distance_at form)
        let seam = LatticeSheetSeam(a: 0, b: 1, bandMM: 11, raiseMM: 0.15, solidWall: false)
        let seamMM = pts.map { Float(($0.x - 10) * 0.8) }
        // (builder E's form reads the distance's gradient too: here (0.8, 0, 0))
        let blend = try XCTUnwrap(pass.probeBlend(pts, seamMM: seamMM, bandMM: 11, raiseMM: 0.15, seamGrad: SIMD3(0.8, 0, 0)))
        var worstBlend = 0.0
        for (i, p) in pts.enumerated() {
            let s = LatticeSheetSeam.blendDistance(fields[0], fields[1], seam: seam, seamMM: Double(seamMM[i]),
                                                   seamGrad: SIMD3(0.8, 0, 0), SIMD3<Double>(p))
            worstBlend = Swift.max(worstBlend, abs(Double(blend[i]) - s))
        }
        print("SHEETS parity shader vs Swift across a blend band: \(worstBlend * 1000) µm")
        XCTAssertLessThan(worstBlend, 0.005, "★ the blend's mix is the Swift copy's within 5 µm")
        // RED CONTROL: the other kind's field read for the same points is far off
        let swapped = try XCTUnwrap(pass.probe(pts, field: which.map { 1 - $0 }))
        let off = pts.indices.map { abs(Double(swapped[$0]) - fields[which[$0]].distance(SIMD3<Double>(pts[$0]))) }.max() ?? 0
        XCTAssertGreaterThan(off, 0.1, "RED CONTROL: the wrong field disagrees")
    }

    // MARK: 3 · the pass draws inside the map and nothing outside

    @MainActor
    func sheetPixels(map: LatticeLayoutSolidGrid, field: LatticeSheetField, size: Int = 320) throws -> (pixels: Int, ms: Double?) {
        guard let device = MTLCreateSystemDefaultDevice(), let r = MeshRenderer(device: device, sampleCount: 1) else {
            throw XCTSkip("no renderer: \(MeshRenderer.lastInitError ?? "?")")
        }
        let walls = LatticeLayoutBarsPass.drawWalls
        defer { LatticeLayoutBarsPass.drawWalls = walls }
        LatticeLayoutBarsPass.drawWalls = false
        r.setMesh(Notes26BarsClipTests.cube)
        r.camera.setOrientation(azimuth: 0.6, elevation: 0.5)
        r.setBodyAlpha(0)   // the body out of the way: every bit of the sheet that draws is counted
        var inputs = LatticeLayoutBarsInputs(token: 1, bars: [])
        inputs.sheets = LatticeSheetDrawing(token: 1, fields: [field], map: map)
        XCTAssertTrue(r.applyLayoutBars(inputs, device: device))
        XCTAssertNil(LatticeLayoutSheetPass.lastInitError)
        let px = try XCTUnwrap(r.renderOffscreen(width: size, height: size,
                                                 clear: MTLClearColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1), stage: false))
        var times: [Double] = []
        for _ in 0..<7 { if let t = r.measureFrameGPUSeconds(size: 1152, stage: false) { times.append(t * 1000) } }
        return (LatticeLayoutSolidViewTests.strutPixels(px), times.sorted().dropFirst().first)
    }

    /// The 10 mm cube's map with its open channel only where `open` says (inside the cube).
    static func map(open: (SIMD3<Float>) -> Bool) -> LatticeLayoutSolidGrid {
        let n = 28, voxel: Float = 0.5, origin = SIMD3<Float>(repeating: -1.75)
        var rg = [Int8](repeating: -127, count: 2 * n * n * n)
        for k in 0..<n { for j in 0..<n { for i in 0..<n {
            let c = origin + SIMD3(Float(i), Float(j), Float(k)) * voxel
            if c.x > 0, c.y > 0, c.z > 0, c.x < 10, c.y < 10, c.z < 10 {
                let v = 2 * ((k * n + j) * n + i)
                rg[v + 1] = 127
                if open(c) { rg[v] = 127 }
            }
        } } }
        return LatticeLayoutSolidGrid(token: 7, origin: origin, voxel: voxel, dims: SIMD3(Int32(n), Int32(n), Int32(n)), rg: rg)
    }

    @MainActor
    func testThePassDrawsInsideTheMapAndNothingOutside() throws {
        let f = LatticeSheetField(kind: .gyroid, cellMM: 5, wallMM: [0.9])
        let whole = try sheetPixels(map: Self.map { _ in true }, field: f)
        let half = try sheetPixels(map: Self.map { $0.x < 5 }, field: f)
        let none = try sheetPixels(map: Self.map { _ in false }, field: f)
        print("SHEETS pass pixels: whole \(whole.pixels), half \(half.pixels), none \(none.pixels); "
              + "frame at 1152 px: \(whole.ms.map { String(format: "%.2f ms", $0) } ?? "?") (whole cube open, Mac GPU)")
        XCTAssertGreaterThan(whole.pixels, 2000, "★ the sheet draws where the map is open lattice")
        XCTAssertEqual(none.pixels, 0, "★ nothing draws where the map is closed")
        XCTAssertGreaterThan(half.pixels, 200, "half the cube open: some sheet")
        XCTAssertLessThan(Double(half.pixels), 0.85 * Double(whole.pixels), "★ and only in that half")
    }

    /// The frame time on a sheet region, the whole frame on the Mac's GPU (offscreen, 1152 × 1152, Metal's own gpuEndTime −
    /// gpuStartTime, the second best of seven): a 60 × 40 × 30 mm block all open lattice, an 8 mm gyroid cell, graded walls.
    @MainActor
    func testTheSheetFrameTimeIsMeasured() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let r = MeshRenderer(device: device, sampleCount: 1) else {
            throw XCTSkip("no renderer")
        }
        let size = SIMD3<Float>(60, 40, 30)
        let corners: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0),
                                       SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 1), SIMD3(0, 1, 1)]
        r.setMesh(ViewerMesh(vertices: corners.flatMap { [$0.x * size.x, $0.y * size.y, $0.z * size.z] },
                             indices: [1, 2, 6, 1, 6, 5, 0, 4, 7, 0, 7, 3, 3, 7, 6, 3, 6, 2, 0, 1, 5, 0, 5, 4, 4, 5, 6, 4, 6, 7, 0, 3, 2, 0, 2, 1],
                             faceIDs: []))
        r.camera.setOrientation(azimuth: 0.6, elevation: 0.5)
        r.setBodyAlpha(LatticeLayoutPreview.ghostAlpha)
        let voxel: Float = 0.5, origin = SIMD3<Float>(repeating: -0.75)
        let dims = SIMD3<Int32>(((size + 1.5) / voxel).rounded(.up)) &+ 1
        let nx = Int(dims.x), ny = Int(dims.y), nz = Int(dims.z)
        var rg = [Int8](repeating: -127, count: 2 * nx * ny * nz)
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx {
            let c = origin + SIMD3(Float(i), Float(j), Float(k)) * voxel
            if all(c .> SIMD3<Float>(repeating: 0)), all(c .< size) { rg[2 * ((k * ny + j) * nx + i)] = 127; rg[2 * ((k * ny + j) * nx + i) + 1] = 127 }
        } } }
        let map = LatticeLayoutSolidGrid(token: 3, origin: origin, voxel: voxel, dims: dims, rg: rg)
        var f = LatticeSheetField(kind: .gyroid, cellMM: 8, n: SIMD3(8, 5, 4), lo: SIMD3(4, 4, 4),
                                  wallMM: (0..<160).map { 0.9 + Float($0 % 7) * 0.12 })
        f.anchor = .zero
        var inputs = LatticeLayoutBarsInputs(token: 1, bars: [], solid: map)
        inputs.sheets = LatticeSheetDrawing(token: 1, fields: [f], map: map)
        XCTAssertTrue(r.applyLayoutBars(inputs, device: device))
        XCTAssertNil(LatticeLayoutSheetPass.lastInitError, "the sheet pass built")
        XCTAssertTrue(r.layoutBarsInFrame, "★ the sheet is in the frame being timed")
        _ = r.measureFrameGPUSeconds(size: 1152, stage: false)   // warm
        var times: [Double] = []
        for _ in 0..<7 { if let t = r.measureFrameGPUSeconds(size: 1152, stage: false) { times.append(t * 1000) } }
        r.applyLayoutBars(nil, device: device)
        var bare: [Double] = []
        for _ in 0..<7 { if let t = r.measureFrameGPUSeconds(size: 1152, stage: false) { bare.append(t * 1000) } }
        let ms = times.sorted().dropFirst().first ?? -1, b = bare.sorted().dropFirst().first ?? -1
        print(String(format: "SHEETS frame time: %.2f ms with the sheet (solid view, walls), %.2f ms without (1152 px, Mac GPU, %@)",
                     ms, b, device.name))
        XCTAssertGreaterThan(ms, 0)
        XCTAssertLessThan(ms, 200, "a frame, not a stall")
    }
    #endif

    // MARK: 4 · the dial, Auto's flag, the captions

    func testTheDialAutoFlagAndTheCaptions() {
        XCTAssertEqual(LatticeSheets.dialTitle("gyroid", strut: "Thickness"), "Wall thickness")
        XCTAssertEqual(LatticeSheets.dialTitle("schwarz_d", strut: "Thickness"), "Wall thickness")
        XCTAssertEqual(LatticeSheets.dialTitle("octet", strut: "Thickness"), "Thickness", "a strut type keeps its word")
        XCTAssertEqual(LatticeSheets.thinnestCaption, "Thinnest is two lines")
        for c in [LatticeSheets.thinnestCaption, LatticeSheets.seamCaption, LatticeTypeCatalog.notPrintTestedCaption]
            + LatticeSheets.Greyed.allCases.map(\.caption) {
            XCTAssertLessThanOrEqual(Self.words(c), 5, "★ his rule: \"\(c)\" is at most five words")
        }
        let info = LatticeSheets.wallInfo("gyroid", cellMM: 8, lineWidthMM: 0.45)
        XCTAssertTrue(info.contains("two lines") && info.contains("% solid") && info.contains("Auto"), "the (i): wall, solid, Auto")
        XCTAssertFalse(info.contains("face"), "never a face number")
        var l = LatticeSettings(enabled: true, topologyID: "gyroid")
        XCTAssertTrue(LatticeSheets.autoByCell(l, pageManual: false), "★ Auto sends auto_by_cell for a sheet")
        XCTAssertFalse(LatticeSheets.autoByCell(l, pageManual: true), "a hand-set dial does not (R10)")
        l.topologyID = "octet"
        XCTAssertFalse(LatticeSheets.autoByCell(l, pageManual: false), "a strut type never")
        // Grade to / Grade from as walls
        XCTAssertEqual(LatticeSheets.gradeUnit("gyroid"), "wall")
        XCTAssertEqual(LatticeSheets.gradeUnit("octet"), "density")
        XCTAssertEqual(LatticeSheets.rangeTitle, "Wall thickness range")
        // RED CONTROL: the sheet read as a strut type
        LatticeSheets.controlTreatAsStrut = true
        defer { LatticeSheets.controlTreatAsStrut = false }
        XCTAssertEqual(LatticeSheets.dialTitle("gyroid", strut: "Thickness"), "Thickness")
        XCTAssertTrue(LatticeSheets.greyed("gyroid").isEmpty)
    }

    @MainActor
    func testThePageSendsWhatASheetLaysWith() throws {
        var l = LatticeSettings(enabled: true, topologyID: "gyroid")
        l.stageMode = .aesthetic
        l.boundary = .fullSkin
        let s = LatticeLayoutPreview.partWide(l, beadMM: 0.45, wallRingMM: 0, referenceMPa: 0, percent: { _, _ in nil })
        XCTAssertEqual(s.algorithm, "uniform", "★ one grid per region, Uniform")
        XCTAssertFalse(s.gradeToShape); XCTAssertFalse(s.cellsByStress); XCTAssertFalse(s.skin, "★ no Finish Skin on a sheet")
        XCTAssertEqual(s.sheetSeam, "blend", "★ Aesthetic: Blend by default")
        l.stageMode = .structural
        XCTAssertEqual(LatticeLayoutPreview.partWide(l, beadMM: 0.45, wallRingMM: 0, referenceMPa: 0, percent: { _, _ in nil }).sheetSeam,
                       "solid_wall", "★ Structural: Solid wall by default")
        l.sheetSeam = "blend"
        XCTAssertEqual(LatticeSheets.seam(l), "blend", "his pick wins")
        // the file job carries both keys for a sheet, none for a strut type (its bytes as before)
        var ss = LatticeLayoutSession.Settings()
        ss.topology = "gyroid"; ss.sheetSeam = "blend"; ss.autoByCell = true
        let job = try XCTUnwrap(try JSONSerialization.jsonObject(with: LatticeFileJob.build(ss, modelName: "m.step")) as? [String: Any])
        let layout = try XCTUnwrap(job["layout"] as? [String: Any])
        XCTAssertEqual(layout["sheet_seam"] as? String, "blend")
        XCTAssertEqual(layout["auto_by_cell"] as? Bool, true)
        ss.topology = "octet"
        let octet = try XCTUnwrap(try JSONSerialization.jsonObject(with: LatticeFileJob.build(ss, modelName: "m.step")) as? [String: Any])
        XCTAssertNil((octet["layout"] as? [String: Any])?["sheet_seam"], "RED CONTROL: a strut job is the bytes it was")
        // the session sends the two to core (the bridge's settings)
        XCTAssertEqual(LatticeFileJob.fieldKeys["sheetSeam"], "sheet_seam")
        XCTAssertEqual(LatticeFileJob.fieldKeys["autoByCell"], "auto_by_cell")
    }

    // MARK: 5 · "Where regions meet"

    func testWhereRegionsMeetShowsOnlyWithTouchingSheetRegionsAndDefaultsByStage() {
        let seam = LatticeSheetSeam(a: 0, b: 1, bandMM: 8, solidWall: true)
        XCTAssertFalse(LatticeSheets.seamRowShown("gyroid", seams: []), "★ one sheet region: no row")
        XCTAssertTrue(LatticeSheets.seamRowShown("gyroid", seams: [seam]), "★ two that touch: the row")
        XCTAssertFalse(LatticeSheets.seamRowShown("octet", seams: [seam]), "RED CONTROL: a strut type never shows it")
        XCTAssertEqual(LatticeSheets.seamDefault(structural: false), "blend")
        XCTAssertEqual(LatticeSheets.seamDefault(structural: true), "solid_wall")
        XCTAssertEqual(LatticeSheets.seamChoices, ["Blend", "Solid wall"])
        XCTAssertTrue(LatticeSheets.seamInfo(structural: true).contains("no strength credit"))
        XCTAssertTrue(LatticeSheets.seamInfo(structural: false).contains("always a solid wall"), "struts or Organic: the wall")
        // stored only when picked (older bytes unchanged)
        var l = LatticeSettings(enabled: true, topologyID: "gyroid")
        let before = try? JSONEncoder().encode(l)
        XCTAssertFalse(String(data: before ?? Data(), encoding: .utf8)?.contains("sheetSeam") ?? true)
        l.sheetSeam = "solid_wall"
        let after = try? JSONEncoder().encode(l)
        XCTAssertEqual((try? JSONDecoder().decode(LatticeSettings.self, from: after ?? Data()))?.sheetSeam, "solid_wall")
    }

    @MainActor
    func testABlendThatFellBackSaysWhichRegionsInACentredPopUp() {
        let report = """
        {"sheet_seams": [{"regions": [1, 2], "seam": "blend", "fell_back": true, "why": "regions 1 and 2: a wall was used"},
                         {"regions": [2, 3], "seam": "blend", "fell_back": false, "why": ""}]}
        """.data(using: .utf8)
        let seams = LatticeSheets.fileSeams(report: report)
        XCTAssertEqual(seams.count, 2)
        let text = LatticeSheets.fellBackText(seams, name: { $0 == 1 ? "Top face" : "Bracket" })
        XCTAssertEqual(text, "Top face and Bracket: the blend between them wouldn’t print, so a solid wall joins them there.")
        XCTAssertFalse(text?.contains("1") ?? true, "★ never a number")
        FlexibleSaid.recording = true
        AppPopups.recorded = []
        defer { FlexibleSaid.recording = false; AppPopups.recorded = []; AppPopups.shared.current = nil }
        XCTAssertTrue(LatticeSheets.sayFellBack(report: report, in: ProjectModel(id: UUID(), name: "P", material: "PLA", process: .fdm, importedFile: nil, importedMesh: nil)))
        XCTAssertEqual(AppPopups.recorded.last?.title, LatticeSheets.fellBackTitle, "★ the centred pop-up")
        // RED CONTROL: nothing fell back — nothing said
        let none = #"{"sheet_seams": [{"regions": [1, 2], "seam": "blend", "fell_back": false, "why": ""}]}"#.data(using: .utf8)
        XCTAssertFalse(LatticeSheets.sayFellBack(report: none, in: ProjectModel(id: UUID(), name: "P", material: "PLA", process: .fdm, importedFile: nil, importedMesh: nil)))
    }

    // MARK: 6 · greyed, the tag, the pictures

    func testSkinAndGradeToShapeAreGreyedForASheet() {
        XCTAssertEqual(LatticeSheets.greyed("gyroid"), LatticeSheets.Greyed.allCases)
        XCTAssertEqual(LatticeSheets.greyed("schwarz_d"), LatticeSheets.Greyed.allCases)
        XCTAssertEqual(LatticeSheets.Greyed.finishSkin.caption, "Not for sheet types")
        for g in [LatticeSheets.Greyed.gradeToShape, .doubledStepped, .cellSizeByStress] {
            XCTAssertEqual(g.caption, "One cell size per region")
        }
        for g in LatticeSheets.Greyed.allCases { XCTAssertGreaterThan(g.info.count, 40, "\(g): its (i)") }
        XCTAssertTrue(LatticeSheets.greyed("octet").isEmpty, "RED CONTROL: nothing greyed for a strut type")
    }

    func testTheNotPrintTestedTagShowsAndClears() {
        for id in Self.sheets {
            XCTAssertTrue(LatticeTypeCatalog.showsNotPrintTested(id, tested: ["octet", "bccz"]), "★ \(id) starts untested")
            XCTAssertFalse(LatticeTypeCatalog.showsNotPrintTested(id, tested: [id]), "★ marked tested, the tag goes")
        }
        XCTAssertFalse(LatticeTypeCatalog.showsNotPrintTested("octet", tested: ["octet"]), "RED CONTROL: a tested type")
    }

    func testTheTypePicturesExistAndDiffer() {
        let g = LatticeTypePicture.sheetPicture(LatticeTypePicture.sheetField(.gyroid), topology: "gyroid", side: 48)
        let d = LatticeTypePicture.sheetPicture(LatticeTypePicture.sheetField(.schwarzD), topology: "schwarz_d", side: 48)
        let litG = g.shade.filter { $0 > 0 }.count, litD = d.shade.filter { $0 > 0 }.count
        print("SHEETS pictures: gyroid \(litG) lit of \(g.shade.count), Schwarz-D \(litD)")
        XCTAssertEqual(g.shadeSide, 48)
        XCTAssertGreaterThan(litG, g.shade.count / 5, "★ the gyroid's picture shows its wall")
        XCTAssertGreaterThan(litD, d.shade.count / 5, "★ Schwarz-D's too")
        XCTAssertNotEqual(g.shade, d.shade, "★ the two pictures differ")
        XCTAssertTrue(g.lines.isEmpty, "a sheet has no bars")
        XCTAssertNotNil(LatticeTypePictureView.image(g, greyed: false))
    }

    // MARK: 7 · the map's regions, the card, the colours

    func testEachVoxelOfTheMapNamesItsRegionsField() {
        let fields = [LatticeSheetField(region: 1, kind: .gyroid, cellMM: 5, wallMM: [0.9]),
                      LatticeSheetField(region: 2, kind: .schwarzD, cellMM: 5, wallMM: [0.9])]
        let map = Self.map { _ in true }
        // two cells on the identity frame: region 1 at x 0..5, region 2 at x 5..10 (y, z 0..5)
        let frames: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]
        let idx = LatticeSheetDrawing.regionIndex(fields: fields, map: map, frames: frames, cellRegion: [1, 2], cellFrame: [0, 0],
                                                  cellLo: [0, 0, 0, 5, 0, 0], cellSize: [5, 5])
        func at(_ p: SIMD3<Float>) -> UInt8 {
            let g: SIMD3<Float> = ((p - map.origin) / map.voxel).rounded(.toNearestOrAwayFromZero)
            let x = Int(g.x), y = Int(g.y), z = Int(g.z)
            let ny = Int(map.dims.y), nx = Int(map.dims.x)
            return idx[(z * ny + y) * nx + x]
        }
        XCTAssertEqual(at(SIMD3(2.25, 2.25, 2.25)), 0, "★ region 1's cell: field 0")
        XCTAssertEqual(at(SIMD3(7.25, 2.25, 2.25)), 1, "★ region 2's cell: field 1")
        XCTAssertEqual(at(SIMD3(7.25, 7.25, 7.25)), 255, "RED CONTROL: no cell holds it, nor is it beside one")
    }

    /// ★ Results (K4): sheet_cells.bin's margins, one texel per cell on the field's own cell grid (read nearest); a blend band
    /// the "not credited" grey; a cell not judged the interior colour. RED CONTROL: another region's field takes none of them.
    func testTheStrengthColoursAreOneTexelPerCellAndABlendBandIsNotCredited() {
        let f = LatticeSheetField(region: 1, kind: .gyroid, cellMM: 5, wallMM: [0.9])
        let other = LatticeSheetField(region: 3, kind: .gyroid, cellMM: 5, wallMM: [0.9])
        let cells = LatticeSheetCells(frames: [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1], region: [1, 1, 1, 2], frame: [0, 0, 0, 0],
                                      lo: [0, 0, 0, 5, 0, 0, 10, 0, 0, 0, 5, 0], sizeMM: [5, 5, 5, 5], wallMM: [0.9, 0.9, 0.9, 0.9],
                                      cellsAcross: [12, 12, 12, 12], margin: [2, .nan, 3, 1.5],
                                      flags: [LatticeSheetCells.credited, 0, LatticeSheetCells.blendBand, LatticeSheetCells.credited])
        let (colours, grids) = LatticeLayoutColours.sheetMarginColours([f, other], cells: cells)
        XCTAssertEqual(grids[0]?.n, SIMD3(3, 1, 1), "★ one texel per laid cell of the region")
        XCTAssertEqual(grids[0]?.lo, SIMD3(2.5, 2.5, 2.5), "the first cell's centre")
        XCTAssertEqual(colours[0][0], LatticeStressTint.colour(fraction: 0.5), "★ a judged cell: its share of the limit")
        let c = LatticeStructureColour.interior
        XCTAssertEqual(colours[0][1], SIMD4(Float(c.r), Float(c.g), Float(c.b), 1), "not judged: the interior colour")
        XCTAssertEqual(colours[0][2], LatticeLayoutColours.notCreditedColour, "★ a blend band: not credited")
        XCTAssertTrue(colours[1].isEmpty, "RED CONTROL: another region's cells are not this field's")
        XCTAssertNil(grids[1])
    }

    @MainActor
    func testTheWallColoursAndTheCardReadTheWall() {
        let f = Self.gradedField(.gyroid)
        let c = LatticeLayoutColours.sheetColours([f])
        XCTAssertEqual(c.count, 1); XCTAssertEqual(c[0].count, f.wallMM.count, "one colour per cell")
        XCTAssertNotEqual(c[0].first, c[0].last, "★ a thicker wall is a stronger colour")
        XCTAssertTrue(LatticeLayoutColours.sheetColours([f], oneColour: true).isEmpty)
        var laid = LatticeLayoutColours.Laid()
        laid.sheets = [f]
        let pd: SIMD3<Double> = f.origin + 10 * f.ax[0] + 4 * f.ax[1] + 6 * f.ax[2]
        let p = SIMD3<Float>(Float(pd.x), Float(pd.y), Float(pd.z))
        let r = LatticeLayoutPreview.readSheet(laid, at: p, lookup: nil)
        XCTAssertEqual(r?.widthMM ?? 0, f.wallAt(SIMD3<Double>(p)), accuracy: 1e-9, "★ the card reads the wall there")
        XCTAssertEqual(r?.cellMM, 8)
        XCTAssertGreaterThan(r?.density ?? 0, 0.1)
    }
}

/// A seeded generator (splitmix64): the same points on every run.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
