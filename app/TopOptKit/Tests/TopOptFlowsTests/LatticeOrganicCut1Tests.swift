// LatticeOrganicCut1Tests — ★ ORGANIC, CUT 1 (his 11-18: "VIEW things on the ipad ASAP"; "Preview PLUS settings
// simultaneously. Export as its own install"; the Lattice button "Off until cut 2"):
//   * his 13 controls reach the engine's keys as LatticeReview mapped them (11-18 08:54Z): every one at Auto is the two stand
//     jobs he judged (Grown `stand_file_gab`, Traced `stand_file_trg0b`); Traced never sends Grown's keys (RED CONTROL: Grown
//     does); his four modes; a heavy end with a single cell size sends min = max (gap a); the Sweeps greyed only when both
//     gradients are off; floating parts' reach and support from the cell size; the Auto Sweep rule on his stand (D 18 mm:
//     struts 0.9 to 1.8, cells 2 to 8, Auto 1.35 and 5);
//   * the runs core packs read back exactly (RED CONTROL: a short packet is refused);
//   * FOR REAL through the bridge: a block with a uniform stress tensor, Traced, laid Exact and Draft; runs come back and
//     the Draft is labelled; core measures the Auto Sweep limits for the woven region;
//   * an old project decodes with no Organic look (all Auto) and a saved look round-trips.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class LatticeOrganicCut1Tests: XCTestCase {

    static let stand = LatticeOrganicLook.Limits(strutLowerMM: 0.9, strutUpperMM: 1.8, strutAutoMM: 1.35,
                                                 cellLowerMM: 2, cellUpperMM: 8, cellAutoMM: 5)

    /// ★ The Auto Sweep rule on his stand, from core alone (Session::sweep_limits, OP5: before any lay, one source): a region
    /// 18 mm deep gives struts 0.9 to 1.8 (Auto 1.35) and cells 2 to 8 (Auto 5); 9 mm deep never goes under the print floor.
    func testTheAutoSweepRuleOnHisStand() async throws {
        let (session, s18) = try await wovenBlock(depthMM: 18)
        let all18 = try await session.sweepLimits(s18, lineMM: 0.45)
        let l = LatticeOrganicLook.Limits(try XCTUnwrap(all18.first))
        XCTAssertTrue(l.measured)
        XCTAssertEqual(l.strutLowerMM, 0.9, accuracy: 1e-6)
        XCTAssertEqual(l.strutUpperMM, 1.8, accuracy: 1e-6)
        XCTAssertEqual(l.strutAutoMM, 1.35, accuracy: 1e-6)
        XCTAssertEqual(l.cellLowerMM, 2, accuracy: 1e-6)
        XCTAssertEqual(l.cellUpperMM, 8, accuracy: 1e-6)
        XCTAssertEqual(l.cellAutoMM, 5, accuracy: 1e-6)
        var s9 = s18
        s9.regions[0].depthMM = 9
        let all9 = try await session.sweepLimits(s9, lineMM: 0.45)
        let small = LatticeOrganicLook.Limits(try XCTUnwrap(all9.first))
        // cut 2 (OG1, the gap rule): never under the cell that leaves 1.5 lines (0.675 mm) between 0.9 mm struts, 2 mm
        // (the print floor, 1.5 mm, is under it)
        XCTAssertEqual(small.gapMM, 0.675, accuracy: 1e-6, "★ the engine's gap between struts")
        XCTAssertEqual(small.cellLowerMM, 2, accuracy: 1e-6, "★ never under the cell that leaves the gap")
        XCTAssertEqual(small.cellUpperMM, 4, accuracy: 1e-6)
        // ★ Look at 100 % halves the range but never goes under the engine's floor (it would refuse the Auto lay)
        XCTAssertEqual(small.looked(percent: 100).cellLowerMM, 2, accuracy: 1e-6, "★ Look keeps the gap floor")
        var noGap = small
        noGap.gapMM = 0
        XCTAssertEqual(noGap.looked(percent: 100).cellLowerMM, 1.5, accuracy: 1e-6, "RED CONTROL: without the gap, the print floor")
        XCTAssertNotNil(LatticeOrganicLook.Check.cell(small: 1.5, large: 4, thinStrutMM: 0.9, gapMM: 0.675),
                        "★ a typed 1.5 mm is refused as the engine refuses it (under_gap_cell)")
        XCTAssertNil(LatticeOrganicLook.Check.cell(small: 2, large: 4, thinStrutMM: 0.9, gapMM: 0.675))
        XCTAssertNil(LatticeOrganicLook.Check.cell(small: 1.5, large: 4, thinStrutMM: 0.9), "RED CONTROL: no gap rule, 1.5 prints")
    }

    /// ★ His 11-18 "a choice between stress and shape gradient or shape gradient alone": the Gradient line is shown and
    /// his pick reaches the engine (organic_follow_stress, OP6).
    func testTheGradientChoiceReachesTheEngine() {
        XCTAssertTrue(LatticeOrganicLook().ask(limits: Self.stand).followStress, "RED CONTROL: stress and shape unless he picks")
        var look = LatticeOrganicLook()
        look.followStress = false
        XCTAssertFalse(look.ask(limits: Self.stand).followStress, "★ shape gradient alone")
        XCTAssertTrue(LatticeOrganicLook.offered(.shapeOnly), "the Gradient line is on the page")
    }

    /// A 30 x 30 x 20 block in a session, its top face woven `depthMM` deep.
    func wovenBlock(depthMM: Double) async throws -> (LatticeLayoutSession, LatticeLayoutSession.Settings) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("organic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("block.stl").path
        try LatticePlaceChipsTests.gridSTL([0, 30], [0, 30], [0, 20]) { _, _, _ in true }.write(to: URL(fileURLWithPath: path))
        let mesh = try TopOptKit.importMesh(path: path)
        let top = try XCTUnwrap(LatticePlaceChipsTests.face(mesh, axis: 2, sign: 1, at: 20))
        let session = try await LatticeLayoutSession.open(path: path)
        addTeardownBlock { session.close() }
        var s = LatticeLayoutSession.Settings()
        var r = LatticeLayoutSession.Region(id: 1, faces: [top], depthMM: depthMM)
        r.weave = true
        s.regions = [r]
        return (session, s)
    }

    func testEveryControlAtAutoIsTheStandJobsHeJudged() {
        // Grown, every control at Auto (nil): stand_file_gab
        let g = LatticeOrganicLook().ask(limits: Self.stand, layerMM: 0.2)
        XCTAssertEqual(g.mode, .grown, "Organic starts Grown")
        XCTAssertEqual(g.spacingMinMM, 2); XCTAssertEqual(g.spacingMaxMM, 8); XCTAssertEqual(g.spacingMM, 0)
        XCTAssertEqual(g.widthMM, 0.9); XCTAssertEqual(g.widthHeavyMM, 1.8)
        XCTAssertTrue(g.wallsOut); XCTAssertEqual(g.wallGap, 2.5); XCTAssertEqual(g.wallGapHeavy, 1.0)
        XCTAssertEqual(g.wallCross, 1, "crossing vines on (never 2)"); XCTAssertEqual(g.crossGap, 2.5); XCTAssertEqual(g.crossGapHeavy, 1.0)
        XCTAssertTrue(g.tieLevel); XCTAssertTrue(g.ties); XCTAssertEqual(g.tieGap, 1.0); XCTAssertEqual(g.tieGapHeavy, 0.5)
        XCTAssertEqual(g.footGap, 2.5); XCTAssertEqual(g.rootRun, 0); XCTAssertEqual(g.topRun, 0); XCTAssertEqual(g.runMax, 1)
        XCTAssertTrue(g.stressGoal); XCTAssertTrue(g.prune)
        XCTAssertTrue(g.shapeFit); XCTAssertEqual(g.shapeReach, 1); XCTAssertFalse(g.memberCap, "always sent false")
        XCTAssertTrue(g.holdParts); XCTAssertTrue(g.partToFloor)
        XCTAssertEqual(g.partReachMM, 12, accuracy: 1e-9, "1.5 x the cell's light end (the stand's 12)")
        XCTAssertEqual(g.partSupportMM, 1.5, accuracy: 1e-9, "0.75 x its heavy end (the stand's 1.5)")
        XCTAssertEqual(g.linkWidth, 1); XCTAssertEqual(g.unbracedMax, 10)
        XCTAssertEqual(g.bedFloorMM, 0.8, accuracy: 1e-9, "4 x the layer height")
        XCTAssertEqual(g.referenceMPa, 0); XCTAssertEqual(g.percentile, 0.95)

        // Traced: Grown's own keys stay at core's defaults (RED CONTROL above: Grown sends them)
        var traced = LatticeOrganicLook(); traced.mode = .traced
        let t = traced.ask(limits: Self.stand)
        XCTAssertEqual(t.mode, .traced)
        XCTAssertFalse(t.wallsOut); XCTAssertEqual(t.wallCross, 0); XCTAssertFalse(t.stressGoal); XCTAssertFalse(t.prune)
        XCTAssertEqual(t.footGap, 2.5, "core's default"); XCTAssertTrue(t.tieLevel, "flat ties are Traced's too")
    }

    /// ★ His ruling 11-18: "It shouldn't be an option if we can't do it or haven't tested" — no single-number Auto anywhere,
    /// Cell size only as a Sweep, Grade to shape always on.
    func testOnlyTheModesThatWereRun() {
        XCTAssertEqual(LatticeOrganicLook.cellModes, [.autoSweep, .manualSweep], "★ Cell size: the two Sweeps only")
        XCTAssertEqual(LatticeOrganicLook.otherModes, [.autoSweep, .manualSweep, .manual], "★ no single-number Auto")
        var look = LatticeOrganicLook()
        look.cell = .init(mode: .manual, single: 4)   // an old saved value: not offered, so Auto Sweep
        XCTAssertEqual(look.four(look.cell, offered: LatticeOrganicLook.cellModes), .autoSweep)
        var o = look.ask(limits: Self.stand)
        XCTAssertEqual(o.spacingMM, 0, "never a single cell size"); XCTAssertEqual(o.spacingMinMM, 2); XCTAssertEqual(o.spacingMaxMM, 8)
        look.cell = .init(mode: .manualSweep, light: 7, heavy: 3)
        look.strut = .init(mode: .manualSweep, light: 1.0, heavy: 1.6)
        o = look.ask(limits: Self.stand)
        XCTAssertEqual(o.spacingMinMM, 3); XCTAssertEqual(o.spacingMaxMM, 7)
        XCTAssertEqual(o.widthMM, 1.0); XCTAssertEqual(o.widthHeavyMM, 1.6)
        look.strut = .init(mode: .manual, single: 1.2)
        look.wallGap = .init(mode: .manual, single: 3)
        o = look.ask(limits: Self.stand)
        XCTAssertEqual(o.widthMM, 1.2); XCTAssertEqual(o.widthHeavyMM, 0, "Manual: one number")
        XCTAssertEqual(o.wallGap, 3); XCTAssertEqual(o.wallGapHeavy, 0)
        look.strut = .init(mode: .auto)   // not offered: Auto Sweep
        XCTAssertEqual(look.ask(limits: Self.stand).widthHeavyMM, 1.8)
        look.gradeToShape = false
        XCTAssertTrue(look.ask(limits: Self.stand).shapeFit, "★ Grade to shape has no off switch")
        XCTAssertTrue(look.sweepsAllowed, "so the Sweeps are never greyed in cut 1")
    }

    @MainActor
    func testTheRunsReadBackAsCorePacksThem() throws {
        var b: [UInt8] = []
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { b.append(contentsOf: $0) } }
        func f(_ v: Float) { u32(v.bitPattern) }
        u32(2); u32(7); b.append(contentsOf: [4, 1, 2, 0])   // 2 points, region 7, support, ends Solid / Surface
        for p: [Float] in [[0, 0, 0, 1.2, 4], [1, 2, 3, 1.4, 5]] { p.forEach(f) }
        u32(1); u32(9); b.append(contentsOf: [8, 0, 0, 0])
        [5, 5, 5, 0.9, 3].forEach { f(Float($0)) }
        let runs = try XCTUnwrap(LatticeLayoutSession.runs(packed: b))
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].region, 7); XCTAssertEqual(runs[0].marks, .support); XCTAssertEqual(runs[0].endA, 1)
        XCTAssertEqual(runs[0].points[1], SIMD3(1, 2, 3)); XCTAssertEqual(runs[0].widthMM, [1.2, 1.4]); XCTAssertEqual(runs[0].spacingMM, [4, 5])
        XCTAssertEqual(runs[1].marks, .net)
        let seg = LatticeLayoutPreview.segments(runs)
        XCTAssertEqual(seg.count, 1, "one segment per pair of neighbouring points")
        XCTAssertEqual(Array(seg.bars), [0, 0, 0, 1, 2, 3, 1.3])
        XCTAssertEqual(seg.cell, [4.5], "a strut's cell size: its points' spacing"); XCTAssertEqual(seg.region, [7])
        XCTAssertNil(LatticeLayoutSession.runs(packed: Array(b.prefix(30))), "RED CONTROL: a short packet is refused")
    }

    /// ★ Packed version 2 (the cut 2 engine; LatticeReview 11-20 03:54Z, final for the skin leg): "WRN2", u32 2, then per run
    /// 28 bytes (the pad now the section; proud_a, proud_b, along_face, proud_mm), per point the file's ring width.
    @MainActor
    func testVersionTwoRunsReadBack() throws {
        var b: [UInt8] = Array("WRN2".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { b.append(contentsOf: $0) } }
        func f(_ v: Float) { u32(v.bitPattern) }
        u32(2)
        u32(2); u32(7); b.append(contentsOf: [8, 0, 2, 1])   // 2 points, region 7, the net, Node / Surface, the D
        f(0); f(0.4); u32(UInt32(bitPattern: 20)); f(0.6)
        for p: [Float] in [[0, 0, 0, 1.2, 4], [1, 2, 3, 1.4, 5]] { p.forEach(f) }
        u32(1); u32(9); b.append(contentsOf: [16, 1, 1, 2 | 4 | 8])   // bit 2 swept (OV1), bit 3 held: neither is the section
        f(0); f(0); u32(UInt32(bitPattern: -1)); f(0)
        [5, 5, 5, 0.9, 3].forEach { f(Float($0)) }
        let runs = try XCTUnwrap(LatticeLayoutSession.runs(packed: b), "★ version 2 reads")
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].marks, .net); XCTAssertEqual(runs[0].endB, 2)
        XCTAssertEqual(runs[0].section, 1, "★ the section byte")
        XCTAssertEqual(runs[0].proudA, 0); XCTAssertEqual(runs[0].proudB, 0.4, accuracy: 1e-6)
        XCTAssertEqual(runs[0].alongFace, 20); XCTAssertEqual(runs[0].proudMM, 0.6, accuracy: 1e-6)
        XCTAssertTrue(runs[0].standsProud)
        XCTAssertEqual(runs[0].widthMM, [1.2, 1.4], "the file's ring widths"); XCTAssertEqual(runs[0].spacingMM, [4, 5])
        XCTAssertEqual(runs[1].marks, .along); XCTAssertEqual(runs[1].section, 2); XCTAssertEqual(runs[1].alongFace, -1)
        XCTAssertTrue(runs[1].swept, "★ bit 2: the file's swept centre line (OV1)"); XCTAssertFalse(runs[0].swept)
        XCTAssertFalse(runs[1].standsProud)
        var bad = b
        bad[4] = 3
        XCTAssertNil(LatticeLayoutSession.runs(packed: bad), "RED CONTROL: another version is refused, never misread")
        XCTAssertNil(LatticeLayoutSession.runs(packed: Array(b.prefix(40))), "RED CONTROL: a short packet is refused")
    }

    /// ★ The key and the card read Organic's struts (no cells): the net skin is boundary work (the rim blue), a strut's
    /// density is its width over its cell size (no strut type's law), and the lay time is on screen.
    @MainActor
    func testTheKeyAndCardReadOrganicStruts() throws {
        let fill = LatticeLayoutSession.Run(region: 1, marks: .brace, endA: 0, endB: 0, points: [SIMD3(0, 0, 0), SIMD3(10, 0, 0)],
                                            widthMM: [1, 1], spacingMM: [4, 4])
        var net = fill
        net.marks = .net; net.points = [SIMD3(0, 5, 0), SIMD3(10, 5, 0)]; net.widthMM = [0.5, 0.5]
        let seg = LatticeLayoutPreview.segments([fill, net])
        XCTAssertEqual(seg.skin, [0, 2], "RED CONTROL: a brace is fill; ★ the net skin is boundary work")
        XCTAssertEqual(seg.lightFrom, 1, "★ the net skin last, drawn by the light pass")
        XCTAssertEqual(LatticeLayoutPreview.organicLightFrom(grown: true, netFrom: 2, count: 2), 0, "★ all of Grown light")
        XCTAssertEqual(LatticeLayoutPreview.organicLightFrom(grown: false, netFrom: 2, count: 2), .max,
                       "RED CONTROL: Traced with no net skin: all drawn round")
        XCTAssertEqual(LatticeLayoutPreview.organicLightFrom(grown: false, netFrom: 1, count: 2), 1, "a net skin: light")
        XCTAssertEqual(LatticeLayoutPreview.segments([net, fill]).skin, [0, 2], "the net goes last whatever the runs' order")
        var laid = LatticeLayoutColours.Laid()
        laid.bars = seg.bars; laid.barFlags = seg.skin; laid.barCell = seg.cell; laid.token = 1
        var organic = LatticeSettings()
        organic.algorithm = "organic"
        let r = try XCTUnwrap(LatticeLayoutPreview.read(laid, at: SIMD3(5, 0, 0), lattice: organic, lookup: nil))
        XCTAssertEqual(r.cellMM, 4); XCTAssertEqual(r.widthMM, 1); XCTAssertEqual(r.density, 0.25, accuracy: 1e-9)
        XCTAssertEqual(r.klass, .interior)
        XCTAssertEqual(try XCTUnwrap(LatticeLayoutPreview.read(laid, at: SIMD3(5, 5, 0), lattice: organic, lookup: nil)).klass, .rim)
        XCTAssertEqual(LatticeLayoutPreview.organicTimeLine(mode: .grown, draft: false, ms: 3840, struts: 63670),
                       "Organic Grown \u{00B7} Exact \u{00B7} laid in 3.8 s \u{00B7} 63,670 struts")
    }

    /// ★ The memory gate: a lay that would not fit in what the iPad has free is refused in one line, never a crash.
    @MainActor
    func testALayThatWouldNotFitIsRefusedInOneLine() {
        XCTAssertNil(LatticeLayoutPreview.organicMemoryShort(mode: .grown, availableMB: 2000), "RED CONTROL: room enough")
        XCTAssertNil(LatticeLayoutPreview.organicMemoryShort(mode: .grown, availableMB: nil), "a Mac does not say: no gate")
        XCTAssertEqual(LatticeLayoutPreview.organicMemoryShort(mode: .grown, availableMB: 400),
                       "Not enough free memory for Grown (400 of 625 MB): close other apps")
        XCTAssertNil(LatticeLayoutPreview.organicMemoryShort(mode: .traced, availableMB: 400), "Traced needs less")
    }

    /// ★ LatticeReview's rulings 2, 3, 4 (organic-app-rulings.md) on his 11-18 iPad notes: Look moves both cell ends by one
    /// factor (50 % = the measured range, never under the smallest printable cell, struts not moved); the whole part's
    /// limits are the union of the measured areas; a typed number is refused only by the engine's own rules (his 2 to 8 is
    /// taken); equal cell ends send no heavy gaps; the page's Auto is Look alone; the printer's layer is sent.
    func testLookTheWholePartLimitsAndTheRules() {
        typealias L = LatticeOrganicLook.Limits
        typealias C = LatticeOrganicLook.Check
        let mid = Self.stand.looked(percent: 50)
        XCTAssertEqual(mid.cellLowerMM, 2); XCTAssertEqual(mid.cellUpperMM, 8, "★ 50 %: the measured range")
        let open = Self.stand.looked(percent: 1)
        XCTAssertEqual(open.cellLowerMM, 4); XCTAssertEqual(open.cellUpperMM, 16, "1 %: twice the range")
        let fine = Self.stand.looked(percent: 100)
        XCTAssertEqual(fine.cellLowerMM, 1.5, "100 %: half, never under the smallest printable cell (1.38 mm, to 1.5)")
        XCTAssertEqual(fine.cellUpperMM, 4)
        XCTAssertEqual(fine.strutLowerMM, 0.9); XCTAssertEqual(fine.strutUpperMM, 1.8, "★ struts are not moved by Look")
        let shallow = L(strutLowerMM: 0.9, strutUpperMM: 0.9, strutAutoMM: 0.9, cellLowerMM: 1.5, cellUpperMM: 4, cellAutoMM: 3)
        let shell = L(strutLowerMM: 0, strutUpperMM: 0, strutAutoMM: 0, cellLowerMM: 0, cellUpperMM: 0, cellAutoMM: 0, measured: false)
        let u = try! XCTUnwrap(L.union([Self.stand, shallow, shell], lineMM: 0.45))
        XCTAssertEqual(u.cellLowerMM, 1.5); XCTAssertEqual(u.cellUpperMM, 8, "★ the union of the measured areas")
        XCTAssertEqual(u.strutLowerMM, 0.9); XCTAssertEqual(u.strutUpperMM, 1.8)
        XCTAssertNil(L.union([shell], lineMM: 0.45), "RED CONTROL: nothing measured, no Auto")
        XCTAssertNil(C.cell(small: 2, large: 8, thinStrutMM: 0.9), "★ his 2 to 8 is taken: no rule against a wall")
        XCTAssertNotNil(C.cell(small: 1, large: 8, thinStrutMM: 0.9), "under the smallest printable cell")
        XCTAssertNotNil(C.cell(small: 5, large: 3, thinStrutMM: 0.9))
        XCTAssertNil(C.cell(small: 3, large: 3, thinStrutMM: 0.9), "equal ends are allowed")
        XCTAssertNotNil(C.strut(thin: 0.45, thick: 1.8, thinnestMM: 0.9), "under two lines")
        XCTAssertNotNil(C.strut(thin: 1.8, thick: 0.9, thinnestMM: 0.9))
        XCTAssertNil(C.strut(thin: 0.9, thick: 1.8, thinnestMM: 0.9))
        XCTAssertNil(C.gap("Wall seed gap", close: 1, wide: 2.5)); XCTAssertNil(C.gap("Wall seed gap", close: 0, wide: 2.5))
        XCTAssertNotNil(C.gap("Wall seed gap", close: 3, wide: 2.5)); XCTAssertNotNil(C.gap("Wall seed gap", close: nil, wide: 0))
        XCTAssertNil(C.unbraced(0)); XCTAssertNil(C.unbraced(10)); XCTAssertNotNil(C.unbraced(2)); XCTAssertNotNil(C.unbraced(41))
        XCTAssertNotNil(C.link(3)); XCTAssertNil(C.link(1))
        var equal = LatticeOrganicLook()
        equal.cell = .init(mode: .manualSweep, light: 3, heavy: 3)
        let q = equal.ask(limits: Self.stand)
        XCTAssertEqual(q.spacingMinMM, 3); XCTAssertEqual(q.spacingMaxMM, 3, "★ equal ends are sent as typed (E2: the engine takes them)")
        var traced = LatticeOrganicLook()
        traced.mode = .traced
        XCTAssertEqual(traced.effective(pageManual: false).ask(limits: Self.stand).mode, .grown, "★ Auto: Look alone, the rest Auto")
        XCTAssertEqual(traced.effective(pageManual: true).ask(limits: Self.stand).mode, .traced)
        XCTAssertEqual(LatticeOrganicLook().ask(limits: Self.stand, layerMM: 0.28).layerMM, 0.28, "★ the printer's layer is sent")
    }

    /// ★ His 11-18 notes ("Please ensure ALL settings are followed"): an Organic control, Look and the page's Auto / Manual
    /// re-lay (release 1 compared only the areas, so a control did not).
    @MainActor
    func testAnOrganicSettingReLays() throws {
        let p = try FlexiblePressFixtures.a1Project(3, self, facePrism: false).project
        p.lattice.algorithm = "organic"
        p.latticePageManual = true
        let k0 = try XCTUnwrap(LatticeLayoutPreview.organicKey(p))
        var look = LatticeOrganicLook()
        look.mode = .traced
        p.lattice.organicLook = look
        let k1 = LatticeLayoutPreview.organicKey(p)
        XCTAssertNotEqual(k1, k0, "★ a control re-lays")
        look.lookPercent = 70
        p.lattice.organicLook = look
        XCTAssertNotEqual(LatticeLayoutPreview.organicKey(p), k1, "★ Look re-lays")
        p.latticePageManual = false
        XCTAssertNotEqual(LatticeLayoutPreview.organicKey(p), k1, "★ the page's Auto re-lays")
        p.lattice.algorithm = "stepped"
        XCTAssertNil(LatticeLayoutPreview.organicKey(p), "RED CONTROL: not Organic, nothing more than the areas")
    }

    func testAnOldProjectHasNoOrganicLookAndASavedOneRoundTrips() throws {
        let old = try JSONDecoder().decode(LatticeSettings.self, from: try JSONEncoder().encode(LatticeSettings()))
        XCTAssertNil(old.organicLook, "absent: every control at Auto")
        XCTAssertFalse(String(data: try JSONEncoder().encode(LatticeSettings()), encoding: .utf8)!.contains("\"organicLook\""),
                       "an untouched project's file is the bytes it was")
        var l = LatticeSettings()
        var look = LatticeOrganicLook(); look.mode = .traced; look.cell = .init(mode: .manualSweep, light: 7, heavy: 3)
        l.organicLook = look
        XCTAssertEqual(try JSONDecoder().decode(LatticeSettings.self, from: try JSONEncoder().encode(l)).organicLook, look)
    }

    /// ★ FOR REAL: Traced on a 30 x 30 x 20 block, its top face woven 15 mm deep, a uniform vertical compression — Exact and
    /// Draft through the bridge; runs come back; core measures Auto's numbers for the woven region.
    /// ★ His 11-18 samples (LatticeReview's E5, E8, FOR REAL through the bridge): the bare 40 mm cube, one woven box region,
    /// ONE stress focus made with no solve — Traced lays curves, Grown lays vines; core reports the region without stress
    /// and filled. RED CONTROL: a count of foci outside 1 to 5 is refused in a plain sentence.
    @MainActor
    func testTheOrganicSampleCubeWithOneFocus() async throws {
        let body = try TopOptKit.latticeSampleBody(cube: true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("organic-test-cube-\(UUID().uuidString).stl")
        try MeshExport.binarySTL(vertices: body.vertices, indices: body.indices, header: Data()).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let session = try await LatticeLayoutSession.open(path: url.path)
        addTeardownBlock { session.close() }
        let b = try XCTUnwrap(LatticeLayoutPreview.box(body.vertices))
        XCTAssertEqual(Double(b.hi.x - b.lo.x), 40, accuracy: 0.01, "premise: the 40 mm cube")
        var s = LatticeLayoutSession.Settings()
        var r = LatticeLayoutSession.Region(id: 1, faces: [], depthMM: 0)
        r.zone = .init(kind: .box, centre: SIMD3<Double>((b.lo + b.hi) / 2), axes: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)],
                       half: SIMD3<Double>((b.hi - b.lo) / 2) + 1)
        r.weave = true
        s.regions = [r]
        let lim = try await session.sweepLimits(s, regions: [1], lineMM: 0.45).map(LatticeOrganicLook.Limits.init)
        for mode in [LatticeOrganicLook.Mode.traced, .grown] {
            var look = LatticeOrganicLook()
            look.mode = mode
            let groups = [LatticeLayoutSession.OrganicGroup(regions: [1], ask: look.ask(limits: lim, layerMM: 0.2))]
            let made = try await session.synthetic(s, groups: groups, walls: [(region: 1, foci: 1)], fromEmpty: true)
            XCTAssertTrue(made.refused.isEmpty, "\(made.refused.map(\.text))")
            XCTAssertEqual(made.withoutStress[1], true, "★ no solve: the region is without stress, and filled")
            XCTAssertGreaterThan(made.filled[1] ?? 0, 0)
            let laid = try await session.layOrganic(s, groups: groups)
            XCTAssertTrue(laid.refused.isEmpty, "\(laid.refused.map(\.text))")
            print("LATTICE-ORGANIC sample cube \(mode.title): \(laid.runs.count) runs, \(laid.segments) segments, "
                  + String(format: "%.0f ms", laid.ms))
            XCTAssertGreaterThan(laid.segments, 100, "★ \(mode.title): one focus lays a lattice in the cube")
        }
        let bad = try await session.synthetic(s, groups: [.init(regions: [1], ask: LatticeOrganicLook().ask(limits: lim))],
                                              walls: [(region: 1, foci: 9)], fromEmpty: true)
        XCTAssertFalse(bad.refused.isEmpty, "RED CONTROL: 9 foci is refused")
    }

    /// ★ Per group (his 11-18; E7, FOR REAL): two woven areas of a block, one Traced and one Grown, laid in one lay, each by
    /// its own ask; a refused group says which. RED CONTROL: a cell end under the smallest printable cell is refused whole.
    func testTwoGroupsLayEachByItsOwnSettings() async throws {
        let (session, s0) = try await wovenBlock(depthMM: 12)
        var s = s0
        // a second woven area: a box zone low in the block (under the top area's 12 mm)
        let n = (16, 16, 11)
        var voigt: [Double] = []
        for k in 0..<n.2 { for _ in 0..<(n.0 * n.1) { voigt += [-1, -1, -10 - Double(k), 0.5, 0.2, 0.1] } }
        try await session.setTensor(voigt: voigt, nx: n.0, ny: n.1, nz: n.2, origin: SIMD3(-1, -1, -1), spacingMM: 2)
        let side = LatticeLayoutSession.Region(id: 2, faces: [], depthMM: 0)
        var z = side
        z.zone = .init(kind: .box, centre: SIMD3(15, 15, 4), axes: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)], half: SIMD3(13, 13, 3))
        z.weave = true
        s.regions.append(z)
        var traced = LatticeOrganicLook(); traced.mode = .traced
        let grown = LatticeOrganicLook()
        let lim = LatticeOrganicLook.Limits(strutLowerMM: 0.9, strutUpperMM: 1.35, strutAutoMM: 0.9, cellLowerMM: 2, cellUpperMM: 4,
                                            cellAutoMM: 3)
        let groups = [LatticeLayoutSession.OrganicGroup(regions: [1], ask: traced.ask(limits: lim)),
                      LatticeLayoutSession.OrganicGroup(regions: [2], ask: grown.ask(limits: lim))]
        let laid = try await session.layOrganic(s, groups: groups)
        XCTAssertTrue(laid.refused.isEmpty, "\(laid.refused.map(\.text))")
        let regions = Set(laid.runs.map(\.region))
        print("LATTICE-ORGANIC two groups: \(laid.runs.count) runs in regions \(regions.sorted()), touches \(laid.crossGroupTouches)")
        XCTAssertTrue(regions.contains(1) && regions.contains(2), "★ each group laid its own area")
        var tiny = traced
        tiny.cell = .init(mode: .manualSweep, light: 4, heavy: 1)
        let refused = try await session.layOrganic(s, groups: [groups[0], .init(regions: [2], ask: tiny.ask(limits: lim))])
        let r = try XCTUnwrap(refused.refused.first, "RED CONTROL: a 1 mm cell end is refused")
        XCTAssertEqual(r.group, 1, "★ the refusal names the group")
        XCTAssertEqual(r.code, "under_gap_cell", "cut 2 (OG1): a 1 mm cell cannot leave the gap between 0.9 mm struts")
        XCTAssertTrue(r.text.hasPrefix("Cell size:"), "a plain sentence, whole: \(r.text)")
    }

    func testTracedOnABlockForRealExactAndDraft() async throws {
        let (session, s) = try await wovenBlock(depthMM: 15)
        // the stress: 2 mm voxels over the block, sigma_zz = -10 MPa with a little shear so directions are defined
        let n = (16, 16, 11)
        var voigt: [Double] = []
        for _ in 0..<(n.0 * n.1 * n.2) { voigt += [-1, -1, -10, 0.5, 0.2, 0.1] }
        try await session.setTensor(voigt: voigt, nx: n.0, ny: n.1, nz: n.2, origin: SIMD3(-1, -1, -1), spacingMM: 2)
        let limits = try await session.sweepLimits(s, lineMM: 0.45)
        XCTAssertEqual(limits.count, 1, "★ core measures the woven region BEFORE any lay (OP5)")
        XCTAssertTrue(limits[0].measured)
        XCTAssertEqual(limits[0].dMM, 15, accuracy: 0.6, "D: the region's depth (its mouth is 30 mm wide)")
        var look = LatticeOrganicLook(); look.mode = .traced
        var ask = look.ask(limits: LatticeOrganicLook.Limits(limits[0]))
        let exact = try await session.layOrganic(s, ask)
        print("LATTICE-ORGANIC block exact: \(exact.runs.count) runs, \(exact.segments) segments, \(exact.strands) strands, "
              + String(format: "%.0f ms", exact.ms))
        XCTAssertEqual(exact.quality, .exact)
        XCTAssertGreaterThan(exact.runs.count, 0, "★ the weave's runs, made on this device")
        XCTAssertGreaterThan(exact.segments, 0)
        // ★ his 11-18 iPad: the solid view's map is open where the weave is, so the body is cut open around it
        let voxel: Float = 1
        let dims = SIMD3<Int32>(34, 34, 24)
        let map = try await session.grid(origin: SIMD3(-2, -2, -2), voxel: voxel, dims: dims)
        var openIn = 0, openDeep = 0
        for k in 0..<Int(dims.z) { for j in 0..<Int(dims.y) { for i in 0..<Int(dims.x) {
            let n = (k * Int(dims.y) + j) * Int(dims.x) + i
            guard map.rg[2 * n] > 0, map.rg[2 * n + 1] > 0 else { continue }
            openIn += 1
            if Float(k) * voxel - 2 < 20 - 16 { openDeep += 1 }   // below the 15 mm weave (z under 4 mm): RED CONTROL
        } } }
        print("LATTICE-ORGANIC block map: \(openIn) open voxels inside, \(openDeep) below the weave")
        XCTAssertGreaterThan(openIn, 1_000, "★ the map is open where the weave is (the body is cut open around it)")
        XCTAssertEqual(openDeep, 0, "RED CONTROL: nothing open below the woven 15 mm")
        ask.quality = .draft
        let draft = try await session.layOrganic(s, ask)
        XCTAssertEqual(draft.quality, .draft, "★ the draft is labelled (it is not what will be made)")
        XCTAssertGreaterThan(draft.runs.count, 0)
    }
}
#endif
