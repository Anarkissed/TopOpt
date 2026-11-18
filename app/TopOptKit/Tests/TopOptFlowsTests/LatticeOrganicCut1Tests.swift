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
        XCTAssertEqual(small.cellLowerMM, 1.5, accuracy: 1e-6, "never under Organic's print floor (1.38 mm at a 0.45 line)")
        XCTAssertEqual(small.cellUpperMM, 4, accuracy: 1e-6)
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
        ask.quality = .draft
        let draft = try await session.layOrganic(s, ask)
        XCTAssertEqual(draft.quality, .draft, "★ the draft is labelled (it is not what will be made)")
        XCTAssertGreaterThan(draft.runs.count, 0)
    }
}
#endif
