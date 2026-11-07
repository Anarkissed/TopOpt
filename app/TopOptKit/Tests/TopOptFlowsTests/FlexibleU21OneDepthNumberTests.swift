// FlexibleU21OneDepthNumberTests — round 7 · U21, batch F "One depth number" (DEPTH-LABEL, SQUISH-CHIP-COVER, HANDLE-PAIRS-AUDIT
// reduced, AUTO-CURVE; his notes of 2026-10-21).
//   His words: Img9 "I set the squish to 7 in the modal and it shows 14 next to the model, after saying it can't go that far....
//   Please ensure that these are consistent. If it can't go to a depth, ensure that the depth it reverts to is labelled correctly
//   in both areas." Img8 "the chip here is covering the icon to drag out the depth of the face prism. Please ensure a buffer
//   between the values and the dragging icon." Img10 "Why can't 'auto' ever meet my curve? … What does it take to meet my curve?
//   Because my curve is literally the default curve."
// On HIS live projects of 2026-10-21 (round7/batch_u21/his_live_1021_lbracket: Group 1 = "Face 6 · lattice" 2000008, 10 lb, his
// curve; his_live_1021_pad: Face 3 + Face 5 and the Edge 9 / Edge 12 presses). Each RED control asserted red inside.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleU21OneDepthNumberTests: XCTestCase {
    static let lattice = 2000008   // his l-bracket's "Face 6 · lattice"
    static var padDir: URL { FlexibleU21DeleteUndoTests.fixtures.appendingPathComponent("his_live_1021_pad", isDirectory: true) }

    override func tearDown() {
        FlexibleBendPrism.controlScaledTag = false
        FlexibleBendPrism.controlTagOnWorkingFace = false
        FlexibleStageModel.controlNoReached = false
        FlexibleRowCopy.controlBendRowAlwaysBend = false
        FlexibleFaceStampHandle.controlCentreGap = false
        super.tearDown()
    }

    func open(_ dir: URL, _ what: String) async throws -> FlexibleStageModel {
        let r = try FlexibleHisProject.restore(dir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await settle(m, what)
        return m
    }

    /// The designs AND Auto settled for what is on screen.
    func settle(_ m: FlexibleStageModel, _ what: String) async throws {
        try await FlexibleSquishFixture.settle(m, what)
        try await FlexibleHisProject.waitFor(120, "\(what): Auto and the designs") {
            !m.autoInFlight && !m.designsInFlight && !m.readiness.designing && m.recommendation != nil
        }
        await m.waitForIdle()
    }

    func set(_ m: FlexibleStageModel, _ r: Int, deepest: Double, dome: Bool = false, kg: Double? = nil) {
        m.edit { s in
            guard var f = s.face(r) else { return }
            f.deepestMM = deepest
            if dome { f.shape = "curves"; f.curveX = FlexibleFaceSettings.defaultCurve; f.curveY = FlexibleFaceSettings.defaultCurve }
            if let kg { f.weightKg = kg; f.weightFrom = nil }
            s.setFace(f)
        }
    }

    func lbracket(deepest: Double, dome: Bool = false, kg: Double? = nil) async throws -> FlexibleStageModel {
        let m = try await open(FlexibleU21OneLatticeRuleTests.lbracketDir, "his l-bracket")
        XCTAssertEqual(m.selectedRegion, Self.lattice, "premise: Face 6 · lattice selected (his Img9)")
        if let g = m.squeezeGroup(of: Self.lattice) { m.rail = .group(g.id) }
        set(m, Self.lattice, deepest: deepest, dome: dome, kg: kg)
        try await settle(m, "his l-bracket at \(deepest) mm")
        return m
    }

    /// X-ray's bend prism as the page builds it (FlexibleStagePage.refreshChannels).
    func prism(_ m: FlexibleStageModel) throws -> (item: ClearanceRenderItem?, k: Double, fe: Bool) {
        let edge = FlexibleSettingsSquish.overlayEdge(model: m)
        let overlay = try XCTUnwrap(edge.map { FlexiblePageChannels.overlay(model: m, maxEdgeMM: $0) } ?? FlexiblePageChannels.overlay(model: m))
        var cache: (key: String, dents: [Float])?
        let views: FlexibleStageViews = [.xray]
        let c = FlexibleStagePage.composeTints(model: m, overlay: overlay, views: views)
        let sq = FlexibleSettingsSquish.shown(model: m, overlay: overlay, channels: c, feCache: &cache)
        return (FlexibleStagePage.xrayItems(model: m, overlay: overlay, dents: sq.dents, k: sq.exaggeration, views: views).first,
                sq.exaggeration, sq.fe)
    }

    // MARK: DEPTH-LABEL — the bend tag reads true millimetres

    func testTheBendLabelReadsTrueMillimetres() async throws {
        let m = try await lbracket(deepest: 7)
        m.selectedRegion = nil   // another face's tag: the face whose chip is not shown
        XCTAssertNil(FlexibleBendPrism.chipFace(model: m))
        let p = try prism(m)
        XCTAssertFalse(p.fe, "premise: the column preview (no Save & Exit), his Img9")
        XCTAssertEqual(p.k, 2, accuracy: 1e-9, "premise: drawn ×2 at 7 mm (the probe's k)")
        FlexibleBendPrism.controlScaledTag = true
        let red = try XCTUnwrap(FlexibleBendPrism.tag(p.item, k: p.k, excluding: nil))
        FlexibleBendPrism.controlScaledTag = false
        let tag = try XCTUnwrap(FlexibleBendPrism.tag(p.item, k: p.k, excluding: FlexibleBendPrism.chipFace(model: m)))
        print("FLEX-U21-F1 7 mm, k \(p.k): RED (today) '\(red.text)' · now '\(tag.text)'")
        XCTAssertEqual(red.text, "14.0 mm", "RED CONTROL: today the ×k drawing's size (his \"14 next to the model\")")
        XCTAssertEqual(tag.text, "7.0 mm", "★ true mm")
        XCTAssertEqual(tag.depthMM, 7, accuracy: 0.05)
        let src = try FlexibleSource.code("FlexibleStagePage.swift")
        XCTAssertTrue(src.contains("FlexibleBendPrism.tag(prism.first, k: c.exaggeration, excluding: FlexibleBendPrism.chipFace(model: model))"),
                      "★ the page reads it so")
    }

    // MARK: DEPTH-LABEL + SQUISH-CHIP-COVER — the working face has one number

    func testTheWorkingFaceHasOneNumber() async throws {
        let m = try await lbracket(deepest: 7)
        XCTAssertEqual(FlexibleBendPrism.chipFace(model: m), Self.lattice, "premise: his face's chip is shown")
        let p = try prism(m)
        let chip = try XCTUnwrap(FlexibleDepthChips.handle(model: m, k: FlexibleStageVolumes.prismK(p.k))).anchor
        FlexibleBendPrism.controlTagOnWorkingFace = true
        let red = try XCTUnwrap(FlexibleBendPrism.tag(p.item, k: p.k, excluding: Self.lattice))
        FlexibleBendPrism.controlTagOnWorkingFace = false
        let d = simd_distance(red.anchor, chip)
        print(String(format: "FLEX-U21-F2 RED (today) bend tag '%@' %.2f mm from the chip's anchor", red.text, d))
        XCTAssertLessThan(d, 1, "RED CONTROL: today the tag sits on the chip (the drag handle)")
        XCTAssertNil(FlexibleBendPrism.tag(p.item, k: p.k, excluding: FlexibleBendPrism.chipFace(model: m)),
                     "★ no bend tag for the face whose chip shows: one number (Group 1 has one face)")
        XCTAssertNotNil(p.item, "★ the prism itself stays drawn")
        // the tag keeps 12 pt off a chip's frame
        let chipFrame = FlexibleDepthChips.frame(at: CGPoint(x: 500, y: 500), model: m)
        XCTAssertFalse(FlexibleBendPrism.tagClear(CGPoint(x: 500, y: 500), chips: [chipFrame]), "★ never on the chip")
        XCTAssertFalse(FlexibleBendPrism.tagClear(CGPoint(x: 500, y: 500 + 22 + 15 + 11), chips: [chipFrame]), "★ never within 12 pt")
        XCTAssertTrue(FlexibleBendPrism.tagClear(CGPoint(x: 500, y: 500 + 22 + 15 + 13), chips: [chipFrame]))
    }

    // MARK: DEPTH-LABEL — an unreached face says the same reached depth in every place

    func testAnUnreachedFaceSaysTheSameReachedDepthInEveryPlace() async throws {
        let m = try await lbracket(deepest: 7)
        let r = Self.lattice
        // RED CONTROL: today's labels
        FlexibleStageModel.controlNoReached = true
        let redCard = FlexibleFaceRows.warning(model: m, region: r)
        let redChip = FlexibleDepthChips.chipText(7, reached: m.reached(region: r))
        FlexibleStageModel.controlNoReached = false
        let x = try XCTUnwrap(m.reached(region: r), "★ core builds short of 7 mm")
        print(String(format: "FLEX-U21-F3 7 mm: core reaches %.3f mm · short %d · RED card '%@' chip '%@'", x.reachedMM, x.shortColumns, redCard ?? "-", redChip))
        XCTAssertEqual(redCard, "Can't reach your curve on \(x.shortColumns) columns", "RED CONTROL: today's card line")
        XCTAssertEqual(redChip, "7.0 mm", "RED CONTROL: today's chip")
        XCTAssertEqual(x.reachedMM, 0.6, accuracy: 0.1, "★ core reaches about 0.6 mm (the probe: 0.64)")
        XCTAssertEqual(x.deepestMM, 7)
        let words = FlexibleRowCopy.reachedOf(x.reachedMM, 7)
        XCTAssertEqual(words, "0.6 of 7.0 mm")
        let card = try XCTUnwrap(FlexibleFaceRows.warning(model: m, region: r))
        XCTAssertEqual(card, "Reaches 0.6 of 7.0 mm \u{00B7} \(x.shortColumns) columns short", "★ the card")
        XCTAssertLessThanOrEqual(card.count, FlexibleRowCopy.maxChars)
        XCTAssertEqual(FlexibleDepthChips.chipText(7, reached: m.reached(region: r)), words, "★ the chip")
        // the Prisms view's floor tag (seen when the face is not the working one) and the Auto pane's per-face line
        m.selectedRegion = nil
        let floor = try XCTUnwrap(FlexibleStageViewTags.floors(model: m, k: 2).first { $0.region == r }, "his face's floor tag")
        XCTAssertEqual(floor.text, words, "★ the Prisms tag")
        let rec = try XCTUnwrap(m.recommendation)
        XCTAssertTrue(rec.failures.contains { $0.face == r }, "premise: Auto lists his face")
        XCTAssertTrue(FlexibleRowCopy.coreBuilds(x.reachedMM, of: x.deepestMM).contains(words), "★ the Auto pane")
        XCTAssertEqual(m.settings.face(r)?.deepestMM, 7, "★ his box keeps 7 (no clamp, ruling G)")
        let panes = try FlexibleSource.code("FlexiblePanes.swift")
        XCTAssertTrue(panes.contains("if let x = model.reached(region: f.face)"), "★ the pane reads the one source")
    }

    // MARK: positive control — a reached face keeps its plain labels

    func testAReachedFaceKeepsItsPlainLabels() async throws {
        // the probe's window: the default dome at twice his weight (20 lb) meets at 0.5 mm
        let m = try await lbracket(deepest: 0.5, dome: true, kg: 9.0718474)
        let r = Self.lattice
        let d = try XCTUnwrap(m.design(r))
        print("FLEX-U21-F4 dome 0.5 mm 20 lb: ok \(d.ok) firm \(d.tooFirm) soft \(d.tooSoft) beyond \(d.beyondData) · reached \(m.reached(region: r).map { "\($0.reachedMM)" } ?? "nil") · card '\(FlexibleFaceRows.warning(model: m, region: r) ?? "-")'")
        XCTAssertNil(m.reached(region: r), "★ core reaches his depth: no 'of'")
        XCTAssertEqual(FlexibleDepthChips.chipText(0.5, reached: m.reached(region: r)), "0.5 mm", "★ the chip's plain number")
        XCTAssertFalse(FlexibleFaceRows.warning(model: m, region: r)?.hasPrefix("Reaches") ?? false, "★ no 'Reaches' line")
        m.selectedRegion = nil
        XCTAssertEqual(FlexibleStageViewTags.floors(model: m, k: 1).first { $0.region == r }?.text, "0.5 mm", "★ the plain Prisms tag")
    }

    // MARK: shortOfDrawn compares true depth

    func testShortOfDrawnReadsTrueDepth() async throws {
        let m = try await lbracket(deepest: 7)
        m.selectedRegion = nil
        // a bend of 0.6 mm true drawn ×12 (7.2 mm on screen) beside his 7 mm drawing: short, said
        let base: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(10, 0, 0), SIMD3(0, 10, 0)]
        let k: Float = 12
        let offset = base.map { $0 + SIMD3<Float>(0, 0, -0.6) * k }
        let shell = FaceOffsetShell(base: base, offset: offset, indices: [0, 1, 2], reachedDepthMM: Double(0.6 * k))
        let item = ClearanceRenderItem(volume: .shell(faceID: -1, shell: shell), selected: false, tint: FlexibleBendPrism.tint,
                                       faceAlpha: 0.2, edgeAlpha: 0.8)
        FlexibleBendPrism.controlScaledTag = true
        let red = try XCTUnwrap(FlexibleBendPrism.tag(item, k: Double(k), excluding: nil))
        let redShort = FlexibleBendPrism.shortOfDrawn(model: m, depthMM: red.depthMM)
        FlexibleBendPrism.controlScaledTag = false
        let tag = try XCTUnwrap(FlexibleBendPrism.tag(item, k: Double(k), excluding: nil))
        let short = FlexibleBendPrism.shortOfDrawn(model: m, depthMM: tag.depthMM)
        print("FLEX-U21-F5 RED (today) \(red.text) short \(redShort) · now \(tag.text) short \(short)")
        XCTAssertFalse(redShort, "RED CONTROL: the ×k number hides the shortfall")
        XCTAssertEqual(tag.depthMM, 0.6, accuracy: 1e-3)
        XCTAssertTrue(short, "★ 0.6 of 7 mm: less than drawn, said")
        // his own 7 mm drawing is never 'less than drawn'
        let p = try prism(m)
        let mine = try XCTUnwrap(FlexibleBendPrism.tag(p.item, k: p.k, excluding: nil))
        XCTAssertFalse(FlexibleBendPrism.shortOfDrawn(model: m, depthMM: mine.depthMM))
    }

    // MARK: the column preview's legend row says "your drawing"

    func testTheColumnPreviewLegendSaysDrawing() async throws {
        let m = try await lbracket(deepest: 7)
        let p = try prism(m)
        XCTAssertFalse(p.fe)
        let k = Int(p.k.rounded())
        FlexibleRowCopy.controlBendRowAlwaysBend = true
        let red = FlexibleRowCopy.legendBendRow(short: false, drawing: !p.fe, k: k)
        FlexibleRowCopy.controlBendRowAlwaysBend = false
        let row = FlexibleRowCopy.legendBendRow(short: false, drawing: !p.fe, k: k)
        print("FLEX-U21-F6 RED (today) '\(red)' · now '\(row)'")
        XCTAssertEqual(red, "Prism = bend at full load", "RED CONTROL: X1's row over his drawing")
        XCTAssertEqual(row, "Prism = your drawing \u{00D7}2", "★ the column preview")
        XCTAssertEqual(FlexibleRowCopy.legendBendRow(short: false, drawing: false, k: 2), "Prism = bend at full load", "★ the 3D sim keeps it")
        XCTAssertEqual(FlexibleRowCopy.legendBendRow(short: false, drawing: true, k: 1), "Prism = your drawing")
        let src = try FlexibleSource.code("FlexibleStagePage.swift")
        XCTAssertTrue(src.contains("bendDrawing: !playingFE"), "★ the page passes the sim's state")
    }

    // MARK: HANDLE-PAIRS-AUDIT (reduced) — the stamp handle keeps 24 pt off the chip

    func testStampHandleKeepsTwentyFourPointsOffTheChip() {
        let chip = CGPoint(x: 400, y: 300)
        let size = FlexibleFaceStampHandle.defaultChipSize
        // RED CONTROL: the old 56 pt centre rule — a stamp 40 pt beside the chip: the handle overlaps the 93 pt chip
        FlexibleFaceStampHandle.controlCentreGap = true
        let redH = FlexibleFaceStampHandle.handlePoint(centre: CGPoint(x: 440, y: 300), chip: chip, chipSize: size)
        let redGap = FlexibleFaceStampHandle.gap(handle: redH, chip: chip, chipSize: size)
        FlexibleFaceStampHandle.controlCentreGap = false
        print(String(format: "FLEX-U21-F7 RED (today) handle %.0f,%.0f gap %.1f pt", redH.x, redH.y, redGap))
        XCTAssertLessThan(redGap, 0, "RED CONTROL: today they overlap (≈ 12 pt sideways)")
        var worst = CGFloat.infinity
        for deg in stride(from: 0.0, to: 360.0, by: 15) {
            for dist in [0.0, 10, 30, 56, 80] {
                let c = CGPoint(x: chip.x + CGFloat(cos(deg * .pi / 180) * dist), y: chip.y + CGFloat(sin(deg * .pi / 180) * dist))
                let h = FlexibleFaceStampHandle.handlePoint(centre: c, chip: chip, chipSize: size)
                worst = min(worst, FlexibleFaceStampHandle.gap(handle: h, chip: chip, chipSize: size))
            }
        }
        print(String(format: "FLEX-U21-F7 now: the smallest gap over 24 directions × 5 distances %.1f pt", worst))
        XCTAssertGreaterThanOrEqual(worst, 24, "★ ≥ 24 pt between the two hit areas, every way round")
        let far = CGPoint(x: 400, y: 380)
        XCTAssertEqual(FlexibleFaceStampHandle.handlePoint(centre: far, chip: chip, chipSize: size), far, "★ clear already: at the stamp's centre")
        // a wider "0.6 of 7.0 mm" chip pushes it further
        let wide = FlexibleDepthChips.size(text: "0.6 of 7.0 mm")
        let hw = FlexibleFaceStampHandle.handlePoint(centre: CGPoint(x: 460, y: 300), chip: chip, chipSize: wide)
        XCTAssertGreaterThanOrEqual(FlexibleFaceStampHandle.gap(handle: hw, chip: chip, chipSize: wide), 24)
    }

    // MARK: AUTO-CURVE — Auto says what it takes

    func autoLine(_ m: FlexibleStageModel, blocker: Bool = true) -> String {
        let r = m.recommendation
        return FlexibleRowCopy.autoLine(noData: m.material?.noPrediction != nil, pressedFaces: m.settings.loadedFaces.count,
                                        chosen: r?.chosen, reachable: r?.reachable, error: m.recommendationError != nil,
                                        topology: r?.topology ?? "", tempC: r?.tempC, blocker: blocker ? m.autoBlocker(r) : nil).text
    }

    func testAutoSaysWhatItTakes() async throws {
        let m = try await lbracket(deepest: 7)
        let red = autoLine(m, blocker: false)
        let line = autoLine(m)
        print("FLEX-U21-F8 l-bracket 7 mm his curve: RED (today) '\(red)' · now '\(line)' · failures \(m.recommendation?.failures.map { "\($0.face): firm \($0.tooFirm) soft \($0.tooSoft) beyond \($0.beyondData)" } ?? [])")
        XCTAssertEqual(red, FlexibleRowCopy.autoUnreachable, "RED CONTROL: today's line")
        XCTAssertEqual(line, "Auto: Face 6 needs more weight or less depth", "★ names his face and what it takes")
        XCTAssertLessThanOrEqual(line.count, FlexibleRowCopy.maxChars)
        let panel = try FlexibleSource.code("FlexibleFacePanel.swift")
        XCTAssertTrue(panel.contains("blocker: model.autoBlocker(r))"), "★ the More tab's row reads it")
        XCTAssertEqual(m.settings.face(Self.lattice)?.deepestMM, 7, "★ nothing changed for him (ruling G)")
    }

    func direction(_ f: FlexFailure) -> String {
        if f.beyondData > max(f.tooFirm, f.tooSoft) { return "is past the tested squish" }
        return f.tooSoft > f.tooFirm ? "less weight or more depth" : "more weight or less depth"
    }

    func worst(_ m: FlexibleStageModel) throws -> FlexFailure {
        try XCTUnwrap(m.recommendation?.failures.max { a, b in
            let na = a.tooFirm + a.tooSoft + a.beyondData, nb = b.tooFirm + b.tooSoft + b.beyondData
            return na != nb ? na < nb : a.face > b.face
        })
    }

    func testAutoNamesTheSoftFace() async throws {
        let m = try await open(Self.padDir, "his pad of 10-21")
        let faces = m.settings.loadedFaces.map(\.faceRegionID).filter { $0 < 1000 }
        XCTAssertFalse(faces.isEmpty, "premise: his pad's pressed faces")
        for r in faces { set(m, r, deepest: 0.1) }   // shallower than the firmest lattice squishes under his weight
        try await settle(m, "his pad at 0.1 mm")
        let w = try worst(m)
        let line = autoLine(m)
        print("FLEX-U21-F9 pad 0.1 mm: '\(line)' · worst \(m.autoName(w.face)) firm \(w.tooFirm) soft \(w.tooSoft) beyond \(w.beyondData) · red '\(autoLine(m, blocker: false))'")
        XCTAssertEqual(autoLine(m, blocker: false), FlexibleRowCopy.autoUnreachable, "RED CONTROL: today's line")
        XCTAssertGreaterThan(w.tooSoft, w.tooFirm, "premise: too soft (even the firmest lattice squishes deeper)")
        XCTAssertEqual(line, "Auto: \(m.autoName(w.face)) needs less weight or more depth", "★ names the face, the direction from core's counts")
        XCTAssertTrue(line.hasPrefix("Auto: Face "))
    }

    func testAutoNamesTheBlockingPress() async throws {
        let m = try await open(Self.padDir, "his pad of 10-21")
        let faces = m.settings.loadedFaces.map(\.faceRegionID).filter { $0 < 1000 }
        for r in faces { set(m, r, deepest: 2, dome: true) }   // the probe: the faces alone meet the dome at 2 mm
        try await settle(m, "his pad, dome at 2 mm")
        let rec = try XCTUnwrap(m.recommendation)
        let w = try worst(m)
        let line = autoLine(m)
        print("FLEX-U21-F10 pad dome 2 mm: '\(line)' · failures \(rec.failures.map { "\(m.autoName($0.face)): firm \($0.tooFirm) soft \($0.tooSoft) beyond \($0.beyondData)" })")
        XCTAssertFalse(rec.reachable, "premise: the presses still fail")
        XCTAssertFalse(rec.failures.contains { faces.contains($0.face) }, "premise: the faces meet the dome at 2 mm")
        XCTAssertTrue(m.autoName(w.face).hasPrefix("Edge "), "★ the blocking press by its name")
        let d = direction(w)
        XCTAssertEqual(line, "Auto: \(m.autoName(w.face)) \(d.hasPrefix("is") ? d : "needs " + d)", "★ what it takes")
        XCTAssertEqual(autoLine(m, blocker: false), FlexibleRowCopy.autoUnreachable, "RED CONTROL: today's line")
    }

    func testTheDefaultDomeCanPass() async throws {
        // positive control: his l-bracket, the default dome, inside the measured window (20 lb, 0.5 mm) — Auto names its pick
        let m = try await lbracket(deepest: 0.5, dome: true, kg: 9.0718474)
        let rec = try XCTUnwrap(m.recommendation)
        let line = autoLine(m)
        print("FLEX-U21-F11 l-bracket dome 0.5 mm 20 lb: reachable \(rec.reachable) · '\(line)'")
        XCTAssertTrue(rec.reachable, "★ the default dome can be met")
        XCTAssertNil(m.autoBlocker(rec))
        XCTAssertEqual(line, FlexibleRowCopy.auto(topology: rec.topology, tempC: rec.tempC), "★ the pick, as today")
    }

    func testCopyFits() {
        for (r, d, n) in [(0.6, 7.0, 4549), (12.3, 23.0, 4557), (0.0, 120.0, 99999)] {
            XCTAssertLessThanOrEqual(FlexibleRowCopy.reaches(r, of: d, short: n).count, FlexibleRowCopy.maxChars)
        }
        for name in ["Face 6", "Edge 12", "A very long surface sector name"] {
            for b in [(1, 0, 0), (0, 1, 0), (0, 0, 1), (0, 0, 0)] {
                let s = FlexibleRowCopy.autoWhatItTakes(.init(name: name, tooFirm: b.0, tooSoft: b.1, beyondData: b.2))
                XCTAssertLessThanOrEqual(s.count, FlexibleRowCopy.maxChars, s)
            }
        }
        XCTAssertEqual(FlexibleRowCopy.autoWhatItTakes(.init(name: "Edge 12", tooFirm: 0, tooSoft: 2, beyondData: 11)),
                       "Auto: Edge 12 is past the tested squish")
        XCTAssertLessThanOrEqual(FlexibleRowCopy.legendBendRow(short: true, drawing: true, k: 12).count, FlexibleRowCopy.maxChars)
    }
}
