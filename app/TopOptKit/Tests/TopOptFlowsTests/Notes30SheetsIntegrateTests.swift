// Notes30SheetsIntegrateTests — ★ notes30 M1: the BUILT notes28 sheets (gyroid, Schwarz-D) and the print resolutions, merged on
// release 21 + Live preview (organic-1 9d94fa02), made to fit release 21's rules:
//   1. the reviewer's ruling 11-26, item 3(b): "NO Structural sheet credit until (a); Aesthetic may ship" — the sheets are
//      Aesthetic only for now: Structural's picker greys them with five words and an (i) that says plainly when Structural
//      comes (positive words); Aesthetic offers them as before;
//   2. captions at most five words, positive words in the sheets' (i)s and pop-ups;
//   3. Small cells in thin walls (notes29b) is a change of cell size a sheet cannot follow: greyed for a sheet, sent off;
//   4. release 21's build timelapse on a sheet: its walls rise floor by floor, bay by bay (a sheet has no struts to stand);
//      nothing of a sheet shows while the site is cleared;
//   5. a sheet's print file job asks for core's 3MF, as every print file does since notes29.
// Each check with its RED control. Hosted tests have no SwiftUI accessibility tree: the page's words are pure, read here.
import XCTest
import simd
#if canImport(MetalKit)
import MetalKit
#endif
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class Notes30SheetsIntegrateTests: XCTestCase {

    static let sheets = ["gyroid", "schwarz_d"]

    override func tearDown() {
        LatticeTypeCatalog.controlSheetsOnStructural = false
        LatticeBuildShow.clockForTesting = nil
        LatticeBuildShow.controlOff = false
        super.tearDown()
    }

    /// The words his positive-words rule keeps off the screen.
    static func negative(_ s: String) -> [String] {
        let l = " " + s.lowercased().replacingOccurrences(of: "\u{2019}", with: "'") + " "
        return ["can't", "cannot", "don't", "won't", "wouldn't", "couldn't", "isn't", " not ", " no longer "].filter { l.contains($0) }
    }

    // MARK: 1 · Structural keeps the sheets for later (the reviewer's 3(b)); Aesthetic offers them

    func testStructuralGreysTheSheetsAndSaysWhenStructuralComes() {
        for id in Self.sheets {
            let name = LatticeType.displayName(forID: id)
            let aesthetic = LatticeTypeCatalog.layoutEntriesFromCore(structural: false).first { $0.id == id }
            XCTAssertEqual(aesthetic?.offered, true, "★ \(id): Aesthetic offers it")
            let s = LatticeTypeCatalog.layoutEntriesFromCore(structural: true).first { $0.id == id }
            XCTAssertEqual(s?.offered, false, "★ \(id): Structural keeps it for later (no Structural sheet credit until the laws)")
            let caption = LatticeTypeCatalog.caption(s!) ?? ""
            XCTAssertEqual(caption, LatticeTypeCatalog.sheetStructuralCaption)
            XCTAssertLessThanOrEqual(LatticeCaptions.words(caption), LatticeCaptions.maxWords, "★ five words: \(caption)")
            let line = LatticeTypeCatalog.line(s!) ?? ""
            XCTAssertTrue(line.contains(name) && line.contains("Structural") && line.contains("Aesthetic"), line)
            XCTAssertTrue(line.contains("update"), "★ it says when Structural comes: \(line)")
            XCTAssertEqual(Self.negative(line), [], "★ positive words: \(line)")
            XCTAssertEqual(Self.negative(caption), [])
            XCTAssertNotNil(LatticeTypeCatalog.layoutRefusal(id, structural: true), "★ a saved sheet on Structural says why")
            XCTAssertNil(LatticeTypeCatalog.layoutRefusal(id, structural: false), "★ and runs on Aesthetic")
        }
        XCTAssertEqual(LatticeTypeCatalog.layoutEntriesFromCore(structural: true).first { $0.id == "octet" }?.offered, true,
                       "a strut type's Structural is as it was")
        // RED CONTROL: as the sheet branches had it, both sheets on Structural (with their credit by place)
        LatticeTypeCatalog.controlSheetsOnStructural = true
        for id in Self.sheets {
            XCTAssertEqual(LatticeTypeCatalog.layoutEntriesFromCore(structural: true).first { $0.id == id }?.offered, true,
                           "RED CONTROL: \(id) offered on Structural")
        }
    }

    // MARK: 2 · five words, positive words

    func testTheSheetsCaptionsAreFiveWordsAndTheirWordsArePositive() {
        let captions = [LatticeSheets.thinnestCaption, LatticeSheets.seamCaption, LatticeSheets.wallRowTitle,
                        LatticeSheets.rangeTitle, LatticeTypeCatalog.sheetStructuralCaption]
            + LatticeSheets.Greyed.allCases.map(\.caption)
        for c in captions {
            XCTAssertLessThanOrEqual(LatticeCaptions.words(c), LatticeCaptions.maxWords, "★ at most five words: \(c)")
            XCTAssertEqual(Self.negative(c), [], "★ positive words: \(c)")
        }
        let infos = LatticeSheets.Greyed.allCases.map(\.info)
            + [LatticeSheets.seamInfo(structural: false), LatticeSheets.wallInfo("gyroid", cellMM: 8, lineWidthMM: 0.45),
               LatticeTypeCatalog.sheetStructuralLater("Gyroid"), LatticeSetupWizard.quiltInfo("gyroid"),
               LatticeSheets.fellBackText([.init(regions: [0, 1], seam: "blend", fellBack: true, why: "")],
                                          name: { $0 == 0 ? "The part" : "Top face" }) ?? "",
               PrintResolutionCopy.info, PrintResolutionCopy.failedTitle, PrintResolutionCopy.failedText,
               PrintResolutionCopy.noMacTitle, PrintResolutionCopy.noMacText, PrintResolutionCopy.changedTitle,
               PrintResolutionCopy.changedText]
        for s in infos {
            XCTAssertFalse(s.isEmpty)
            XCTAssertEqual(Self.negative(s), [], "★ positive words: \(s)")
        }
        // the pop-up still names the regions his way and says a solid wall joins them
        let said = LatticeSheets.fellBackText([.init(regions: [0, 1], seam: "blend", fellBack: true, why: "")],
                                              name: { $0 == 0 ? "The part" : "Top face" })
        XCTAssertEqual(said, "The part and Top face: a solid wall joins them there, where a blend would print too thin.")
        // RED CONTROL: the sheet branches' words are caught
        XCTAssertFalse(Self.negative("Not for sheet types").isEmpty)
        XCTAssertFalse(Self.negative("Top face and Bracket: the blend between them wouldn\u{2019}t print, so a solid wall joins them there.").isEmpty)
        XCTAssertFalse(Self.negative("The file couldn\u{2019}t be made").isEmpty)
    }

    // MARK: 3 · Small cells in thin walls: greyed for a sheet, sent off

    func testSmallCellsInThinWallsIsGreyedForASheetAndSentOff() throws {
        XCTAssertTrue(LatticeSheets.greyed("gyroid").contains(.smallCellsInThinWalls))
        XCTAssertEqual(LatticeSheets.Greyed.smallCellsInThinWalls.caption, "One cell size per region")
        XCTAssertTrue(LatticeSheets.greyed("octet").isEmpty, "a strut type: nothing greyed")
        var l = LatticeSettings(enabled: true, topologyID: "gyroid")
        l.stageMode = .aesthetic
        l.smallCellsInThinWalls = true
        let s = LatticeLayoutPreview.partWide(l, beadMM: 0.45, wallRingMM: 0, referenceMPa: 0, percent: { _, _ in nil })
        XCTAssertFalse(s.smallCellsInThinWalls, "★ a sheet lays one cell size per region: sent off")
        // RED CONTROL: a strut type keeps his choice
        l.topologyID = "octet"
        XCTAssertTrue(LatticeLayoutPreview.partWide(l, beadMM: 0.45, wallRingMM: 0, referenceMPa: 0, percent: { _, _ in nil })
                        .smallCellsInThinWalls, "RED CONTROL: the octet's switch is his")
        let wiz = try FlexibleSource.code("LatticeSetupWizard.swift")
        XCTAssertTrue(wiz.contains(".disabled(model.allowQuilt || LatticeSheets.greyed(model.topologyID).contains(.smallCellsInThinWalls))"),
                      "★ the switch is greyed for a sheet")
        XCTAssertTrue(wiz.contains("sheetGreyedCaption(.smallCellsInThinWalls)"), "★ with its five words and (i)")
    }

    // MARK: 6 · the refresh card in a sheet's own words (M1's follow-up)

    /// With Skip all animations on, the card says what the engine does: a sheet lays its walls (never "struts"), then its map
    /// (a sheet is drawn on it, X-ray too). RED CONTROL: a strut type's card is as it was.
    func testTheRefreshCardSaysASheetLaysItsWalls() throws {
        let words = LatticeLayoutPreview.layStep(sheet: true)
        XCTAssertEqual(words, "Laying the walls")
        XCTAssertLessThanOrEqual(LatticeCaptions.words(words), LatticeCaptions.maxWords)
        XCTAssertEqual(Self.negative(words), [], "★ positive words")
        let preview = LatticeLayoutPreview()
        let sheet = preview.refreshSteps(organic: false, path: "/nowhere.step", sheet: true).map(\.words)
        XCTAssertTrue(sheet.contains("Laying the walls"), "★ \(sheet)")
        XCTAssertFalse(sheet.contains { $0.contains("strut") }, "★ never struts for a sheet: \(sheet)")
        XCTAssertTrue(sheet.contains(LatticeLayoutPreview.stepMap), "★ and its map, made in every view: \(sheet)")
        // RED CONTROL: a strut type's lay, X-ray: as it was
        let struts = preview.refreshSteps(organic: false, path: "/nowhere.step").map(\.words)
        XCTAssertTrue(struts.contains(LatticeLayoutPreview.stepLay), "RED CONTROL: \(struts)")
        XCTAssertFalse(struts.contains(LatticeLayoutPreview.stepMap), "RED CONTROL: no map step in X-ray for struts")
        // the page and the sample ask the lay's own words
        let page = try FlexibleSource.code("LatticeLayoutPreview.swift"), sample = try FlexibleSource.code("LatticeSampleView.swift")
        XCTAssertTrue(page.contains("refresh.reached(layWords)"))
        XCTAssertTrue(page.contains("sheet: LatticeSheets.isSheet(p.lattice.topologyID)"))
        XCTAssertTrue(sample.contains("LatticeLayoutPreview.layStep(sheet: LatticeSheets.isSheet(i.topology))"))
    }

    // MARK: 5 · a sheet's print file is core's 3MF

    func testASheetPrintFileJobAsksForA3MF() throws {
        var s = LatticeLayoutSession.Settings()
        s.topology = "gyroid"; s.sheetSeam = "blend"; s.autoByCell = true; s.allLattice = true
        let job = try XCTUnwrap(try JSONSerialization.jsonObject(with: LatticeFileJob.build(s, modelName: "part.step")) as? [String: Any])
        XCTAssertEqual(job["file_format"] as? String, "3mf", "★ a sheet's print file is a 3MF (painted supports, his print settings)")
        XCTAssertEqual((job["layout"] as? [String: Any])?["sheet_seam"] as? String, "blend", "and it carries the sheet's keys")
        // RED CONTROL: release 20's job left a cell lattice to core's STL
        LatticeFileJob.controlOrganicOnly3MF = true
        defer { LatticeFileJob.controlOrganicOnly3MF = false }
        let before = try XCTUnwrap(try JSONSerialization.jsonObject(with: LatticeFileJob.build(s, modelName: "part.step")) as? [String: Any])
        XCTAssertNil(before["file_format"], "RED CONTROL: no file_format, core's STL")
    }

    // MARK: 4 · the build timelapse on a sheet

    /// The shader's `sheet_build_hidden` is `LatticeBuildTimelapse.sheetStep`: a place shows once the snaps reach its floor's
    /// bay; a floor's first snap (its columns, for struts) shows nothing of a sheet. RED CONTROL: no timelapse hides nothing.
    func testTheSheetShaderHidesWhatTheTimelapseHasNotBuilt() throws {
        #if canImport(MetalKit)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let pass = try LatticeLayoutSheetPass(device: device)
        let f = LatticeBuildTimelapse.Frame(lo: SIMD3(-2, -3, 0), hi: SIMD3(38, 27, 40), up: SIMD3(0, 0, 1), across: SIMD3(1, 0, 0))
        XCTAssertEqual(f.floors, 4)
        // deterministic points over the box (a fixed lattice of irrational steps, wrapped)
        let pts = (0..<500).map { i -> SIMD3<Float> in
            let k = Float(i)
            return SIMD3(-2 + 40 * (k * 0.618034).truncatingRemainder(dividingBy: 1),
                         -3 + 30 * (k * 0.754878).truncatingRemainder(dividingBy: 1),
                         40 * (k * 0.569840).truncatingRemainder(dividingBy: 1))
        }
        let all = f.floors * LatticeBuildTimelapse.perFloor
        var shownBefore = -1
        for n in 0...all {
            let hidden = try XCTUnwrap(pass.probeBuildHidden(pts, reveal: LatticeBuildRevealUniform(snaps: n, frame: f)))
            let want = pts.map { LatticeBuildTimelapse.sheetStep($0, f) >= n }
            XCTAssertEqual(zip(hidden, want).filter { $0 != $1 }.count, 0, "★ snap \(n): the shader is the Swift rule")
            let shown = hidden.filter { !$0 }.count
            XCTAssertGreaterThanOrEqual(shown, shownBefore, "it only ever rises")
            if n > 0, n % LatticeBuildTimelapse.perFloor == 1 {
                XCTAssertEqual(shown, shownBefore, "★ a floor's first beat adds nothing of a sheet (it has no columns)")
            }
            shownBefore = shown
        }
        XCTAssertEqual(shownBefore, pts.count, "★ every place shows at the end")
        // RED CONTROL: no timelapse (build.x < 0) hides nothing, whatever the frame
        XCTAssertEqual(try XCTUnwrap(pass.probeBuildHidden(pts, reveal: LatticeBuildRevealUniform())).filter { $0 }.count, 0)
        #endif
    }

    #if canImport(MetalKit)
    /// The 10 mm cube's map, all open lattice inside it (LatticeSheetsAppTests.map).
    static func openCube() -> LatticeLayoutSolidGrid { LatticeSheetsAppTests.map { _ in true } }

    /// ★ img 97 made impossible for a sheet too: while the lay runs nothing of a sheet is drawn (neither the last lay's nor the
    /// new one's); the new sheet then rises floor by floor, each snap more of it, ending on the whole sheet. Its box is its own
    /// (a sheet has no bars to take one from). RED CONTROL (no timelapse): the last sheet stays on screen mid-lay.
    @MainActor
    func testASheetRisesFloorByFloorAndNothingShowsMidLay() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let r = MeshRenderer(device: device, sampleCount: 1) else {
            throw XCTSkip("no renderer: \(MeshRenderer.lastInitError ?? "?")")
        }
        let walls = LatticeLayoutBarsPass.drawWalls
        defer { LatticeLayoutBarsPass.drawWalls = walls }
        LatticeLayoutBarsPass.drawWalls = false
        r.setMesh(Notes26BarsClipTests.cube)
        r.camera.setOrientation(azimuth: 0.6, elevation: 0.5)
        r.setBodyAlpha(0)
        let clear = MTLClearColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)
        func pixels() throws -> Int {
            LatticeLayoutSolidViewTests.strutPixels(try XCTUnwrap(r.renderOffscreen(width: 320, height: 320, clear: clear, stage: false)))
        }
        let field = LatticeSheetField(kind: .gyroid, cellMM: 5, wallMM: [0.9])
        func inputs(_ token: Int) -> LatticeLayoutBarsInputs {
            var i = LatticeLayoutBarsInputs(token: token, bars: [])
            i.sheets = LatticeSheetDrawing(token: token, fields: [field], map: Self.openCube())
            return i
        }
        XCTAssertTrue(r.applyLayoutBars(inputs(2), device: device))
        let whole = try pixels()
        XCTAssertGreaterThan(whole, 2000, "premise: the sheet drawn whole")
        XCTAssertNotNil(r.layoutBars?.box, "★ a sheet's own box: the timelapse's floors and bays")
        XCTAssertNil(LatticeLayoutBarsPass.box([]), "RED CONTROL: the bars' box alone gave a sheet none (shown whole at once)")
        for red in [false, true] {
            LatticeBuildShow.controlOff = red
            let show = LatticeBuildShow()
            r.applyBuildShow(show)
            r.applyLayoutBars(inputs(1), device: device)
            let t0 = CACurrentMediaTime() + 1000
            LatticeBuildShow.clockForTesting = t0
            show.layBegins(now: t0)
            var midLay: [Int] = []
            for k in 0..<4 {
                LatticeBuildShow.clockForTesting = t0 + Double(k) * 0.2
                midLay.append(try pixels())
            }
            let land = t0 + 0.8
            LatticeBuildShow.clockForTesting = land
            r.applyLayoutBars(inputs(2), device: device)
            show.landed(token: 2, now: land)
            if red {
                XCTAssertGreaterThan(midLay.min() ?? 0, 1000, "RED CONTROL: the last sheet stays on screen while the engine lays")
                continue
            }
            XCTAssertEqual(midLay, [0, 0, 0, 0], "★ nothing of a sheet while the engine lays")
            let end = try XCTUnwrap(show.timelapse?.end)
            var t = land, seen: [Int] = [], counts: [Int] = []
            while t < end + 0.5 {
                LatticeBuildShow.clockForTesting = t
                let px = try pixels()
                if let n = r.lastBuildSnaps, n > 0 {
                    if seen.last != n { seen.append(n); counts.append(px) }
                } else if r.lastBuildSnaps == nil, seen.last != .max {
                    seen.append(.max); counts.append(px)
                }
                t += 1.0 / 30
            }
            let fr = try XCTUnwrap(r.lastBuildFrame)
            print("NOTES30 SHEET TIMELAPSE: \(fr.floors) floors; snaps \(seen); pixels per snap \(counts); whole \(whole)")
            XCTAssertEqual(seen.last, .max, "★ it ends on the whole sheet")
            XCTAssertEqual(Double(counts.last ?? 0), Double(whole), accuracy: Double(whole) / 50, "★ the finished sheet")
            for (a, b) in zip(counts, counts.dropFirst()) { XCTAssertGreaterThanOrEqual(b, a - whole / 100, "it only ever rises") }
            XCTAssertLessThan(counts.dropLast().filter { $0 > 0 }.first ?? whole, whole / 2, "★ the first floor a part of it")
            XCTAssertGreaterThanOrEqual(Set(counts).count, fr.floors, "★ floor by floor")
        }
    }
    #endif
}
