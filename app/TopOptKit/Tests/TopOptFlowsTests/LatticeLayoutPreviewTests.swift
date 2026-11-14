// LatticeLayoutPreviewTests — the new engine's preview (the lattice rebuild, stage E; his blitz 2026-11-12, the reviewer's go
// 20:21Z) behind "New engine (test)":
//   * the switch is OFF by default (off, the page is today's: the full suite is the proof of that);
//   * P7: the bars are ONE buffer — his stand's 37,233 bars are 1.2 MB, far past Metal's 4 KB inline limit (his 11-11 crash);
//     the only inline bytes are one fixed frame (RED CONTROL: the bars inline would be 290 times the limit);
//   * the pass packs a bar's width as its radius;
//   * the bars DRAW (a frame with them is not the frame without), and taking them away gives today's frame back exactly;
//   * the page's settings for core: two-line struts always, its face rows as regions (his pad's Group C, faces 3 and 5).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import MetalKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class LatticeLayoutPreviewTests: XCTestCase {

    func testTheSwitchIsOffByDefault() throws {
        let suite = "LatticeLayoutPreviewTests-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let s = AppSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertFalse(s.newEngineTest, "★ New engine (test) is OFF until he turns it on")
        s.newEngineTest = true
        XCTAssertTrue(AppSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite))).newEngineTest, "it is remembered")
    }

    func testPackHalvesTheWidthAndKeepsTheEnds() {
        let p = LatticeLayoutBarsPass.pack([0, 0, 0, 1, 2, 3, 0.9, 4, 5, 6, 7, 8, 9, 1.2])
        XCTAssertEqual(p, [SIMD4(0, 0, 0, 0.45), SIMD4(1, 2, 3, 0), SIMD4(4, 5, 6, 0.6), SIMD4(7, 8, 9, 0)])
    }

    /// ★ P7 (18c0b0e0): his stand's 37,233 bars in ONE buffer; the only inline bytes are a fixed frame under 4 KB.
    func testTheBarsAreOneBufferAndTheInlineBytesAreFixed() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let pass = try LatticeLayoutBarsPass(device: device)
        let n = 37_233
        pass.upload(.init(token: 1, bars: Self.grid(n)))
        XCTAssertEqual(pass.count, n)
        XCTAssertEqual(pass.buffer?.length, n * 2 * MemoryLayout<SIMD4<Float>>.stride, "★ every bar in one buffer")
        XCTAssertLessThan(MemoryLayout<LatticeLayoutBarsPass.Frame>.stride, 4096, "★ the only inline bytes: one fixed frame")
        XCTAssertGreaterThan(n * 2 * MemoryLayout<SIMD4<Float>>.stride, 4096 * 200, "RED CONTROL: inline, they'd be ~290× Metal's 4 KB")
    }

    /// ★ The bars draw, inside a see-through cube; taking them away gives today's frame back, byte for byte.
    func testTheBarsDrawAndOffIsTodaysFrame() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let r = MeshRenderer(device: device, sampleCount: 1) else { throw XCTSkip("no renderer: \(MeshRenderer.lastInitError ?? "?")") }
        r.setMesh(Self.cubeMesh(20))
        r.camera.setOrientation(azimuth: 0.6, elevation: 0.5)
        r.setBodyAlpha(0.2)
        let clear = MTLClearColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)
        let today = try XCTUnwrap(r.renderOffscreen(width: 320, height: 240, clear: clear, stage: false))
        XCTAssertFalse(r.applyLayoutBars(nil, device: device), "no bars, no pass: nothing to redraw")
        XCTAssertEqual(try XCTUnwrap(r.renderOffscreen(width: 320, height: 240, clear: clear, stage: false)), today,
                       "★ OFF: the frame is today's")
        XCTAssertTrue(r.applyLayoutBars(.init(token: 7, bars: Self.grid(400, pitch: 2, from: -8)), device: device))
        XCTAssertTrue(r.layoutBarsInFrame, "premise: the bars are in the frame")
        let withBars = try XCTUnwrap(r.renderOffscreen(width: 320, height: 240, clear: clear, stage: false))
        let changed = zip(withBars, today).filter { $0 != $1 }.count
        print("NEW-ENGINE bars drawn: \(changed / 4) pixels differ")
        XCTAssertGreaterThan(changed / 4, 2_000, "★ the bars are drawn")
        XCTAssertTrue(r.applyLayoutBars(nil, device: device))
        XCTAssertEqual(try XCTUnwrap(r.renderOffscreen(width: 320, height: 240, clear: clear, stage: false)), today,
                       "★ taken away: today's frame again")
    }

    /// ★ The page's settings for core: two-line struts; his pad's Group C face rows (faces 3 and 5) as two regions.
    func testTheSettingsReadThePagesFaceRows() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        let bare = LatticeLayoutPreview.settings(p)
        XCTAssertEqual(bare.minStrutLines, 2, "★ two-line struts (the reviewer's ruling 11-12)")
        _ = try FlexibleR7M1Fixtures.hisLiveLattice(p)
        let s = LatticeLayoutPreview.settings(p)
        print("NEW-ENGINE settings on his pad: \(s.regions.map { "\($0.faces) \($0.noLattice ? "no lattice" : "lattice") \($0.depthMM) mm" })")
        XCTAssertEqual(s.minStrutLines, 2)
        XCTAssertEqual(Set(s.regions.filter { !$0.noLattice }.flatMap(\.faces)), [3, 5], "★ Group C's two face rows")
        XCTAssertEqual(Set(s.regions.filter { !$0.noLattice }.map(\.depthMM)), [25], "★ each with its face row's depth (his Group C: 25 mm)")
        XCTAssertFalse(s.allLattice, "a face asks for lattice: All solid with regions")
    }

    /// ★ His pick 11-12: Lattice Setup's Finish and Grade to shape reach core (Skin went as Covered; Covered and the grade were
    /// not sent).
    func testTheFinishAndGradeReachTheEngine() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.boundary = .fullSkin
        var s = LatticeLayoutPreview.settings(p)
        XCTAssertTrue(s.skin, "★ Finish Skin is core's Finish Skin (S3)")
        XCTAssertEqual(s.coverMM, 0, "★ Skin is not Covered")
        p.lattice.boundary = .covered
        s = LatticeLayoutPreview.settings(p)
        XCTAssertLessThan(s.coverMM, 0, "★ Covered is core's cover (S9)")
        XCTAssertFalse(s.skin)
        p.lattice.boundary = .rim
        s = LatticeLayoutPreview.settings(p)
        XCTAssertLessThan(s.rimMM, 0, "Rim is core's rim")
        XCTAssertFalse(s.skin)
        XCTAssertEqual(s.coverMM, 0)
        p.lattice.boundary = .none
        s = LatticeLayoutPreview.settings(p)
        XCTAssertEqual([s.rimMM, s.coverMM], [0, 0])
        XCTAssertFalse(s.skin)

        p.lattice.algorithm = "stepped"
        p.lattice.gradingMode = .fitShape
        p.lattice.shapeFitBandMM = 6
        p.lattice.shapeFitGradeStrength = 0.5
        s = LatticeLayoutPreview.settings(p)
        XCTAssertTrue(s.gradeToShape, "★ Grade to shape reaches core")
        XCTAssertEqual(s.bandMM, 6, "★ with its band")
        XCTAssertEqual(s.strength, 0.5, "★ and its Strength")
        p.lattice.gradingMode = .stressOnly
        s = LatticeLayoutPreview.settings(p)
        XCTAssertFalse(s.gradeToShape, "stress only: no shape grade")
        XCTAssertEqual(s.bandMM, 0)
    }

    /// ★ 11-13: a Protect skin group is a Protect skin at its rows' depth (D5), not a No lattice region; Whole part lattices the
    /// whole part even with face rows set.
    func testProtectSkinAndWholePartReachTheEngine() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        _ = try FlexibleR7M1Fixtures.hisLiveLattice(p)
        let g = try XCTUnwrap(p.latticeGroups.first { p.lattice.groupRoles[$0.id] == .include && !p.latticeSelectableRefs($0).isEmpty },
                              "premise: a Lattice group with face rows")
        let faces = Set(p.latticeSelectableRefs(g).flatMap { ref -> [Int32] in
            if case let .face(_, f) = ref { return [Int32(f)] }
            return []
        })
        XCTAssertFalse(faces.isEmpty, "premise: its face rows")
        p.lattice.skinGroups.insert(g.id)
        p.lattice.groupRoles[g.id] = .exclude   // as the page stores a Protect skin
        let s = LatticeLayoutPreview.settings(p)
        XCTAssertEqual(Set(s.protect.flatMap(\.faces)), faces, "★ its faces are a Protect skin")
        XCTAssertTrue(s.regions.allSatisfy { Set($0.faces).isDisjoint(with: faces) }, "★ and not a No lattice region")
        XCTAssertTrue(!s.protect.isEmpty && s.protect.allSatisfy { $0.depthMM > 0.5 }, "★ at its rows' depth, not 0")
        p.lattice.skinGroups.remove(g.id)
        p.lattice.groupRoles[g.id] = .include
        XCTAssertFalse(LatticeLayoutPreview.settings(p).allLattice, "premise: face rows ask for lattice")
        p.lattice.wholePart = true
        XCTAssertTrue(LatticeLayoutPreview.settings(p).allLattice, "★ Whole part: the whole part is lattice")
    }

    /// ★ 11-13 round 2 (LatticeReview's answers): cells across a wall by mode (C3-C5), and the page's density as core's dial
    /// (R10: the percent he sees / 100).
    func testCellsAcrossAndDensityReachTheEngine() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        _ = try FlexibleR7M1Fixtures.hisLiveLattice(p)
        p.lattice.stageMode = .structural
        XCTAssertEqual(LatticeLayoutPreview.settings(p).minCellsAcross, 5, "★ Structural: five cells across a wall (C5)")
        p.lattice.stageMode = .aesthetic
        p.lattice.singleCellMembers = true
        XCTAssertEqual(LatticeLayoutPreview.settings(p).minCellsAcross, 1, "★ Aesthetic with single-cell members: one (C4)")
        p.lattice.singleCellMembers = false
        XCTAssertEqual(LatticeLayoutPreview.settings(p).minCellsAcross, 2, "★ Aesthetic: two (C3)")
        let pick = p.latticeGroups.flatMap { g in p.latticeSelectableRefs(g).map { (g, $0) } }
            .first { p.latticeSelectableRole($0.1, in: $0.0.id) == .include }
        let (g, ref) = try XCTUnwrap(pick, "premise: a Lattice row")
        p.lattice.densityMode = .perRegion
        p.writeLatticeDensity(ref, fraction: 0.2, cellMM: 8)   // the page's own write
        XCTAssertNotNil(p.latticeSelectableDensity(ref, in: g.id), "premise: the row has a density")
        XCTAssertNotNil(p.latticeDensityPercent(rho: 0.2, cellMM: 8), "premise: the page shows a percent for it")
        let s = LatticeLayoutPreview.settings(p)
        XCTAssertTrue(s.perRegion, "★ per-row density")
        XCTAssertFalse(s.regionDials.isEmpty, "★ the rows' densities reach core as dials")
        XCTAssertTrue(s.regionDials.allSatisfy { $0.dial >= 0.01 && $0.dial <= 1 }, "★ on core's 0.01 ... 1 scale")
    }

    /// ★ 11-13 round 2: Small cells in thin walls is saved with the part (off is not written) and reaches core; Organic keeps the old
    /// preview with one plain line; By stress gets one plain line.
    func testSmallCellsOrganicAndByStress() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        var l = p.lattice
        let off = String(decoding: try JSONEncoder().encode(l), as: UTF8.self)
        XCTAssertFalse(off.contains("smallCellsInThinWalls"), "★ off is not written: older bytes unchanged")
        l.smallCellsInThinWalls = true
        XCTAssertTrue(try JSONDecoder().decode(LatticeSettings.self, from: JSONEncoder().encode(l)).smallCellsInThinWalls, "★ saved")
        p.lattice.smallCellsInThinWalls = true
        XCTAssertTrue(LatticeLayoutPreview.settings(p).smallCellsInThinWalls, "★ reaches core")
        l.algorithm = "organic"
        XCTAssertFalse(LatticeLayoutPreview.draws(l), "★ Organic: the new engine does not draw it")
        l.algorithm = "stepped"
        XCTAssertTrue(LatticeLayoutPreview.draws(l))
        l.densityMode = .sim
        XCTAssertEqual(LatticeLayoutPreview.note(l), LatticeLayoutPreview.byStressLine, "★ By stress: said in one line")
    }

    /// ★ 11-13: skins of one depth go as one (his v4 stand: 26 skins of 4 mm, 289 s → 0.7 s on the Mac, the same lattice).
    func testProtectSkinsOfOneDepthGoAsOne() {
        let merged = LatticeLayoutPreview.mergedByDepth([.init(id: 1, faces: [1, 2], depthMM: 4), .init(id: 2, faces: [3, 2], depthMM: 4),
                                                         .init(id: 3, faces: [4], depthMM: 1)])
        XCTAssertEqual(merged.count, 2, "★ one skin per depth")
        XCTAssertEqual(merged[0].faces, [1, 2, 3], "★ every face of that depth, once")
        XCTAssertEqual(merged[0].depthMM, 4)
        XCTAssertEqual(merged[1].faces, [4])
        XCTAssertEqual(merged[1].depthMM, 1, "a different depth stays its own skin")
    }

    /// ★ 11-13: the cell window is the one the page RESOLVES (as the old engine's job): never a number its mode does not show.
    func testTheCellWindowIsThePagesResolvedOne() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        _ = try FlexibleR7M1Fixtures.hisLiveLattice(p)
        p.lattice.cellSizeMode = .auto
        p.lattice.cellMinMM = 0.5
        p.lattice.cellMaxMM = 99   // a stored number Auto does not show
        let b = LatticeBounds.compute(settings: p.lattice, limits: TopOptKit.latticeLimits(topology: p.lattice.topologyID),
                                      lineWidthMM: p.printParams.strutLineWidthMM)
        let plan = p.lattice.resolvedCellPlan(bounds: b, minimizePlastic: false)
        let s = LatticeLayoutPreview.settings(p)
        XCTAssertNotEqual(s.cellMaxMM, 99, "★ Auto never sends the stored max it does not show")
        XCTAssertEqual(s.cellMaxMM, plan.hiMM, accuracy: 1e-9, "★ Auto sends its own range's top")
        XCTAssertEqual(s.cellMinMM, plan.loMM, accuracy: 1e-9, "★ and its floor")
    }

    /// ★ 11-14: a flat bridge (core's bar_flags bit 16) is drawn SQUARE, as the print writes it (RED CONTROL: unflagged, round).
    func testAFlatBridgeIsDrawnSquare() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let r = MeshRenderer(device: device, sampleCount: 1) else {
            throw XCTSkip("no renderer: \(MeshRenderer.lastInitError ?? "?")")
        }
        XCTAssertEqual(LatticeLayoutBarsPass.pack([0, 0, 0, 1, 0, 0, 1], flags: [16])[1].w, 16, "the flag rides in the bar's buffer")
        r.setMesh(Self.cubeMesh(20))
        r.camera.setOrientation(azimuth: 0.6, elevation: 0.5)
        r.setBodyAlpha(0.2)
        let bar: [Float] = [-8, 0, 14, 8, 0, 14, 3]   // level, above the cube
        let clear = MTLClearColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)
        XCTAssertTrue(r.applyLayoutBars(.init(token: 1, bars: bar), device: device))
        let round = try XCTUnwrap(r.renderOffscreen(width: 320, height: 240, clear: clear, stage: false))
        XCTAssertTrue(r.applyLayoutBars(.init(token: 2, bars: bar, flags: [16]), device: device))
        let square = try XCTUnwrap(r.renderOffscreen(width: 320, height: 240, clear: clear, stage: false))
        let changed = zip(round, square).filter { $0 != $1 }.count / 4
        print("NEW-ENGINE square bridge: \(changed) pixels differ from the round bar")
        XCTAssertGreaterThan(changed, 150, "★ the flagged bar is drawn square")
    }

    // MARK: fixtures

    /// `n` bars on a grid: a 0.8 mm bar along x from each point.
    static func grid(_ n: Int, pitch: Float = 1, from: Float = 0) -> [Float] {
        var out = [Float]()
        out.reserveCapacity(7 * n)
        let side = Int(ceil(cbrt(Double(n))))
        for i in 0..<n {
            let x = from + Float(i % side) * pitch, y = from + Float(i / side % side) * pitch, z = from + Float(i / (side * side)) * pitch
            out += [x, y, z, x + 0.8 * pitch, y, z, 0.25 * pitch]
        }
        return out
    }

    /// A closed cube of side `s`, centred on the origin, one face id per side.
    static func cubeMesh(_ s: Float) -> ViewerMesh {
        let h = s / 2
        let c: [SIMD3<Float>] = [[-h, -h, -h], [h, -h, -h], [h, h, -h], [-h, h, -h], [-h, -h, h], [h, -h, h], [h, h, h], [-h, h, h]]
        let quads: [[Int]] = [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4], [2, 3, 7, 6], [1, 2, 6, 5], [0, 4, 7, 3]]
        var v: [Float] = [], idx: [Int32] = [], fid: [Int32] = []
        for (f, q) in quads.enumerated() {
            let base = Int32(v.count / 3)
            for k in q { v += [c[k].x, c[k].y, c[k].z] }
            idx += [base, base + 1, base + 2, base, base + 2, base + 3]
            fid += [Int32(f), Int32(f)]
        }
        return ViewerMesh(vertices: v, indices: idx, faceIDs: fid, faceGeometry: [])
    }
}
#endif
